/// 统一中间表示（IR）——计划书 §3.3。
///
/// 所有流式格式（EPUB/MD/MOBI/AZW3/TXT）解析后统一为 [BookDocument]，
/// 渲染层只认 IR 不认原格式；新增格式只需写 Parser，渲染零改动。
library;

/// 行内样式
enum InlineFlag { bold, italic, link, noteref }

/// 行内片段：一段带样式的纯文本
class InlineRun {
  const InlineRun(this.text, {this.flags = const {}, this.ruby, this.refId});

  final String text;
  final Set<InlineFlag> flags;

  /// 振假名注音（EPUB `<ruby>漢<rt>かん</rt></ruby>` 的 rt 内容）。
  /// 注音不计入 [text]（不影响 Locator 坐标），渲染时绘制在文字上方。
  final String? ruby;

  /// 注标目标 id（EPUB `<a epub:type="noteref" href="#fn1">` 的锚点），
  /// 对应 [Chapter.footnotes] 中的脚注内容；仅 noteref 片段非空。
  final String? refId;

  bool get hasBold => flags.contains(InlineFlag.bold);
  bool get hasItalic => flags.contains(InlineFlag.italic);
  bool get hasLink => flags.contains(InlineFlag.link);
  bool get hasNoteref => flags.contains(InlineFlag.noteref);
}

/// 块级元素类型（HTML-lite 白名单子集）
enum BlockType { paragraph, heading, image, blockquote, listItem, code, hr }

/// 块级元素：排版引擎的最小处理单元（段落级）。
class Block {
  const Block({
    required this.type,
    required this.spans,
    this.headingLevel = 0,
    this.imageSrc,
    this.listMarker,
    this.quoteDepth = 0,
  });

  final BlockType type;

  /// 行内内容；[BlockType.image] 时为空
  final List<InlineRun> spans;

  /// 标题级别 1-6（仅 heading）
  final int headingLevel;

  /// 图片资源 id（相对资源存储的 key，仅 image）
  final String? imageSrc;

  /// 列表序号：无序列表为 -1（渲染圆点），有序为 1..n
  final int? listMarker;

  /// 引用嵌套深度
  final int quoteDepth;

  /// 本块的纯文本（Locator 偏移计算依据，与排版无关）
  String get plainText => spans.map((s) => s.text).join();

  Block copyWith({String? imageSrc}) => Block(
    type: type,
    spans: spans,
    headingLevel: headingLevel,
    imageSrc: imageSrc ?? this.imageSrc,
    listMarker: listMarker,
    quoteDepth: quoteDepth,
  );
}

/// 章：spine 中的一个阅读单元
class Chapter {
  const Chapter({
    required this.id,
    required this.title,
    required this.blocks,
    this.footnotes = const {},
  });

  final String id;
  final String title;
  final List<Block> blocks;

  /// 脚注内容（EPUB `<aside epub:type="footnote" id="fn1">` 提取），
  /// key 为元素 id，与行内注标 run 的 [InlineRun.refId] 对应。
  final Map<String, Footnote> footnotes;

  /// 章内字符偏移 → 所在行内片段（注标点击命中检测用）；
  /// 偏移落在块间分隔符上时返回 null。
  InlineRun? inlineRunAt(int charOffset) {
    final offsets = blockOffsets;
    for (var i = 0; i < blocks.length; i++) {
      final start = offsets[i];
      final end = start + blocks[i].plainText.length;
      if (charOffset < start || charOffset >= end) continue;
      var pos = start;
      for (final run in blocks[i].spans) {
        if (charOffset < pos + run.text.length) return run;
        pos += run.text.length;
      }
      return null;
    }
    return null;
  }

  /// 章内扁平纯文本：块文本用 '\n' 连接。
  /// [Locator.charOffset] 以此字符串为坐标系，与排版参数无关。
  String get plainText {
    final buf = StringBuffer();
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) buf.write('\n');
      buf.write(blocks[i].plainText);
    }
    return buf.toString();
  }

  /// 各块在 [plainText] 中的起始偏移
  List<int> get blockOffsets {
    final offsets = <int>[];
    var pos = 0;
    for (final b in blocks) {
      offsets.add(pos);
      pos += b.plainText.length + 1; // +1 分隔符
    }
    return offsets;
  }

  int get charLength => plainText.length;
}

