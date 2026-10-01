import 'dart:typed_data';

import '../ir/book_document.dart';
import 'epub_parser.dart' show BookParseException;
import 'html_lite_converter.dart';

/// MOBI / AZW3（KF8）基础解析器（计划书 M3「文本+封面+图片」子集，风险 R1 缩小范围策略）。
///
/// PDB 容器 → PalmDOC 记录 → PalmDOC-LZ77 解压 → HTML → 复用 HTML-lite 管线，
/// 从此 MOBI/AZW3 与 EPUB/MD 共用全部排版/主题/标注能力。
///
/// 不支持（抛 [BookParseException] 明确提示）：HUFF/CDIC 压缩、DRM 加密。
/// 分章：MOBI6 按 <mbp:pagebreak/>；KF8 无此标记时整书单章（目录仍可跳转）。
class MobiParser {
  const MobiParser();

  Future<MobiParseResult> parse(List<int> bytes) async {
    if (bytes.length < 80) {
      throw const BookParseException('MOBI 文件损坏：长度不足');
    }
    if (!_ascii(bytes, 60, 'BOOK')) {
      throw const BookParseException('无效的 MOBI/PDB 文件：缺少 BOOKMOBI 标识');
    }

    final numRecords = _u16(bytes, 76);
    if (numRecords < 1) {
      throw const BookParseException('MOBI 文件损坏：无记录');
    }
    final offsets = <int>[];
    for (var i = 0; i < numRecords; i++) {
      final o = 78 + 8 * i;
      if (o + 4 > bytes.length) {
        throw const BookParseException('MOBI 文件损坏：记录表越界');
      }
      offsets.add(_u32(bytes, o));
    }

    Uint8List record(int i) {
      if (i < 0 || i >= numRecords) return Uint8List(0);
      final start = offsets[i];
      final end = i + 1 < numRecords ? offsets[i + 1] : bytes.length;
      if (start >= end || end > bytes.length) return Uint8List(0);
      return Uint8List.fromList(bytes.sublist(start, end));
    }

    final rec0 = record(0);
    if (rec0.length < 16) {
      throw const BookParseException('MOBI 文件损坏：记录 0 过短');
    }

    // ---- PalmDOC header（record 0 前 16 字节） ----
    final compression = _u16(rec0, 0);
    final textLength = _u32(rec0, 4);
    final textRecordCount = _u16(rec0, 8);
    final encryption = _u16(rec0, 12);
    if (encryption != 0) {
      throw const BookParseException('该文件包含 DRM 加密，法律风险原因明确不支持');
    }
    if (compression == 17480) {
      throw const BookParseException('该 MOBI 使用 HUFF/CDIC 压缩，当前版本暂不支持');
    }
    if (compression != 1 && compression != 2) {
      throw BookParseException('未知的 MOBI 压缩类型：$compression');
    }

    // ---- MOBI header（可选：老 PRC 无此头） ----
    var textEncoding = 1252; // 默认 Latin-1
    var firstImageIndex = -1;
    String? fullName;
    final hasMobiHeader = rec0.length >= 24 && _ascii(rec0, 16, 'MOBI');
    if (hasMobiHeader) {
      final headerLength = _u32(rec0, 20);
      bool has(int absOffset) =>
          rec0.length >= absOffset + 4 && 16 + headerLength > absOffset;
      if (has(28)) textEncoding = _u32(rec0, 28);
      if (has(108)) firstImageIndex = _u32(rec0, 108);
      if (has(84) && has(88)) {
        final off = _u32(rec0, 84);
        final len = _u32(rec0, 88);
        if (off >= 0 && len > 0 && off + len <= rec0.length) {
          fullName = _decode(rec0.sublist(off, off + len), textEncoding);
        }
      }
    }

    // ---- EXTH 元数据（可选） ----
    var author = <String?>[];
    var title503 = <String?>[];
    var coverOffset = -1;
    if (hasMobiHeader && rec0.length >= 132) {
      final headerLength = _u32(rec0, 20);
      final exthFlags = _u32(rec0, 128);
      final exthStart = 16 + headerLength;
      if (exthFlags & 0x40 != 0 &&
          exthStart + 12 <= rec0.length &&
          _ascii(rec0, exthStart, 'EXTH')) {
        final count = _u32(rec0, exthStart + 8);
        var p = exthStart + 12;
        for (var i = 0; i < count && p + 8 <= rec0.length; i++) {
          final type = _u32(rec0, p);
          final len = _u32(rec0, p + 4);
          if (len < 8 || p + len > rec0.length) break;
          final data = rec0.sublist(p + 8, p + len);
          switch (type) {
            case 100:
              author.add(_decode(data, textEncoding));
            case 503:
              title503.add(_decode(data, textEncoding));
            case 201:
              if (data.length >= 4) coverOffset = _u32(data, 0);
          }
          p += len;
        }
      }
    }

    // ---- 文本记录解压拼接 ----
    final textBytes = BytesBuilder(copy: false);
    for (var i = 1; i <= textRecordCount && i < numRecords; i++) {
      final raw = record(i);
      if (compression == 2) {
        textBytes.add(palmDocDecompress(raw));
      } else {
        textBytes.add(raw);
      }
    }
    var all = textBytes.toBytes();
    if (textLength > 0 && textLength < all.length) {
      all = Uint8List.sublistView(all, 0, textLength);
    }
    final html = _decode(all, textEncoding);
    if (html.trim().isEmpty) {
      throw const BookParseException('MOBI 无可读文本内容');
    }

    // ---- 分章：<mbp:pagebreak/>（MOBI6）；KF8 无标记时单章 ----
    final parts = html
        .split(RegExp(r'<mbp:pagebreak\s*/?>', caseSensitive: false))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final converter = const HtmlLiteConverter();
    final chapters = <Chapter>[];
    for (var i = 0; i < parts.length; i++) {
      final blocks = converter.convert(parts[i]);
      if (blocks.isEmpty) continue;
      String? title;
      for (final b in blocks) {
        if (b.type == BlockType.heading &&
            b.headingLevel <= 2 &&
            b.plainText.trim().isNotEmpty) {
          title = b.plainText.trim();
          break;
        }
      }
      chapters.add(
        Chapter(
          id: 'mobi-$i',
          title: title ?? (i == 0 ? '正文' : '第 ${i + 1} 节'),
          blocks: blocks,
        ),
      );
    }
    if (chapters.isEmpty) {
      throw const BookParseException('MOBI 内容解析为空');
    }

    // ---- 目录：章内标题块（h1-h3）→ 定位条目 ----
    final toc = <TocEntry>[];
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      final offsets = c.blockOffsets;
      var added = false;
      for (var b = 0; b < c.blocks.length; b++) {
        final block = c.blocks[b];
        if (block.type == BlockType.heading &&
            block.plainText.trim().isNotEmpty) {
          toc.add(
            TocEntry(
              title: block.plainText.trim(),
              spineIndex: i,
              charOffset: offsets[b],
              depth: block.headingLevel - 1,
            ),
          );
          added = true;
        }
      }
      if (!added) {
        toc.add(TocEntry(title: c.title, spineIndex: i));
      }
    }

