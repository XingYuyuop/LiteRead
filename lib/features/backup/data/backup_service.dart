import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;

import '../../../core/storage/app_database.dart';
import '../../library/data/book_repository.dart';
import 'remote_store.dart';

/// 备份清单（设置 + 书籍清单元数据；书籍文件与进度分目录单独存放）
///
/// 目录结构（根目录名可自定义，默认 literead）：
/// ```
/// <根目录>/
///   backup_<设备名>_<yyyyMMdd_HHmmss>.json   ← 本清单（含设备名、日期时间）
///   `book/<id>.<ext>`                        ← 书籍文件（id = 内容 sha256）
///   `covers/<id>.img`                        ← 封面
///   `progress/<bookId>.json`                 ← 阅读进度（独立目录，便于多设备同步）
/// ```
class BackupManifest {
  const BackupManifest({
    required this.deviceName,
    required this.createdAt,
    required this.settings,
    required this.books,
  });

  static const formatVersion = 1;

  final String deviceName;
  final int createdAt;

  /// 软件设置快照（settings_kv：key → valueJson 原文）
  final Map<String, String> settings;

  /// 书籍清单（只记录有哪些书，文件单独存放于 book/）
  final List<Map<String, dynamic>> books;

  Map<String, dynamic> toJson() => {
    'app': 'literead',
    'formatVersion': formatVersion,
    'deviceName': deviceName,
    'createdAt': createdAt,
    'settings': settings,
    'books': books,
  };

