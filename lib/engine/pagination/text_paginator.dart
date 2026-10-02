import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show SizedBox, WidgetSpan;

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
    this.inlineImages = const [],
    this.justLines,
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

  /// 行内图片：(块内纯文本起点, 资源 src)。占位盒排版，渲染层绘制真实图片
  ///（修复注标角标图片显示成「图」占位文本的 bug）
  final List<(int, String)> inlineImages;

  /// 两端对齐的逐行 painter（字级均布，借鉴 legado TextColumn）；
  /// null = 未启用逐行对齐（绘制/命中退回块级 painter）
  final List<JustifiedLine>? justLines;

  /// 图片显示高度（仅图片块）
  final double imageHeight = 0;

  double get totalHeight =>
      lineHeights.isEmpty ? 0 : lineTops.last + lineHeights.last;

  /// 块 painter 坐标区间 → 以块顶为原点的包围盒。
  /// 逐行对齐时按行 painter 取盒（与实际绘制像素一致），高亮/选区/行内图片/
  /// 注音的绘制与命中统一走这里。
  List<Rect> boxesForRange(int pStart, int pEnd) {
    final jl = justLines;
    if (jl == null) {
      return painter
          .getBoxesForSelection(
            TextSelection(baseOffset: pStart, extentOffset: pEnd),
            boxHeightStyle: ui.BoxHeightStyle.tight,
          )
          .map((b) => Rect.fromLTRB(b.left, b.top, b.right, b.bottom))
          .toList();
    }
    final out = <Rect>[];
    for (final line in jl) {
      final s = pStart.clamp(line.paintStart, line.paintEnd);
      final e = pEnd.clamp(line.paintStart, line.paintEnd);
      if (s >= e) continue;
      final boxes = line.painter.getBoxesForSelection(
        TextSelection(
          baseOffset: s - line.paintStart,
          extentOffset: e - line.paintStart,
        ),
        boxHeightStyle: ui.BoxHeightStyle.tight,
      );
      for (final b in boxes) {
        out.add(
          Rect.fromLTRB(b.left, line.top + b.top, b.right, line.top + b.bottom),
        );
      }
    }
    return out;
  }

  /// 以块顶为原点的坐标 → painter 文本偏移（调用方负责剔除前缀）。
  /// 逐行对齐时先按 y 定位行，再在行 painter 内精确命中。
  int? paintedCharAt(Offset local) {
    final jl = justLines;
    if (jl == null) return painter.getPositionForOffset(local).offset;
    JustifiedLine? best;
    var bestDist = double.infinity;
    for (final line in jl) {
      if (local.dy >= line.top && local.dy < line.top + line.height) {
        best = line;
        break;
      }
      final d = (local.dy - (line.top + line.height / 2)).abs();
      if (d < bestDist) {
        bestDist = d;
        best = line;
      }
    }
    if (best == null) return null;
    return best.paintStart +
        best.painter
            .getPositionForOffset(Offset(local.dx, best.height / 2))
            .offset;
  }
}

/// 两端对齐的单行排版结果：按剩余宽度微调字距（字级均布）后的行 painter
class JustifiedLine {
  const JustifiedLine({
    required this.painter,
    required this.paintStart,
    required this.paintEnd,
    required this.top,
    required this.height,
  });

  final TextPainter painter;

  /// 本行在块 painter 文本坐标中的起止偏移（含前缀）
  final int paintStart;
  final int paintEnd;

  /// 行顶相对块顶的 y 偏移与行高
  final double top;
  final double height;
}

/// 排版段：块内一段等样式文本或图片占位（块级与逐行 painter 共用）
class _LayoutSeg {
  const _LayoutSeg(this.start, this.text, this.color, {this.letterSpacing = 0})
    : isPlaceholder = false,
      placeholderSize = Size.zero;

  const _LayoutSeg.ph(this.start, this.text, this.placeholderSize)
    : color = const ui.Color(0x00000000),
      letterSpacing = 0,
      isPlaceholder = true;

