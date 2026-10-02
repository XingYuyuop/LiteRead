import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Locator;
import 'package:pdfrx/pdfrx.dart';
import 'package:window_manager/window_manager.dart';

import '../../../app/theme_controller.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/theme/reader_theme.dart';
import '../../../engine/ir/book_document.dart' show Locator, TocEntry;
import '../../../engine/pagination/text_paginator.dart';
import '../logic/reader_controller.dart';
import '../logic/reader_settings.dart';
import '../../library/data/book_repository.dart';
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
    // 每次打开阅读页清空全局图片缓存：图片 src 为 zip 内相对路径，跨书可能同名
    PageCanvas.clearImageCaches();
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

    // 打开书籍：按 bookId 判断而非 document 是否为空——
    // 修复「第二本书打开仍是第一本内容」（close 异步落盘期间旧状态未清空）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = ref.read(readerControllerProvider);
      if (!s.loading && s.error == null && s.book?.id != widget.bookId) {
        ref.read(readerControllerProvider.notifier).open(widget.bookId);
      }
    });

    final isPdf = state.book?.format == 'PDF';

    Widget body = SafeArea(
      top: !settings.showStatusBar,
      bottom: false,
      child: isPdf
          ? _PdfReaderView(book: state.book!)
          : KeyboardListener(
              focusNode: _keyboardFocus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: _buildTextReader(state, settings, spec, isDark),
            ),
    );

    return Scaffold(backgroundColor: spec.background, body: body);
  }

  // ---- 文本阅读区（EPUB/MD/TXT/MOBI） ----

  Widget _buildTextReader(
    ReaderState state,
    ReaderSettings settings,
    ReaderThemeSpec spec,
    bool isDark,
  ) {
    final controller = ref.read(readerControllerProvider.notifier);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 版心宽度：阅读区占窗口宽度的比例（桌面端可收窄成书页感）
        final fullW = constraints.maxWidth.clamp(0.0, double.infinity);
        final areaW = (fullW * settings.contentWidthScale).clamp(40.0, fullW);
        final areaSize = Size(areaW, constraints.maxHeight);
        // 视口注入（帧末执行，避免 build 期间副作用）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref
                .read(readerControllerProvider.notifier)
                .updateViewport(areaSize);
          }
        });
        return Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: areaW),
                  child: _buildReadingArea(state, settings, spec, controller),
                ),
              ),
            ),
            // 上下状态栏
            if (settings.showStatusBar && state.document != null)
              _buildStatusBars(state, spec),
            // 菜单浮层
            if (_menuVisible) _buildMenu(state, settings, spec, isDark),
            // 加载/错误
            if (state.loading) const Center(child: CircularProgressIndicator()),
            if (state.error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 40,
                        color: spec.secondary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        state.error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: spec.secondary, fontSize: 14),
                      ),
                      const SizedBox(height: 20),
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

  // ---- 菜单浮层（180ms ease-out 出入场） ----

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
        panel = _buildTypographyPanel(settings, spec);
        break;
      case _MenuTab.main:
        panel = _buildMainPanel(state, settings, spec, fg, secondary);
        break;
    }

    return Positioned.fill(
      child: Material(
        color: Colors.black45,
        child: Column(
          children: [
            // 顶栏
            Container(
              color: overlayColor,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回书架',
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
                      style: TextStyle(
                        color: fg,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 分段切换：目录 / 排版
                  _MenuSegmented(
                    spec: spec,
                    value: _menuTab,
                    onChanged: (t) => setState(() => _menuTab = t),
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
            // 底部面板：圆角卡片式
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              child: Container(
                key: ValueKey(_menuTab),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: overlayColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: spec.secondary.withValues(alpha: 0.15),
                    ),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                child: SafeArea(top: false, child: panel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _MenuTab _menuTab = _MenuTab.main;

  /// 分组标题
  Widget _sectionLabel(String text, Color color) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: color,
      ),
    ),
  );

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
        _sectionLabel('阅读主题', secondary),
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
                    height: 40,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: t.background,
                      border: Border.all(
                        color: spec.id == t.id
                            ? spec.accent
                            : spec.secondary.withValues(alpha: 0.3),
                        width: spec.id == t.id ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(10),
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
        _sectionLabel('翻页动画', secondary),
        // 翻页动画
        Row(
          children: [
            for (final (label, value) in [
              ('无', 'none'),
              ('覆盖', 'cover'),
              ('平移', 'slide'),
              ('淡入', 'fade'),
            ])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Center(
                      child: Text(label, style: const TextStyle(fontSize: 12)),
                    ),
                    selected: settings.pageAnim == value,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => ref
                        .read(readerSettingsProvider.notifier)
                        .update((s) => s.copyWith(pageAnim: value)),
                  ),
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
      height: 280,
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
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
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

  Widget _buildTypographyPanel(ReaderSettings settings, ReaderThemeSpec spec) {
    final ctl = ref.read(readerSettingsProvider.notifier);
    final labelStyle = TextStyle(fontSize: 12, color: spec.secondary);

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

    // 字号步进器：更直观的 A- / A+
    Widget fontStepper() {
      return Row(
        children: [
          SizedBox(width: 64, child: Text('字号', style: labelStyle)),
          const Spacer(),
          _StepButton(
            icon: Icons.text_decrease,
            spec: spec,
            onTap: () => ctl.update(
              (s) => s.copyWith(fontSize: (s.fontSize - 1).clamp(12, 36)),
            ),
          ),
          Container(
            width: 56,
            alignment: Alignment.center,
            child: Text(
              '${settings.fontSize.round()}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: spec.foreground,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.text_increase,
            spec: spec,
            onTap: () => ctl.update(
              (s) => s.copyWith(fontSize: (s.fontSize + 1).clamp(12, 36)),
            ),
          ),
        ],
      );
    }

    // 字体选择
    const fontOptions = [
      ('默认', null),
      ('黑体', 'sans-serif'),
      ('宋体', 'serif'),
      ('等宽', 'monospace'),
    ];
    Widget fontChips() {
      return Row(
        children: [
          SizedBox(width: 64, child: Text('字体', style: labelStyle)),
          Expanded(
            child: Row(
              children: [
                for (final (label, family) in fontOptions)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Center(
                          child: Text(
                            label,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        selected: settings.fontFamily == family,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => ctl.update(
                          (s) => s.copyWith(
                            clearFont: family == null,
                            fontFamily: family,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        fontStepper(),
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
        // 版心宽度：阅读区占窗口宽度比例（自定义阅读界面大小）
        sliderRow(
          '版心宽',
          settings.contentWidthScale,
          0.5,
          1.0,
          25,
          (v) => ctl.update((s) => s.copyWith(contentWidthScale: v)),
          (v) => '${(v * 100).round()}%',
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
        const SizedBox(height: 4),
        fontChips(),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(width: 64, child: Text('对齐', style: labelStyle)),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Center(child: Text('两端对齐')),
                      selected: settings.justify,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) =>
                          ctl.update((s) => s.copyWith(justify: true)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Center(child: Text('左对齐')),
                      selected: !settings.justify,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) =>
                          ctl.update((s) => s.copyWith(justify: false)),
                    ),
                  ),
                ],
              ),
            ),
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

/// 菜单顶栏的分段切换（目录 / 排版 / 主面板）
class _MenuSegmented extends StatelessWidget {
  const _MenuSegmented({
    required this.spec,
    required this.value,
    required this.onChanged,
  });

  final ReaderThemeSpec spec;
  final _MenuTab value;
  final ValueChanged<_MenuTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: spec.secondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (tab, icon, tip) in [
            (_MenuTab.main, Icons.tune, '阅读设置'),
            (_MenuTab.toc, Icons.format_list_bulleted, '目录'),
            (_MenuTab.typography, Icons.text_fields, '排版'),
          ])
            Tooltip(
              message: tip,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onChanged(tab),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: value == tab
                        ? spec.background.withValues(alpha: 0.9)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: value == tab ? spec.accent : spec.secondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 排版面板步进按钮
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.spec,
    required this.onTap,
  });

  final IconData icon;
  final ReaderThemeSpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: spec.secondary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 20, color: spec.foreground),
      ),
    );
  }
}

enum _MenuTab { main, toc, typography }

// ---- PDF 阅读视图（固定版式，独立于文本分页引擎） ----

class _PdfReaderView extends ConsumerStatefulWidget {
  const _PdfReaderView({required this.book});

  final Book book;

  @override
  ConsumerState<_PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends ConsumerState<_PdfReaderView> {
  final _viewerCtl = PdfViewerController();
  Timer? _saveDebounce;
  Future<Locator?>? _progress;
  int _pages = 0;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _progress = ref.read(bookRepositoryProvider).getProgress(widget.book.id);
    // 文档加载完成后同步页数（onPageChanged 触发时 pageCount 已可用）
    _viewerCtl.addListener(_onViewerChanged);
  }

  void _onViewerChanged() {
    if (!mounted) return;
    if (_viewerCtl.isReady) {
      final pages = _viewerCtl.pageCount;
      final page = _viewerCtl.pageNumber;
      if (pages != _pages || (page != null && page != _page)) {
        setState(() {
          _pages = pages;
          if (page != null) _page = page;
        });
      }
    }
  }

  @override
  void dispose() {
    _viewerCtl.removeListener(_onViewerChanged);
    _saveDebounce?.cancel();
    // 离开时按页码落盘进度
    final repo = ref.read(bookRepositoryProvider);
    _saveNow(repo);
    super.dispose();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 800),
      () => _saveNow(ref.read(bookRepositoryProvider)),
    );
  }

  Future<void> _saveNow(BookRepository repo) async {
    if (_pages == 0) return;
    final page = _page.clamp(1, _pages);
    try {
      await repo.saveProgress(
        widget.book.id,
        Locator(spineIndex: 0, charOffset: page, chapterLength: _pages),
        page / _pages,
      );
    } catch (_) {
      // 进度保存失败不阻塞阅读
    }
  }

  void _jumpToPage(int page) {
    final target = page.clamp(1, _pages == 0 ? 1 : _pages);
    _viewerCtl.goToPage(pageNumber: target);
    setState(() => _page = target);
    _scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeControllerProvider);
    final systemDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final spec = themeState.resolve(systemDark);
    final fg = spec.foreground;
    final secondary = spec.secondary;
    final percent = _pages == 0 ? 0.0 : _page / _pages;

    return FutureBuilder<Locator?>(
      future: _progress,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final savedPage = snap.data?.charOffset ?? 1;
        return Stack(
          children: [
            PdfViewer.file(
              widget.book.filePath,
              controller: _viewerCtl,
              initialPageNumber: savedPage.clamp(1, 1 << 30),
              params: PdfViewerParams(
                backgroundColor: spec.background,
                onPageChanged: (page) {
                  if (page == null || !mounted) return;
                  setState(() => _page = page);
                  _scheduleSave();
                },
              ),
            ),
            // 顶栏
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: spec.background.withValues(alpha: 0.94),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回书架',
                      icon: Icon(Icons.arrow_back, color: fg),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        widget.book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '全屏',
                      icon: Icon(Icons.fullscreen, color: fg),
                      onPressed: () async {
                        final fullscreen = await windowManager.isFullScreen();
                        await windowManager.setFullScreen(!fullscreen);
                      },
                    ),
                  ],
                ),
              ),
            ),
            // 底栏：页码 + 进度
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                color: spec.background.withValues(alpha: 0.94),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text(
                      '$_page / $_pages',
                      style: TextStyle(fontSize: 12, color: secondary),
                    ),
                    Expanded(
                      child: _pages == 0
                          ? const SizedBox()
                          : SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7,
                                ),
                              ),
                              child: Slider(
                                value: percent.clamp(0.0, 1.0),
                                activeColor: spec.accent,
                                onChanged: (v) =>
                                    _jumpToPage((v * _pages).round() + 1),
                              ),
                            ),
                    ),
                    Text(
                      '${(percent * 100).toStringAsFixed(0)}%',
                      style: TextStyle(fontSize: 12, color: secondary),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
