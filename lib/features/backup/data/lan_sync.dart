import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;

import '../../../core/storage/app_database.dart';
import '../../library/data/book_repository.dart';
import 'remote_store.dart';

/// 局域网同步服务端口（发现 UDP 与 HTTP 服务共用同一端口段约定）
const lanSyncPort = 47816;

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
/// - GET  /api/ping      → {"app","name","port"}
/// - GET  /api/manifest  → 备份清单（设置+书籍清单）
/// - GET  /api/list?path=book|progress|covers|'' → 文件相对路径列表
/// - GET  /api/file?path=`book/<id>.<ext>` 等 → 文件内容
/// - POST /api/register  → 注册书籍元数据行（body: 清单书籍条目 JSON）
/// - POST /api/file?path=... → 上传文件内容
class LanSyncServer {
  LanSyncServer(this._repo, this._db);

  final BookRepository _repo;
  final AppDatabase _db;

  HttpServer? _server;
  RawDatagramSocket? _udp;

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
      req.response.statusCode = 404;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
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

  /// UDP 广播发现
  static Future<List<LanDevice>> _udpScan() async {
    final out = <LanDevice>[];
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
    String? localIp;
    try {
      final interfaces = await NetworkInterface.list();
      for (final ni in interfaces) {
        for (final a in ni.addresses) {
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
            localIp = a.address;
            break;
          }
        }
        if (localIp != null) break;
      }
    } catch (_) {}
    if (localIp == null) return out;
    final parts = localIp.split('.');
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    final candidates = <String>[
      for (var i = 1; i <= 254; i++)
        if ('$prefix.$i' != localIp) '$prefix.$i',
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

    await Future.wait([for (var i = 0; i < 32; i++) worker()]);
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