/// 脚注/尾注内容（EPUB aside epub:type="footnote|rearnote|note" 提取）
class Footnote {
  const Footnote({required this.id, required this.text});

  /// 源元素 id（noteref href 锚点，不含 #）
  final String id;

  /// 注释纯文本（多段落以 \n 连接）
  final String text;
}

/// 目录条目（含层级）
class TocEntry {
  const TocEntry({
    required this.title,
    required this.spineIndex,
    this.charOffset = 0,
    this.depth = 0,
  });

  final String title;

  /// 目标章节在 spine 中的序号
  final int spineIndex;

  /// 章内偏移
  final int charOffset;

  /// 缩进层级
  final int depth;
}

/// 书籍元数据
class BookMeta {
  const BookMeta({
    required this.title,
    this.author,
    this.language,
    this.description,
    this.coverResource,
  });

  final String title;
  final String? author;
  final String? language;

  /// 书籍简介（EPUB dc:description 等）
  final String? description;

  /// 封面资源 id（EPUB 内部路径或独立存储 key）
  final String? coverResource;
}

/// 资源存储：图片/字体按需加载。
/// [resolve] 返回资源字节；解析器负责提供实现。
class ResourceStore {
  ResourceStore(this._resolver);

  final Future<List<int>?> Function(String id) _resolver;
  final Map<String, List<int>?> _cache = {};

  Future<List<int>?> get(String id) async {
    if (_cache.containsKey(id)) return _cache[id];
    final data = await _resolver(id);
    _cache[id] = data;
    return data;
  }
}

/// 文档：渲染层唯一入口
class BookDocument {
  const BookDocument({
    required this.meta,
    required this.spine,
    required this.toc,
    required this.resources,
  });

  final BookMeta meta;
  final List<Chapter> spine;
  final List<TocEntry> toc;
  final ResourceStore resources;

  /// 全书总字符数（用于全局进度加权）
  int get totalChars => spine.fold(0, (s, c) => s + c.charLength);

  /// [locator] 之前的全局字符数
  int globalCharsBefore(int spineIndex) {
    var n = 0;
    for (var i = 0; i < spineIndex && i < spine.length; i++) {
      n += spine[i].charLength;
    }
    return n;
  }
}

/// 位置标识（计划书 §3.4 ADR-005）。
///
/// 「章 + 偏移」的简化设计：字号变了页码会变，但 Locator 不变——
/// 这是同步和进度记忆不漂移的关键。JSON 可序列化。
class Locator {
  const Locator({
    required this.spineIndex,
    required this.charOffset,
    required this.chapterLength,
  });

  final int spineIndex;
  final int charOffset;
  final int chapterLength;

  Map<String, dynamic> toJson() => {
    'spineIndex': spineIndex,
    'charOffset': charOffset,
    'chapterLength': chapterLength,
  };

  static Locator fromJson(Map<String, dynamic> j) => Locator(
    spineIndex: j['spineIndex'] as int,
    charOffset: j['charOffset'] as int,
    chapterLength: j['chapterLength'] as int,
  );

  String encode() => Uri(
    queryParameters: {
      's': '$spineIndex',
      'c': '$charOffset',
      'l': '$chapterLength',
    },
  ).query;

  static Locator decode(String s) {
    final q = Uri(query: s).queryParameters;
    return Locator(
      spineIndex: int.parse(q['s'] ?? '0'),
      charOffset: int.parse(q['c'] ?? '0'),
      chapterLength: int.parse(q['l'] ?? '0'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Locator &&
      other.spineIndex == spineIndex &&
      other.charOffset == charOffset;

  @override
  int get hashCode => Object.hash(spineIndex, charOffset);
}
