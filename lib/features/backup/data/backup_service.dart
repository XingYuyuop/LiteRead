import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;

import '../../../core/storage/app_database.dart';
import '../../library/data/book_repository.dart';
import 'remote_store.dart';

/// 备份清单（设置 + 书籍清单元数据 + 附加数据快照；书籍文件与进度分目录单独存放）
///
/// 目录结构（根目录名可自定义，默认 LiteRead）：
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
    this.data = const {},
  });

  /// v2：新增 data（标注/书签/标签/阅读统计全量快照）
  static const formatVersion = 2;

  final String deviceName;
  final int createdAt;

  /// 软件设置快照（settings_kv：key → valueJson 原文）
  final Map<String, String> settings;

  /// 书籍清单（只记录有哪些书，文件单独存放于 book/）
  final List<Map<String, dynamic>> books;

  /// 附加数据全量快照（v2）：
  /// highlights / bookmarks / bookTags / readingTimes → 行列表
  final Map<String, List<Map<String, dynamic>>> data;

  Map<String, dynamic> toJson() => {
    'app': 'literead',
    'formatVersion': formatVersion,
    'deviceName': deviceName,
    'createdAt': createdAt,
    'settings': settings,
    'books': books,
    'data': data,
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
    data: (j['data'] as Map<String, dynamic>? ?? const {}).map(
      (k, v) => MapEntry(
        k,
        (v as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList(),
      ),
    ),
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

/// 备份选项：忽略列表（用户可选择某些数据不参与备份/恢复）
class BackupOptions {
  const BackupOptions({
    this.ignoreTheme = false,
    this.ignoreReader = false,
    this.ignoreStats = false,
    this.ignoreBackupCfg = false,
  });

  /// 忽略主题设置（app.theme）
  final bool ignoreTheme;

  /// 忽略阅读界面设置（reader.settings）
  final bool ignoreReader;

  /// 忽略阅读统计（readingTimes 数据）
  final bool ignoreStats;

  /// 忽略本机备份配置（backup.config 等，避免覆盖新设备已填写的备份目标）
  final bool ignoreBackupCfg;

  /// 按忽略列表过滤设置键
  Map<String, String> filterSettings(Map<String, String> all) {
    if (!ignoreTheme && !ignoreReader && !ignoreBackupCfg) return all;
    bool keep(String key) {
      if (ignoreTheme && key == 'app.theme') return false;
      if (ignoreReader && key == 'reader.settings') return false;
      if (ignoreBackupCfg &&
          (key == 'backup.config' ||
              key == 'backup.folderName' ||
              key == 'backup.lanSharing')) {
        return false;
      }
      return true;
    }

    return {
      for (final e in all.entries)
        if (keep(e.key)) e.key: e.value,
    };
  }
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

/// 局域网同步差异（同步确认数据源）
class LanDiff {
  const LanDiff({
    required this.remoteDeviceName,
    required this.remoteOnly,
    required this.localOnly,
  });

  final String remoteDeviceName;

  /// 远端有、本地没有的书籍清单条目
  final List<Map<String, dynamic>> remoteOnly;

  /// 本地有、远端没有的书籍
  final List<Book> localOnly;

  bool get isEmpty => remoteOnly.isEmpty && localOnly.isEmpty;
}

/// 备份/同步进度回调：(已完成步数, 本阶段总步数, 阶段描述)。
/// 步数在每个阶段开始时归零重计。
typedef BackupProgressCallback =
    void Function(int done, int total, String phase);

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

  /// 生成清单（设置 + 书籍 + 附加数据快照，按忽略列表过滤）
  Future<BackupManifest> buildManifest({
    BackupOptions opts = const BackupOptions(),
  }) async {
    final books = await _repo.listBooks();
    return BackupManifest(
      deviceName: _deviceName(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      settings: opts.filterSettings(await _repo.allSettings()),
      books: await manifestBooks(books),
      data: {
        'highlights': await _repo.allHighlightRows(),
        'bookmarks': await _repo.allBookmarkRows(),
        'bookTags': await _repo.allBookTagRows(),
        if (!opts.ignoreStats) 'readingTimes': await _repo.allReadingTimeRows(),
      },
    );
  }

  // ---- 备份（推送到远端） ----

  /// 立即备份：上传缺失的书籍/封面 + 全部进度 + 新清单（含标注/统计等全量数据）
  Future<BackupResult> backup(
    RemoteStore store, {
    BackupProgressCallback? onProgress,
    BackupOptions opts = const BackupOptions(),
  }) async {
    final r = BackupResult();
    await _ensureDirs(store);
    final books = await _repo.listBooks();

    // 远端已有书籍（避免重复上传）
    final remoteBookFiles = await store.listFiles('book');
    final remoteIds = remoteBookFiles
        .map((p) => p.split('/').last.split('.').first)
        .toSet();
    final toUpload = books.where((b) => !remoteIds.contains(b.id)).toList();

    // 进度全部上传（备份以本机为当前状态）
    final progressRows = await _repo.allProgressRows();
    final total = toUpload.length + progressRows.length + 1;
    var done = 0;
    void step(String phase) => onProgress?.call(++done, total, phase);

    for (final b in toUpload) {
      onProgress?.call(done, total, '上传 ${b.title}');
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
      step('上传书籍');
    }

    for (final p in progressRows) {
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
      step('上传进度');
    }

    // 清单
    onProgress?.call(done, total, '写入清单');
    final manifest = await buildManifest(opts: opts);
    final name = BackupManifest.fileNameFor(
      manifest.deviceName,
      DateTime.now(),
    );
    await store.putFile(name, utf8.encode(jsonEncode(manifest.toJson())));
    r.manifestName = name;
    onProgress?.call(total, total, '完成');
    return r;
  }

  // ---- 同步（自动检索差异，双向合并） ----

  /// 与远端差异同步：
  /// - 远端有本地没有的书 → 下载入库
  /// - 本地有远端没有的书 → 上传
  /// - 进度按 updatedAt 新者胜（双向）
  Future<BackupResult> sync(
    RemoteStore store, {
    BackupProgressCallback? onProgress,
    BackupOptions opts = const BackupOptions(),
  }) async {
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
    final toDownload = remoteBooks.values
        .where((e) => _bookById(localBooks, e['id'] as String) == null)
        .toList();
    final toPush = localBooks
        .where((b) => !remoteBooks.containsKey(b.id))
        .toList();
    final total = toDownload.length + toPush.length + 2; // + 进度合并 + 清单
    var done = 0;
    void step(String phase) => onProgress?.call(++done, total, phase);

    // 1. 下载远端独有的书籍
    for (final entry in toDownload) {
      onProgress?.call(done, total, '下载 ${entry['title'] ?? '书籍'}');
      if (await _downloadBook(store, entry)) r.booksDownloaded++;
      step('下载书籍');
    }

    // 2. 上传本地独有的书籍
    for (final b in toPush) {
      onProgress?.call(done, total, '上传 ${b.title}');
      await _uploadSingleBook(store, b);
      r.booksUploaded++;
      step('上传书籍');
    }

    // 3. 进度差异合并（新者胜，双向）
    onProgress?.call(done, total, '合并进度');
    await _mergeProgress(store, r);
    step('合并进度');

    // 4. 上传本机最新清单（供其他设备检索）
    onProgress?.call(done, total, '写入清单');
    final manifest = await buildManifest(opts: opts);
    final name = BackupManifest.fileNameFor(
      manifest.deviceName,
      DateTime.now(),
    );
    await store.putFile(name, utf8.encode(jsonEncode(manifest.toJson())));
    r.manifestName = name;

    // 清理：仅保留每设备最新 3 份清单
    await _pruneManifests(store, keepPerDevice: 3);
    onProgress?.call(total, total, '完成');
    return r;
  }

  // ---- 同步确认（局域网设备间） ----

  /// 与远端书籍清单对比（同步确认对话框数据源）
  Future<LanDiff> diffWithRemote(RemoteStore store) async {
    final localBooks = await _repo.listBooks();
    final raw = await store.getFile('manifest.json');
    if (raw == null) {
      throw const BackupException('无法读取对端清单（对端可能未开启共享）');
    }
    final BackupManifest m;
    try {
      m = BackupManifest.fromJson(
        jsonDecode(utf8.decode(raw)) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const BackupException('对端清单格式异常');
    }
    final localIds = localBooks.map((b) => b.id).toSet();
    final remoteOnly = <Map<String, dynamic>>[];
    final remoteIds = <String>{};
    for (final b in m.books) {
      final id = b['id'] as String?;
      if (id == null) continue;
      remoteIds.add(id);
      if (!localIds.contains(id)) remoteOnly.add(b);
    }
    final localOnly = localBooks
        .where((b) => !remoteIds.contains(b.id))
        .toList();
    return LanDiff(
      remoteDeviceName: m.deviceName,
      remoteOnly: remoteOnly,
      localOnly: localOnly,
    );
  }

  /// 执行已确认的同步动作（拉取 / 推送 / 删除本机多余 / 删除远端指定 / 设置同步）
  Future<BackupResult> applyLanDiff(
    RemoteStore store,
    LanDiff diff, {
    bool pull = false,
    bool push = false,
    List<String> deleteLocalIds = const [],
    List<String> deleteRemoteIds = const [],
    bool pullSettings = false,
    bool pushSettings = false,
    BackupOptions opts = const BackupOptions(),
    BackupProgressCallback? onProgress,
  }) async {
    final r = BackupResult();
    await _ensureDirs(store);
    final total =
        (pull ? diff.remoteOnly.length : 0) +
        (push ? diff.localOnly.length : 0) +
        (pullSettings ? 1 : 0) +
        (pushSettings ? 1 : 0) +
        (pull || push ? 1 : 0); // + 进度合并
    var done = 0;
    void step(String phase) => onProgress?.call(++done, total, phase);
    if (pull) {
      for (final e in diff.remoteOnly) {
        onProgress?.call(done, total, '下载 ${e['title'] ?? '书籍'}');
        if (await _downloadBook(store, e)) r.booksDownloaded++;
        step('拉取书籍');
      }
    }
    if (push) {
      for (final b in diff.localOnly) {
        onProgress?.call(done, total, '上传 ${b.title}');
        await _uploadSingleBook(store, b);
        r.booksUploaded++;
        step('推送书籍');
      }
    }
    // 设置同步：拉取对端设置 / 推送本机设置（含备份配置如 WebDAV 地址）
    if (pullSettings) {
      onProgress?.call(done, total, '拉取设置');
      final raw = await store.getFile('manifest.json');
      if (raw != null) {
        try {
          final j = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
          final remote =
              (j['settings'] as Map<String, dynamic>?)?.cast<String, String>() ??
              const {};
          for (final e in opts.filterSettings(remote).entries) {
            await _db.setSetting(e.key, e.value);
          }
          r.settingsRestored = true;
        } catch (_) {}
      }
      step('拉取设置');
    }
    if (pushSettings && store is LanStore) {
      onProgress?.call(done, total, '推送设置');
      try {
        await store.pushSettings(
          opts.filterSettings(await _repo.allSettings()),
        );
        r.settingsRestored = true;
      } catch (_) {}
      step('推送设置');
    }
    // 本机删除指定内容（用户在确认对话框中勾选）
    if (deleteLocalIds.isNotEmpty) {
      await _repo.deleteBooks(deleteLocalIds, deleteManagedFile: true);
    }
    // 远端删除指定内容（对端 /api/delete-book 端点）
    if (deleteRemoteIds.isNotEmpty && store is LanStore) {
      for (final id in deleteRemoteIds) {
        await store.deleteBook(id);
      }
    }
    // 进度双向合并（新者胜；仅在有内容变动时执行）
    if (pull || push) {
      onProgress?.call(done, total, '合并进度');
      await _mergeProgress(store, r);
      step('合并进度');
    }
    onProgress?.call(total, total, '完成');
    return r;
  }

  // ---- 恢复（从清单还原） ----

  /// 列出远端全部备份清单（文件名 + 清单）
  Future<List<(String, BackupManifest)>> listManifests(RemoteStore store) =>
      _fetchAllManifests(store);

  /// 从指定清单恢复（默认最新）：应用设置 + 补齐书籍 + 进度合并 + 标注/统计恢复
  Future<BackupResult> restore(
    RemoteStore store, {
    String? manifestName,
    BackupProgressCallback? onProgress,
    BackupOptions opts = const BackupOptions(),
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

    // 1. 应用设置（按忽略列表过滤，例如保留本机主题/备份目标）
    for (final e in opts.filterSettings(manifest.settings).entries) {
      await _db.setSetting(e.key, e.value);
    }
    r.settingsRestored = true;

    // 2. 补齐书籍
    final missing = <Map<String, dynamic>>[];
    for (final entry in manifest.books) {
      final id = entry['id'] as String?;
      if (id == null) continue;
      final existing = await _repo.getBook(id);
      if (existing == null) missing.add(entry);
    }
    final total = missing.length + 2; // + 进度合并 + 附加数据恢复
    var done = 0;
    for (final entry in missing) {
      onProgress?.call(done, total, '下载 ${entry['title'] ?? '书籍'}');
      if (await _downloadBook(store, entry)) r.booksDownloaded++;
      onProgress?.call(++done, total, '下载书籍');
    }

    // 3. 进度合并（本机缺失或远端更新才应用）
    onProgress?.call(done, total, '合并进度');
    await _mergeProgress(store, r);
    done++;

    // 4. 恢复附加数据：标注/书签/标签/阅读统计（按各自合并规则）
    onProgress?.call(done, total, '恢复标注与统计');
    final data = manifest.data;
    await _repo.restoreHighlights(data['highlights'] ?? const []);
    await _repo.restoreBookmarks(data['bookmarks'] ?? const []);
    await _repo.restoreBookTags(data['bookTags'] ?? const []);
    if (!opts.ignoreStats) {
      await _repo.restoreReadingTimes(data['readingTimes'] ?? const []);
    }
    onProgress?.call(total, total, '完成');
    r.manifestName = chosenName;
    return r;
  }

  // ---- 内部实现 ----

  Future<void> _ensureDirs(RemoteStore store) async {
    // 根目录（备份目标不存在时自动创建，如 WebDAV/LiteRead 文件夹）
    await store.ensureDir('');
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
