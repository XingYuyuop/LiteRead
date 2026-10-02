import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';

import '../ir/book_document.dart';
import 'epub_parser.dart' show BookParseException;
import 'html_lite_converter.dart';

/// MOBI / AZW3（KF8）基础解析器（计划书 M3「文本+封面+图片」子集，风险 R1 缩小范围策略）。
///
/// PDB 容器 → PalmDOC 记录 → PalmDOC-LZ77 解压 → HTML → 复用 HTML-lite 管线，
/// 从此 MOBI/AZW3 与 EPUB/MD 共用全部排版/主题/标注能力。
///
/// 不支持（抛 [BookParseException] 明确提示）：DRM 加密。
/// HUFF/CDIC 压缩（KF8/AZW3 常见）已完整支持，算法移植自 KindleUnpack。
/// 分章：MOBI6 按 <mbp:pagebreak/>；KF8 无此标记时整书单章（目录仍可跳转）。
class MobiParser {
  const MobiParser();

  /// [bookCss] 开启后提取原书 text-align 对齐（见 HtmlLiteConverter）。
  Future<MobiParseResult> parse(List<int> bytes, {bool bookCss = false}) async {
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
    if (compression != 1 && compression != 2 && compression != 17480) {
      throw BookParseException('未知的 MOBI 压缩类型：$compression');
    }

    // ---- MOBI header（可选：老 PRC 无此头） ----
    var textEncoding = 1252; // 默认 Latin-1
    var firstImageIndex = -1;
    var extraFlags = 0; // 记录尾部附加数据标志（KF8/AZW3 必有）
    var huffRecordIndex = 0; // HUFF 记录号（1-based，压缩类型 17480 时有效）
    var huffRecordCount = 0; // HUFF + CDIC 记录总数
    String? fullName;
    final hasMobiHeader = rec0.length >= 24 && _ascii(rec0, 16, 'MOBI');
    if (hasMobiHeader) {
      final headerLength = _u32(rec0, 20);
      bool has(int absOffset) =>
          rec0.length >= absOffset + 4 && 16 + headerLength > absOffset;
      if (has(28)) textEncoding = _u32(rec0, 28);
      if (has(108)) firstImageIndex = _u32(rec0, 108);
      // 112/116 = MOBI header 内的 Huffman 记录偏移与数量（1-based）
      if (has(112)) huffRecordIndex = _u32(rec0, 112);
      if (has(116)) huffRecordCount = _u32(rec0, 116);
      // 242 = MOBI header 内的 extra record data flags（16 位）
      if (rec0.length >= 244 && 16 + headerLength >= 244) {
        extraFlags = _u16(rec0, 242);
      }
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
    // 关键修复：KF8/AZW3 记录尾部带附加数据（extra data flags），
    // 不剥离会污染解压流，导致整本书乱码。
    // HUFF/CDIC（17480）：先加载 Huffman 表与多张 CDIC 词典，逐记录解码。
    _HuffCdic? huff;
    if (compression == 17480) {
      // HUFF 记录号（1-based）+ 数量（含 HUFF 自身）必须合法，
      // 缺失/越界直接报词典缺失，避免深层解码抛出模糊错误
      if (huffRecordIndex < 1 ||
          huffRecordCount < 2 ||
          huffRecordIndex - 1 + huffRecordCount > numRecords) {
        throw const BookParseException('该 AZW3 的 HUFF/CDIC 词典缺失或损坏');
      }
      huff = _HuffCdic();
      huff.loadHuff(record(huffRecordIndex - 1));
      for (var i = 1; i < huffRecordCount; i++) {
        final cdic = record(huffRecordIndex - 1 + i);
        if (cdic.isEmpty) continue;
        huff.loadCdic(cdic);
      }
      if (huff.dictionaryCount == 0) {
        throw const BookParseException('该 AZW3 的 HUFF/CDIC 词典缺失或损坏');
      }
    }
    final textBytes = BytesBuilder(copy: false);
    for (var i = 1; i <= textRecordCount && i < numRecords; i++) {
      final raw = record(i);
      final clean = extraFlags != 0 ? _stripTrailingData(raw, extraFlags) : raw;
      if (compression == 2) {
        textBytes.add(palmDocDecompress(clean));
      } else if (compression == 17480) {
        textBytes.add(huff!.unpack(clean));
      } else {
        textBytes.add(clean);
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
      final blocks = converter.convert(parts[i], bookCss: bookCss);
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

    // 章节标题回填：章名只认 h1-h2 标题块，仅含 h3-h6 标题的章会落到
    // 「第 N 节」兜底，而目录条目包含全部标题块 → 章名与目录名不一致。
    // 此处用该章第一条目录条目（按章内偏移排序的首个标题）回填章名。
    // 修复阅读页章节名显示「第 N 节」而目录显示实际标题的 bug
    final fallbackTitleRe = RegExp(r'^第 \d+ 节$');
    for (var i = 0; i < chapters.length; i++) {
      if (!fallbackTitleRe.hasMatch(chapters[i].title)) continue;
      TocEntry? first;
      for (final e in toc) {
        if (e.spineIndex == i) {
          first = e;
          break;
        }
      }
      final t = first?.title.trim() ?? '';
      if (t.isNotEmpty && t != chapters[i].title) {
        chapters[i] = Chapter(
          id: chapters[i].id,
          title: t,
          blocks: chapters[i].blocks,
        );
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

  /// 剥离记录尾部的附加数据（extra record data entries）。
  ///
  /// 规则（MobileRead MOBI 规范 / KindleUnpack 实现）：
  ///  - flags 位 15..1：每个附加条目的长度由记录尾部「反序变长整数」给出；
  ///  - flags 位 0：条目长度由尾部 1-4 字节（高位 bit 作为终止/继续标志）编码。
  static Uint8List _stripTrailingData(Uint8List data, int flags) {
    var end = data.length;
    for (var bit = 15; bit >= 1; bit--) {
      if (flags & (1 << bit) == 0) continue;
      final size = _readBackwardVarint(data, end);
      if (size <= 0 || size > end) break;
      end -= size;
    }
    if (flags & 1 != 0 && end > 0) {
      end -= _trailingEntrySize(data, end);
    }
    if (end <= 0 || end >= data.length) return data;
    return Uint8List.sublistView(data, 0, end);
  }

  /// 反序变长整数：从尾部向前读，每字节低 7 位按位权累加，高位为 0 终止
  static int _readBackwardVarint(Uint8List data, int end) {
    var pos = end;
    var result = 0;
    var bitpos = 0;
    while (pos > 0) {
      final v = data[pos - 1];
      result |= (v & 0x7F) << bitpos;
      pos--;
      bitpos += 7;
      if (v & 0x80 == 0 || bitpos >= 35) return result;
    }
    return result;
  }

  /// flags 位 0 的条目长度编码：反序读，每字节的最高位累加进结果
  static int _trailingEntrySize(Uint8List data, int end) {
    var pos = end;
    var result = 0;
    var bitpos = 0;
    while (pos > 0 && bitpos < 4) {
      final v = data[pos - 1];
      result |= (v & 0x80) >> bitpos;
      pos--;
      bitpos++;
      if (v & 0x80 == 0) return result;
    }
    return result;
  }

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

  /// 按 MOBI textEncoding 解码：65001=UTF-8（容错）。
  /// 中文 MOBI 常错误标注 1252：高位字节占比明显时回退 GBK 解码，修复乱码。
  static String _decode(List<int> data, int encoding) {
    if (encoding == 65001) {
      return utf8DecodeBestEffort(data);
    }
    var high = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] >= 0x80) high++;
    }
    if (high > 0 && high * 10 >= data.length) {
      try {
        final text = gbk_bytes.decode(data);
        if (_hasCJK(text)) return text;
      } catch (_) {
        // 非 GBK 内容，退回 Latin-1
      }
    }
    return String.fromCharCodes(data);
  }

  static bool _hasCJK(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x4E00 && c <= 0x9FFF) return true;
    }
    return false;
  }
}

class MobiParseResult {
  const MobiParseResult({required this.document, this.coverBytes});

