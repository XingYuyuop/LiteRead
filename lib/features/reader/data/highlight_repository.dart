import 'dart:convert';
import 'dart:ui' show Color;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Locator;

import '../../../app/theme_controller.dart';
import '../../../core/storage/app_database.dart';

/// 划线颜色盘（colorIndex 0-4）：黄/绿/蓝/粉/紫
/// 绘制层（page_flow）与样式选择 UI 共用，保证所见即所选。
const List<Color> highlightPalette = [
  Color(0xFFE6B800),
  Color(0xFF4CAF50),
  Color(0xFF2F6FED),
  Color(0xFFE91E63),
  Color(0xFF9C27B0),
];

/// 划线样式：颜色 × 线型
/// colorIndex: 0-4 → 黄/绿/蓝/粉/紫
/// styleIndex: 0=背景高亮 1=直线下划线 2=波浪下划线
class HighlightStyle {
  const HighlightStyle({required this.colorIndex, required this.styleIndex});

  final int colorIndex;
  final int styleIndex;
}

/// 一条批注（划线/标注/笔记）
class BookHighlight {
  const BookHighlight({
    required this.id,
    required this.bookId,
    required this.spineIndex,
    required this.startChar,
    required this.endChar,
    required this.colorIndex,
    required this.styleIndex,
    required this.text,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String bookId;

  /// 选中范围（章内扁平文本坐标，与排版无关）
  final int spineIndex;
  final int startChar;
  final int endChar;

  final int colorIndex;
  final int styleIndex;
  final String text;
  final String? note;
  final int createdAt;
  final int updatedAt;

  bool get isNote => note != null && note!.trim().isNotEmpty;

  HighlightStyle get style =>
      HighlightStyle(colorIndex: colorIndex, styleIndex: styleIndex);
}

/// locatorJson 编解码：{"spineIndex","start","end","chapterLength"}
Map<String, dynamic> encodeHighlightLocator(
  int spineIndex,
  int start,
  int end,
  int chapterLength,
) => {
  'spineIndex': spineIndex,
  'start': start,
  'end': end,
  'chapterLength': chapterLength,
};

(int, int, int) decodeHighlightLocator(String json) {
  final m = jsonDecode(json) as Map<String, dynamic>;
  return (m['spineIndex'] as int, m['start'] as int, m['end'] as int);
}

/// 批注仓库
class HighlightRepository {
  HighlightRepository(this._db);

  final AppDatabase _db;

  BookHighlight _rowToModel(Highlight r) {
    final (spine, start, end) = decodeHighlightLocator(r.locatorJson);
    return BookHighlight(
      id: r.id,
      bookId: r.bookId,
      spineIndex: spine,
      startChar: start,
      endChar: end,
      colorIndex: r.colorIndex,
      styleIndex: r.styleIndex,
      text: r.selectedText,
      note: r.note,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    );
  }

  Future<List<BookHighlight>> listByBook(String bookId) async {
    final rows =
        await (_db.select(_db.highlights)
              ..where((t) => t.bookId.equals(bookId) & t.deleted.equals(false))
              ..orderBy([(t) => OrderingTerm.asc(t.locatorJson)]))
            .get();
    return rows.map(_rowToModel).toList();
  }

  Future<BookHighlight> add({
    required String bookId,
    required int spineIndex,
    required int startChar,
    required int endChar,
    required String text,
    int colorIndex = 0,
    int styleIndex = 0,
    String? note,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'hl-$bookId-$now-${startChar.hashCode}';
    final companion = HighlightsCompanion.insert(
      id: id,
      bookId: bookId,
      locatorJson: jsonEncode(
        encodeHighlightLocator(spineIndex, startChar, endChar, 0),
      ),
      selectedText: text,
      colorIndex: colorIndex,
      styleIndex: Value(styleIndex),
      note: Value(note),
      createdAt: now,
      updatedAt: now,
    );
    await _db.into(_db.highlights).insert(companion);
    return BookHighlight(
      id: id,
      bookId: bookId,
      spineIndex: spineIndex,
      startChar: startChar,
      endChar: endChar,
      colorIndex: colorIndex,
      styleIndex: styleIndex,
      text: text,
      note: note,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> updateStyle(String id, int colorIndex, int styleIndex) {
    return (_db.update(_db.highlights)..where((t) => t.id.equals(id))).write(
      HighlightsCompanion(
        colorIndex: Value(colorIndex),
        styleIndex: Value(styleIndex),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> updateNote(String id, String? note) {
    return (_db.update(_db.highlights)..where((t) => t.id.equals(id))).write(
      HighlightsCompanion(
        note: Value(note),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> remove(String id) {
    return (_db.update(_db.highlights)..where((t) => t.id.equals(id))).write(
      HighlightsCompanion(
        deleted: const Value(true),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }
}

final highlightRepositoryProvider = Provider<HighlightRepository>((ref) {
  return HighlightRepository(ref.watch(appDatabaseProvider));
});
