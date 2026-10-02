import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Locator;

import '../../../app/theme_controller.dart';
import '../../../core/storage/app_database.dart';
import '../../../engine/ir/book_document.dart';
import '../../../engine/parsers/book_parser.dart';

/// 书库仓库：导入、查询、删除、进度读写
class BookRepository {
  BookRepository(this._db);

  final AppDatabase _db;

  /// 导入文件：流式哈希去重 → 解析 → 托管副本 + 封面 → 入库
  ///
  /// 性能要点（大文件导入不卡顿、不双倍占内存）：
  /// - 哈希按 1MB 分块流式计算，不再 `readAsBytes` 全量驻留；
  /// - 解析在 isolate 内自行读文件（不传 bytesHint）；
  /// - 托管副本用 `File.copy` 流式复制。
  Future<ImportOutcome> importFile(String path) async {
    final src = File(path);
    final fileSize = await src.length();
    final id = await _hashFileStreaming(src);

    final existing = await (_db.select(
      _db.books,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing != null) {
      return ImportOutcome(book: existing, duplicated: true);
    }

    final output = await const BookParser().parseFile(path);
    final doc = output.document;

    // 托管副本（流式复制，不占额外内存）
    final ext = path.toLowerCase().split('.').last;
    final libDir = await AppDirs.library();
    final managedPath = '${libDir.path}${Platform.pathSeparator}$id.$ext';
    await src.copy(managedPath);

    // 封面
    String? coverPath;
    final coverBytes = await _extractCover(doc, output.coverBytes);
    if (coverBytes != null) {
      final coverDir = await AppDirs.covers();
      coverPath = '${coverDir.path}${Platform.pathSeparator}$id.img';
      await File(coverPath).writeAsBytes(coverBytes, flush: true);
    }

    final companion = BooksCompanion.insert(
      id: id,
      title: doc.meta.title,
      author: Value(doc.meta.author),
      language: Value(doc.meta.language),
      format: formatName(output.format),
      filePath: managedPath,
      fileSize: Value(fileSize),
      coverPath: Value(coverPath),
      addedAt: DateTime.now().millisecondsSinceEpoch,
      metaJson: Value(jsonEncode(_buildMeta(doc, output))),
    );
    await _db.into(_db.books).insertOnConflictUpdate(companion);

    final row = await (_db.select(
      _db.books,
    )..where((t) => t.id.equals(id))).getSingle();
    return ImportOutcome(book: row, duplicated: false);
  }

  /// 流式计算文件 sha256（1MB 分块读取，避免大文件全量载入内存）
  static Future<String> _hashFileStreaming(File f) async {
    final sink = _DigestSink();
    final converter = sha256.startChunkedConversion(sink);
    final raf = await f.open();
    try {
      const chunkSize = 1 << 20;
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        converter.add(chunk);
      }
    } finally {
      await raf.close();
    }
    converter.close();
    return sink.digest.toString();
  }

  Map<String, dynamic> _buildMeta(BookDocument doc, ParseOutput output) => {
    'chapterCount': doc.spine.length,
    'charCount': doc.totalChars,
    if (output.pageCount != null) 'pageCount': output.pageCount,
    if (doc.meta.description != null) 'description': doc.meta.description,
  };

  Future<Uint8List?> _extractCover(
    BookDocument doc,
    List<int>? parseCover,
  ) async {
    if (parseCover != null && parseCover.isNotEmpty) {
      return Uint8List.fromList(parseCover);
    }
    if (doc.meta.coverResource != null) {
      final data = await doc.resources.get(doc.meta.coverResource!);
      if (data != null && data.isNotEmpty) return Uint8List.fromList(data);
    }
    return null;
  }