    // ---- 资源：recindex:NNNN / kindle:embed:NNNN → 图片记录 ----
    Uint8List imageRecord(int idx) =>
        firstImageIndex >= 0 ? record(firstImageIndex + idx) : Uint8List(0);

    Uint8List resolveImage(String id) {
      int? n;
      if (id.startsWith('recindex:')) {
        n = int.tryParse(id.substring(9).trim());
      } else if (id.startsWith('kindle:embed:')) {
        n = int.tryParse(id.substring(13).trim());
      } else if (id == 'cover') {
        return coverOffset >= 0 ? imageRecord(coverOffset) : Uint8List(0);
      }
      if (n == null || n < 1) return Uint8List(0);
      return imageRecord(n - 1);
    }

    final resources = ResourceStore((id) async => resolveImage(id));

    // ---- 封面：EXTH 201 coverOffset → 图片记录 ----
    Uint8List? coverBytes;
    if (coverOffset >= 0) {
      final b = imageRecord(coverOffset);
      if (b.isNotEmpty) coverBytes = b;
    }

    final title =
        title503.firstWhere(
          (t) => t != null && t.trim().isNotEmpty,
          orElse: () => null,
        ) ??
        (fullName?.trim().isNotEmpty == true ? fullName!.trim() : null) ??
        '未命名';

