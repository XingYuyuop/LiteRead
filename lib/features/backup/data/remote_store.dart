import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart' as xml;

/// 备份存储抽象：本地文件夹 / WebDAV / S3 兼容对象存储 / 局域网设备。
///
/// 路径均为相对备份根目录的相对路径（'/' 分隔），如
/// `book/<id>.epub`、`progress/<bookId>.json`、`covers/<id>.img`、
/// `backup_<设备名>_<时间>.json`。
abstract class RemoteStore {
  String get label;

  /// 确保目录存在（'book'、'progress' 等，自动逐级创建）
  Future<void> ensureDir(String path);

  /// 写入文件（覆盖）
  Future<void> putFile(String path, List<int> bytes);

  /// 读取文件；不存在返回 null
  Future<List<int>?> getFile(String path);

  /// 列出 [path] 目录下的直接子文件（含目录前缀，不含子目录）
  Future<List<String>> listFiles(String path);

  /// 删除文件（不存在时静默成功）
  Future<void> deleteFile(String path);

  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// 本地文件夹
// ---------------------------------------------------------------------------

/// 本地文件夹存储：备份目录为用户选择目录下的自定义文件夹名
class LocalFolderStore extends RemoteStore {
  LocalFolderStore(this.parentDir, this.folderName) {
    root = Directory('${parentDir.path}${Platform.pathSeparator}$folderName');
  }

  final Directory parentDir;
  final String folderName;
  late final Directory root;

  String _local(String path) {
    final rel = path.replaceAll('/', Platform.pathSeparator);
    return '${root.path}${Platform.pathSeparator}$rel';
  }

  @override
  String get label => '本地文件夹 ${root.path}';

  @override
  Future<void> ensureDir(String path) async {
    if (path.isEmpty) {
      // 根目录：备份目标不存在时自动创建
      await root.create(recursive: true);
      return;
    }
    await Directory(_local(path)).create(recursive: true);
  }

  @override
  Future<void> putFile(String path, List<int> bytes) async {
    final f = File(_local(path));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<List<int>?> getFile(String path) async {
    final f = File(_local(path));
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<List<String>> listFiles(String path) async {
    final clean = path.replaceAll('/', Platform.pathSeparator);
    final dir = clean.isEmpty
        ? root
        : Directory('${root.path}${Platform.pathSeparator}$clean');
    if (!await dir.exists()) return const [];
    final out = <String>[];
    await for (final e in dir.list()) {
      if (e is File) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        out.add(path.isEmpty ? name : '$path/$name');
      }
    }
    return out;
  }

  @override
  Future<void> deleteFile(String path) async {
    final f = File(_local(path));
    if (await f.exists()) await f.delete();
  }
}

// ---------------------------------------------------------------------------
// WebDAV
// ---------------------------------------------------------------------------

/// WebDAV 存储（Nextcloud /坚果云 / Alist 等兼容服务）
class WebDavStore extends RemoteStore {
  WebDavStore({
    required this.baseUrl,
    required this.rootFolder,
    this.username,
    this.password,
  });

