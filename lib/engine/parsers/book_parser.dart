import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'epub_parser.dart' show BookParseException, EpubParser;
export 'epub_parser.dart' show BookParseException;
import 'md_parser.dart';
import 'mobi_parser.dart';
import 'pdf_parser.dart';
import 'txt_parser.dart';
import '../ir/book_document.dart';

/// 支持的书籍格式
enum BookFormat { epub, mobi, azw3, pdf, md, txt }

BookFormat formatFromExtension(String path) {
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'epub':
      return BookFormat.epub;
    case 'mobi':
    case 'prc':
    case 'azw':
      return BookFormat.mobi;
    case 'azw3':
    case 'kf8':
      return BookFormat.azw3;
    case 'pdf':
      return BookFormat.pdf;
    case 'md':
    case 'markdown':
      return BookFormat.md;
    case 'txt':
    case 'text':
      return BookFormat.txt;
    default:
      throw BookParseException('暂不支持的格式：.$ext');
  }
}

String formatName(BookFormat f) => switch (f) {
  BookFormat.epub => 'EPUB',
  BookFormat.mobi => 'MOBI',
  BookFormat.azw3 => 'AZW3',
  BookFormat.pdf => 'PDF',
  BookFormat.md => 'MD',
  BookFormat.txt => 'TXT',
};

/// 格式探测：扩展名 + 魔数双重校验
BookFormat detectFormat(String path, List<int> bytes) {
  final byExt = formatFromExtension(path);
  // 魔数校验（仅对二进制容器格式）
  if (bytes.length >= 4) {
    if (bytes[0] == 0x50 && bytes[1] == 0x4B) {
      // zip 容器：epub 或 md/txt 打包误判 —— 一律按 EPUB
      return BookFormat.epub;
    }
    if (bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46) {
      return BookFormat.pdf;
    }
    if (bytes[0] == 0x42 &&
        bytes[1] == 0x4F &&
        bytes[2] == 0x4F &&
        bytes[3] == 0x4B) {
      // 'BOOK' MOBI PDB 头
      return BookFormat.mobi;
    }
  }
  // 文本格式信任扩展名
  return byExt;
}

/// 统一解析入口：文件 → BookDocument
class BookParser {
  const BookParser();

  /// 性能优化：EPUB/MOBI/MD/TXT 的全量解析（zip 解压 + 逐章 HTML 解析）
  /// 在后台 isolate 执行，避免大文件打开时阻塞 UI 造成「打开慢」。
  /// PDF 依赖 pdfrx 原生插件上下文，保留在主 isolate（本身开销很小）。
  Future<ParseOutput> parseFile(String path, {List<int>? bytesHint}) async {
    final format = formatFromExtension(path);
    if (format == BookFormat.pdf) return _parseSync(path);
    return Isolate.run(() => _parseSync(path));
  }

  Future<ParseOutput> _parseSync(String path, {List<int>? bytesHint}) async {
    final bytes = bytesHint ?? await File(path).readAsBytes();
    final format = detectFormat(path, bytes);

    switch (format) {
      case BookFormat.epub:
        final r = await const EpubParser().parse(bytes);
        return ParseOutput(
          document: r.document,
          format: format,
          coverBytes: r.coverBytes,
        );

      case BookFormat.md:
        final name = path.split(Platform.pathSeparator).last;
        final r = await const MdParser().parse(
          utf8Safe(bytes),
          title: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        );
        return ParseOutput(document: r.document, format: format);

      case BookFormat.txt:
        final name = path.split(Platform.pathSeparator).last;
        final r = await const TxtParser().parse(
          bytes,
          title: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        );
        return ParseOutput(
          document: r.document,
          format: format,
          txtEncoding: r.encoding,
        );

      case BookFormat.mobi:
      case BookFormat.azw3:
        final r = await const MobiParser().parse(bytes);
        return ParseOutput(
          document: r.document,
          format: format,
          coverBytes: r.coverBytes,
        );
      case BookFormat.pdf:
        final r = await const PdfParser().parse(path);
        return ParseOutput(
          document: r.document,
          format: format,
          coverBytes: r.coverBytes,
          pageCount: r.pageCount,
        );
    }
  }
}

class ParseOutput {
  const ParseOutput({
    required this.document,
    required this.format,
    this.coverBytes,
    this.txtEncoding,
    this.pageCount,
  });

  final BookDocument document;
  final BookFormat format;
  final List<int>? coverBytes;
  final TxtEncoding? txtEncoding;

  /// PDF 专属：总页数（其他格式为 null）
  final int? pageCount;
}

String utf8Safe(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return utf8.decode(bytes, allowMalformed: true);
  }
}
