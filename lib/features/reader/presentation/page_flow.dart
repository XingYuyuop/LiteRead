import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/reader_theme.dart';
import '../../../engine/ir/book_document.dart';
import '../../../engine/pagination/text_paginator.dart';
import '../data/highlight_repository.dart';

/// 页内批注区间（章内扁平文本坐标，供 PageCanvas 绘制）
class PageMark {
  const PageMark({
    required this.start,
    required this.end,
    required this.colorIndex,
    required this.styleIndex,
  });

  final int start;
  final int end;
  final int colorIndex;
  final int styleIndex;
}

/// 单页画布：用分页时烘焙的 TextPainter 逐行绘制，保证测量/绘制像素一致。
class PageCanvas extends StatelessWidget {
  const PageCanvas({
    super.key,
    required this.laid,
    required this.page,
    required this.theme,
    required this.margins,
    this.resources,
    this.marks = const [],
    this.selection,
  });

  final LaidOutChapter laid;
  final PageBox page;
  final ReaderThemeSpec theme;
  final EdgeInsets margins;
  final ResourceStore? resources;

  /// 已保存的批注（章内字符区间）
  final List<PageMark> marks;

  /// 进行中的划词选择（章内字符区间，有序）
  final (int, int)? selection;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PagePainter(
        laid: laid,
        page: page,
        theme: theme,
        margins: margins,
        resources: resources,
        marks: marks,
        selection: selection,
        // 关键修复：异步图片加载完成不会改变 page/laid 对象，
        // shouldRepaint 恒为 false 导致除首章外的图片永远停留在占位框。
        // 挂上 imageLoadedTick，任何图片解码完成即触发本页重绘。
        repaint: imageLoadedTick,
      ),
      size: Size.infinite,
    );
  }

  /// 图片缓存按 src 全局共享；src 是 zip 内相对路径，跨书可能同名冲突，
  /// 打开新书时必须清空。
  static void clearImageCaches() {
    _PagePainter.imageCache.clear();
    _PagePainter.imageLoading.clear();
  }

  /// 图片页（整页仅插图/分隔线）垂直居中偏移：让整页插图在版心内
  /// 上下均衡分布，而不是堆在页首、页尾留大片空白。
  /// 绘制与命中测试共用同一计算，保证长按查看大图的判定准确。
  static double imagePageTopOffset(
    LaidOutChapter laid,
    PageBox page,
    EdgeInsets margins,
  ) {
    if (page.units.isEmpty) return 0;
    final allVisual = page.units.every((u) {
      final lb = laid.blocks[u.blockIndex];
      return lb.isImage || lb.block.type == BlockType.hr;
    });
    if (!allVisual) return 0;
    var total = 0.0;
    for (final unit in page.units) {
      final lb = laid.blocks[unit.blockIndex];
      final spaceAbove = identical(unit, page.units.first)
          ? 0.0
          : lb.spaceAbove;
      total +=
          spaceAbove +
          lb.lineHeights.skip(unit.firstLine).take(unit.lineCount).fold(
            0.0,
            (a, b) => a + b,
          );
    }
    final free = laid.config.contentHeight - total;
    return free > 0 ? free / 2 : 0;
  }

  /// 局部坐标 → 章内扁平文本字符偏移；未命中文本返回 null。
  /// 批注长按划词的命中实现（CustomPaint 无 TextField，需自行换算）。
  static int? hitTestChar(
    LaidOutChapter laid,
    PageBox page,
    EdgeInsets margins,
    Offset local,
  ) {
    var y = margins.top;
    for (final unit in page.units) {
      final lb = laid.blocks[unit.blockIndex];
      final spaceAbove = identical(unit, page.units.first)
          ? 0.0
          : lb.spaceAbove;
      final visibleH = lb.lineHeights
          .skip(unit.firstLine)
          .take(unit.lineCount)
          .fold(0.0, (a, b) => a + b);
      y += spaceAbove;
      if (lb.isImage || lb.block.type == BlockType.hr) {
        y += visibleH;
        continue;
      }
      if (local.dy >= y && local.dy < y + visibleH) {
        final quoteIndent = lb.quoteDepth * 18.0;
        // painter 原点在画布上的位置（partial 单位 painter 平移到行顶）
        final originDy = y - lb.lineTops[unit.firstLine];
        final pos = lb.painter.getPositionForOffset(
          Offset(local.dx - margins.left - quoteIndent, local.dy - originDy),
        );
        // painter 坐标 → 章内坐标：剔除前缀（缩进/列表标号），限幅到块内
        final inBlock = (pos.offset - lb.prefixChars).clamp(
          0,
          lb.block.plainText.length,
        );
        return lb.charBase + inBlock;
      }
      y += visibleH;
    }
    return null;
  }

  /// 局部坐标 → 命中的图片资源 src（长按查看大图用）；未命中返回 null。
  /// 判定逻辑与 _PagePainter._paintImage 的布局保持一致
  /// （含整页插图的垂直居中偏移）。
  static String? hitTestImage(
    LaidOutChapter laid,
    PageBox page,
    EdgeInsets margins,
    Offset local,
  ) {
    final cfg = laid.config;
    var y = margins.top + imagePageTopOffset(laid, page, margins);
    for (final unit in page.units) {
      final lb = laid.blocks[unit.blockIndex];
      final spaceAbove = identical(unit, page.units.first)
          ? 0.0
          : lb.spaceAbove;
      final visibleH = lb.lineHeights
          .skip(unit.firstLine)
          .take(unit.lineCount)
          .fold(0.0, (a, b) => a + b);
      y += spaceAbove;
      if (lb.isImage) {
        final rect = Rect.fromLTWH(margins.left, y, cfg.contentWidth, visibleH);
        if (rect.contains(local)) {
          return lb.block.imageSrc;
        }
      }
      y += visibleH;
    }
    return null;
  }

  /// 章内字符区间 → 当前页局部坐标的包围盒（划词菜单贴近划线位置用）。
  static Rect? selectionRect(
    LaidOutChapter laid,
    PageBox page,
    EdgeInsets margins,
    int start,
    int end,
  ) {
    Rect? result;
    var y = margins.top;
    for (final unit in page.units) {
      final lb = laid.blocks[unit.blockIndex];
      final spaceAbove = identical(unit, page.units.first)
          ? 0.0
          : lb.spaceAbove;
      final visibleH = lb.lineHeights
          .skip(unit.firstLine)
          .take(unit.lineCount)
          .fold(0.0, (a, b) => a + b);
      y += spaceAbove;
      final isImageOrHr = lb.isImage || lb.block.type == BlockType.hr;
      if (!isImageOrHr) {
        final blockStart = lb.charBase;
        final blockEnd = lb.charBase + lb.block.plainText.length;
        if (end > blockStart && start < blockEnd) {
          final maxOffset = lb.prefixChars + lb.block.plainText.length;
          final pStart = ((start - blockStart) + lb.prefixChars).clamp(
            0,
            maxOffset,
          );
          final pEnd = ((end - blockStart) + lb.prefixChars).clamp(
            0,
            maxOffset,
          );
          if (pStart < pEnd) {
            final boxes = lb.painter.getBoxesForSelection(
              TextSelection(baseOffset: pStart, extentOffset: pEnd),
              boxHeightStyle: ui.BoxHeightStyle.tight,
            );
            // painter 原点在页面局部坐标中的位置
            final originDy = y - lb.lineTops[unit.firstLine];
            final originDx = margins.left + lb.quoteDepth * 18.0;
            for (final b in boxes) {
              final r = Rect.fromLTRB(
                originDx + b.left,
                originDy + b.top,
                originDx + b.right,
                originDy + b.bottom,
              );
              result = result == null ? r : result.expandToInclude(r);
            }
          }
        }
      }
      y += visibleH;
    }
    return result;
  }
}