  /// 如 https://dav.example.com/dav/（末尾斜杠可省略）
  final String baseUrl;
  final String rootFolder;
  final String? username;
  final String? password;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  String get _base {
    var b = baseUrl.trim();
    if (!b.startsWith(RegExp(r'https?://'))) b = 'https://$b';
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /// 根目录绝对 URL（路径段逐段编码）
  String _url(String path) {
    final segs = [rootFolder, ...path.split('/').where((s) => s.isNotEmpty)];
    final encoded = segs
        .map((s) => Uri.encodeComponent(s).replaceAll('+', '%20'))
        .join('/');
    return '$_base/$encoded';
  }

  Future<HttpClientRequest> _open(String method, String url) async {
    final req = await _client.openUrl(method, Uri.parse(url));
    if (username != null && username!.isNotEmpty) {
      final token = base64Encode(utf8.encode('$username:${password ?? ''}'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
    }
    return req;
  }

  @override
  String get label => 'WebDAV $_base/$rootFolder';

  @override
  Future<void> ensureDir(String path) async {
    // 逐级 MKCOL（已存在 405 视为成功）；path 为空时创建根文件夹
    final segs = path.isEmpty
        ? [rootFolder]
        : path.split('/').where((s) => s.isNotEmpty).toList();
    var cur = '';
    for (final s in segs) {
      cur = cur.isEmpty ? s : '$cur/$s';
      final url = _url(cur);
      try {
        final req = await _open('MKCOL', url);
        final res = await req.close();
        await res.drain<void>();
      } catch (_) {
        // 网络层错误推迟到真正的读写时报错
      }
    }
  }

  @override
  Future<void> putFile(String path, List<int> bytes) async {
    var res = await _put(path, bytes);
    // 部分服务在父目录缺失时返回 404/409：补建父目录后重试一次
    if (res.statusCode == 404 || res.statusCode == 409) {
      await res.drain<void>();
      final segs = path.split('/')..removeLast();
      await ensureDir(segs.isEmpty ? '' : segs.join('/'));
      res = await _put(path, bytes);
    }
    await res.drain<void>();
    if (res.statusCode >= 300) {
      throw BackupException('WebDAV 上传失败（HTTP ${res.statusCode}）');
    }
  }

  Future<HttpClientResponse> _put(String path, List<int> bytes) async {
    final req = await _open('PUT', _url(path));
    req.headers.contentType = ContentType.binary;
    req.add(bytes);
    return req.close();
  }

  @override
  Future<List<int>?> getFile(String path) async {
    final req = await _open('GET', _url(path));
    final res = await req.close();
    if (res.statusCode == 404) return null;
    if (res.statusCode >= 300) {
      await res.drain<void>();
      throw BackupException('WebDAV 下载失败（HTTP ${res.statusCode}）');
    }
    return res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
  }

  @override
  Future<List<String>> listFiles(String path) async {
    final body =
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:">'
        '<d:prop><d:resourcetype/></d:prop></d:propfind>';
    final req = await _open('PROPFIND', _url(path));
    req.headers.set('Depth', '1');
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/xml');
    req.add(utf8.encode(body));
    final res = await req.close();
    final data = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode == 404) return const [];
    if (res.statusCode >= 300) {
      throw BackupException('WebDAV 列表失败（HTTP ${res.statusCode}）');
    }
    // 解析多状态响应，取直接子文件
    final doc = xml.XmlDocument.parse(utf8.decode(data, allowMalformed: true));
    final out = <String>[];
    final prefix = path.isEmpty ? '' : '$path/';
    for (final resp in doc.findAllElementsSelf('response')) {
      final hrefRaw =
          resp.findElementsNamed('href').firstOrNull?.innerText ??
          resp.findElementsNamed('D:href').firstOrNull?.innerText ??
          resp.findElementsNamed('d:href').firstOrNull?.innerText;
      if (hrefRaw == null) continue;
      final href = Uri.decodeComponent(hrefRaw);
      if (href.endsWith('/')) continue; // 目录
      final targetSuffix = Uri.decodeComponent(
        path.isEmpty ? rootFolder : '$rootFolder/$path',
      );
      final idx = href.indexOf(targetSuffix);
      if (idx < 0) continue;
      final rel = href.substring(idx + targetSuffix.length);
      final clean = rel.startsWith('/') ? rel.substring(1) : rel;
      if (clean.isEmpty || clean.contains('/')) continue; // 仅直接子文件
      out.add('$prefix$clean');
    }
    return out;
  }

  @override
  Future<void> deleteFile(String path) async {
    final req = await _open('DELETE', _url(path));
    final res = await req.close();
    await res.drain<void>();
  }

  @override
  Future<void> dispose() async {
    _client.close(force: true);
  }
}

extension on xml.XmlDocument {
  Iterable<xml.XmlElement> findAllElementsSelf(String name) => [
    ...findAllElements(name),
    ...findAllElements('D:$name'),
    ...findAllElements('d:$name'),
  ];
}

extension on xml.XmlElement {
  Iterable<xml.XmlElement> findElementsNamed(String name) => [
    ...findElements(name),
    ...findElements('D:$name'),
    ...findElements('d:$name'),
  ];
}

extension on Iterable<xml.XmlElement> {
  xml.XmlElement? get firstOrNull => isEmpty ? null : first;
}

// ---------------------------------------------------------------------------
// S3 兼容对象存储（SigV4 签名）
// ---------------------------------------------------------------------------

/// S3 / MinIO / R2 / OSS(兼容模式) 等
class S3Store extends RemoteStore {
  S3Store({
    required this.endpoint,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    this.region = 'us-east-1',
    this.rootFolder = 'literead',
    this.pathStyle = true,
  });

  final String endpoint; // https://s3.example.com 或含桶的虚拟主机地址
  final String bucket;
  final String accessKey;
  final String secretKey;
  final String region;
  final String rootFolder;
  final bool pathStyle; // true: endpoint/bucket/key（自建 MinIO/R2 常用）

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  String get _host {
    var e = endpoint.trim();
    if (!e.startsWith(RegExp(r'https?://'))) e = 'https://$e';
    return Uri.parse(e).host;
  }

  String get _scheme => endpoint.startsWith('http://') ? 'http' : 'https';

  /// 显式端口；未指定时按协议默认（Uri.port 为 0）
  int get _port {
    var e = endpoint.trim();
    if (!e.startsWith(RegExp(r'https?://'))) e = 'https://$e';
    final p = Uri.parse(e).port;
    if (p != 0) return p;
    return _scheme == 'http' ? 80 : 443;
  }

  /// 对象 key：rootFolder/path
  String _objectKey(String path) =>
      path.isEmpty ? rootFolder : '$rootFolder/$path';

  /// 请求 URI（/bucket/key，含编码但保留 '/'）；objectKey 为空时列举桶根
  String _canonicalUri(String objectKey) {
    if (objectKey.isEmpty) return pathStyle ? '/$bucket/' : '/';
    final encoded = objectKey
        .split('/')
        .map((s) => Uri.encodeComponent(s).replaceAll('+', '%20'))
        .join('/');
    return pathStyle ? '/$bucket$encoded' : encoded;
  }

  String _url(String objectKey) {
    final host = pathStyle ? _host : '$bucket.$_host';
    final portPart =
        (_port == 80 && _scheme == 'http') ||
            (_port == 443 && _scheme == 'https')
        ? ''
        : ':$_port';
    final uri = _canonicalUri(objectKey);
    return '$_scheme://$host$portPart$uri';
  }

  /// SigV4 签名并执行
  Future<HttpClientResponse> _signed(
    String method,
    String objectKey, {
    Map<String, String> query = const {},
    List<int>? body,
    String? contentType,
  }) async {
    final now = DateTime.now().toUtc();
    final amzDate =
        '${now.year}${_p2(now.month)}${_p2(now.day)}T${_p2(now.hour)}${_p2(now.minute)}${_p2(now.second)}Z';
    final dateStamp = '${now.year}${_p2(now.month)}${_p2(now.day)}';
    final payloadHash = sha256.convert(body ?? const <int>[]).toString();
    final host = pathStyle ? _host : '$bucket.$_host';

    // Canonical query
    final queryKeys = query.keys.toList()..sort();
    final canonicalQuery = queryKeys
        .map(
          (k) =>
              '${Uri.encodeComponent(k).replaceAll('+', '%20')}='
              '${Uri.encodeComponent(query[k]!).replaceAll('+', '%20')}',
        )
        .join('&');

    final headers = <String, String>{
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
    };
    if (contentType != null) headers['content-type'] = contentType;

    final sortedHeaderKeys = headers.keys.toList()..sort();
    final canonicalHeaders = sortedHeaderKeys
        .map((k) => '$k:${headers[k]!.trim()}\n')
        .join();
    final signedHeaders = sortedHeaderKeys.join(';');

    final canonicalRequest = [
      method,
      _canonicalUri(objectKey),
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$dateStamp/$region/s3/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    final kDate = _hmac(utf8.encode('AWS4$secretKey'), utf8.encode(dateStamp));
    final kRegion = _hmac(kDate, utf8.encode(region));
    final kService = _hmac(kRegion, utf8.encode('s3'));
    final kSigning = _hmac(kService, utf8.encode('aws4_request'));
    final signature = _hmac(
      kSigning,
      utf8.encode(stringToSign),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final authorization =
        'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';

    final req = await _client.openUrl(
      method,
      Uri.parse(
        query.isEmpty ? _url(objectKey) : '${_url(objectKey)}?$canonicalQuery',
      ),
    );
    req.headers.set('x-amz-date', amzDate);
    req.headers.set('x-amz-content-sha256', payloadHash);
    req.headers.set(HttpHeaders.authorizationHeader, authorization);
    if (contentType != null) {
      req.headers.contentType = ContentType.parse(contentType);
    }
    if (body != null) {
      req.add(body);
    }
    return req.close();
  }

  List<int> _hmac(List<int> key, List<int> msg) =>
      Hmac(sha256, key).convert(msg).bytes;

  static String _p2(int v) => v.toString().padLeft(2, '0');

  @override
  String get label => 'S3 $bucket/$rootFolder';

  @override
  Future<void> ensureDir(String path) async {
    // 对象存储无真实目录，无需创建
  }

  @override
  Future<void> putFile(String path, List<int> bytes) async {
    final res = await _signed(
      'PUT',
      _objectKey(path),
      body: bytes,
      contentType: 'application/octet-stream',
    );
    await res.drain<void>();
    if (res.statusCode >= 300) {
      throw BackupException('S3 上传失败（HTTP ${res.statusCode}）');
    }
  }

  @override
  Future<List<int>?> getFile(String path) async {
    final res = await _signed('GET', _objectKey(path));
    if (res.statusCode == 404) {
      await res.drain<void>();
      return null;
    }
    if (res.statusCode >= 300) {
      await res.drain<void>();
      throw BackupException('S3 下载失败（HTTP ${res.statusCode}）');
    }
    return res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
  }

  @override
  Future<List<String>> listFiles(String path) async {
    final prefix = _objectKey(path.isEmpty ? '' : path);
    // 列举桶级请求：canonicalUri 为根路径
    final res = await _signed(
      'GET',
      '',
      query: {'list-type': '2', 'prefix': prefix, 'delimiter': '/'},
    );
    final data = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode >= 300) {
      throw BackupException('S3 列表失败（HTTP ${res.statusCode}）');
    }
    final doc = xml.XmlDocument.parse(utf8.decode(data, allowMalformed: true));
    final out = <String>[];
    for (final c in doc.findAllElements('Contents')) {
      final key = c.findElements('Key').firstOrNull?.innerText;
      if (key == null) continue;
      if (key.endsWith('/')) continue;
      // 去掉 rootFolder 前缀，还原为相对路径
      var rel = key;
      if (rel.startsWith('$rootFolder/')) {
        rel = rel.substring(rootFolder.length + 1);
      }
      if (rel.isNotEmpty) out.add(rel);
    }
    return out;
  }

  @override
  Future<void> deleteFile(String path) async {
    final res = await _signed('DELETE', _objectKey(path));
    await res.drain<void>();
  }

  @override
  Future<void> dispose() async {
    _client.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// 局域网设备（对端 LiteRead 内置同步服务）
// ---------------------------------------------------------------------------

/// 局域网设备存储：连接另一台运行 LiteRead 并开启共享的设备
class LanStore extends RemoteStore {
  LanStore(this.host, this.port);

  final String host;
  final int port;

  /// 单请求超时：连接超时之外再限制整体等待，避免对端失联时同步永久挂起
  static const _reqTimeout = Duration(seconds: 20);

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  Uri _uri(String path, [Map<String, String>? q]) => Uri.parse(
    'http://$host:$port/api/$path${q == null ? '' : '?${Uri(queryParameters: q).query}'}',
  );

  @override
  String get label => '局域网 $host:$port';

  @override
  Future<void> ensureDir(String path) async {}

  @override
  Future<void> putFile(String path, List<int> bytes) async {
    final req = await _client.postUrl(_uri('file', {'path': path}));
    req.headers.contentType = ContentType.binary;
    req.add(bytes);
    final res = await req.close().timeout(_reqTimeout);
    await res.drain<void>().timeout(_reqTimeout);
    if (res.statusCode >= 300) {
      throw BackupException('局域网上传失败（HTTP ${res.statusCode}）');
    }
  }

  @override
  Future<List<int>?> getFile(String path) async {
    final req = await _client.getUrl(_uri('file', {'path': path}));
    final res = await req.close().timeout(_reqTimeout);
    if (res.statusCode == 404) return null;
    if (res.statusCode >= 300) {
      await res.drain<void>();
      throw BackupException('局域网下载失败（HTTP ${res.statusCode}）');
    }
    return res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
  }

  @override
  Future<List<String>> listFiles(String path) async {
    final req = await _client.getUrl(_uri('list', {'path': path}));
    final res = await req.close().timeout(_reqTimeout);
    if (res.statusCode >= 300) return const [];
    final body = await res.transform(utf8.decoder).join().timeout(_reqTimeout);
    final list = (jsonDecode(body) as List).cast<String>();
    return list;
  }

  @override
  Future<void> deleteFile(String path) async {}

  /// 注册书籍元数据行（推送本地书籍到对端前先调用）
  Future<void> registerBook(Map<String, dynamic> entry) async {
    final req = await _client.postUrl(_uri('register'));
    req.add(utf8.encode(jsonEncode(entry)));
    final res = await req.close().timeout(_reqTimeout);
    await res.drain<void>().timeout(_reqTimeout);
  }

  /// 删除对端设备上的指定书籍（对端弹确认前由本机用户勾选）
  Future<void> deleteBook(String id) async {
    final req = await _client.postUrl(_uri('delete-book'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'id': id})));
    final res = await req.close().timeout(_reqTimeout);
    await res.drain<void>().timeout(_reqTimeout);
    if (res.statusCode >= 300) {
      throw BackupException('远端删除失败（HTTP ${res.statusCode}）');
    }
  }

  /// 读取对端备份清单（同步确认前对比差异用）
  Future<Map<String, dynamic>?> fetchManifest() async {
    final raw = await getFile('manifest.json');
    if (raw == null) return null;
    try {
      return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 探测设备信息（name）
  static Future<String?> ping(String host, int port) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      final req = await client.getUrl(Uri.parse('http://$host:$port/api/ping'));
      final res = await req.close().timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        client.close();
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      client.close();
      return (jsonDecode(body) as Map<String, dynamic>)['name'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _client.close(force: true);
  }
}

/// 备份操作异常（带用户可读信息）
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
