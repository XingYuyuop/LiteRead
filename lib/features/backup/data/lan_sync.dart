import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart' hide isNull;

import '../../../core/storage/app_database.dart';
import '../../library/data/book_repository.dart';
import 'lan_discovery.dart';

export 'lan_discovery.dart'
    show
        lanSyncPort,
        localIPv4Addresses,
        allLocalIPv4s,
        LanDevice,
        LanScanner,
        LanStorePing,
        lanConnectErrorText;

/// WiFi 传书统计（浏览器上传进度），UI 通过 ValueNotifier 监听
class LanTransferStats {
  const LanTransferStats({this.received = 0, this.lastTitle});

  /// 本次开启以来已接收书籍数（含重复）
  final int received;

  /// 最近一次接收的书名
  final String? lastTitle;
}

/// 对端推送来的同步进度（本机作为接收方展示，双方进度可见）
class LanSyncProgress {
  const LanSyncProgress({
    required this.phase,
    required this.done,
    required this.total,
    this.finished = false,
  });

  final String phase;
  final int done;
  final int total;
  final bool finished;

  double get value => total > 0 ? (done / total).clamp(0.0, 1.0) : 0;
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

  /// beacon 广播定时器：每 2 秒主动广播本机信息（发现不依赖应答回包，
  /// 与验证过可行的对等 beacon 模式一致：双方绑定同一 UDP 端口互相收听）
  Timer? _beaconTimer;

  /// 本机共享服务的被动发现结果：对端 beacon 持续到达时设备列表实时更新，
  /// 15 秒无 beacon 自动过期移除
  final discovered = ValueNotifier<List<LanDevice>>(const []);
  final _discoveredMap = <String, (LanDevice, DateTime)>{};

  /// WiFi 传书状态（浏览器每上传一本更新一次）
  final transferStats = ValueNotifier<LanTransferStats>(
    const LanTransferStats(),
  );

  /// 对端同步进度（对端推送 /api/sync-progress 更新；超时自动清除）
  final syncProgress = ValueNotifier<LanSyncProgress?>(null);
  Timer? _progressExpire;

  /// 收到对端进度：finished 时 3 秒后清除，否则 15 秒无更新自动清除
  void _updateSyncProgress(LanSyncProgress p) {
    _progressExpire?.cancel();
    syncProgress.value = p;
    if (p.finished) {
      _progressExpire = Timer(const Duration(seconds: 3), () {
        syncProgress.value = null;
      });
    } else {
      _progressExpire = Timer(const Duration(seconds: 15), () {
        syncProgress.value = null;
      });
    }
  }

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

