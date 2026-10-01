import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Locator;
import 'package:window_manager/window_manager.dart';

import '../../../app/theme_controller.dart';
import '../../../core/theme/reader_theme.dart';
import '../../../engine/ir/book_document.dart' show TocEntry;
import '../../../engine/pagination/text_paginator.dart';
import '../logic/reader_controller.dart';
import '../logic/reader_settings.dart';
import 'page_flow.dart';

/// 阅读页（计划书 §4.4 交互规格）
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.bookId});

  final String bookId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  bool _menuVisible = false;
  final FocusNode _keyboardFocus = FocusNode();
  String? _lastThemeId;

  @override
  void initState() {
    super.initState();
    imageLoadedTick.addListener(_onImageLoaded);
  }

  @override
  void dispose() {
    imageLoadedTick.removeListener(_onImageLoaded);
    _keyboardFocus.dispose();
    // 离开时保存进度并重置会话
    ref.read(readerControllerProvider.notifier).close();
    super.dispose();
  }

  void _onImageLoaded() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerControllerProvider);
    final themeState = ref.watch(themeControllerProvider);
    final settings = ref.watch(readerSettingsProvider);

    final systemDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final spec = themeState.resolve(systemDark);
    final isDark = spec.isDark;

    // 主题注入控制器（颜色烘焙进排版）——仅在主题变化时，且延迟到帧末
    if (_lastThemeId != spec.id) {
      _lastThemeId = spec.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(readerControllerProvider.notifier).updateTheme(spec);
        }
      });
    }

    final controller = ref.read(readerControllerProvider.notifier);
    final scaffoldBg = spec.background;

    // 键盘翻页（桌面端）
    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: scaffoldBg,
        body: SafeArea(
          top: !settings.showStatusBar,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              // 视口注入 + 首次打开（帧末执行，避免 build 期间副作用）
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                final c = ref.read(readerControllerProvider.notifier);
                final s = ref.read(readerControllerProvider);
                c.updateViewport(size);
                if (!s.loading && s.document == null && s.error == null) {
                  c.open(widget.bookId, viewport: size);
                }
              });
              return Stack(
                children: [
                  Positioned.fill(
                    child: _buildReadingArea(state, settings, spec, controller),
                  ),
                  // 上下状态栏
                  if (settings.showStatusBar && state.document != null)
                    _buildStatusBars(state, spec),
                  // 菜单浮层
                  if (_menuVisible) _buildMenu(state, settings, spec, isDark),
                  // 加载/错误
                  if (state.loading)
                    const Center(child: CircularProgressIndicator()),
                  if (state.error != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              state.error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: spec.secondary),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () => Navigator.of(context).maybePop(),
                              child: const Text('返回书架'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final controller = ref.read(readerControllerProvider.notifier);
    if (_menuVisible) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _menuVisible = false);
      }
      return;
    }
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    // Ctrl + ←/→：上一章 / 下一章（附录 C 快捷键表）
    if (ctrl && key == LogicalKeyboardKey.arrowLeft) {
      controller.jumpToChapter(
        ref.read(readerControllerProvider).spineIndex - 1,
      );
      return;
    }
    if (ctrl && key == LogicalKeyboardKey.arrowRight) {
      final s = ref.read(readerControllerProvider);
      if (s.spineIndex + 1 < (s.document?.spine.length ?? 0)) {
        controller.jumpToChapter(s.spineIndex + 1);
      }
      return;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.pageDown) {
      controller.nextPage();
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      controller.prevPage();
    } else if (key == LogicalKeyboardKey.home) {
      // Home / End：本章开头 / 结尾
      controller.jumpToChapter(
        ref.read(readerControllerProvider).spineIndex,
        charOffset: 0,
      );
    } else if (key == LogicalKeyboardKey.end) {
      final s = ref.read(readerControllerProvider);
      controller.jumpToChapter(
        s.spineIndex,
        charOffset: controller.chapterLength(s.spineIndex),
      );
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.keyM) {
      setState(() => _menuVisible = !_menuVisible);
    }
  }

  Future<void> _toggleFullscreen() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // 桌面端：真实窗口全屏切换（计划书附录 C：F11）
      final fullscreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!fullscreen);
    } else {
      // 移动端：隐藏系统栏的沉浸模式（FR-B10）
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  Widget _buildReadingArea(
    ReaderState state,
    ReaderSettings settings,
    ReaderThemeSpec spec,
    ReaderController controller,
  ) {
    final doc = state.document;
    if (doc == null || state.loading) {
      return const SizedBox.expand();
    }
    // PageFlow 负责手势与动画；页面内容由当前分页数据构建
    return PageFlow(
      animType: pageTurnTypeOf(settings.pageAnim),
      buildPage: () {
        final s = ref.read(readerControllerProvider);
        final chapterLaid = _laidOf(s);
        if (chapterLaid == null) {
          return Container(color: spec.background);
        }
        final pageIdx = s.pageIndex.clamp(0, chapterLaid.pages.length - 1);
        return PageCanvas(
          key: ValueKey('p-${s.spineIndex}-$pageIdx-${chapterLaid.hashCode}'),
          laid: chapterLaid,
          page: chapterLaid.pages[pageIdx],
          theme: spec,
          margins: settings.margins,
          resources: doc.resources,
        );
      },
      onNext: () => controller.nextPage(),
      onPrev: () => controller.prevPage(),
      onTapCenter: () => setState(() => _menuVisible = !_menuVisible),
    );
  }

  LaidOutChapter? _laidOf(ReaderState s) {
    // 直接从控制器 LRU 取（避免状态膨胀）
    return ref
        .read(readerControllerProvider.notifier)
        .laidChapter(s.spineIndex);
  }

  Widget _buildStatusBars(ReaderState state, ReaderThemeSpec spec) {
    final chapter = state.currentChapter;
    final doc = state.document;
    final chapterTitle = chapter?.title ?? '';
    final percent = (state.percent * 100).toStringAsFixed(1);
    final pageText = '第 ${state.pageIndex + 1}/${state.pageCount} 页';
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return IgnorePointer(
      child: Column(
        children: [
          Container(
            height: 28,
            color: spec.background,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: Text(
              chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: spec.secondary),
            ),
          ),
          const Spacer(),
          Container(
            height: 28,
            color: spec.background,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    doc == null ? '' : '$chapterTitle · $pageText',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: spec.secondary),
                  ),
                ),
                Text(
                  '$percent% · $time',
                  style: TextStyle(fontSize: 11, color: spec.secondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- 菜单浮层（毛玻璃，180ms ease-out 出入场） ----

  Widget _buildMenu(
    ReaderState state,
    ReaderSettings settings,
    ReaderThemeSpec spec,
    bool isDark,
  ) {
    final overlayColor = spec.background.withValues(alpha: 0.96);
    final fg = spec.foreground;
    final secondary = spec.secondary;

    Widget panel;
    switch (_menuTab) {
      case _MenuTab.toc:
        panel = _buildTocPanel(state, spec);
        break;
      case _MenuTab.typography:
        panel = _buildTypographyPanel(settings, spec, isDark);
        break;
      case _MenuTab.main:
        panel = _buildMainPanel(state, settings, spec, fg, secondary);
        break;
    }

    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: Column(
          children: [
            // 顶栏
            Container(
              color: overlayColor,
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back, color: fg),
                    onPressed: () async {
                      await ref.read(readerControllerProvider.notifier).close();
                      if (mounted) {
                        Navigator.of(context).maybePop();
                      }
                    },
                  ),
                  Expanded(
                    child: Text(
                      state.book?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontSize: 15),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.format_list_bulleted, color: fg),
                    onPressed: () => setState(() => _menuTab = _MenuTab.toc),
                  ),
                  IconButton(
                    icon: Icon(Icons.text_fields, color: fg),
                    onPressed: () =>
                        setState(() => _menuTab = _MenuTab.typography),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _menuVisible = false),
                child: Container(color: Colors.transparent),
              ),
            ),
            // 底部面板
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              child: Container(
                key: ValueKey(_menuTab),
                width: double.infinity,
                color: overlayColor,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SafeArea(top: false, child: panel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _MenuTab _menuTab = _MenuTab.main;

  Widget _buildMainPanel(
    ReaderState state,
    ReaderSettings settings,
    ReaderThemeSpec spec,
    Color fg,
    Color secondary,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 进度条
        Row(
          children: [
            Text('进度', style: TextStyle(fontSize: 12, color: secondary)),
            const SizedBox(width: 8),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  value: state.percent.clamp(0.0, 1.0),
                  onChanged: (v) => _jumpByPercent(state, v),
                  activeColor: spec.accent,
                ),
              ),
            ),
            Text(
              '${(state.percent * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 主题快捷切换
        Row(
          children: [
            for (final t in BuiltinThemes.all)
              Expanded(
                child: GestureDetector(
                  onTap: () => ref
                      .read(themeControllerProvider.notifier)
                      .setFixedTheme(t.id),
                  child: Container(
                    height: 36,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: t.background,
                      border: Border.all(
                        color: spec.id == t.id
                            ? spec.accent
                            : spec.secondary.withValues(alpha: 0.3),
                        width: spec.id == t.id ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      t.name,
                      style: TextStyle(fontSize: 12, color: t.foreground),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // 翻页动画
        Row(
          children: [
            Text('翻页动画', style: TextStyle(fontSize: 12, color: secondary)),
            const SizedBox(width: 12),
            for (final (label, value) in [
              ('无', 'none'),
              ('覆盖', 'cover'),
              ('平移', 'slide'),
              ('淡入', 'fade'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: settings.pageAnim == value,
                  onSelected: (_) => ref
                      .read(readerSettingsProvider.notifier)
                      .update((s) => s.copyWith(pageAnim: value)),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _jumpByPercent(ReaderState state, double v) async {
    final doc = state.document;
    if (doc == null) return;
    final target = (v * doc.totalChars).round();
    var acc = 0;
    for (var i = 0; i < doc.spine.length; i++) {
      final len = doc.spine[i].charLength;
      if (acc + len >= target) {
        await ref
            .read(readerControllerProvider.notifier)
            .jumpToChapter(i, charOffset: (target - acc).clamp(0, len));
        setState(() => _menuVisible = false);
        return;
      }
      acc += len;
    }
  }

  Widget _buildTocPanel(ReaderState state, ReaderThemeSpec spec) {
    final doc = state.document;
    final toc = doc?.toc ?? const <TocEntry>[];
    final fg = spec.foreground;
    final secondary = spec.secondary;
    return SizedBox(
      height: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '目录（${toc.length}）',
            style: TextStyle(fontSize: 13, color: secondary),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: toc.isEmpty
                ? Center(
                    child: Text('无目录', style: TextStyle(color: secondary)),
                  )
                : ListView.builder(
                    itemCount: toc.length,
                    itemBuilder: (context, i) {
                      final e = toc[i];
                      final active = e.spineIndex == state.spineIndex;
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: EdgeInsets.only(
                          left: 8 + e.depth * 16.0,
                          right: 8,
                        ),
                        title: Text(
                          e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: active ? spec.accent : fg,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        onTap: () async {
                          await ref
                              .read(readerControllerProvider.notifier)
                              .jumpToChapter(
                                e.spineIndex,
                                charOffset: e.charOffset,
                              );
                          setState(() => _menuVisible = false);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypographyPanel(
    ReaderSettings settings,
    ReaderThemeSpec spec,
    bool isDark,
  ) {
    final ctl = ref.read(readerSettingsProvider.notifier);
    TextStyle labelStyle = TextStyle(fontSize: 12, color: spec.secondary);

    Widget sliderRow(
      String label,
      double value,
      double min,
      double max,
      int divisions,
      ValueChanged<double> onChanged,
      String Function(double) fmt,
    ) {
      return Row(
        children: [
          SizedBox(width: 64, child: Text(label, style: labelStyle)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                activeColor: spec.accent,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              fmt(value),
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 12, color: spec.foreground),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        sliderRow(
          '字号',
          settings.fontSize,
          12,
          36,
          24,
          (v) => ctl.update((s) => s.copyWith(fontSize: v)),
          (v) => '${v.round()}',
        ),
        sliderRow(
          '行距',
          settings.lineHeight,
          1.0,
          2.5,
          30,
          (v) => ctl.update((s) => s.copyWith(lineHeight: v)),
          (v) => v.toStringAsFixed(1),
        ),
        sliderRow(
          '段距',
          settings.paragraphSpacing,
          0,
          2,
          20,
          (v) => ctl.update((s) => s.copyWith(paragraphSpacing: v)),
          (v) => v.toStringAsFixed(1),
        ),
        sliderRow(
          '字距',
          settings.letterSpacing,
          -0.5,
          2.0,
          25,
          (v) => ctl.update((s) => s.copyWith(letterSpacing: v)),
          (v) => v.toStringAsFixed(1),
        ),
        sliderRow(
          '页边距',
          settings.marginLeft,
          0,
          64,
          32,
          (v) => ctl.update(
            (s) => s.copyWith(
              marginLeft: v,
              marginRight: v,
              marginTop: v,
              marginBottom: v,
            ),
          ),
          (v) => '${v.round()}',
        ),
        sliderRow(
          '缩进',
          settings.indentChars.toDouble(),
          0,
          4,
          4,
          (v) => ctl.update((s) => s.copyWith(indentChars: v.round())),
          (v) => '${v.round()}',
        ),
        Row(
          children: [
            SizedBox(width: 64, child: Text('两端对齐', style: labelStyle)),
            Switch(
              value: settings.justify,
              activeThumbColor: spec.accent,
              onChanged: (v) => ctl.update((s) => s.copyWith(justify: v)),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => ctl.update((_) => const ReaderSettings()),
              child: Text(
                '恢复默认',
                style: TextStyle(fontSize: 12, color: spec.accent),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

enum _MenuTab { main, toc, typography }