  static BackupManifest fromJson(Map<String, dynamic> j) => BackupManifest(
    deviceName: j['deviceName'] as String? ?? '未知设备',
    createdAt: j['createdAt'] as int? ?? 0,
    settings:
        (j['settings'] as Map<String, dynamic>?)?.cast<String, String>() ??
        const {},
    books: (j['books'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(),
  );

  /// 清单文件名：`backup_<设备名>_<yyyyMMdd_HHmmss>.json`
  static String fileNameFor(String deviceName, DateTime time) {
    final safe = deviceName.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
    final ts =
        '${time.year}${_p2(time.month)}${_p2(time.day)}_'
        '${_p2(time.hour)}${_p2(time.minute)}${_p2(time.second)}';
    return 'backup_${safe}_$ts.json';
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');
}

/// 同步/恢复结果统计
class BackupResult {
  BackupResult({
    this.booksDownloaded = 0,
    this.booksUploaded = 0,
    this.progressPulled = 0,
    this.progressPushed = 0,
    this.settingsRestored = false,
    this.manifestName,
  });

  int booksDownloaded;
  int booksUploaded;
  int progressPulled;
  int progressPushed;
  bool settingsRestored;
  String? manifestName;

  String summary() {
    final parts = <String>[];
    if (booksDownloaded > 0) parts.add('新增书籍 $booksDownloaded 本');
    if (booksUploaded > 0) parts.add('上传书籍 $booksUploaded 本');
    if (progressPulled > 0) parts.add('拉取进度 $progressPulled 条');
    if (progressPushed > 0) parts.add('推送进度 $progressPushed 条');
    if (settingsRestored) parts.add('设置已恢复');
    return parts.isEmpty ? '已是最新，无差异' : parts.join('，');
  }
}

/// 备份与同步服务
class BackupService {
  BackupService(this._repo, this._db);

  final BookRepository _repo;
  final AppDatabase _db;

  String _deviceName() {
    try {
      final name = Platform.localHostname;
      return name.isEmpty ? 'unknown' : name;
    } catch (_) {
      return 'unknown';
    }
  }

  Book? _bookById(List<Book> list, String id) {
    for (final b in list) {
      if (b.id == id) return b;
    }
    return null;
  }

  // ---- 快照 ----

  /// 当前书籍清单（不含文件内容）
  Future<List<Map<String, dynamic>>> manifestBooks(List<Book> books) async {
    final out = <Map<String, dynamic>>[];
    for (final b in books) {
      Map<String, dynamic> meta = const {};
      try {
        if (b.metaJson != null) {
          meta = jsonDecode(b.metaJson!) as Map<String, dynamic>;
        }
      } catch (_) {}
      out.add({
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
    return out;
  }

  /// 生成清单（设置 + 书籍）
  Future<BackupManifest> buildManifest() async {
    final books = await _repo.listBooks();
    return BackupManifest(
      deviceName: _deviceName(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      settings: await _repo.allSettings(),
      books: await manifestBooks(books),
    );
  }

  // ---- 备份（推送到远端） ----

  /// 立即备份：上传缺失的书籍/封面 + 全部进度 + 新清单
  Future<BackupResult> backup(RemoteStore store) async {
    final r = BackupResult();
    await _ensureDirs(store);
    final books = await _repo.listBooks();

    // 远端已有书籍（避免重复上传）
    final remoteBookFiles = await store.listFiles('book');
    final remoteIds = remoteBookFiles
        .map((p) => p.split('/').last.split('.').first)
        .toSet();

    for (final b in books) {
      if (!remoteIds.contains(b.id)) {
        final f = File(b.filePath);
        if (await f.exists()) {
          final ext = b.filePath.split('.').last;
          await store.putFile('book/${b.id}.$ext', await f.readAsBytes());
          r.booksUploaded++;
        }
        if (b.coverPath != null) {
          final c = File(b.coverPath!);
          if (await c.exists()) {
            await store.putFile('covers/${b.id}.img', await c.readAsBytes());
          }
        }
      }
    }

    // 进度全部上传（备份以本机为当前状态）
    for (final p in await _repo.allProgressRows()) {
      await store.putFile(
        'progress/${p.bookId}.json',
        utf8.encode(
          jsonEncode({
            'bookId': p.bookId,
            'locatorJson': p.locatorJson,
            'percent': p.percent,
            'updatedAt': p.updatedAt,
            'deviceId': p.deviceId,
          }),
        ),
      );
    }

    // 清单
    final manifest = await buildManifest();
    final name = BackupManifest.fileNameFor(
      manifest.deviceName,
      DateTime.now(),
    );
    await store.putFile(name, utf8.encode(jsonEncode(manifest.toJson())));
    r.manifestName = name;
    return r;
  }

  // ---- 同步（自动检索差异，双向合并） ----

  /// 与远端差异同步：
  /// - 远端有本地没有的书 → 下载入库
  /// - 本地有远端没有的书 → 上传
  /// - 进度按 updatedAt 新者胜（双向）
  Future<BackupResult> sync(RemoteStore store) async {
    final r = BackupResult();
    await _ensureDirs(store);

    final localBooks = await _repo.listBooks();
    final remoteManifests = await _fetchAllManifests(store);
    final remoteBooks = <String, Map<String, dynamic>>{};
    for (final (_, m) in remoteManifests) {
      for (final b in m.books) {
        final id = b['id'] as String?;
        if (id != null && !remoteBooks.containsKey(id)) remoteBooks[id] = b;
      }
    }

    // 1. 下载远端独有的书籍
    for (final entry in remoteBooks.values) {
      final id = entry['id'] as String;
      if (_bookById(localBooks, id) != null) continue;
      if (await _downloadBook(store, entry)) r.booksDownloaded++;
    }

    // 2. 上传本地独有的书籍
    for (final b in localBooks) {
      if (remoteBooks.containsKey(b.id)) continue;
      await _uploadSingleBook(store, b);
      r.booksUploaded++;
    }

    // 3. 进度差异合并（新者胜，双向）
    await _mergeProgress(store, r);

    // 4. 上传本机最新清单（供其他设备检索）
    final manifest = await buildManifest();
    final name = BackupManifest.fileNameFor(
      manifest.deviceName,
      DateTime.now(),
    );
    await store.putFile(name, utf8.encode(jsonEncode(manifest.toJson())));
    r.manifestName = name;

    // 清理：仅保留每设备最新 3 份清单
    await _pruneManifests(store, keepPerDevice: 3);
    return r;
  }

  // ---- 恢复（从清单还原） ----

  /// 列出远端全部备份清单（文件名 + 清单）
  Future<List<(String, BackupManifest)>> listManifests(RemoteStore store) =>
      _fetchAllManifests(store);

  /// 从指定清单恢复（默认最新）：应用设置 + 补齐书籍 + 进度合并
  Future<BackupResult> restore(
    RemoteStore store, {
    String? manifestName,
  }) async {
    final r = BackupResult();
    await _ensureDirs(store);

    final manifests = await _fetchAllManifests(store);
    if (manifests.isEmpty) {
      throw const BackupException('远端没有找到备份清单');
    }
    String chosenName;
    if (manifestName != null) {
      chosenName = manifestName;
    } else {
      // 取 createdAt 最新的清单
      var latest = manifests.first;
      for (final (name, m) in manifests) {
        if (m.createdAt > latest.$2.createdAt) latest = (name, m);
      }
      chosenName = latest.$1;
    }
    final raw = await store.getFile(chosenName);
    if (raw == null) {
      throw const BackupException('备份清单不存在或已被删除');
    }
    final manifest = BackupManifest.fromJson(
      jsonDecode(utf8.decode(raw)) as Map<String, dynamic>,
    );

    // 1. 应用设置
    for (final e in manifest.settings.entries) {
      await _db.setSetting(e.key, e.value);
    }
    r.settingsRestored = true;

    // 2. 补齐书籍
    for (final entry in manifest.books) {
      final id = entry['id'] as String?;
      if (id == null) continue;
      final existing = await _repo.getBook(id);
      if (existing == null) {
        if (await _downloadBook(store, entry)) r.booksDownloaded++;
      }
    }

    // 3. 进度合并（本机缺失或远端更新才应用）
    await _mergeProgress(store, r);
    r.manifestName = chosenName;
    return r;
  }

  // ---- 内部实现 ----

  Future<void> _ensureDirs(RemoteStore store) async {
    await store.ensureDir('book');
    await store.ensureDir('progress');
    await store.ensureDir('covers');
  }

  Future<List<(String, BackupManifest)>> _fetchAllManifests(
    RemoteStore store,
  ) async {
    final files = await store.listFiles('');
    final out = <(String, BackupManifest)>[];
    for (final f in files) {
      if (!f.endsWith('.json')) continue;
      try {
        final raw = await store.getFile(f);
        if (raw == null) continue;
        final m = BackupManifest.fromJson(
          jsonDecode(utf8.decode(raw)) as Map<String, dynamic>,
        );
        out.add((f, m));
      } catch (_) {
        // 跳过损坏清单
      }
    }
    return out;
  }

  Future<bool> _downloadBook(
    RemoteStore store,
    Map<String, dynamic> entry,
  ) async {
    final id = entry['id'] as String;
    final format = (entry['format'] as String? ?? 'TXT').toLowerCase();
    final data = await store.getFile('book/$id.$format');
    if (data == null || data.isEmpty) return false;

    // 写入托管目录
    final libDir = await AppDirs.library();
    final managedPath = '${libDir.path}${Platform.pathSeparator}$id.$format';
    await File(managedPath).writeAsBytes(data, flush: true);

    // 封面
    String? coverPath;
    if (entry['hasCover'] == true) {
      final cover = await store.getFile('covers/$id.img');
      if (cover != null && cover.isNotEmpty) {
        final coverDir = await AppDirs.covers();
        coverPath = '${coverDir.path}${Platform.pathSeparator}$id.img';
        await File(coverPath).writeAsBytes(cover, flush: true);
      }
    }

    // 分组数据在 metaJson 之外单独透传，注册行时一并恢复
    final groupName = entry['groupName'] as String?;
    final metaJson = entry['metaJson'] as String?;
    // metaJson 中可能没有 groupName（它是 Books 表字段）；保持原样即可，
    // 分组由独立列 groupName 恢复。
    await _repo.upsertBookRow(
      BooksCompanion.insert(
        id: id,
        title: entry['title'] as String? ?? '未命名',
        format: entry['format'] as String? ?? 'TXT',
        filePath: managedPath,
        addedAt:
            entry['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ).copyWith(
        author: Value(entry['author'] as String?),
        language: Value(entry['language'] as String?),
        fileSize: Value(entry['fileSize'] as int?),
        coverPath: Value(coverPath),
        metaJson: Value(metaJson),
        groupName: Value(
          (groupName == null || groupName.isEmpty) ? null : groupName,
        ),
      ),
    );
    return true;
  }

  Future<void> _uploadSingleBook(RemoteStore store, Book b) async {
    // LAN 对端需要先注册元数据行
    if (store is LanStore) {
      final entries = await manifestBooks([b]);
      if (entries.isNotEmpty) {
        await store.registerBook(entries.first);
      }
    }
    final f = File(b.filePath);
    if (await f.exists()) {
      final ext = b.filePath.split('.').last;
      await store.putFile('book/${b.id}.$ext', await f.readAsBytes());
    }
    if (b.coverPath != null) {
      final c = File(b.coverPath!);
      if (await c.exists()) {
        await store.putFile('covers/${b.id}.img', await c.readAsBytes());
      }
    }
  }

  /// 进度差异合并：updatedAt 新者胜（双向）
  Future<void> _mergeProgress(RemoteStore store, BackupResult r) async {
    final localRows = await _repo.allProgressRows();
    final localById = {for (final p in localRows) p.bookId: p};

    final remoteFiles = await store.listFiles('progress');
    for (final path in remoteFiles) {
      final raw = await store.getFile(path);
      if (raw == null) continue;
      try {
        final j = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
        final bookId = j['bookId'] as String;
        final updatedAt = j['updatedAt'] as int? ?? 0;
        final local = localById[bookId];
        if (local == null || updatedAt > local.updatedAt) {
          // 远端更新 → 应用到本地
          await _repo.restoreProgress(
            bookId,
            j['locatorJson'] as String? ?? '{}',
            (j['percent'] as num?)?.toDouble() ?? 0,
            updatedAt,
            deviceId: j['deviceId'] as String? ?? 'remote',
          );
          r.progressPulled++;
        }
      } catch (_) {}
    }

    // 本机较新的进度 → 推送到远端
    final remoteNames = remoteFiles.map((p) => p.split('/').last).toSet();
    for (final p in localRows) {
      final name = '${p.bookId}.json';
      final remotePath = 'progress/$name';
      if (!remoteNames.contains(name)) {
        await _pushProgress(store, p, remotePath);
        r.progressPushed++;
        continue;
      }
      // 已存在：比较时间戳（上面拉取时只在远端更新时应用；
      // 若本地更新则需要推送覆盖）
      final local = localById[p.bookId];
      if (local == null) continue;
      try {
        final raw = await store.getFile(remotePath);
        if (raw == null) {
          await _pushProgress(store, p, remotePath);
          r.progressPushed++;
          continue;
        }
        final j = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
        final remoteUpdated = j['updatedAt'] as int? ?? 0;
        if (local.updatedAt > remoteUpdated) {
          await _pushProgress(store, p, remotePath);
          r.progressPushed++;
        }
      } catch (_) {}
    }
  }

  Future<void> _pushProgress(
    RemoteStore store,
    ProgressRow p,
    String remotePath,
  ) async {
    await store.putFile(
      remotePath,
      utf8.encode(
        jsonEncode({
          'bookId': p.bookId,
          'locatorJson': p.locatorJson,
          'percent': p.percent,
          'updatedAt': p.updatedAt,
          'deviceId': p.deviceId,
        }),
      ),
    );
  }

  /// 清理旧清单：每设备保留最新 [keepPerDevice] 份
  Future<void> _pruneManifests(
    RemoteStore store, {
    int keepPerDevice = 3,
  }) async {
    try {
      final files = await store.listFiles('');
      final manifestFiles = files.where((f) => f.endsWith('.json')).toList()
        ..sort();
      // 文件名 backup_<device>_<timestamp>.json 按字典序即时间序
      final byDevice = <String, List<String>>{};
      for (final f in manifestFiles) {
        final base = f.split('/').last;
        final m = RegExp(r'^backup_(.+)_\d{8}_\d{6}\.json$').firstMatch(base);
        final device = m?.group(1) ?? base;
        byDevice.putIfAbsent(device, () => []).add(f);
      }
      for (final list in byDevice.values) {
        if (list.length <= keepPerDevice) continue;
        final toDelete = list.sublist(0, list.length - keepPerDevice);
        for (final f in toDelete) {
          await store.deleteFile(f);
        }
      }
    } catch (_) {
      // 清理失败不影响同步
    }
  }
}
