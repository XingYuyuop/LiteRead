import 'dart:io';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import '../ir/book_document.dart';
import 'epub_parser.dart' show BookParseException;

class PdfParseResult {
  const PdfParseResult({
    required this.document,
    required this.pageCount,
    this.coverBytes,
  });

  final BookDocument document;

  /// PDF 页数（阅读进度按页计）
  final int pageCount;
  final List<int>? coverBytes;
}

/// PDF 解析器：页数 + 封面缩略图。
///
/// PDF 为固定版式，不走文本分页引擎；阅读渲染由 pdfrx 直接呈现
/// （ReaderPage 对 PDF 格式走独立视图）。
/// 注：pdfrx 1.3.x 不暴露 Info 字典，标题回退文件名。
class PdfParser {
  const PdfParser();

  Future<PdfParseResult> parse(String path) async {
    PdfDocument doc;
    try {
      doc = await PdfDocument.openFile(path);
    } catch (e) {
      throw BookParseException('PDF 打开失败，文件可能损坏或已加密（$e）');
    }

    final name = path
        .split(Platform.pathSeparator)
        .last
        .replaceFirst(RegExp(r'\.[^.]+$'), '');
    final pageCount = doc.pages.length;

    // 封面：渲染第 1 页为 PNG 缩略图
    List<int>? cover;
    try {
      final page = doc.pages.first;
      final w = 360.0;
      final h = page.width > 0 ? w * page.height / page.width : w * 1.414;
      final rendered = await page.render(fullWidth: w, fullHeight: h);
      if (rendered != null) {
        final img = await rendered.createImage();
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        cover = data?.buffer.asUint8List();
        img.dispose();
        rendered.dispose();
      }
    } catch (_) {
      // 封面失败不阻塞导入
    }

    try {
      await doc.dispose();
    } catch (_) {}

    final document = BookDocument(
      meta: BookMeta(title: name),
      // 单一占位章；渲染与进度均由 PDF 视图按页管理
      spine: [Chapter(id: 'pdf', title: name, blocks: const [])],
      toc: const [],
      resources: ResourceStore((_) async => null),
    );
    return PdfParseResult(
      document: document,
      pageCount: pageCount,
      coverBytes: cover,
    );
  }
}