    // UDP 发现：应答 DISCOVER + 周期 beacon 广播 + 收听对端 beacon
    try {
      // 本机地址集在启动时取一次即可（服务运行期间网卡通常不变）
      final localAddrs = (await allLocalIPv4s()).toList();
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        lanSyncPort,
        reuseAddress: true,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _udp!.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true);
        if (msg == 'LITEREAD_DISCOVER') {
          final reply = utf8.encode(
            jsonEncode({
              'app': 'literead',
              'name': _deviceName(),
              'port': port,
              'addrs': localAddrs,
            }),
          );
          _udp!.send(reply, dg.address, dg.port);
          return;
        }
        // 对端 beacon（对端共享服务周期广播）：被动收听即发现设备。
        // beacon 为单向广播，无需回包——回包路径（防火墙/路由）不再影响发现。
        try {
          final j =
              jsonDecode(msg) as Map<String, dynamic>;
          if (j['app'] != 'literead') return;
          _recordDiscovered(
            dg.address.address,
            j,
            localAddrs.toSet(),
          );
        } catch (_) {}
      });
      // beacon 广播：每 2 秒一轮（对端被动收听本机 47816 即可发现本机）
      _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _sendBeacon(localAddrs);
      });
      // 立即广播首轮，对端无需等满一个周期
      _sendBeacon(localAddrs);
    } catch (_) {
      // UDP 不可用时仍可 TCP 扫描
    }
  }

  /// 发送本机 beacon 广播（受限广播 + 各网卡定向广播）
  void _sendBeacon(List<String> localAddrs) {
    final udp = _udp;
    if (udp == null) return;
    final packet = utf8.encode(
      jsonEncode({
        'app': 'literead',
        'name': _deviceName(),
        'port': port,
        'addrs': localAddrs,
      }),
    );
    unawaited(
      broadcastAddresses().then((targets) {
        for (final t in targets) {
          try {
            udp.send(packet, InternetAddress(t), lanSyncPort);
          } catch (_) {}
        }
      }),
    );
  }

  /// 记录 beacon 发现的设备（自过滤 + 去重 + 过期清理）
  void _recordDiscovered(
    String sourceIp,
    Map<String, dynamic> j,
    Set<String> localAddrs,
  ) {
    // 源地址是本机地址 → 自身广播回环（理论不发生，防御）
    if (localAddrs.contains(sourceIp)) return;
    // 对端上报的任一地址与本机地址有交集 → 是自身（多网卡/热点场景）
    final reported = <String>{
      for (final a in (j['addrs'] as List<dynamic>? ?? const [])) a as String,
    };
    if (reported.any(localAddrs.contains)) return;
    final devPort = (j['port'] as num?)?.toInt() ?? lanSyncPort;
    final key = '$sourceIp:$devPort';
    _discoveredMap[key] = (
      LanDevice(
        address: sourceIp,
        port: devPort,
        name: j['name'] as String? ?? '未知设备',
        addrs: reported.toList(),
      ),
      DateTime.now(),
    );
    // 清理 15 秒无 beacon 的过期条目
    final now = DateTime.now();
    _discoveredMap.removeWhere(
      ( _, v) => now.difference(v.$2).inSeconds >= 15,
    );
    discovered.value = [
      for (final e in _discoveredMap.values) e.$1,
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> stop() async {
    _server?.close(force: true);
    _server = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _udp?.close();
    _udp = null;
    _discoveredMap.clear();
    discovered.value = const [];
    _progressExpire?.cancel();
    _progressExpire = null;
    syncProgress.value = null;
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
          'addrs': (await allLocalIPv4s()).toList(),
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
      if (path == '/api/sync-progress' && req.method == 'POST') {
        // 对端推送的同步进度（双方进度可见）
        final bytes = await _readBody(req);
        try {
          final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          _updateSyncProgress(
            LanSyncProgress(
              phase: j['phase'] as String? ?? '',
              done: (j['done'] as num?)?.toInt() ?? 0,
              total: (j['total'] as num?)?.toInt() ?? 0,
              finished: j['finished'] == true,
            ),
          );
        } catch (_) {}
        await _json(req, {'ok': true});
        return;
      }
      if (path == '/api/settings' && req.method == 'POST') {
        // 对端推送设置（局域网设置同步）：逐键写入本机设置表
        final bytes = await _readBody(req);
        try {
          final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          for (final e in j.entries) {
            final v = e.value;
            if (v is String && v.isNotEmpty) {
              await _db.setSetting(e.key, v);
            }
          }
          await _json(req, {'ok': true});
        } catch (_) {
          await _json(req, {'ok': false});
        }
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
    final tmp = File('${tmpDir.path}${Platform.pathSeparator}up.$ext');
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
      'formatVersion': 2,
      'deviceName': _deviceName(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'settings': settings,
      'books': list,
      // 附加数据全量快照（v2）：对端「从备份恢复」时可完整还原
      'data': {
        'highlights': await _repo.allHighlightRows(),
        'bookmarks': await _repo.allBookmarkRows(),
        'bookTags': await _repo.allBookTagRows(),
        'readingTimes': await _repo.allReadingTimeRows(),
      },
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
      // 同步更新书籍行的封面路径：修复对端推送书籍后封面（插图）不显示
      final bookId = name.substring(0, 64);
      final row = await (_db.select(
        _db.books,
      )..where((t) => t.id.equals(bookId))).getSingleOrNull();
      if (row != null && row.coverPath != f.path) {
        await (_db.update(_db.books)..where((t) => t.id.equals(bookId))).write(
          BooksCompanion(coverPath: Value(f.path)),
        );
      }
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
    // 封面路径是确定性的（covers/<id>.img，随后由推送方上传该文件），
    // 注册时即写入，避免推送方向对端同步书籍后对端封面（插图）不显示
    String? coverPath;
    if (entry['hasCover'] == true) {
      final covDir = await AppDirs.covers();
      coverPath = '${covDir.path}${Platform.pathSeparator}$id.img';
    }
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
        coverPath: Value(coverPath),
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