  final BookDocument document;
  final List<int>? coverBytes;
}

/// HUFF/CDIC Huffman 解码器（KF8/AZW3 压缩类型 17480）。
///
/// 算法忠实移植 KindleUnpack（lib/mobi_uncompress.py，MIT License）：
///  - HUFF 记录：256 项一级缓存表（dict1，索引 = 32 位码的前 8 位）
///    + 64 个 u32 的 mincode/maxcode 表（对应码长 1..32）；
///  - CDIC 记录：码元词典，每项 u16 偏移 + 长度/标志位；
///  - 词典项可递归引用其他项（flag=0 表示未展开）。
class _HuffCdic {
  final List<(int, bool, int)> _dict1 = []; // (codelen, term, maxcode)
  final List<int> _mincode = [];
  final List<int> _maxcode = [];
  final List<(Uint8List, bool)?> _dictionary = [];

  int get dictionaryCount => _dictionary.length;

  void loadHuff(Uint8List huff) {
    if (huff.length < 24 || !_ascii(huff, 0, 'HUFF')) {
      throw const BookParseException('AZW3 解码失败：HUFF 记录损坏');
    }
    final off1 = _u32(huff, 8);
    final off2 = _u32(huff, 12);
    if (off1 <= 0 || off1 + 4 * 256 > huff.length) {
      throw const BookParseException('AZW3 解码失败：HUFF 缓存表越界');
    }
    if (off2 <= 0 || off2 + 4 * 64 > huff.length) {
      throw const BookParseException('AZW3 解码失败：HUFF 码表越界');
    }

    // 一级缓存表：256 项，codelen = v & 0x1f，term = v & 0x80，maxcode = v >> 8
    for (var i = 0; i < 256; i++) {
      final v = _u32(huff, off1 + 4 * i);
      final codelen = v & 0x1f;
      if (codelen == 0) {
        throw const BookParseException('AZW3 解码失败：HUFF 码长为 0');
      }
      final term = v & 0x80 != 0;
      final maxcode = (((v >> 8) + 1) << (32 - codelen)) - 1;
      _dict1.add((codelen, term, maxcode));
    }

    // mincode/maxcode 表：64 个 u32，偶位 mincode、奇位 maxcode，码长 1..32。
    // c==1 时理论上限 2^63 会溢出 Dart int，用 BigInt 钳位到 int 最大值。
    final intMax = BigInt.parse('9223372036854775807');
    _mincode.add(0);
    _maxcode.add(((BigInt.one << 32) - BigInt.one).toInt());
    for (var c = 1; c <= 32; c++) {
      final mnRaw = _u32(huff, off2 + 4 * (2 * (c - 1)));
      var mn = BigInt.from(mnRaw) << (32 - c);
      if (mn > intMax) mn = intMax;
      _mincode.add(mn.toInt());
      final mxRaw = _u32(huff, off2 + 4 * (2 * (c - 1) + 1));
      var mx = BigInt.from(mxRaw + 1) << (32 - c);
      if (mx > intMax) mx = intMax;
      _maxcode.add(mx.toInt() - 1);
    }
  }