  final int start;
  final String text;
  final ui.Color color;
  final double letterSpacing;
  final bool isPlaceholder;
  final Size placeholderSize;

  int get end => start + text.length;
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
    var fontFamily = cfg.fontFamily;

    switch (block.type) {
      case BlockType.heading:
        final scale = _headingScale[block.headingLevel] ?? 1.0;
        fontSize = cfg.fontSize * scale;
        fontWeight = FontWeight.w700;
        height = 1.35;
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

    // 原书样式居中/右对齐的段落不加首行缩进（居中排版惯例，缩进会破坏居中）
    if (block.type == BlockType.paragraph &&
        cfg.indentChars > 0 &&
        block.align == BlockAlign.start) {
      // 缩进前缀用透明 CJK 字形而非全角空格（U+3000）：
      // U+3000 属空白字符，两端对齐时会被对齐算法拉伸，
      // 导致缩进宽度随每行剩余空间变化（缩进忽大忽小）；
      // 透明字形不参与空白拉伸，宽度恒为 1em，对齐/左对齐缩进一致。
      prefix = '\u4E00' * cfg.indentChars;
      prefixTransparent = true;
      indentWidth = cfg.indentChars * fontSize;
    }

    // 构建排版段：前缀 + 逐 run；行内图片 run 转为占位段（先按宽高比占盒，
    // 渲染层在占位盒内绘制真实图片，修复角标图片显示成「图」文本的 bug）
    final segs = <_LayoutSeg>[];
    final placeholderSizes = <Size>[];
    final inlineImages = <(int, String)>[];
    if (prefix.isNotEmpty) {
      segs.add(
        _LayoutSeg(
          0,
          prefix,
          prefixTransparent ? const ui.Color(0x00000000) : color,
          letterSpacing: letterSpacing,
        ),
      );
    }
    var runOffset = 0;
    for (final run in block.spans) {
      if (run.isImage && run.imageSrc!.isNotEmpty) {
        final src = run.imageSrc!;
        final aspect = imageAspects[src] ?? 0.72; // w/h，未知用默认
        final phH = fontSize * 0.95;
        final phW = (phH * aspect).clamp(fontSize * 0.45, fontSize * 2.2);
        final size = Size(phW, phH);
        segs.add(_LayoutSeg.ph(prefix.length + runOffset, run.text, size));
        placeholderSizes.add(size);
        inlineImages.add((runOffset, src));
      } else {
        var runColor = color;
        if (run.hasLink) runColor = styles.accent;
        // 注标（脚注引用）：强调色提示可点
        if (run.hasNoteref) runColor = styles.accent;
        segs.add(
          _LayoutSeg(
            prefix.length + runOffset,
            run.text,
            runColor,
            letterSpacing: letterSpacing,
          ),
        );
      }
      runOffset += run.text.length;
    }

    // 振假名注音区间（块内纯文本坐标，渲染层绘制在文字上方）
    final rubyRuns = <(int, int, String)>[];
    var rubyOffset = 0;
    for (final run in block.spans) {
      final len = run.text.length;
      final rb = run.ruby;
      if (rb != null && rb.isNotEmpty && len > 0) {
        rubyRuns.add((rubyOffset, rubyOffset + len, rb));
      }
      rubyOffset += len;
    }

    final tp = TextPainter(
      text: TextSpan(
        children: _segSpans(
          segs,
          fontSize: fontSize,
          height: height,
          fontWeight: fontWeight,
          fontFamily: fontFamily,
          fontFallbacks: styles.fontFallbacks,
        ),
      ),
      textDirection: TextDirection.ltr,
      // 两端对齐由逐行 painter（_buildJustifiedLines）实现（字级均布，
      // 借鉴 legado TextColumn）；原书样式指定居中/右对齐的块改用
      // 块级 painter 内建对齐，此时不启用逐行两端对齐
      textAlign: switch (block.align) {
        BlockAlign.start => TextAlign.left,
        BlockAlign.center => TextAlign.center,
        BlockAlign.right => TextAlign.right,
      },
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
    // 行内图片占位尺寸：按出现顺序注入（WidgetSpan 纯文本化为 U+FFFC，
    // 与 run.text 一致，字符坐标不受影响）
    if (placeholderSizes.isNotEmpty) {
      tp.setPlaceholderDimensions([
        for (final d in placeholderSizes)
          PlaceholderDimensions(
            size: d,
            alignment: PlaceholderAlignment.middle,
          ),
      ]);
    }
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

    // 两端对齐：按最终断行结果构建逐行 painter（字级均布，末行不拉伸）。
    // 必须在孤行控制二次排版之后调用，保证与最终绘制像素一致
    final justLines = _buildJustifiedLines(
      tp,
      segs,
      lineStartChars,
      lineTops,
      lineHeights,
      cfg,
      availWidth,
      prefix.length,
      block,
      fontSize: fontSize,
      lineHeight: height,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      fontFallbacks: styles.fontFallbacks,
    );

    // 段前间距：标题前更大；正文段落取 paragraphSpacing × 整行高
    // （默认 0.85 行，量化后为 1 个半行槽，配合 1.65 行距达到舒适的阅读密度）。
    // 行网格量化：段前距对齐到半行槽——正文行高已由 strut 恒定，
    // 量化后段前距不挤占正文行位（页首/页尾版面整齐）
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
      inlineImages: inlineImages,
      justLines: justLines,
    );
  }