  /// 全部书籍（可排序）
  Future<List<Book>> listBooks({BookSort sort = BookSort.lastRead}) async {
    final query = _db.select(_db.books);
    switch (sort) {
      case BookSort.lastRead:
        query.orderBy([
          (t) => OrderingTerm.desc(t.lastReadAt),
          (t) => OrderingTerm.desc(t.addedAt),
        ]);
        break;
      case BookSort.addedAt:
        query.orderBy([(t) => OrderingTerm.desc(t.addedAt)]);
        break;
      case BookSort.title:
        query.orderBy([(t) => OrderingTerm.asc(t.title)]);
        break;
    }
    return query.get();
  }

  Stream<List<Book>> watchBooks({BookSort sort = BookSort.lastRead}) {
    final query = _db.select(_db.books);
    switch (sort) {
      case BookSort.lastRead:
        query.orderBy([
          (t) => OrderingTerm.desc(t.lastReadAt),
          (t) => OrderingTerm.desc(t.addedAt),
        ]);
        break;
      case BookSort.addedAt:
        query.orderBy([(t) => OrderingTerm.desc(t.addedAt)]);
        break;
      case BookSort.title:
        query.orderBy([(t) => OrderingTerm.asc(t.title)]);
        break;
    }
    return query.watch();
  }

