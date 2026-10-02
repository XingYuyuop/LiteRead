import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../ir/book_document.dart';

/// 排版配置（由 ReaderSettings 派生，分页引擎只认它）
class LayoutConfig {
  const LayoutConfig({
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    required this.paragraphSpacing,
    required this.contentWidth,
    required this.contentHeight,
    required this.indentChars,
    required this.justify,
    this.fontFamily,
  });

  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final double contentWidth;
  final double contentHeight;
  final int indentChars;
  final bool justify;
  final String? fontFamily;

  double get lineHeightPx => fontSize * lineHeight;
}

/// 主题提供的文本样式集（分页时烘焙进 TextPainter）
class LayoutStyleSet {
  const LayoutStyleSet({
    required this.config,
    required this.foreground,
    required this.secondary,
    required this.accent,
    this.fontFallbacks = const [],
  });

  final LayoutConfig config;
  final ui.Color foreground;
  final ui.Color secondary;
  final ui.Color accent;
  final List<String> fontFallbacks;
}

/// 单个已测量块
class LaidOutBlock {
  LaidOutBlock({
    required this.blockIndex,
    required this.block,
    required this.painter,
    required this.lineTops,
    required this.lineHeights,
    required this.lineStartChars,
    required this.spaceAbove,
    required this.indentWidth,
    required this.quoteDepth,
    required this.isImage,
    this.charBase = 0,
    this.prefixChars = 0,
    this.rubyRuns = const [],
  });

  final int blockIndex;
  final Block block;
  final TextPainter painter;

  /// 每行相对块顶部的 y 偏移
  final List<double> lineTops;
  final List<double> lineHeights;

  /// 每行首字符在 block.plainText 中的偏移（已剔除前缀缩进/标号）
  final List<int> lineStartChars;

  /// 段前间距
  final double spaceAbove;

  /// 首行缩进宽度（渲染用）
  final double indentWidth;

  final int quoteDepth;

  /// 图片块
  final bool isImage;

  /// 块首在章扁平文本中的偏移（批注坐标映射用）
  final int charBase;

  /// 文本前缀字符数（缩进全角空格/列表标号），批注坐标 ↔ TextPainter 偏移换算
  final int prefixChars;

  /// 振假名注音区间：(块内纯文本起点, 终点, 注音文本)，渲染时绘制在文字上方
  final List<(int, int, String)> rubyRuns;

  /// 图片显示高度（仅图片块）
  final double imageHeight = 0;

  double get totalHeight =>
      lineHeights.isEmpty ? 0 : lineTops.last + lineHeights.last;
}

/// 页内渲染单元：某块的第 [firstLine, firstLine+lineCount) 行
class PageUnit {
  const PageUnit(
    this.blockIndex,
    this.firstLine,
    this.lineCount, {
    this.spaceAbove = 0.0,
  });

  final int blockIndex;
  final int firstLine;
  final int lineCount;

  /// 本单元上方间距（分页时决定：页首为 0；页尾放不下段前距时压缩为 0）
  final double spaceAbove;
}

/// 页盒：一章内的一页
class PageBox {
  const PageBox({
    required this.spineIndex,
    required this.startChar,
    required this.endChar,
    required this.units,
  });

  final int spineIndex;

  /// 本章坐标中的起始字符偏移（Locator.charOffset 直接可用）
  final int startChar;
  final int endChar;
  final List<PageUnit> units;
}

/// 已排版章节：渲染与定位的统一载体
class LaidOutChapter {
  const LaidOutChapter({
    required this.spineIndex,
    required this.blocks,
    required this.pages,
    required this.config,
    required this.chapterLength,
  });

  final int spineIndex;
  final List<LaidOutBlock> blocks;
  final List<PageBox> pages;
  final LayoutConfig config;
  final int chapterLength;

  /// 字符偏移 → 页号（二分）
  int pageIndexForChar(int charOffset) {
    var lo = 0;
    var hi = pages.length - 1;
    var ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (pages[mid].startChar <= charOffset) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  int get pageCount => pages.length;
}

/// 分页引擎（计划书 §3.4）。
///
/// 算法：块 → TextPainter 逐行测量 → 按可视高度贪心填充页；
/// 单段超页时按行切分。产出 [LaidOutChapter]。
/// 渲染层复用同一批 TextPainter，保证测量与绘制像素级一致。
class TextPaginator {
  const TextPaginator();