  /// 段列表 → span 树（块级与逐行 painter 共用；占位段为图片预留空间）
  List<InlineSpan> _segSpans(
    List<_LayoutSeg> segs, {
    required double fontSize,
    required double height,
    required FontWeight fontWeight,
    required String? fontFamily,
    required List<String> fontFallbacks,
  }) {
    return [
      for (final seg in segs)
        if (seg.isPlaceholder)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            baseline: TextBaseline.alphabetic,
            child: SizedBox(
              width: seg.placeholderSize.width,
              height: seg.placeholderSize.height,
            ),
          )
        else
          TextSpan(
            text: seg.text,
            style: TextStyle(
              color: seg.color,
              fontSize: fontSize,
              fontWeight: fontWeight,
              height: height,
              letterSpacing: seg.letterSpacing,
              fontFamily: fontFamily,
              fontFamilyFallback: fontFallbacks,
            ),
          ),
    ];
  }

  /// 两端对齐：对 [painter]（已按最终宽度排版）的每一非末行构建
  /// 字级均布的行 painter——把行宽与可用宽度之差摊到行内每个字距上，
  /// 中文右缘也能对齐（内建 justify 只拉伸空格，对 CJK 无效）。
  ///
  /// 末行与放不下均布的行（字距增量大）不拉伸；前缀段（缩进/标号）
  /// 不参与拉伸，保持缩进稳定。仅段落/引用/列表启用。
  List<JustifiedLine>? _buildJustifiedLines(
    TextPainter painter,
    List<_LayoutSeg> segs,
    List<int> lineStartChars,
    List<double> lineTops,
    List<double> lineHeights,
    LayoutConfig cfg,
    double availWidth,
    int prefixLen,
    Block block, {
    required double fontSize,
    required double lineHeight,
    required FontWeight fontWeight,
    required String? fontFamily,
    required List<String> fontFallbacks,
  }) {
    if (!cfg.justify) return null;
    // 原书样式居中/右对齐的块不参与两端对齐（居中行拉伸会破坏版式）
    if (block.align != BlockAlign.start) return null;
    switch (block.type) {
      case BlockType.paragraph:
      case BlockType.blockquote:
      case BlockType.listItem:
        break;
      default:
        return null;
    }
    final n = lineStartChars.length;
    if (n < 2) return null; // 单行无需两端对齐

    final metrics = painter.computeLineMetrics();
    final plainLen = block.plainText.length;
    // 前缀段在 segs 中的下标（不参与拉伸）
    final prefixSegIdx =
        prefixLen > 0 && segs.isNotEmpty && segs.first.start == 0 ? 0 : -1;

    final out = <JustifiedLine>[];
    for (var i = 0; i < n; i++) {
      final isLast = i == n - 1;
      final paintStart = i == 0 ? 0 : prefixLen + lineStartChars[i];
      var paintEnd = isLast
          ? prefixLen + plainLen
          : prefixLen + lineStartChars[i + 1];
      if (paintEnd < paintStart) paintEnd = paintStart;

      // 行宽缺口：只对非末行做字距均布
      var extra = 0.0;
      if (!isLast) {
        final deficit = availWidth - metrics[i].width;
        if (deficit > 0.5) {
          var contentChars = 0;
          for (final seg in segs) {
            if (seg.isPlaceholder) continue;
            final s = seg.start.clamp(paintStart, paintEnd);
            final e = seg.end.clamp(paintStart, paintEnd);
            contentChars += e - s;
          }
          if (contentChars >= 2) {
            extra = deficit / contentChars;
            // 缺口过大（行内字符太少或行很短）：强拉会明显松散，放弃
            if (extra > cfg.fontSize * 0.55) extra = 0;
          }
        }
      }

      // 裁剪段到本行区间，重建行 span 树
      final lineSegs = <_LayoutSeg>[];
      final linePhSizes = <Size>[];
      var cursor = 0;
      for (var si = 0; si < segs.length; si++) {
        final seg = segs[si];
        final s = seg.start.clamp(paintStart, paintEnd);
        final e = seg.end.clamp(paintStart, paintEnd);
        if (e <= s) continue;
        if (seg.isPlaceholder) {
          lineSegs.add(_LayoutSeg.ph(cursor, seg.text, seg.placeholderSize));
          linePhSizes.add(seg.placeholderSize);
          cursor += seg.text.length;
        } else {
          var ls = seg.letterSpacing;
          if (extra > 0 && si != prefixSegIdx) ls += extra;
          final text = seg.text.substring(s - seg.start, e - seg.start);
          lineSegs.add(_LayoutSeg(cursor, text, seg.color, letterSpacing: ls));
          cursor += text.length;
        }
      }

      final lp = TextPainter(
        text: TextSpan(
          children: _segSpans(
            lineSegs,
            fontSize: fontSize,
            height: lineHeight,
            fontWeight: fontWeight,
            fontFamily: fontFamily,
            fontFallbacks: fontFallbacks,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
        strutStyle: StrutStyle(
          fontSize: fontSize,
          height: lineHeight,
          fontWeight: fontWeight,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFallbacks,
          forceStrutHeight: true,
        ),
      );
      if (linePhSizes.isNotEmpty) {
        lp.setPlaceholderDimensions([
          for (final d in linePhSizes)
            PlaceholderDimensions(
              size: d,
              alignment: PlaceholderAlignment.middle,
            ),
        ]);
      }
      lp.layout(maxWidth: double.infinity);
      out.add(
        JustifiedLine(
          painter: lp,
          paintStart: paintStart,
          paintEnd: paintEnd,
          top: lineTops[i],
          height: lineHeights[i],
        ),
      );
    }
    return out;
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

  /// 行网格量化：[v] 对齐到半行槽（fontSize×lineHeight 的一半）的整数倍。
  /// 正文行高已由 forceStrutHeight 恒定；半行槽取整（而非整行向下取整）
  /// 让段距 0–2 的滑档有 0/0.5/1/1.5/2 五级平滑过渡——旧实现整行向下
  /// 取整时 0.9 与 0 同样无段前距、1.0 直接跳到整行，档位差异过大。
  /// 段前距不得挤占正文行位（页首/页尾版面仍保持行槽对齐）；
  /// 取整后为 0 时段落紧邻，以首行缩进区分段落（标准书版式）。
  static double _snapSlot(double v, LayoutConfig cfg) {
    final slot = cfg.fontSize * cfg.lineHeight;
    if (v <= 0 || slot <= 0) return 0;
    final half = slot / 2;
    return (v / half).roundToDouble() * half;
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