/// 图片加载完成通知（触发重绘）
final imageLoadedTick = ValueNotifier<int>(0);

class _PagePainter extends CustomPainter {
  _PagePainter({
    required this.laid,
    required this.page,
    required this.theme,
    required this.margins,
    this.resources,
    this.marks = const [],
    this.selection,
    super.repaint,
  });

  final LaidOutChapter laid;
  final PageBox page;
  final ReaderThemeSpec theme;
  final EdgeInsets margins;
  final ResourceStore? resources;
  final List<PageMark> marks;
  final (int, int)? selection;

  static final imageCache = <String, ui.Image>{};
  static final imageLoading = <String>{};

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = theme.background);

    final cfg = laid.config;
    final x0 = margins.left;
    final y0 = margins.top + PageCanvas.imagePageTopOffset(laid, page, margins);
    var y = y0;

    for (final unit in page.units) {
      final lb = laid.blocks[unit.blockIndex];
      final spaceAbove = identical(unit, page.units.first)
          ? 0.0
          : lb.spaceAbove;
      final visibleH = lb.lineHeights
          .skip(unit.firstLine)
          .take(unit.lineCount)
          .fold(0.0, (a, b) => a + b);
      y += spaceAbove;

      if (lb.isImage) {
        _paintImage(canvas, lb, x0, y, cfg.contentWidth, visibleH);
        y += visibleH;
        continue;
      }
      if (lb.block.type == BlockType.hr) {
        final paint = Paint()
          ..color = theme.secondary.withValues(alpha: 0.4)
          ..strokeWidth = 1;
        canvas.drawLine(
          Offset(x0 + cfg.contentWidth * 0.2, y + visibleH / 2),
          Offset(x0 + cfg.contentWidth * 0.8, y + visibleH / 2),
          paint,
        );
        y += visibleH;
        continue;
      }

      // 引用条
      if (lb.quoteDepth > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              x0,
              y + 2,
              3,
              (visibleH - 4).clamp(2, double.infinity),
            ),
            const Radius.circular(1.5),
          ),
          Paint()..color = theme.accent.withValues(alpha: 0.55),
        );
      }

      final quoteIndent = lb.quoteDepth * 18.0;
      final fullBlock =
          unit.firstLine == 0 && unit.lineCount == lb.lineHeights.length;
      // painter 原点在画布上的位置：整块时 lineTops[0]==0，partial 时平移到首行
      final painterOrigin = Offset(
        x0 + quoteIndent,
        y - lb.lineTops[unit.firstLine],
      );
      final ranges = _rangesForBlock(lb);

      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          x0 + quoteIndent,
          y,
          (cfg.contentWidth - quoteIndent).clamp(0, double.infinity),
          visibleH,
        ),
      );
      // 第一遍：背景高亮（样式 0）与选区 —— 垫在文字下方
      _paintRanges(canvas, lb, painterOrigin, ranges, underlinePass: false);
      if (fullBlock) {
        lb.painter.paint(canvas, painterOrigin);
      } else {
        final top = lb.lineTops[unit.firstLine];
        canvas.save();
        canvas.translate(x0 + quoteIndent, y - top);
        canvas.clipRect(
          Rect.fromLTWH(
            0,
            top,
            (cfg.contentWidth - quoteIndent).clamp(0, double.infinity),
            visibleH,
          ),
        );
        lb.painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
      // 第二遍：下划线（样式 1/2）—— 压在文字上方
      _paintRanges(canvas, lb, painterOrigin, ranges, underlinePass: true);
      // 振假名（ruby 注音）绘制在文字上方
      _paintRuby(canvas, lb, painterOrigin, unit);
      canvas.restore();

      y += visibleH;
    }
  }

  /// 计算本块需要绘制的批注/选区区间（换算为 TextPainter 坐标）
  List<(int, int, ui.Color, int)> _rangesForBlock(LaidOutBlock lb) {
    final blockEnd = lb.charBase + lb.block.plainText.length;
    final pTextLen = lb.prefixChars + lb.block.plainText.length;
    final ranges = <(int, int, ui.Color, int)>[];

    void add(int start, int end, ui.Color color, int styleIndex) {
      final ps = ((start - lb.charBase) + lb.prefixChars).clamp(0, pTextLen);
      final pe = ((end - lb.charBase) + lb.prefixChars).clamp(0, pTextLen);
      if (ps >= pe) return;
      ranges.add((ps, pe, color, styleIndex));
    }

    for (final m in marks) {
      if (m.end <= lb.charBase || m.start >= blockEnd) continue;
      add(
        m.start,
        m.end,
        highlightPalette[m.colorIndex.clamp(0, highlightPalette.length - 1)],
        m.styleIndex.clamp(0, 2),
      );
    }
    final sel = selection;
    if (sel != null && sel.$2 > lb.charBase && sel.$1 < blockEnd) {
      add(sel.$1, sel.$2, theme.accent, 0);
    }
    return ranges;
  }

  /// 绘制一个块内的高亮区间。[underlinePass]=false 画背景填充，true 画下划线。
  /// 标注统一样式：0=选区背景，1=下划线（历史波浪 2 也按直线渲染）。
  void _paintRanges(
    Canvas canvas,
    LaidOutBlock lb,
    Offset painterOrigin,
    List<(int, int, ui.Color, int)> ranges, {
    required bool underlinePass,
  }) {
    for (final (pStart, pEnd, color, styleIndex) in ranges) {
      final isUnderline = styleIndex != 0;
      if (isUnderline != underlinePass) continue;
      final boxes = lb.painter.getBoxesForSelection(
        TextSelection(baseOffset: pStart, extentOffset: pEnd),
        boxHeightStyle: ui.BoxHeightStyle.tight,
      );
      for (final box in boxes) {
        final r = Rect.fromLTRB(
          painterOrigin.dx + box.left,
          painterOrigin.dy + box.top,
          painterOrigin.dx + box.right,
          painterOrigin.dy + box.bottom,
        );
        if (styleIndex == 0) {
          canvas.drawRect(r, Paint()..color = color.withValues(alpha: 0.35));
        } else {
          // 下划线
          canvas.drawLine(
            Offset(r.left, r.bottom - 1.5),
            Offset(r.right, r.bottom - 1.5),
            Paint()
              ..color = color
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round,
          );
        }
      }
    }
  }

  /// 绘制振假名（ruby 注音）：半号小字绘制在所注音文字的正上方。
  /// 注音跨行时按行分段绘制；行内上方空间不足时贴行顶绘制。
  void _paintRuby(
    Canvas canvas,
    LaidOutBlock lb,
    Offset origin,
    PageUnit unit,
  ) {
    if (lb.rubyRuns.isEmpty) return;
    final cfg = laid.config;
    final rubyFontSize = cfg.fontSize * 0.5;
    final blockLen = lb.block.plainText.length;
    final maxOffset = lb.prefixChars + blockLen;
    final firstLine = unit.firstLine;
    final lastLine = unit.firstLine + unit.lineCount - 1;

    for (final (rs, re, rt) in lb.rubyRuns) {
      for (
        var ln = firstLine;
        ln <= lastLine && ln < lb.lineStartChars.length;
        ln++
      ) {
        final ls = lb.lineStartChars[ln];
        final le = ln + 1 < lb.lineStartChars.length
            ? lb.lineStartChars[ln + 1]
            : blockLen;
        // 注音区间与本行无交集则跳过
        if (re <= ls || rs >= le) continue;
        final segStart = rs < ls ? ls : rs;
        final segEnd = re > le ? le : re;
        final pStart = (segStart + lb.prefixChars).clamp(0, maxOffset);
        final pEnd = (segEnd + lb.prefixChars).clamp(0, maxOffset);
        if (pStart >= pEnd) continue;
        final boxes = lb.painter.getBoxesForSelection(
          TextSelection(baseOffset: pStart, extentOffset: pEnd),
          boxHeightStyle: ui.BoxHeightStyle.tight,
        );
        if (boxes.isEmpty) continue;
        var left = double.infinity;
        var right = double.negativeInfinity;
        var glyphTop = double.infinity;
        for (final b in boxes) {
          if (b.left < left) left = b.left;
          if (b.right > right) right = b.right;
          if (b.top < glyphTop) glyphTop = b.top;
        }
        final tp = TextPainter(
          text: TextSpan(
            text: rt,
            style: TextStyle(
              color: theme.foreground.withValues(alpha: 0.78),
              fontSize: rubyFontSize,
              height: 1.05,
              letterSpacing: 0,
              fontFamily: cfg.fontFamily,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // 水平：居中对齐被注音文字，不超出版心
        var dx = (left + right) / 2 - tp.width / 2;
        dx = dx.clamp(
          0.0,
          (cfg.contentWidth - tp.width).clamp(0.0, double.infinity),
        );
        // 垂直：字形顶上方；空间不足时贴本行行顶
        final lineTop = lb.lineTops[ln];
        final dy = (glyphTop - tp.height - 1.0).clamp(lineTop, glyphTop);
        tp.paint(canvas, Offset(origin.dx + dx, origin.dy + dy));
      }
    }
  }

  void _paintImage(
    Canvas canvas,
    LaidOutBlock block,
    double x,
    double y,
    double w,
    double h,
  ) {
    final src = block.block.imageSrc;
    final rect = Rect.fromLTWH(x, y, w, h);
    final img = src != null ? imageCache[src] : null;
    if (img != null) {
      // aspect-fit 居中 + 圆角裁切 + 中等滤波：插图观感更精致
      final srcRect = Rect.fromLTWH(
        0,
        0,
        img.width.toDouble(),
        img.height.toDouble(),
      );
      final s1 = w / img.width;
      final s2 = h / img.height;
      final s = s1 < s2 ? s1 : s2;
      final dst = Rect.fromCenter(
        center: rect.center,
        width: img.width * s,
        height: img.height * s,
      );
      final rrect = RRect.fromRectAndRadius(dst, const Radius.circular(8));
      // 柔和投影：让插图从页面上轻微浮起
      canvas.drawRRect(
        rrect.shift(const Offset(0, 2)),
        Paint()
          ..color = theme.secondary.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawImageRect(
        img,
        srcRect,
        dst,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      return;
    }
    // 加载占位：圆角浅色卡片 + 居中加载环（与成品图同样的 aspect-fit 区域）
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(rrect, Paint()..color = theme.secondary.withValues(alpha: 0.08));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = theme.secondary.withValues(alpha: 0.22),
    );
    final ringR = 14.0;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = theme.accent.withValues(alpha: 0.55);
    canvas.drawArc(
      Rect.fromCircle(center: rect.center, radius: ringR),
      -1.57,
      4.4,
      false,
      ringPaint,
    );
    if (src != null && resources != null && !imageLoading.contains(src)) {
      imageLoading.add(src);
      _loadImage(src);
    }
  }

  Future<void> _loadImage(String src) async {
    try {
      final data = await resources!.get(src);
      if (data == null || data.isEmpty) return;
      // 以 2048px 解码：桌面端大窗口（HiDPI 物理像素 > 1024）不再发虚
      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(data),
        targetWidth: 2048,
      );
      final frame = await codec.getNextFrame();
      imageCache[src] = frame.image;
      imageLoadedTick.value++;
    } catch (_) {
      // 图片解码失败保持占位
    } finally {
      imageLoading.remove(src);
    }
  }

  @override
  bool shouldRepaint(covariant _PagePainter old) =>
      old.page != page ||
      old.theme != theme ||
      old.laid != laid ||
      old.selection != selection ||
      !listEquals(old.marks, marks);
}

/// 翻页动画类型（无/覆盖/平移）
enum PageTurnType { none, cover, slide }

PageTurnType pageTurnTypeOf(String s) => switch (s) {
  'none' => PageTurnType.none,
  'slide' => PageTurnType.slide,
  // 历史设置中的 'fade' 已下线，归入覆盖
  _ => PageTurnType.cover,
};

/// 覆盖动画的视差幅度（底层页位移比例）与压暗峰值
const _coverParallax = 0.2;
const _coverDim = 0.35;

/// 页面流：三区点按 + 拖拽 + 三种翻页动画（无/覆盖/平移，180ms ease-out）。
class PageFlow extends StatefulWidget {
  const PageFlow({
    super.key,
    required this.buildPage,
    required this.onNext,
    required this.onPrev,
    required this.animType,
    this.duration = const Duration(milliseconds: 180),
    this.onTapCenter,
    this.enabled = true,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.selecting = false,
  });

  /// 构建当前阅读状态的页面 Widget（快照式：翻页前先取旧页）
  final Widget Function() buildPage;
  final Future<bool> Function() onNext;
  final Future<bool> Function() onPrev;
  final PageTurnType animType;
  final Duration duration;

  /// 中部点按回调（携带局部坐标，用于批注命中）
  final void Function(Offset localPosition)? onTapCenter;
  final bool enabled;

  /// 长按手势透传（批注：长按划词选择）。为 null 时不注册长按手势。
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;
  final GestureLongPressEndCallback? onLongPressEnd;

  /// 是否正在选择文本（选择期间 tap 不触发翻页/菜单）
  final bool selecting;

  @override
  State<PageFlow> createState() => _PageFlowState();
}

class _PageFlowState extends State<PageFlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  Widget? _outgoing; // 旧页快照
  int _direction = 0; // 1 下一页（新页从右进），-1 上一页
  double _dragT = 0; // 拖拽进度（0..1，配合方向）
  double _dragDx = 0; // 手势累计水平位移（含符号，右为正）
  bool _dragging = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _turn(Future<bool> Function() turn, int dir) async {
    if (_ctrl.isAnimating) return;
    if (widget.animType == PageTurnType.none) {
      final ok = await turn();
      if (ok && mounted) setState(() {});
      return;
    }
    final old = widget.buildPage();
    final ok = await turn();
    if (!ok || !mounted) return;
    setState(() {
      _outgoing = old;
      _direction = dir;
    });
    await _ctrl.forward(from: 0);
    if (mounted) {
      setState(() => _outgoing = null);
    }
  }

  void _handleTapUp(TapUpDetails d) {
    if (!widget.enabled || _ctrl.isAnimating || _dragging) return;
    final w = context.size?.width ?? 1;
    final x = d.localPosition.dx;
    // 批注选择/编辑态：任意区域点按都交给外层处理——
    // 点在操作条外=清除选择状态，实现「点击其他区域自动关闭」
    if (widget.selecting) {
      widget.onTapCenter?.call(d.localPosition);
      return;
    }
    if (x < w * 0.3) {
      _turn(widget.onPrev, -1);
    } else if (x > w * 0.7) {
      _turn(widget.onNext, 1);
    } else {
      widget.onTapCenter?.call(d.localPosition);
    }
  }

  void _onDragStart(DragStartDetails _) {
    if (!widget.enabled || _ctrl.isAnimating) return;
    _dragging = true;
    _dragDx = 0;
    _dragT = 0;
    _direction = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging || !widget.enabled) return;
    final w = context.size?.width ?? 1;
    if (w <= 0) return;
    // 累计位移决定进度与方向：进度连续可逆（左右往返不跳变），
    // 修复旧实现「反向即翻转方向并镜像进度」导致的幅度突跳
    _dragDx += d.delta.dx;
    final pos = -_dragDx / w; // 向左滑 → 正（下一页）
    if (widget.animType == PageTurnType.none) {
      // 「无」动画模式：只记录手势轨迹用于翻页判定，不触发重绘，
      // 保证滑动翻页在禁用动画时依然即时响应（60fps 无压力）
      if (pos > 0) {
        _direction = 1;
        _dragT = pos.clamp(0.0, 1.0);
      } else if (pos < 0) {
        _direction = -1;
        _dragT = (-pos).clamp(0.0, 1.0);
      } else {
        _dragT = 0;
      }
      return;
    }
    setState(() {
      if (pos > 0) {
        _direction = 1;
        _dragT = pos.clamp(0.0, 1.0);
      } else if (pos < 0) {
        _direction = -1;
        _dragT = (-pos).clamp(0.0, 1.0);
      } else {
        _dragT = 0;
      }
    });
  }

  Future<void> _onDragEnd(DragEndDetails d) async {
    if (!_dragging) return;
    _dragging = false;
    final velocity = d.velocity.pixelsPerSecond.dx;
    final shouldTurn = _direction == 1
        ? (_dragT > 0.3 || velocity < -400)
        : _direction == -1
        ? (_dragT > 0.3 || velocity > 400)
        : false;
    final t = _dragT;
    _dragT = 0;
    _dragDx = 0;

    // 「无」动画模式：滑动达到阈值后即时翻页（无过渡动画、无弹回帧）
    if (widget.animType == PageTurnType.none) {
      if (shouldTurn) {
        final ok = await (_direction == 1 ? widget.onNext() : widget.onPrev());
        if (ok && mounted) setState(() {});
      }
      return;
    }

    if (shouldTurn) {
      // 从当前拖拽进度继续动画到 1
      if (_outgoing == null) {
        final old = widget.buildPage();
        final ok = await (_direction == 1 ? widget.onNext() : widget.onPrev());
        if (ok && mounted) {
          setState(() {
            _outgoing = old;
          });
          _ctrl.value = t;
          await _ctrl.forward();
          if (mounted) setState(() => _outgoing = null);
          return;
        }
      }
      await _turn(_direction == 1 ? widget.onNext : widget.onPrev, _direction);
    } else {
      // 弹回
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _handleTapUp,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      // 长按透传（批注选择）；桌面端鼠标长按同样触发
      onLongPressStart: widget.onLongPressStart,
      onLongPressMoveUpdate: widget.onLongPressMoveUpdate,
      onLongPressEnd: widget.onLongPressEnd,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => LayoutBuilder(
          builder: (context, bc) {
            // 用实际阅读区宽度（版心收窄后 ≠ 窗口宽度）
            final width = bc.maxWidth;
            final hasOutgoing = _outgoing != null;
            final t = _dragging ? _dragT : (hasOutgoing ? _ctrl.value : 0.0);
            final dir = _direction;
            if (!hasOutgoing && t == 0) {
              return RepaintBoundary(child: widget.buildPage());
            }
            if (!hasOutgoing && _dragging && widget.animType != PageTurnType.none) {
              // 拖拽反馈与松手后的动画状态无缝衔接（进度同为 t，松手不跳变）：
              // - 平移：当前页跟手全幅位移（松手后即为动画中旧页位置）
              // - 覆盖-前进：当前页=底层页，视差左移 + 渐暗（松手后新页自右缘盖入）
              // - 覆盖-后退：当前页=顶层页，跟手右移滑出（松手后继续滑出揭出新页）
              // RepaintBoundary 放在 Transform 内层：平移只改图层偏移，
              // 不触发整页重绘（修复桌面端长按拖动的卡顿）。
              final Offset off;
              double? dim;
              switch (widget.animType) {
                case PageTurnType.slide:
                  off = Offset(-dir * t * width, 0);
                case PageTurnType.cover:
                  if (dir > 0) {
                    off = Offset(-_coverParallax * t * width, 0);
                    dim = _coverDim * t;
                  } else {
                    off = Offset(t * width, 0);
                  }
                case PageTurnType.none:
                  off = Offset.zero;
              }
              Widget page = Transform.translate(
                offset: off,
                child: RepaintBoundary(child: widget.buildPage()),
              );
              if (dim != null && dim > 0.001) {
                page = Stack(
                  children: [
                    Positioned.fill(child: page),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: dim),
                        ),
                      ),
                    ),
                  ],
                );
              }
              return page;
            }
            return _StackPages(
              current: RepaintBoundary(child: widget.buildPage()),
              outgoing: _outgoing,
              t: t,
              dir: dir,
              type: widget.animType,
              width: width,
            );
          },
        ),
      ),
    );
  }
}