  static const _headingScale = {
    1: 1.55,
    2: 1.35,
    3: 1.22,
    4: 1.12,
    5: 1.06,
    6: 1.0,
  };

  /// 同步分页一章。
  ///
  /// [imageAspects]: 图片资源 id → 宽高比（w/h），未知用默认 0.72。
  Future<LaidOutChapter> paginate({
    required Chapter chapter,
    required int spineIndex,
    required LayoutStyleSet styles,
    Map<String, double> imageAspects = const {},
  }) async {
    final cfg = styles.config;
    final blocks = <LaidOutBlock>[];

    var charBase = 0;
    for (var bi = 0; bi < chapter.blocks.length; bi++) {
      final block = chapter.blocks[bi];
      blocks.add(_measureBlock(block, bi, styles, imageAspects, charBase));
      charBase += block.plainText.length + 1;
      // 分块让出事件循环，避免超长章卡 UI（M1 在主 isolate 分页）
      if (bi % 64 == 63) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    // 贪心填页
    final pages = <PageBox>[];
    final units = <PageUnit>[];
    var used = 0.0;
    var pageStartChar = 0;

    /// 记录当前页首个可见字符
    int firstVisibleChar(int blockIdx, int firstLine) {
      final lb = blocks[blockIdx];
      if (firstLine < lb.lineStartChars.length) {
        return _blockCharBase(chapter, blockIdx) + lb.lineStartChars[firstLine];
      }
      return _blockCharBase(chapter, blockIdx);
    }

    void flush() {
      if (units.isEmpty) return;
      final lastUnit = units.last;
      final lastBlock = blocks[lastUnit.blockIndex];
      final lastLine = lastUnit.firstLine + lastUnit.lineCount - 1;
      var endChar =
          _blockCharBase(chapter, lastUnit.blockIndex) +
          (lastLine + 1 < lastBlock.lineStartChars.length
              ? lastBlock.lineStartChars[lastLine + 1]
              : lastBlock.block.plainText.length);
      pages.add(
        PageBox(
          spineIndex: spineIndex,
          startChar: pageStartChar,
          endChar: endChar,
          units: List.of(units),
        ),
      );
      units.clear();
      used = 0;
    }

    // 固定行数分页：正文行高恒为 fontSize × lineHeight（strut 强制等高），
    // 段前距量化为整数行槽 → 每页可容纳的行槽数固定（N = 页高 / 行槽）。
    // 逐行填页：放不下即切页（不做孤行回退），页首顶格省略段前距、
    // 页尾放不下段前距时压缩段前距——保证除标题/图片等整块移动的页外，
    // 每页文本行数恒定、页底对齐（先定每页 N 行，再按行均匀分页）。
    for (var bi = 0; bi < blocks.length; bi++) {
      final lb = blocks[bi];

      // 标题/图片/分隔线：跨页切开非常难看，整块处理
      if (!_splittableAcrossPage(lb)) {
        final sa = units.isEmpty ? 0.0 : lb.spaceAbove;
        if (units.isNotEmpty &&
            used + sa + lb.totalHeight > cfg.contentHeight) {
          // 页尾放不下：整块移到下一页（页首顶格，不再计段前距）
          flush();
          pageStartChar = firstVisibleChar(bi, 0);
          units.add(PageUnit(bi, 0, lb.lineHeights.length));
          used = lb.totalHeight;
          continue;
        }
        if (units.isEmpty) pageStartChar = firstVisibleChar(bi, 0);
        units.add(PageUnit(bi, 0, lb.lineHeights.length, spaceAbove: sa));
        used += sa + lb.totalHeight;
        continue;
      }

      // 正文/引用/列表/代码：逐行填页，页满即切
      var lineIdx = 0;
      while (lineIdx < lb.lineHeights.length) {
        final h = lb.lineHeights[lineIdx];
        var sa = 0.0;
        if (lineIdx == 0 && units.isNotEmpty) sa = lb.spaceAbove;
        if (used + sa + h > cfg.contentHeight && used > 0) {
          if (used + h <= cfg.contentHeight) {
            // 页尾放不下段前距：压缩段前距，本行留在本页（固定行数优先）
            sa = 0.0;
          } else {
            flush();
            sa = 0.0;
          }
        }
        if (units.isEmpty) pageStartChar = firstVisibleChar(bi, lineIdx);
        final last = units.isEmpty ? null : units.last;
        if (last != null &&
            last.blockIndex == bi &&
            last.firstLine + last.lineCount == lineIdx) {
          // 同块连续行并入现有渲染单元
          units[units.length - 1] = PageUnit(
            bi,
            last.firstLine,
            last.lineCount + 1,
            spaceAbove: last.spaceAbove,
          );
        } else {
          units.add(PageUnit(bi, lineIdx, 1, spaceAbove: sa));
        }
        used += sa + h;
        lineIdx++;
      }
    }
    flush();

    // 兜底：空章至少一页
    if (pages.isEmpty) {
      pages.add(
        PageBox(
          spineIndex: spineIndex,
          startChar: 0,
          endChar: chapter.charLength,
          units: const [],
        ),
      );
    }

    return LaidOutChapter(
      spineIndex: spineIndex,
      blocks: blocks,
      pages: pages,
      config: cfg,
      chapterLength: chapter.charLength,
    );
  }

  LaidOutBlock _measureBlock(
    Block block,
    int blockIndex,
    LayoutStyleSet styles,
    Map<String, double> imageAspects,
    int charBase,
  ) {
    final cfg = styles.config;

    switch (block.type) {
      case BlockType.image:
        return _measureImage(block, blockIndex, styles, imageAspects);
      case BlockType.hr:
        return _measureHr(block, blockIndex, styles);
      default:
        break;
    }

    // 文本前缀：首行缩进（透明 CJK 字形）与列表标号。
    // 前缀不计入 Locator 坐标，行首字符映射时统一剔除。
    var prefix = '';
    var prefixTransparent = false;
    var indentWidth = 0.0;
    var fontSize = cfg.fontSize;
    var fontWeight = FontWeight.normal;
    var color = styles.foreground;
    var letterSpacing = cfg.letterSpacing;
    var height = cfg.lineHeight;
    var align = cfg.justify ? TextAlign.justify : TextAlign.left;
    var fontFamily = cfg.fontFamily;

    switch (block.type) {
      case BlockType.heading:
        final scale = _headingScale[block.headingLevel] ?? 1.0;
        fontSize = cfg.fontSize * scale;
        fontWeight = FontWeight.w700;
        height = 1.35;
        align = TextAlign.left;
        break;
      case BlockType.listItem:
        final marker = block.listMarker ?? -1;
        if (marker == -1) {
          prefix = '• ';
        } else {
          prefix = '$marker. ';
        }
        prefix += '\u3000' * 0;
        break;
      case BlockType.code:
        fontFamily = 'monospace';
        fontSize = cfg.fontSize * 0.88;
        height = 1.4;
        align = TextAlign.left;
        letterSpacing = 0;
        break;
      case BlockType.blockquote:
        break;
      default:
        break;
    }

    // 列表/引用缩进
    final quoteIndent = block.quoteDepth > 0 ? block.quoteDepth * 18.0 : 0.0;
    var listIndent = 0.0;
    if (block.type == BlockType.listItem) {
      // 前导空格已在 span 中（嵌套层级），此处不额外缩进
      listIndent = 0.0;
    }

    if (block.type == BlockType.paragraph && cfg.indentChars > 0) {
      // 缩进前缀用透明 CJK 字形而非全角空格（U+3000）：
      // U+3000 属空白字符，两端对齐时会被对齐算法拉伸，
      // 导致缩进宽度随每行剩余空间变化（缩进忽大忽小）；
      // 透明字形不参与空白拉伸，宽度恒为 1em，对齐/左对齐缩进一致。
      prefix = '\u4E00' * cfg.indentChars;
      prefixTransparent = true;
      indentWidth = cfg.indentChars * fontSize;
    }

    // 构建 span
    final spans = <InlineSpan>[];
    for (final run in block.spans) {
      var runColor = color;
      if (run.hasLink) runColor = styles.accent;
      // 注标（脚注引用）：强调色提示可点
      if (run.hasNoteref) runColor = styles.accent;
      spans.add(
        TextSpan(
          text: run.text,
          style: TextStyle(
            color: runColor,
            fontSize: fontSize,
            fontWeight: fontWeight,
            height: height,
            letterSpacing: letterSpacing,
            fontFamily: fontFamily,
            fontFamilyFallback: styles.fontFallbacks,
          ),
        ),
      );
    }
    if (prefix.isNotEmpty) {
      spans.insert(
        0,
        TextSpan(
          text: prefix,
          style: TextStyle(
            // 透明缩进前缀：占位但不参与两端对齐的空白拉伸
            color: prefixTransparent ? const ui.Color(0x00000000) : color,
            fontSize: fontSize,
            fontWeight: fontWeight,
            height: height,
            letterSpacing: letterSpacing,
            fontFamily: fontFamily,
          ),
        ),
      );
    }

    // 振假名注音区间（块内纯文本坐标，渲染层绘制在文字上方）
    final rubyRuns = <(int, int, String)>[];
    var runOffset = 0;
    for (final run in block.spans) {
      final len = run.text.length;
      final rb = run.ruby;
      if (rb != null && rb.isNotEmpty && len > 0) {
        rubyRuns.add((runOffset, runOffset + len, rb));
      }
      runOffset += len;
    }

    final tp = TextPainter(
      text: TextSpan(children: spans),
      textDirection: TextDirection.ltr,
      textAlign: align,
      // 强制等高 strut：行高不再随行内字符（中文/西文/数字/表情等回退字体）变化。
      // 否则西文字体回退会让某些行高 2–3px，整页累积后末行位置忽上忽下；
      // 固定后每行高度恒为 fontSize × height，页末行始终落在同一网格线上。
      strutStyle: StrutStyle(
        fontSize: fontSize,
        height: height,
        fontWeight: fontWeight,
        fontFamily: fontFamily,
        fontFamilyFallback: styles.fontFallbacks,
        forceStrutHeight: true,
      ),
    );
    final availWidth = cfg.contentWidth - quoteIndent - listIndent;

    // 按给定宽度排版并提取逐行信息（孤行控制会二次排版，抽成闭包复用）
    (List<double>, List<double>, List<int>) layoutAt(double width) {
      tp.layout(maxWidth: width.clamp(40, double.infinity));
      final metrics = tp.computeLineMetrics();
      final tops = <double>[];
      final heights = <double>[];
      final starts = <int>[];
      var y = 0.0;
      final prefixLen = prefix.length;
      for (final m in metrics) {
        tops.add(y);
        heights.add(m.height);
        final pos = tp.getPositionForOffset(Offset(0, y + m.height / 2));
        starts.add((pos.offset - prefixLen).clamp(0, 1 << 30));
        y += m.height;
      }
      return (tops, heights, starts);
    }

    var (lineTops, lineHeights, lineStartChars) = layoutAt(availWidth);

    // 孤行控制（现代排版规范）：段落末行仅剩 1–2 字时（如「气。」「相交。」），
    // 收窄可用宽度两个字号，把尾部 1–2 字拉回末行，使末行至少 3 字；
    // 测量与绘制共用同一 TextPainter，二次排版后高度自动保持一致
    if (block.type == BlockType.paragraph &&
        lineStartChars.length >= 2 &&
        block.plainText.length - lineStartChars.last <= 2) {
      final (t2, h2, s2) = layoutAt(availWidth - cfg.fontSize * 2);
      if (s2.isNotEmpty && block.plainText.length - s2.last > 2) {
        lineTops = t2;
        lineHeights = h2;
        lineStartChars = s2;
      }
    }

    // 段前间距：标题前更大；正文段落取 paragraphSpacing × 整行高
    // （默认 0.85 行，配合 1.65 行距达到舒适的阅读密度）。
    // 行网格量化：段前距对齐到整数行——正文行高已由 strut 恒定，
    // 量化后每页可容纳的行槽数固定，页首/页尾版面整齐（固定每页行数）
    double spaceAbove;
    final spacingUnit = cfg.fontSize * cfg.lineHeight;
    switch (block.type) {
      case BlockType.heading:
        spaceAbove = spacingUnit * (block.headingLevel <= 2 ? 1.0 : 0.7);
        break;
      case BlockType.blockquote:
      case BlockType.listItem:
      case BlockType.code:
      case BlockType.image:
      case BlockType.hr:
      case BlockType.paragraph:
        spaceAbove = spacingUnit * cfg.paragraphSpacing;
        break;
    }
    spaceAbove = _snapSlot(spaceAbove, cfg);

    return LaidOutBlock(
      blockIndex: blockIndex,
      block: block,
      painter: tp,
      lineTops: lineTops,
      lineHeights: lineHeights,
      lineStartChars: lineStartChars,
      spaceAbove: spaceAbove,
      indentWidth: indentWidth,
      quoteDepth: block.quoteDepth,
      isImage: false,
      charBase: charBase,
      prefixChars: prefix.length,
      rubyRuns: rubyRuns,
    );
  }

  /// 块能否在页边界处按行切分：正文/引用/列表/代码可以；
  /// 标题、图片、分隔线整块移动（跨页切开非常难看）。
  static bool _splittableAcrossPage(LaidOutBlock lb) {
    switch (lb.block.type) {
      case BlockType.paragraph:
      case BlockType.blockquote:
      case BlockType.listItem:
      case BlockType.code:
        return true;
      case BlockType.heading:
      case BlockType.image:
      case BlockType.hr:
        return false;
    }
  }

  /// 行网格量化：[v] 对齐到标准行高（fontSize×lineHeight）的整数倍。
  /// 正文行高已由 forceStrutHeight 恒定，段前距向下取整到整数行槽：
  /// 段前距不得挤占正文行位（保证每页文本行数恒定、页底对齐）；
  /// 取整后为 0 时段落紧邻，以首行缩进区分段落（标准书版式）。
  static double _snapSlot(double v, LayoutConfig cfg) {
    final slot = cfg.fontSize * cfg.lineHeight;
    if (v <= 0 || slot <= 0) return 0;
    return (v / slot).floorToDouble() * slot;
  }

  LaidOutBlock _measureImage(
    Block block,
    int blockIndex,
    LayoutStyleSet styles,
    Map<String, double> imageAspects,
  ) {
    final cfg = styles.config;
    final aspect = imageAspects[block.imageSrc] ?? 0.72; // w/h
    final w = cfg.contentWidth;
    var h = w / aspect;
    if (h > cfg.contentHeight * 0.7) {
      h = cfg.contentHeight * 0.7;
    }
    return LaidOutBlock(
      blockIndex: blockIndex,
      block: block,
      painter: TextPainter(
        text: const TextSpan(text: ''),
        textDirection: TextDirection.ltr,
      ),
      lineTops: [0],
      lineHeights: [h],
      lineStartChars: [0],
      spaceAbove: _snapSlot(
        cfg.fontSize * cfg.lineHeight * cfg.paragraphSpacing * 0.6,
        cfg,
      ),
      indentWidth: 0,
      quoteDepth: 0,
      isImage: true,
    );
  }

  LaidOutBlock _measureHr(Block block, int blockIndex, LayoutStyleSet styles) {
    final cfg = styles.config;
    final h = cfg.fontSize * 0.8;
    return LaidOutBlock(
      blockIndex: blockIndex,
      block: block,
      painter: TextPainter(
        text: const TextSpan(text: ''),
        textDirection: TextDirection.ltr,
      ),
      lineTops: [0],
      lineHeights: [h],
      lineStartChars: [0],
      spaceAbove: _snapSlot(cfg.fontSize * cfg.lineHeight * 0.5, cfg),
      indentWidth: 0,
      quoteDepth: 0,
      isImage: false,
    );
  }

  /// 块在章扁平文本中的起始偏移
  static int _blockCharBase(Chapter chapter, int blockIdx) {
    // 偏移 = Σ(前序块文本长 + 1)
    var pos = 0;
    for (var i = 0; i < blockIdx; i++) {
      pos += chapter.blocks[i].plainText.length + 1;
    }
    return pos;
  }
}
