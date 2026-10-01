import 'dart:convert';

import 'package:gbk_codec/gbk_codec.dart';

import '../ir/book_document.dart';

/// TXT 解析器（计划书 §3.5.6）。
///
/// 编码探测：UTF-8 BOM/严格校验 → GBK → Big5(退化为 GBK 尝试)。
/// 智能分章：中文章节模式（第X章/卷/回）+ 英文（Chapter N），可关闭。
class TxtParser {
  const TxtParser({this.smartChapters = true});

  /// 关闭后整本书作为单章
  final bool smartChapters;

  /// 章节标题模式（计划书 FR-A07）
  static final _chapterRegex = RegExp(
    r'^\s*('
    r'第\s*[零一二三四五六七八九十百千万0-9两\d]+\s*[章节卷回部集幕]'
    r'|序章|序言|楔子|前言|引子|后记|尾声|终章|番外|附录'
    r'|Chapter\s+[\dIVXLCivxlc]+|CHAPTER\s+[\dIVXLCivxlc]+'
    r'|卷[零一二三四五六七八九十百千万0-9\d]+'
    r')\s*[^\n]{0,40}$',
    multiLine: true,
  );

  TxtDecodeResult detectAndDecode(List<int> bytes) {
    // 1. BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return TxtDecodeResult(
        utf8.decode(bytes.sublist(3), allowMalformed: true),
        TxtEncoding.utf8,
      );
    }
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
            (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      final bigEndian = bytes[0] == 0xFE;
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(
          bigEndian
              ? (bytes[i] << 8) | bytes[i + 1]
              : bytes[i] | (bytes[i + 1] << 8),
        );
      }
      return TxtDecodeResult(String.fromCharCodes(units), TxtEncoding.utf16);
    }

    // 2. 严格 UTF-8 校验
    try {
      return TxtDecodeResult(utf8.decode(bytes), TxtEncoding.utf8);
    } on FormatException {
      // fallthrough
    }

    // 3. GBK（gbk_codec 含 GBK/GB2312/GB18030 大部分）
    final decoded = gbk_bytes.decode(bytes);
    return TxtDecodeResult(decoded, TxtEncoding.gbk);
  }

  Future<TxtParseResult> parse(List<int> bytes, {String title = ''}) async {
    final decoded = detectAndDecode(bytes);
    final text = decoded.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final chapters = smartChapters && text.length > 500
        ? _splitChapters(text)
        : [Chapter(id: 'txt-0', title: '正文', blocks: _paragraphs(text))];

    final docTitle = title.isNotEmpty ? title : _firstLine(text, maxLength: 40);

    final toc = [
      for (var i = 0; i < chapters.length; i++)
        TocEntry(title: chapters[i].title, spineIndex: i),
    ];

    return TxtParseResult(
      document: BookDocument(
        meta: BookMeta(title: docTitle.isEmpty ? '未命名' : docTitle),
        spine: chapters,
        toc: toc,
        resources: ResourceStore((_) async => null),
      ),
      encoding: decoded.encoding,
    );
  }

  /// 按章节标题切分；无匹配时退化为按 2 万字切块（利于分页缓存）
  List<Chapter> _splitChapters(String text) {
    final matches = _chapterRegex.allMatches(text).toList();
    // 仅当命中 ≥2 处才认为有效分章
    final realMatches = matches.length >= 2 ? matches : null;
    if (realMatches == null) {
      return _chunkByTextLength(text);
    }

    final chapters = <Chapter>[];
    // 文首前置内容（版权/简介等）
    final firstStart = realMatches.first.start;
    if (firstStart > 200) {
      final pre = text.substring(0, firstStart).trim();
      if (pre.isNotEmpty) {
        chapters.add(
          Chapter(id: 'txt-pre', title: '开篇', blocks: _paragraphs(pre)),
        );
      }
    }

    for (var i = 0; i < realMatches.length; i++) {
      final m = realMatches[i];
      final start = m.start;
      final end = i + 1 < realMatches.length
          ? realMatches[i + 1].start
          : text.length;
      final body = text.substring(start, end);
      final titleLine = text.substring(m.start, m.end).trim();
      final nlIdx = body.indexOf('\n');
      final bodyText = nlIdx == -1 ? '' : body.substring(nlIdx + 1);
      final blocks = _paragraphs(bodyText.trim());
      chapters.add(Chapter(id: 'txt-$i', title: titleLine, blocks: blocks));
    }
    return chapters;
  }

  /// 无章节标记的超长文本：按 ~20000 字切块并附序号
  List<Chapter> _chunkByTextLength(String text) {
    const size = 20000;
    if (text.length <= size * 1.5) {
      return [Chapter(id: 'txt-0', title: '正文', blocks: _paragraphs(text))];
    }
    final chapters = <Chapter>[];
    var pos = 0;
    var idx = 0;
    while (pos < text.length) {
      var end = (pos + size).clamp(0, text.length);
      if (end < text.length) {
        // 尽量在段落边界切
        final nl = text.indexOf('\n', end);
        if (nl != -1 && nl - end < 2000) end = nl + 1;
      }
      final part = text.substring(pos, end).trim();
      if (part.isNotEmpty) {
        idx++;
        chapters.add(
          Chapter(id: 'txt-$idx', title: '第 $idx 节', blocks: _paragraphs(part)),
        );
      }
      pos = end;
    }
    return chapters;
  }

  /// 空行分段；单行超长（无空行的网络文本）按句读硬切
  List<Block> _paragraphs(String text) {
    final blocks = <Block>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.length <= 300) {
        blocks.add(_p(line));
      } else {
        // 无空行长段落按句号切，避免单块超页
        final buf = StringBuffer();
        for (var i = 0; i < line.length; i++) {
          buf.write(line[i]);
          if (_sentenceEnd.contains(line[i]) && buf.length >= 160) {
            blocks.add(_p(buf.toString()));
            buf.clear();
          }
        }
        if (buf.isNotEmpty) blocks.add(_p(buf.toString()));
      }
    }
    if (blocks.isEmpty) blocks.add(_p('（空文件）'));
    return blocks;
  }

  static Block _p(String text) =>
      Block(type: BlockType.paragraph, spans: [InlineRun(text)]);

  static const _sentenceEnd = '。！？…；\n';

  String _firstLine(String text, {int maxLength = 40}) {
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      return l.length > maxLength ? l.substring(0, maxLength) : l;
    }
    return '未命名';
  }
}

enum TxtEncoding { utf8, utf16, gbk }

class TxtDecodeResult {
  const TxtDecodeResult(this.text, this.encoding);

  final String text;
  final TxtEncoding encoding;
}

class TxtParseResult {
  const TxtParseResult({required this.document, required this.encoding});

  final BookDocument document;
  final TxtEncoding encoding;
}