class _StackPages extends StatelessWidget {
  const _StackPages({
    required this.current,
    required this.outgoing,
    required this.t,
    required this.dir,
    required this.type,
    required this.width,
  });

  final Widget current;
  final Widget? outgoing;
  final double t;
  final int dir;
  final PageTurnType type;
  final double width;

  @override
  Widget build(BuildContext context) {
    final old = outgoing;
    if (old == null || type == PageTurnType.none) return current;
    switch (type) {
      case PageTurnType.slide:
        // 平移：双页刚性同步位移（经典 push）——
        // 新页与旧页像两张连着的卡片一起移动，全程等速、无阴影层次
        return Stack(
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(-dir * t * width, 0),
                child: RepaintBoundary(child: old),
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(dir * (1 - t) * width, 0),
                child: RepaintBoundary(child: current),
              ),
            ),
          ],
        );
      case PageTurnType.cover:
        // 覆盖（参考 iOS 导航 push / 主流阅读 App）：
        // - 前进：新页自右缘滑入盖在旧页上方；旧页以 20% 幅度视差左移并逐渐压暗
        // - 后退：旧页向右滑出揭出新页；新页从 -20% 视差位归位、压暗逐渐解除
        // 与平移的本质区别：底层页视差移动 + 压暗，顶层页带前导边缘投影
        final topPage = dir > 0 ? current : old;
        final underPage = dir > 0 ? old : current;
        // 顶层页：前进时从右缘外滑入（1→0），后退时从 0 滑回右缘外（0→1）
        final topOffset = dir > 0 ? (1 - t) * width : t * width;
        // 底层页：前进 0→-20%，后退 -20%→0（视差跟随）
        final underOffset =
            -_coverParallax * (dir > 0 ? t : 1 - t) * width;
        // 底层页压暗：进度越深越暗，随覆盖完成收敛
        final dim = _coverDim * (dir > 0 ? t : 1 - t);
        return Stack(
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(underOffset, 0),
                child: RepaintBoundary(child: underPage),
              ),
            ),
            // 底层页压暗层（在顶层页之下，只盖住底层页可见区域）
            if (dim > 0.001)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: dim),
                  ),
                ),
              ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(topOffset, 0),
                child: RepaintBoundary(child: topPage),
              ),
            ),
            // 顶层页前导边缘投影（随滑动收敛），强化「上层卡片」立体感
            Positioned(
              left: topOffset - 28,
              width: 28,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.28 * (1 - t)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      case PageTurnType.none:
        return current;
    }
  }
}