    return MobiParseResult(
      document: BookDocument(
        meta: BookMeta(
          title: title,
          author: author
              .firstWhere(
                (a) => a != null && a.trim().isNotEmpty,
                orElse: () => null,
              )
              ?.trim(),
          coverResource: coverBytes != null ? 'cover' : null,
        ),
        spine: chapters,
        toc: toc,
        resources: resources,
      ),
      coverBytes: coverBytes,
    );
  }

  // ---- PalmDOC LZ77 解压（compression==2） ----

  /// 经典 PalmDOC（LZ77 滑动窗口，距离 11bit / 长度 3-10）解压。
  static Uint8List palmDocDecompress(List<int> data) {
    final out = <int>[];
    var i = 0;
    while (i < data.length) {
      final c = data[i++];
      if (c == 0) {
        out.add(0);
      } else if (c <= 8) {
        for (var j = 0; j < c && i < data.length; j++) {
          out.add(data[i++]);
        }
      } else if (c < 0x80) {
        out.add(c);
      } else if (c < 0xC0) {
        if (i >= data.length) break;
        final pair = (c << 8) | data[i++];
        final distance = (pair >> 3) & 0x7FF;
        final length = (pair & 7) + 3;
        if (distance == 0 || distance > out.length) continue; // 损坏防御
        for (var j = 0; j < length; j++) {
          out.add(out[out.length - distance]);
        }
      } else {
        out.add(0x20);
        out.add(c ^ 0xC0);
      }
    }
    return Uint8List.fromList(out);
  }

  // ---- 基础工具 ----

  static bool _ascii(List<int> b, int offset, String s) {
    if (offset + s.length > b.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (b[offset + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _u16(List<int> b, int o) => (b[o] << 8) | b[o + 1];

  static int _u32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  /// 按 MOBI textEncoding 解码：65001=UTF-8（容错），其余按 Latin-1（CP1252 近似）
  static String _decode(List<int> data, int encoding) {
    if (encoding == 65001) {
      return utf8DecodeBestEffort(data);
    }
    return String.fromCharCodes(data);
  }
}

class MobiParseResult {
  const MobiParseResult({required this.document, this.coverBytes});

  final BookDocument document;
  final List<int>? coverBytes;
}

/// UTF-8 容错解码（坏字节替换为 U+FFFD，不抛异常）
String utf8DecodeBestEffort(List<int> data) {
  final out = StringBuffer();
  var i = 0;
  while (i < data.length) {
    final b = data[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i++;
    } else if (b < 0xC0) {
      out.write('\uFFFD');
      i++;
    } else if (b < 0xE0 && i + 1 < data.length) {
      out.writeCharCode(((b & 0x1F) << 6) | (data[i + 1] & 0x3F));
      i += 2;
    } else if (b < 0xF0 && i + 2 < data.length) {
      out.writeCharCode(
        ((b & 0x0F) << 12) | ((data[i + 1] & 0x3F) << 6) | (data[i + 2] & 0x3F),
      );
      i += 3;
    } else if (i + 3 < data.length) {
      final cp =
          ((b & 0x07) << 18) |
          ((data[i + 1] & 0x3F) << 12) |
          ((data[i + 2] & 0x3F) << 6) |
          (data[i + 3] & 0x3F);
      out.writeCharCode(cp); // BMP 之外由 StringBuffer 处理代理对
      i += 4;
    } else {
      out.write('\uFFFD');
      i++;
    }
  }
  return out.toString();
}
