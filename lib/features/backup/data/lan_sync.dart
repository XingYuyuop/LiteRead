import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart' hide isNull;

import '../../../core/storage/app_database.dart';
import '../../library/data/book_repository.dart';
import 'remote_store.dart';

/// 局域网同步服务端口（发现 UDP 与 HTTP 服务共用同一端口段约定）
const lanSyncPort = 47816;

/// WiFi 传书统计（浏览器上传进度），UI 通过 ValueNotifier 监听
class LanTransferStats {
  const LanTransferStats({this.received = 0, this.lastTitle});

  /// 本次开启以来已接收书籍数（含重复）
  final int received;

  /// 最近一次接收的书名
  final String? lastTitle;
}

/// 本机局域网 IPv4 地址（排除回环与虚拟网卡），用于展示传书网址
Future<List<String>> localIPv4Addresses() async {
  final out = <String>[];
  try {
    for (final ni in await NetworkInterface.list()) {
      final n = ni.name.toLowerCase();
      final virtual =
          n.contains('vethernet') ||
          n.contains('virtualbox') ||
          n.contains('vmware') ||
          n.contains('loopback') ||
          n.contains('wsl') ||
          n.contains('tap') ||
          n.contains('tun') ||
          n.contains('hamachi') ||
          n.contains('hyper-v');
      if (virtual) continue;
      for (final a in ni.addresses) {
        if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
          out.add(a.address);
        }
      }
    }
  } catch (_) {}
  return out;
}

/// 局域网设备信息
class LanDevice {
  const LanDevice({
    required this.address,
    required this.port,
    required this.name,
  });

  final String address;
  final int port;
  final String name;
}

/// 局域网同步服务端：开放 HTTP 端口，供其他 LiteRead 设备扫描/拉取/推送。
///
/// 端点（均限定本应用）：
/// - GET  /             → WiFi 传书网页（PC 浏览器上传书籍）
/// - GET  /api/ping      → {"app","name","port"}
/// - GET  /api/manifest  → 备份清单（设置+书籍清单）
/// - GET  /api/list?path=book|progress|covers|'' → 文件相对路径列表
/// - GET  /api/file?path=`book/<id>.<ext>` 等 → 文件内容
/// - POST /api/upload?name=<文件名> → WiFi 传书上传（原始字节流）
/// - POST /api/register  → 注册书籍元数据行（body: 清单书籍条目 JSON）
/// - POST /api/file?path=... → 上传文件内容
class LanSyncServer {
  LanSyncServer(this._repo, this._db);

  final BookRepository _repo;
  final AppDatabase _db;

  HttpServer? _server;
  RawDatagramSocket? _udp;

  /// WiFi 传书状态（浏览器每上传一本更新一次）
  final transferStats = ValueNotifier<LanTransferStats>(
    const LanTransferStats(),
  );