/// 翻页动画预览：迷你页面按当前选中动画循环演示，供设置面板直观对比
class PageAnimPreview extends StatefulWidget {
  const PageAnimPreview({super.key, required this.type});

  final PageTurnType type;

  @override
  State<PageAnimPreview> createState() => _PageAnimPreviewState();
}

class _PageAnimPreviewState extends State<PageAnimPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  int _dir = 1;

  @override
  void initState() {
    super.initState();
    _loop();
  }

  Future<void> _loop() async {
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    if (!mounted) return;
    if (widget.type == PageTurnType.none) {
      // 无动画：跳变演示
      _dir = -_dir;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (mounted) _loop();
      return;
    }
    _dir = -_dir;
    await _ctrl.forward(from: 0);
    if (mounted) _loop();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _miniPage(int n, Color bg, Color fg) => Container(
    color: bg,
    alignment: Alignment.center,
    child: Text(
      '$n',
      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: fg),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => LayoutBuilder(
        builder: (context, bc) {
          final width = bc.maxWidth;
          final t = widget.type == PageTurnType.none
              ? ((_ctrl.value > 0.5) ? 1.0 : 0.0)
              : _ctrl.value;
          Widget page() => _miniPage(2, cs.surfaceContainerHighest, cs.primary);
          Widget oldPage() => _miniPage(1, cs.surfaceContainerHigh, cs.onSurface);
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 92,
              child: _StackPages(
                current: page(),
                outgoing: oldPage(),
                t: t,
                dir: _dir,
                type: widget.type,
                width: width,
              ),
            ),
          );
        },
      ),
    );
  }
}
