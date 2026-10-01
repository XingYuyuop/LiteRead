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

  /// 导入文件：解析元数据 → 内容哈希去重 → 托管副本 + 封面 → 入库
  Future<ImportOutcome> importFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final id = sha256.convert(bytes).toString();

    final existing = await (_db.select(
      _db.books,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing != null) {
      return ImportOutcome(book: existing, duplicated: true);
    }

    final output = await const BookParser().parseFile(path, bytesHint: bytes);
    final doc = output.document;

    // 托管副本
    final ext = path.toLowerCase().split('.').last;
    final libDir = await AppDirs.library();
    final managedPath = '${libDir.path}${Platform.pathSeparator}$id.$ext';
    await File(managedPath).writeAsBytes(bytes, flush: true);

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
      fileSize: Value(bytes.length),
      coverPath: Value(coverPath),
      addedAt: DateTime.now().millisecondsSinceEpoch,
      metaJson: Value(
        jsonEncode({
          'chapterCount': doc.spine.length,
          'charCount': doc.totalChars,
        }),
      ),
    );
    await _db.into(_db.books).insertOnConflictUpdate(companion);

    final row = await (_db.select(
      _db.books,
    )..where((t) => t.id.equals(id))).getSingle();
    return ImportOutcome(book: row, duplicated: false);
  }

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

  /// 删除书籍（书籍记录 + 托管文件 + 封面；源文件由调用方决定）
  Future<void> deleteBook(String id, {bool deleteManagedFile = true}) async {
    final row = await getBook(id);
    if (row != null && deleteManagedFile) {
      final f = File(row.filePath);
      if (await f.exists()) await f.delete();
      if (row.coverPath != null) {
        final c = File(row.coverPath!);
        if (await c.exists()) await c.delete();
      }
    }
    await (_db.delete(_db.books)..where((t) => t.id.equals(id))).go();
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
}

enum BookSort { lastRead, addedAt, title }

class ImportOutcome {
  const ImportOutcome({required this.book, required this.duplicated});

  final Book book;
  final bool duplicated;
}

final bookRepositoryProvider = Provider<BookRepository>((ref) {
  return BookRepository(ref.watch(appDatabaseProvider));
});
