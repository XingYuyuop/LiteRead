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
  /// 判定逻辑与 _PagePainter._paintImage 的布局保持一致。
  static String? hitTestImage(
    LaidOutChapter laid,
    PageBox page,
    EdgeInsets margins,
    Offset local,
  ) {
    final cfg = laid.config;
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
      if (lb.isImage) {
        final rect = Rect.fromLTWH(
          margins.left,
          y,
          cfg.contentWidth,
          visibleH,
        );
        if (rect.contains(local)) {
          return lb.block.imageSrc;
        }
      }
      y += visibleH;
    }
    return null;
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
    final y0 = margins.top;
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
        } else if (styleIndex == 1) {
          // 直线下划线
          canvas.drawLine(
            Offset(r.left, r.bottom - 1.5),
            Offset(r.right, r.bottom - 1.5),
            Paint()
              ..color = color
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round,
          );
        } else {
          // 波浪下划线
          final path = Path();
          final yWave = r.bottom - 1.5;
          const amp = 1.5;
          const wl = 5.0;
          var x = r.left;
          var up = true;
          path.moveTo(x, yWave);
          while (x < r.right) {
            final nx = (x + wl).clamp(r.left, r.right).toDouble();
            path.quadraticBezierTo(
              (x + nx) / 2,
              up ? yWave - amp : yWave + amp,
              nx,
              yWave,
            );
            up = !up;
            x = nx;
          }
          canvas.drawPath(
            path,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
        }
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
      canvas.drawImageRect(img, srcRect, dst, Paint());
      return;
    }
    canvas.drawRect(
      rect,
      Paint()..color = theme.secondary.withValues(alpha: 0.12),
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '图片',
        style: TextStyle(
          color: theme.secondary.withValues(alpha: 0.7),
          fontSize: 13,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(
      canvas,
      Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2),
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
      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(data),
        targetWidth: 1024,
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

/// 翻页动画类型
enum PageTurnType { none, cover, slide, fade }

PageTurnType pageTurnTypeOf(String s) => switch (s) {
  'none' => PageTurnType.none,
  'slide' => PageTurnType.slide,
  'fade' => PageTurnType.fade,
  _ => PageTurnType.cover,
};

/// 页面流：三区点按 + 拖拽 + 四种翻页动画（无/覆盖/平移/淡入，180ms ease-out）。
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
    // 选择批注期间：点按仅用于清除选择，不翻页/不弹菜单
    if (widget.selecting) return;
    final w = context.size?.width ?? 1;
    final x = d.localPosition.dx;
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
    _dragT = 0;
    _direction = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging || !widget.enabled) return;
    final w = context.size?.width ?? 1;
    if (w <= 0) return;
    final dx = -d.delta.dx / w; // 向左滑 → 下一页（正）
    setState(() {
      if (_direction == 0) {
        _direction = dx >= 0 ? 1 : -1;
      }
      _dragT = (_dragT + dx.abs()).clamp(0.0, 1.0);
      if (dx.sign != 0 && dx.sign != _direction) {
        // 反向拖：视为回退
        _dragT = (1 - _dragT).clamp(0.0, 1.0);
        _direction = _direction * -1;
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

    if (shouldTurn) {
      // 从当前拖拽进度继续动画到 1
      if (_outgoing == null && widget.animType != PageTurnType.none) {
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
            if (!hasOutgoing && _dragging) {
              // 拖拽反馈：当前页跟手平移（peek），邻页未排版时无对接页。
              // RepaintBoundary 放在 Transform 内层：平移只改图层偏移，
              // 不触发整页重绘（修复桌面端长按拖动的卡顿）。
              return Transform.translate(
                offset: Offset(-dir * t * width * 0.25, 0),
                child: RepaintBoundary(child: widget.buildPage()),
              );
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
        return Stack(
          children: [
            Positioned.fill(child: RepaintBoundary(child: old)),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(dir * (1 - t) * width, 0),
                child: RepaintBoundary(child: current),
              ),
            ),
          ],
        );
      case PageTurnType.fade:
        return Stack(
          children: [
            Positioned.fill(
              child: Opacity(opacity: 1 - t, child: old),
            ),
            Positioned.fill(
              child: Opacity(opacity: t, child: current),
            ),
          ],
        );
      case PageTurnType.none:
        return current;
    }
  }
}