  Future<Book?> getBook(String id) =>
      (_db.select(_db.books)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 搜索：书名/作者/标签
  Future<List<Book>> search(String keyword) {
    final k = '%${keyword.trim()}%';
    return (_db.select(_db.books)
          ..where((t) => t.title.like(k) | t.author.like(k) | t.format.like(k)))
        .get();
  }

  /// 删除书籍（书籍记录 + 托管文件 + 封面 + 进度/标注/书签；源文件由调用方决定）
  Future<void> deleteBook(String id, {bool deleteManagedFile = true}) async {
    await deleteBooks([id], deleteManagedFile: deleteManagedFile);
  }

  /// 批量删除书籍
  Future<void> deleteBooks(
    List<String> ids, {
    bool deleteManagedFile = true,
  }) async {
    if (ids.isEmpty) return;
    for (final id in ids) {
      final row = await getBook(id);
      if (row != null && deleteManagedFile) {
        final f = File(row.filePath);
        if (await f.exists()) await f.delete();
        if (row.coverPath != null) {
          final c = File(row.coverPath!);
          if (await c.exists()) await c.delete();
        }
      }
      // 清理关联数据（进度/标注/书签/标签），避免孤儿记录
      await (_db.delete(_db.progress)..where((t) => t.bookId.equals(id))).go();
      await (_db.delete(
        _db.highlights,
      )..where((t) => t.bookId.equals(id))).go();
      await (_db.delete(_db.bookmarks)..where((t) => t.bookId.equals(id))).go();
      await (_db.delete(_db.bookTags)..where((t) => t.bookId.equals(id))).go();
    }
    await (_db.delete(_db.books)..where((t) => t.id.isIn(ids))).go();
  }

  // ---- 分组 ----

  /// 全部分组名（去重、非空，按名称排序）
  Future<List<String>> listGroups() async {
    final query = _db.selectOnly(_db.books)
      ..addColumns([_db.books.groupName])
      ..where(
        _db.books.groupName.isNotNull() & _db.books.groupName.equals('').not(),
      )
      ..groupBy([_db.books.groupName]);
    final rows = await query.get();
    final groups = rows.map((r) => r.read(_db.books.groupName)!).toList()
      ..sort();
    return groups;
  }

  /// 设置书籍分组（null = 移出分组）
  Future<void> setGroup(String bookId, String? group) async {
    final g = (group == null || group.trim().isEmpty) ? null : group.trim();
    await (_db.update(_db.books)..where((t) => t.id.equals(bookId))).write(
      BooksCompanion(groupName: Value(g)),
    );
  }

  /// 批量移动分组
  Future<void> setGroups(List<String> bookIds, String? group) async {
    final g = (group == null || group.trim().isEmpty) ? null : group.trim();
    if (bookIds.isEmpty) return;
    await (_db.update(_db.books)..where((t) => t.id.isIn(bookIds))).write(
      BooksCompanion(groupName: Value(g)),
    );
  }

  // ---- 进度 ----

  Future<Locator?> getProgress(String bookId) async {
    final row = await (_db.select(
      _db.progress,
    )..where((t) => t.bookId.equals(bookId))).getSingleOrNull();
    if (row == null) return null;
    try {
      return Locator.fromJson(
        jsonDecode(row.locatorJson) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// 全部进度行（备份/同步用）
  Future<List<ProgressRow>> allProgressRows() async {
    final rows = await _db.select(_db.progress).get();
    return [
      for (final r in rows)
        ProgressRow(
          bookId: r.bookId,
          locatorJson: r.locatorJson,
          percent: r.percent,
          updatedAt: r.updatedAt,
          deviceId: r.deviceId,
        ),
    ];
  }

  /// 直接写入进度（同步/恢复用，不更新 lastReadAt）
  Future<void> restoreProgress(
    String bookId,
    String locatorJson,
    double percent,
    int updatedAt, {
    String deviceId = 'local',
  }) async {
    await _db
        .into(_db.progress)
        .insertOnConflictUpdate(
          ProgressCompanion.insert(
            bookId: bookId,
            locatorJson: locatorJson,
            percent: percent,
            updatedAt: updatedAt,
            deviceId: Value(deviceId),
          ),
        );
  }

  /// 同步/恢复：直接注册书籍行（文件由调用方写入托管目录）
  Future<void> upsertBookRow(BooksCompanion companion) =>
      _db.into(_db.books).insertOnConflictUpdate(companion);

  /// 全部设置行（备份用：key → valueJson 原文）
  Future<Map<String, String>> allSettings() async {
    final rows = await _db.select(_db.settingsKv).get();
    return {for (final r in rows) r.key: r.valueJson};
  }

  // ---- 全量附加数据（备份/恢复用：标注/书签/标签/阅读统计） ----

  /// 全部标注行（含 deleted，用于多端合并删除语义）
  Future<List<Map<String, dynamic>>> allHighlightRows() async {
    final rows = await _db.select(_db.highlights).get();
    return [
      for (final r in rows)
        {
          'id': r.id,
          'bookId': r.bookId,
          'locatorJson': r.locatorJson,
          'selectedText': r.selectedText,
          'colorIndex': r.colorIndex,
          'styleIndex': r.styleIndex,
          'note': r.note,
          'createdAt': r.createdAt,
          'updatedAt': r.updatedAt,
          'deleted': r.deleted,
        },
    ];
  }

  /// 全部书签行
  Future<List<Map<String, dynamic>>> allBookmarkRows() async {
    final rows = await _db.select(_db.bookmarks).get();
    return [
      for (final r in rows)
        {
          'id': r.id,
          'bookId': r.bookId,
          'locatorJson': r.locatorJson,
          'title': r.title,
          'createdAt': r.createdAt,
        },
    ];
  }

  /// 全部书籍标签
  Future<List<Map<String, dynamic>>> allBookTagRows() async {
    final rows = await _db.select(_db.bookTags).get();
    return [
      for (final r in rows) {'bookId': r.bookId, 'tag': r.tag},
    ];
  }

  /// 全部阅读统计行
  Future<List<Map<String, dynamic>>> allReadingTimeRows() async {
    final rows = await _db.select(_db.readingTimes).get();
    return [
      for (final r in rows)
        {'bookId': r.bookId, 'day': r.day, 'seconds': r.seconds},
    ];
  }

  /// 恢复标注：按 updatedAt 新者胜（含删除标记）
  Future<void> restoreHighlights(List<Map<String, dynamic>> items) async {
    for (final j in items) {
      final id = j['id'] as String?;
      if (id == null) continue;
      final remoteUpdated = j['updatedAt'] as int? ?? 0;
      final local = await (_db.select(
        _db.highlights,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (local != null && local.updatedAt >= remoteUpdated) continue;
      await _db
          .into(_db.highlights)
          .insertOnConflictUpdate(
            HighlightsCompanion.insert(
              id: id,
              bookId: j['bookId'] as String? ?? '',
              locatorJson: j['locatorJson'] as String? ?? '{}',
              selectedText: j['selectedText'] as String? ?? '',
              colorIndex: j['colorIndex'] as int? ?? 0,
              createdAt: j['createdAt'] as int? ?? 0,
              updatedAt: remoteUpdated,
            ).copyWith(
              styleIndex: Value(j['styleIndex'] as int? ?? 0),
              note: Value(j['note'] as String?),
              deleted: Value(j['deleted'] as bool? ?? false),
            ),
          );
    }
  }

  /// 恢复书签：本机缺失才插入
  Future<void> restoreBookmarks(List<Map<String, dynamic>> items) async {
    for (final j in items) {
      final id = j['id'] as String?;
      if (id == null) continue;
      final exists = await (_db.select(
        _db.bookmarks,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (exists != null) continue;
      await _db
          .into(_db.bookmarks)
          .insert(
            BookmarksCompanion.insert(
              id: id,
              bookId: j['bookId'] as String? ?? '',
              locatorJson: j['locatorJson'] as String? ?? '{}',
              createdAt: j['createdAt'] as int? ?? 0,
            ).copyWith(title: Value(j['title'] as String?)),
          );
    }
  }

  /// 恢复书籍标签：按 (bookId, tag) 缺失才插入
  Future<void> restoreBookTags(List<Map<String, dynamic>> items) async {
    for (final j in items) {
      final bookId = j['bookId'] as String?;
      final tag = j['tag'] as String?;
      if (bookId == null || tag == null || bookId.isEmpty || tag.isEmpty) {
        continue;
      }
      final exists =
          await (_db.select(_db.bookTags)
                ..where((t) => t.bookId.equals(bookId) & t.tag.equals(tag)))
              .getSingleOrNull();
      if (exists != null) continue;
      await _db
          .into(_db.bookTags)
          .insert(BookTagsCompanion.insert(bookId: bookId, tag: tag));
    }
  }

  /// 恢复阅读统计：按 (bookId, day) 取较大秒数
  Future<void> restoreReadingTimes(List<Map<String, dynamic>> items) async {
    for (final j in items) {
      final bookId = j['bookId'] as String?;
      final day = j['day'] as String?;
      final seconds = j['seconds'] as int? ?? 0;
      if (bookId == null || day == null || seconds <= 0) continue;
      final local =
          await (_db.select(_db.readingTimes)
                ..where((t) => t.bookId.equals(bookId) & t.day.equals(day)))
              .getSingleOrNull();
      if (local != null && local.seconds >= seconds) continue;
      await _db
          .into(_db.readingTimes)
          .insertOnConflictUpdate(
            ReadingTimesCompanion.insert(
              bookId: bookId,
              day: day,
              seconds: Value(seconds),
            ),
          );
    }
  }

  Future<void> saveProgress(
    String bookId,
    Locator locator,
    double percent,
  ) async {
    await _db
        .into(_db.progress)
        .insertOnConflictUpdate(
          ProgressCompanion.insert(
            bookId: bookId,
            locatorJson: jsonEncode(locator.toJson()),
            percent: percent,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
    await (_db.update(_db.books)..where((t) => t.id.equals(bookId))).write(
      BooksCompanion(lastReadAt: Value(DateTime.now().millisecondsSinceEpoch)),
    );
  }

  /// 全局进度（0-1），无记录返回 null
  Future<double?> getPercent(String bookId) async {
    final row = await (_db.select(
      _db.progress,
    )..where((t) => t.bookId.equals(bookId))).getSingleOrNull();
    return row?.percent;
  }

  Stream<double?> watchPercent(String bookId) {
    return (_db.select(_db.progress)..where((t) => t.bookId.equals(bookId)))
        .watchSingleOrNull()
        .map((row) => row?.percent);
  }

  // ---- 阅读时长统计 ----

  /// 累计阅读时长：按 书籍 × 本地日期 聚合（秒），供日/周/总统计
  Future<void> addReadingTime(String bookId, int seconds) async {
    if (seconds <= 0) return;
    final now = DateTime.now();
    final day =
        '${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final row =
        await (_db.select(_db.readingTimes)
              ..where((t) => t.bookId.equals(bookId) & t.day.equals(day)))
            .getSingleOrNull();
    if (row == null) {
      await _db
          .into(_db.readingTimes)
          .insert(
            ReadingTimesCompanion.insert(
              bookId: bookId,
              day: day,
              seconds: Value(seconds),
            ),
          );
    } else {
      await (_db.update(_db.readingTimes)
            ..where((t) => t.bookId.equals(bookId) & t.day.equals(day)))
          .write(ReadingTimesCompanion(seconds: Value(row.seconds + seconds)));
    }
  }

  /// 阅读统计：[fromDay, toDay] 日期区间（闭区间，null = 不限），按书汇总秒数。
  /// 书籍可能已被删除 → 标题回退为「已删除书籍」。
  Future<List<ReadingStatRow>> readingStats({
    String? fromDay,
    String? toDay,
  }) async {
    final rows = await _db.select(_db.readingTimes).get();
    final books = await _db.select(_db.books).get();
    final titleById = {for (final b in books) b.id: b.title};

    // 区间过滤（yyyy-MM-dd 字典序即时间序）+ 按书聚合
    final agg = <String, int>{};
    for (final r in rows) {
      if (fromDay != null && r.day.compareTo(fromDay) < 0) continue;
      if (toDay != null && r.day.compareTo(toDay) > 0) continue;
      agg[r.bookId] = (agg[r.bookId] ?? 0) + r.seconds;
    }
    final out = [
      for (final e in agg.entries)
        ReadingStatRow(
          bookId: e.key,
          title: titleById[e.key] ?? '已删除书籍',
          seconds: e.value,
        ),
    ]..sort((a, b) => b.seconds - a.seconds);
    return out;
  }

  /// 指定日期区间的总阅读秒数
  Future<int> readingTotalSeconds({String? fromDay, String? toDay}) async {
    final rows = await readingStats(fromDay: fromDay, toDay: toDay);
    var total = 0;
    for (final r in rows) {
      total += r.seconds;
    }
    return total;
  }

  static String dayOf(DateTime d) =>
      '${d.year}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 单本书的阅读统计（聚合后）
class ReadingStatRow {
  const ReadingStatRow({
    required this.bookId,
    required this.title,
    required this.seconds,
  });

  final String bookId;
  final String title;
  final int seconds;
}

/// 秒数 → 「X 小时 Y 分钟」/「Y 分钟」/「不足 1 分钟」
String formatDuration(int seconds) {
  if (seconds < 60) return '不足 1 分钟';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h == 0) return '$m 分钟';
  return '$h 小时 $m 分钟';
}

enum BookSort { lastRead, addedAt, title }

/// 进度行快照（备份/同步用；与 Progress 表解耦的纯数据类）
class ProgressRow {
  const ProgressRow({
    required this.bookId,
    required this.locatorJson,
    required this.percent,
    required this.updatedAt,
    this.deviceId = 'local',
  });

  final String bookId;
  final String locatorJson;
  final double percent;
  final int updatedAt;
  final String deviceId;
}

class ImportOutcome {
  const ImportOutcome({required this.book, required this.duplicated});

  final Book book;
  final bool duplicated;
}

/// 流式哈希收集器（crypto 分块转换的终点）
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest ?? (throw StateError('哈希尚未完成（未调用 close）'));

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

final bookRepositoryProvider = Provider<BookRepository>((ref) {
  return BookRepository(ref.watch(appDatabaseProvider));
});