  void loadCdic(Uint8List cdic) {
    if (cdic.length < 16 || !_ascii(cdic, 0, 'CDIC')) {
      throw const BookParseException('AZW3 解码失败：CDIC 记录损坏');
    }
    final phrases = _u32(cdic, 8);
    final bits = _u32(cdic, 12);
    if (phrases <= _dictionary.length || bits <= 0 || bits > 31) return;
    final n = (1 << bits) < (phrases - _dictionary.length)
        ? (1 << bits)
        : phrases - _dictionary.length;
    for (var i = 0; i < n; i++) {
      final off = _u16(cdic, 16 + 2 * i);
      if (18 + off + 2 > cdic.length) break;
      final blen = _u16(cdic, 16 + off);
      final len = blen & 0x7fff;
      if (18 + off + len > cdic.length) break;
      final slice = Uint8List.sublistView(cdic, 18 + off, 18 + off + len);
      _dictionary.add((slice, blen & 0x8000 != 0));
    }
  }

  /// 解码一条文本记录
  Uint8List unpack(Uint8List data) {
    var bitsLeft = data.length * 8;
    // 尾部补 8 个零字节，保证 64 位滑动窗口读取越界安全
    final padded = Uint8List(data.length + 8);
    padded.setRange(0, data.length, data);
    final bd = ByteData.sublistView(padded);
    var pos = 0;
    var x = _u64(bd, pos);
    var n = 32;
    final out = BytesBuilder(copy: false);

    while (true) {
      if (n <= 0) {
        pos += 4;
        if (pos + 8 > padded.length) break;
        x = _u64(bd, pos);
        n += 32;
      }
      final code = (x >> n) & 0xFFFFFFFF;
      final e = _dict1[code >> 24];
      var codelen = e.$1;
      var maxcode = e.$3;
      if (!e.$2) {
        // 未命中一级缓存：沿码长递增查找
        while (codelen < 32 && code < _mincode[codelen]) {
          codelen++;
        }
        if (codelen > 32) break;
        maxcode = _maxcode[codelen];
      }
      n -= codelen;
      bitsLeft -= codelen;
      if (bitsLeft < 0) break;
      final r = (maxcode - code) >> (32 - codelen);
      if (r < 0 || r >= _dictionary.length) break; // 损坏防御
      var entry = _dictionary[r];
      if (entry == null) break; // 循环引用防御
      if (!entry.$2) {
        // 未展开的词典项：递归展开后缓存
        _dictionary[r] = null;
        final expanded = unpack(entry.$1);
        _dictionary[r] = (expanded, true);
        entry = (expanded, true);
      }
      out.add(entry.$1);
    }
    return out.toBytes();
  }

  // ---- 基础工具（与 MobiParser 内同名方法一致） ----

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

  static int _u64(ByteData bd, int o) => bd.getUint64(o);
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
