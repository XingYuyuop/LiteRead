import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/theme/reader_theme.dart';
import '../../../engine/ir/book_document.dart';
import '../../../engine/pagination/text_paginator.dart';

/// 单页画布：用分页时烘焙的 TextPainter 逐行绘制，保证测量/绘制像素一致。
class PageCanvas extends StatelessWidget {
  const PageCanvas({
    super.key,
    required this.laid,
    required this.page,
    required this.theme,
    required this.margins,
    this.resources,
  });

  final LaidOutChapter laid;
  final PageBox page;
  final ReaderThemeSpec theme;
  final EdgeInsets margins;
  final ResourceStore? resources;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PagePainter(
        laid: laid,
        page: page,
        theme: theme,
        margins: margins,
        resources: resources,
      ),
      size: Size.infinite,
    );
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
  });

  final LaidOutChapter laid;
  final PageBox page;
  final ReaderThemeSpec theme;
  final EdgeInsets margins;
  final ResourceStore? resources;

  static final _imageCache = <String, ui.Image>{};
  static final _loading = <String>{};

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

      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          x0 + quoteIndent,
          y,
          (cfg.contentWidth - quoteIndent).clamp(0, double.infinity),
          visibleH,
        ),
      );
      if (fullBlock) {
        lb.painter.paint(canvas, Offset(x0 + quoteIndent, y));
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
      canvas.restore();

      y += visibleH;
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
    final img = src != null ? _imageCache[src] : null;
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
    if (src != null && resources != null && !_loading.contains(src)) {
      _loading.add(src);
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
      _imageCache[src] = frame.image;
      imageLoadedTick.value++;
    } catch (_) {
      // 图片解码失败保持占位
    } finally {
      _loading.remove(src);
    }
  }

  @override
  bool shouldRepaint(covariant _PagePainter old) =>
      old.page != page || old.theme != theme || old.laid != laid;
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
  });

  /// 构建当前阅读状态的页面 Widget（快照式：翻页前先取旧页）
  final Widget Function() buildPage;
  final Future<bool> Function() onNext;
  final Future<bool> Function() onPrev;
  final PageTurnType animType;
  final Duration duration;
  final VoidCallback? onTapCenter;
  final bool enabled;

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
    final w = context.size?.width ?? 1;
    final x = d.localPosition.dx;
    if (x < w * 0.3) {
      _turn(widget.onPrev, -1);
    } else if (x > w * 0.7) {
      _turn(widget.onNext, 1);
    } else {
      widget.onTapCenter?.call();
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
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final width = MediaQuery.sizeOf(context).width;
          final hasOutgoing = _outgoing != null;
          final t = _dragging ? _dragT : (hasOutgoing ? _ctrl.value : 0.0);
          final dir = _direction;
          if (!hasOutgoing && t == 0) {
            return widget.buildPage();
          }
          if (!hasOutgoing && _dragging) {
            // 拖拽反馈：当前页跟手平移（peek），邻页未排版时无对接页
            return Transform.translate(
              offset: Offset(-dir * t * width * 0.25, 0),
              child: widget.buildPage(),
            );
          }
          return _StackPages(
            current: widget.buildPage(),
            outgoing: _outgoing,
            t: t,
            dir: dir,
            type: widget.animType,
            width: width,
          );
        },
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
                child: old,
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(dir * (1 - t) * width, 0),
                child: current,
              ),
            ),
          ],
        );
      case PageTurnType.cover:
        return Stack(
          children: [
            Positioned.fill(child: old),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(dir * (1 - t) * width, 0),
                child: current,
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