  bool get running => _server != null;

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    if (running) return;
    // HTTP：优先固定端口，被占用则向后重试几个
    HttpServer? server;
    Object? lastError;
    for (var p = lanSyncPort; p < lanSyncPort + 10; p++) {
      try {
        server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          p,
          shared: true,
        );
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (server == null) {
      throw Exception('无法开放局域网同步端口：$lastError');
    }
    _server = server;
    server.listen(_handleRequest, onError: (_) {});

    // UDP 发现应答
    try {
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        lanSyncPort,
        reuseAddress: true,
      );
      _udp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _udp!.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true);
        if (msg != 'LITEREAD_DISCOVER') return;
        final reply = utf8.encode(
          jsonEncode({'app': 'literead', 'name': _deviceName(), 'port': port}),
        );
        _udp!.send(reply, dg.address, dg.port);
      });
    } catch (_) {
      // UDP 不可用时仍可 TCP 扫描
    }
  }

  Future<void> stop() async {
    _server?.close(force: true);
    _server = null;
    _udp?.close();
    _udp = null;
  }

  String _deviceName() {
    try {
      final name = Platform.localHostname;
      return name.isEmpty ? 'LiteRead' : name;
    } catch (_) {
      return 'LiteRead';
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/' || path == '/index.html') {
        // WiFi 传书网页（PC/手机浏览器直接访问）
        req.response.headers.contentType = ContentType.html;
        req.response.add(utf8.encode(_uploadPageHtml));
        await req.response.close();
        return;
      }
      if (path == '/api/upload' && req.method == 'POST') {
        await _handleUpload(req);
        return;
      }
      if (path == '/api/ping') {
        await _json(req, {
          'app': 'literead',
          'name': _deviceName(),
          'port': port,
        });
        return;
      }
      if (path == '/api/manifest') {
        final manifest = await _buildLocalManifest();
        await _json(req, manifest);
        return;
      }
      if (path == '/api/list') {
        final dir = req.uri.queryParameters['path'] ?? '';
        await _json(req, await _listFiles(dir));
        return;
      }
      if (path == '/api/file' && req.method == 'GET') {
        final fp = req.uri.queryParameters['path'] ?? '';
        final data = await _readFile(fp);
        if (data == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        req.response.add(data);
        await req.response.close();
        return;
      }
      if (path == '/api/file' && req.method == 'POST') {
        final fp = req.uri.queryParameters['path'] ?? '';
        final bytes = await _readBody(req);
        await _writeFile(fp, bytes);
        await _json(req, {'ok': true});
        return;
      }
      if (path == '/api/register' && req.method == 'POST') {
        final bytes = await _readBody(req);
        final entry = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        await _registerBook(entry);
        await _json(req, {'ok': true});
        return;
      }
      if (path == '/api/delete-book' && req.method == 'POST') {
        // 远端删除确认：删除对端指定书籍（记录 + 文件 + 进度/标注）
        final bytes = await _readBody(req);
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final id = body['id'] as String?;
        if (id == null || id.length != 64) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        await _repo.deleteBook(id, deleteManagedFile: true);
        await _json(req, {'ok': true});
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// WiFi 传书上传：原始字节流 → 临时文件 → 走标准导入管线
  /// （流式哈希去重 / 解析 / 托管副本 / 封面 / 入库）
  Future<void> _handleUpload(HttpRequest req) async {
    final name = req.uri.queryParameters['name'] ?? 'book.bin';
    // 文件名安全化：仅保留基础名，防路径穿越
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final ext = safeName.contains('.')
        ? safeName.split('.').last.toLowerCase()
        : '';
    const supported = {'epub', 'txt', 'mobi', 'azw3', 'pdf', 'fb2', 'cbz'};
    if (!supported.contains(ext)) {
      await _json(req, {'ok': false, 'error': '不支持的格式：$ext'});
      return;
    }
    final tmpDir = await Directory.systemTemp.createTemp('literead_up');
    final tmp = File(
      '${tmpDir.path}${Platform.pathSeparator}up.$ext',
    );
    try {
      final sink = tmp.openWrite();
      await req.cast<List<int>>().pipe(sink);
      final outcome = await _repo.importFile(tmp.path);
      final stats = transferStats.value;
      transferStats.value = LanTransferStats(
        received: stats.received + 1,
        lastTitle: outcome.book.title,
      );
      await _json(req, {
        'ok': true,
        'title': outcome.book.title,
        'duplicated': outcome.duplicated,
      });
    } catch (e) {
      await _json(req, {'ok': false, 'error': e.toString()});
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 本机清单：设置 + 书籍清单（实时生成）
  Future<Map<String, dynamic>> _buildLocalManifest() async {
    final books = await _repo.listBooks();
    final settings = await _repo.allSettings();
    final list = <Map<String, dynamic>>[];
    for (final b in books) {
      Map<String, dynamic> meta = const {};
      try {
        if (b.metaJson != null) {
          meta = jsonDecode(b.metaJson!) as Map<String, dynamic>;
        }
      } catch (_) {}
      list.add({
        'id': b.id,
        'title': b.title,
        'author': b.author,
        'language': b.language,
        'format': b.format,
        'fileSize': b.fileSize,
        'groupName': b.groupName,
        'addedAt': b.addedAt,
        'metaJson': b.metaJson,
        'hasCover': b.coverPath != null,
        if (meta['description'] != null) 'description': meta['description'],
      });
    }
    return {
      'app': 'literead',
      'formatVersion': 1,
      'deviceName': _deviceName(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'settings': settings,
      'books': list,
    };
  }

  /// 列出指定目录（相对路径映射到本机书库/进度/封面）
  Future<List<String>> _listFiles(String dir) async {
    switch (dir) {
      case 'book':
        final lib = await AppDirs.library();
        if (!await lib.exists()) return const [];
        final out = <String>[];
        await for (final e in lib.list()) {
          if (e is File) out.add('book/${e.uri.pathSegments.last}');
        }
        return out;
      case 'progress':
        final rows = await _repo.allProgressRows();
        return [for (final r in rows) 'progress/${r.bookId}.json'];
      case 'covers':
        final cov = await AppDirs.covers();
        if (!await cov.exists()) return const [];
        final out = <String>[];
        await for (final e in cov.list()) {
          if (e is File) out.add('covers/${e.uri.pathSegments.last}');
        }
        return out;
      case '':
        return ['manifest.json'];
      default:
        return const [];
    }
  }

  /// 读取文件（白名单路径；progress 读取进度表；manifest 实时生成）
  Future<List<int>?> _readFile(String fp) async {
    if (fp == 'manifest.json') {
      return utf8.encode(jsonEncode(await _buildLocalManifest()));
    }
    if (fp.startsWith('/') || fp.contains('..')) return null;
    if (fp.startsWith('book/')) {
      final name = fp.substring(5);
      if (!RegExp(r'^[0-9a-f]{64}\.[A-Za-z0-9]+$').hasMatch(name)) return null;
      final lib = await AppDirs.library();
      final f = File('${lib.path}${Platform.pathSeparator}$name');
      if (!await f.exists()) return null;
      return f.readAsBytes();
    }
    if (fp.startsWith('covers/')) {
      final name = fp.substring(7);
      if (!RegExp(r'^[0-9a-f]{64}\.img$').hasMatch(name)) return null;
      final cov = await AppDirs.covers();
      final f = File('${cov.path}${Platform.pathSeparator}$name');
      if (!await f.exists()) return null;
      return f.readAsBytes();
    }
    if (fp.startsWith('progress/')) {
      final bookId = fp.substring(9, fp.length - 5);
      if (bookId.length != 64) return null;
      final row = await (_db.select(
        _db.progress,
      )..where((t) => t.bookId.equals(bookId))).getSingleOrNull();
      if (row == null) return null;
      return utf8.encode(
        jsonEncode({
          'bookId': row.bookId,
          'locatorJson': row.locatorJson,
          'percent': row.percent,
          'updatedAt': row.updatedAt,
          'deviceId': row.deviceId,
        }),
      );
    }
    return null;
  }

  /// 写入文件（上传书籍/封面到托管目录；progress 走进度表）
  Future<void> _writeFile(String fp, List<int> bytes) async {
    if (fp.startsWith('/') || fp.contains('..')) return;
    if (fp.startsWith('book/')) {
      final name = fp.substring(5);
      if (!RegExp(r'^[0-9a-f]{64}\.[A-Za-z0-9]+$').hasMatch(name)) return;
      final lib = await AppDirs.library();
      final f = File('${lib.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(bytes, flush: true);
      return;
    }
    if (fp.startsWith('covers/')) {
      final name = fp.substring(7);
      if (!RegExp(r'^[0-9a-f]{64}\.img$').hasMatch(name)) return;
      final cov = await AppDirs.covers();
      final f = File('${cov.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(bytes, flush: true);
      return;
    }
    if (fp.startsWith('progress/') && fp.endsWith('.json')) {
      final bookId = fp.substring(9, fp.length - 5);
      try {
        final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        await _repo.restoreProgress(
          bookId,
          j['locatorJson'] as String? ?? '{}',
          (j['percent'] as num?)?.toDouble() ?? 0,
          j['updatedAt'] as int? ?? 0,
          deviceId: j['deviceId'] as String? ?? 'remote',
        );
      } catch (_) {}
      return;
    }
  }

  /// 注册书籍元数据行（推送书籍前先注册）
  Future<void> _registerBook(Map<String, dynamic> entry) async {
    final id = entry['id'] as String?;
    if (id == null || id.length != 64) return;
    final format = entry['format'] as String? ?? 'TXT';
    final libDir = await AppDirs.library();
    final managedPath =
        '${libDir.path}${Platform.pathSeparator}$id.${format.toLowerCase()}';
    await _repo.upsertBookRow(
      BooksCompanion.insert(
        id: id,
        title: entry['title'] as String? ?? '未命名',
        format: format,
        filePath: managedPath,
        addedAt:
            entry['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ).copyWith(
        author: Value(entry['author'] as String?),
        language: Value(entry['language'] as String?),
        fileSize: Value(entry['fileSize'] as int?),
        metaJson: Value(entry['metaJson'] as String?),
        groupName: Value(() {
          final g = entry['groupName'] as String?;
          return (g == null || g.isEmpty) ? null : g;
        }()),
      ),
    );
  }

  Future<List<int>> _readBody(HttpRequest req) async =>
      req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));

  Future<void> _json(HttpRequest req, Object data) async {
    req.response.headers.contentType = ContentType.json;
    req.response.add(utf8.encode(jsonEncode(data)));
    await req.response.close();
  }
}

/// WiFi 传书网页：PC 浏览器访问 `http://<设备IP>:<端口>` 直接上传书籍。
/// 上传用 XHR 原始字节流（POST /api/upload?name=），可读进度百分比。
/// 支持拖入上传：文件拖到页面任意位置即可发送，也可点击选择文件。
const _uploadPageHtml = r'''<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LiteRead · WiFi 传书</title>
<style>
:root{--acc:#FF7A1A;--bg:#F6F6F4;--card:#FFFFFF;--tx:#26221E;--sub:#8A8378}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);font-family:-apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;color:var(--tx);
min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:var(--card);border-radius:20px;box-shadow:0 8px 32px rgba(0,0,0,.08);
padding:36px 32px;width:100%;max-width:420px;text-align:center}
h1{font-size:20px;margin-bottom:4px}
.wifi{width:64px;height:64px;margin:18px auto 10px;border-radius:50%;background:#FFF3E8;
display:flex;align-items:center;justify-content:center}
.tip{color:var(--sub);font-size:13px;line-height:1.7;margin:14px 0 18px}
#pick{display:none}
#drop{margin-top:16px;border:2px dashed #E3DDD2;border-radius:14px;padding:26px 16px;
cursor:pointer;transition:border-color .15s,background .15s;background:#FCFBF9}
#drop .big{font-size:15px;font-weight:600;margin-top:10px}
#drop .small{color:var(--sub);font-size:12px;margin-top:5px}
#drop.on{border-color:var(--acc);background:#FFF6EE}
#drop.on .big{color:var(--acc)}
ul{list-style:none;margin-top:18px;text-align:left;max-height:220px;overflow:auto}
li{padding:8px 2px;font-size:13px;border-bottom:1px solid #F0EDE8;display:flex;justify-content:space-between;gap:8px}
li .st{color:var(--sub);white-space:nowrap}
li .st.ok{color:#2AA952}.st.dup{color:var(--acc)}.st.err{color:#D93025}
.bar{height:3px;background:#F0EDE8;border-radius:2px;margin-top:6px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--acc);width:0}
</style></head><body>
<div class="card">
  <h1>WiFi 传书</h1>
  <div class="wifi">
    <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="#FF7A1A" stroke-width="2" stroke-linecap="round">
      <path d="M2.5 8.5a15 15 0 0 1 19 0"/><path d="M5.5 12a11 11 0 0 1 13 0"/>
      <path d="M8.5 15.5a7 7 0 0 1 7 0"/><circle cx="12" cy="19" r="1.4" fill="#FF7A1A" stroke="none"/>
    </svg>
  </div>
  <div style="font-size:14px">选择书籍文件，通过局域网发送到本设备</div>
  <p class="tip">支持 EPUB / TXT / MOBI / AZW3 / PDF / FB2 / CBZ<br>发送后书籍会自动出现在书架中</p>
  <div id="drop">
    <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="#8A8378" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 15V4"/><path d="m8 8 4-4 4 4"/>
      <path d="M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/>
    </svg>
    <div class="big">拖入文件上传</div>
    <div class="small">或点击选择文件（可多选）</div>
  </div>
  <input type="file" id="pick" multiple accept=".epub,.txt,.mobi,.azw3,.pdf,.fb2,.cbz">
  <ul id="list"></ul>
</div>
<script>
const pick=document.getElementById('pick'),drop=document.getElementById('drop'),list=document.getElementById('list');
drop.onclick=()=>pick.click();
pick.onchange=()=>{for(const f of pick.files)send(f);pick.value='';};
// 拖入上传：整个页面均为放置目标
let dragDepth=0;
window.addEventListener('dragenter',e=>{e.preventDefault();dragDepth++;drop.classList.add('on');});
window.addEventListener('dragover',e=>{e.preventDefault();});
window.addEventListener('dragleave',e=>{e.preventDefault();if(--dragDepth<=0){dragDepth=0;drop.classList.remove('on');}});
window.addEventListener('drop',e=>{
  e.preventDefault();dragDepth=0;drop.classList.remove('on');
  for(const f of e.dataTransfer.files)send(f);
});
function send(f){
  const li=document.createElement('li');
  li.innerHTML='<span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span><span class="st">0%</span><div class="bar" style="position:absolute"></div>';
  const nameEl=li.firstChild,stEl=li.querySelector('.st');
  nameEl.textContent=f.name;
  const bar=document.createElement('div');bar.className='bar';bar.innerHTML='<i></i>';
  li.appendChild(bar);list.prepend(li);
  const fill=bar.firstChild;
  const xhr=new XMLHttpRequest();
  xhr.open('POST','/api/upload?name='+encodeURIComponent(f.name));
  xhr.setRequestHeader('Content-Type','application/octet-stream');
  xhr.upload.onprogress=e=>{if(e.lengthComputable){const p=Math.round(e.loaded/e.total*100);
    stEl.textContent=p+'%';fill.style.width=p+'%';}};
  xhr.onload=()=>{
    fill.style.width='100%';bar.remove();
    try{const r=JSON.parse(xhr.responseText);
      if(r.ok){stEl.textContent=r.duplicated?'书架已有':'已接收';stEl.className='st '+(r.duplicated?'dup':'ok');}
      else{stEl.textContent=r.error||'失败';stEl.className='st err';}
    }catch(_){stEl.textContent='失败';stEl.className='st err';}
  };
  xhr.onerror=()=>{stEl.textContent='网络错误';stEl.className='st err';bar.remove();};
  xhr.send(f);
}
</script>
</body></html>''';

/// 局域网设备扫描：优先 UDP 广播发现，失败时回退 TCP 端口扫描本网段
class LanScanner {
  /// 扫描局域网设备（约 3 秒超时）
  static Future<List<LanDevice>> scan() async {
    final devices = <String, LanDevice>{};
    final udp = await _udpScan();
    for (final d in udp) {
      devices['${d.address}:${d.port}'] = d;
    }
    if (devices.isEmpty) {
      final tcp = await _tcpScan();
      for (final d in tcp) {
        devices['${d.address}:${d.port}'] = d;
      }
    }
    return devices.values.toList();
  }

  /// 本机全部 IPv4 地址（含回环）：扫描结果中据此过滤自身，
  /// 避免广播环回导致本机以多个 IP 出现在设备列表
  static Future<Set<String>> _localIPv4s() async {
    final out = <String>{'127.0.0.1'};
    try {
      for (final ni in await NetworkInterface.list()) {
        for (final a in ni.addresses) {
          if (a.type == InternetAddressType.IPv4) out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  /// 是否虚拟/回环网卡（WSL、虚拟机、VPN TAP 等，子网内不会有同步设备）
  static bool _isVirtualInterface(String name) {
    final n = name.toLowerCase();
    return n.contains('vethernet') ||
        n.contains('virtualbox') ||
        n.contains('vmware') ||
        n.contains('loopback') ||
        n.contains('wsl') ||
        n.contains('tap') ||
        n.contains('tun') ||
        n.contains('hamachi') ||
        n.contains('hyper-v');
  }

  /// UDP 广播发现
  static Future<List<LanDevice>> _udpScan() async {
    final out = <LanDevice>[];
    final localIps = await _localIPv4s();
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      // 本机所有网段的广播地址
      final addrs = <String>{'255.255.255.255'};
      for (final ni in await NetworkInterface.list()) {
        if (_isVirtualInterface(ni.name)) continue;
        for (final a in ni.addresses) {
          if (a.type != InternetAddressType.IPv4) continue;
          final parts = a.address.split('.');
          if (parts.length != 4) continue;
          addrs.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      final packet = utf8.encode('LITEREAD_DISCOVER');
      for (final addr in addrs) {
        socket.send(packet, InternetAddress(addr), lanSyncPort);
      }
      final completer = Completer<void>();
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        // 过滤自身应答（广播环回）
        if (localIps.contains(dg.address.address)) return;
        try {
          final j =
              jsonDecode(utf8.decode(dg.data, allowMalformed: true))
                  as Map<String, dynamic>;
          if (j['app'] == 'literead') {
            out.add(
              LanDevice(
                address: dg.address.address,
                port: j['port'] as int? ?? lanSyncPort,
                name: j['name'] as String? ?? '未知设备',
              ),
            );
          }
        } catch (_) {}
      });
      await completer.future.timeout(
        const Duration(milliseconds: 2500),
        onTimeout: () {},
      );
      sub.cancel();
    } catch (_) {
      // UDP 广播被防火墙拦截时回退 TCP 扫描
    } finally {
      socket?.close();
    }
    return out;
  }

  /// TCP 逐 IP 端口扫描本机所在 /24 网段（回退方案）
  static Future<List<LanDevice>> _tcpScan() async {
    final out = <LanDevice>[];
    final localIps = await _localIPv4s();

    // 收集全部物理网卡的 /24 网段前缀（排除虚拟网卡，网段去重）
    final prefixes = <String>{};
    try {
      for (final ni in await NetworkInterface.list()) {
        if (_isVirtualInterface(ni.name)) continue;
        for (final a in ni.addresses) {
          if (a.type != InternetAddressType.IPv4 || a.isLoopback) continue;
          final parts = a.address.split('.');
          if (parts.length != 4) continue;
          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    } catch (_) {}
    if (prefixes.isEmpty) return out;

    final candidates = <String>[
      for (final prefix in prefixes)
        for (var i = 1; i <= 254; i++)
          if (!localIps.contains('$prefix.$i')) '$prefix.$i',
    ];

    var index = 0;
    Future<void> worker() async {
      while (index < candidates.length) {
        final ip = candidates[index++];
        final name = await _probe(ip);
        if (name != null) {
          out.add(LanDevice(address: ip, port: lanSyncPort, name: name));
        }
      }
    }

    await Future.wait([for (var i = 0; i < 64; i++) worker()]);
    return out;
  }

  /// 探测单台设备：TCP 连上且 /api/ping 返回 literead 才算命中
  static Future<String?> _probe(String ip) async {
    try {
      final socket = await Socket.connect(
        ip,
        lanSyncPort,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      final name = await LanStorePing.ping(ip, lanSyncPort);
      return name;
    } catch (_) {
      return null;
    }
  }
}

/// 独立的 ping 工具（避免与 LanStore 依赖循环）
class LanStorePing {
  static Future<String?> ping(String host, int port) =>
      LanStore.ping(host, port);
}
