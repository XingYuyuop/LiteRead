import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Locator;
import 'package:pdfrx/pdfrx.dart';
import 'package:window_manager/window_manager.dart';

import '../../../app/theme_controller.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/theme/reader_theme.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../../engine/ir/book_document.dart'
    show BookDocument, Footnote, Locator, TocEntry;
import '../../../engine/pagination/text_paginator.dart';
import '../data/highlight_repository.dart';
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

  /// 有效边距（_buildTextReader 布局时更新；命中测试/选区换算共用）
  EdgeInsets _effMargins = const EdgeInsets.fromLTRB(16, 24, 16, 24);

  // ---- 四角信息（时间/电量需要定时刷新） ----
  Timer? _cornerTimer;
  StreamSubscription<BatteryState>? _batterySub;
  final Battery _battery = Battery();
  int? _batteryLevel; // null = 不可用（桌面端无电池）
  bool _batteryCharging = false;

  // ---- 批注（划线/笔记）选择状态 ----
  List<BookHighlight> _highlights = const [];
  int? _selStart; // 章内字符偏移（选择锚点）
  int? _selEnd; // 当前拖动端
  BookHighlight? _activeHighlight; // 点按已有批注进入编辑态

  bool get _selecting => _selStart != null && _selEnd != null;

  @override
  void initState() {
    super.initState();
    imageLoadedTick.addListener(_onImageLoaded);
    // 每次打开阅读页清空全局图片缓存：图片 src 为 zip 内相对路径，跨书可能同名
    PageCanvas.clearImageCaches();
    // 移动端：进入阅读页即隐藏系统状态栏/导航栏（沉浸式全屏），退出时恢复
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _loadHighlights();
    // 时间/电量每 30 秒刷新一次
    _cornerTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _refreshBattery();
    _batterySub = _battery.onBatteryStateChanged.listen((state) {
      if (!mounted) return;
      _batteryCharging = state == BatteryState.charging;
      _refreshBattery();
    });
  }

  Future<void> _refreshBattery() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted && level >= 0) setState(() => _batteryLevel = level);
    } catch (_) {
      // 平台不支持时保持 null（不显示电量项）
    }
  }

  Future<void> _loadHighlights() async {
    try {
      final list = await ref
          .read(highlightRepositoryProvider)
          .listByBook(widget.bookId);
      if (mounted) setState(() => _highlights = list);
    } catch (_) {
      // 批注加载失败不阻塞阅读
    }
  }

  @override
  void dispose() {
    imageLoadedTick.removeListener(_onImageLoaded);
    _keyboardFocus.dispose();
    _cornerTimer?.cancel();
    _batterySub?.cancel();
    // 移动端：离开阅读页恢复系统栏
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
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
    // 墨水屏模式：纯黑白高对比配色覆盖（消除彩色残影），动画已在 PageFlow 强制关闭
    final isDark = settings.inkMode ? false : spec.isDark;
    final effSpec = settings.inkMode ? _inkSpec(spec) : spec;

    // 主题注入控制器（颜色烘焙进排版）——仅在主题变化时，且延迟到帧末
    if (_lastThemeId != effSpec.id) {
      _lastThemeId = effSpec.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(readerControllerProvider.notifier).updateTheme(effSpec);
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

    // 键盘监听包住整个页面（文本/PDF/菜单统一处理）：
    // 修复 ESC/方向键在 PDF 视图与焦点被滑块抢走后失效的问题
    Widget body = KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      // 文本阅读的安全区在 _buildTextReader 内以「有效边距」统一处理；
      // PDF 视图沿用系统 SafeArea
      child: isPdf
          ? SafeArea(
              top: !settings.showStatusBar,
              child: _PdfReaderView(book: state.book!),
            )
          : _buildTextReader(state, settings, effSpec, isDark),
    );

    return Scaffold(backgroundColor: effSpec.background, body: body);
  }

  /// 墨水屏配色：纯黑白、无彩色（高对比、无残影）
  ReaderThemeSpec _inkSpec(ReaderThemeSpec s) => s.copyWith(
    id: 'ink-override',
    name: '墨水屏',
    background: const Color(0xFFFFFFFF),
    foreground: const Color(0xFF000000),
    secondary: const Color(0xFF444444),
    accent: const Color(0xFF000000),
    highlightPalette: const [
      Color(0x2E000000),
      Color(0x2E000000),
      Color(0x2E000000),
      Color(0x2E000000),
    ],
  );

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

        // 有效边距 = 用户设置与预设安全下限取大，再叠加系统安全区
        // （viewPadding 在沉浸模式隐藏系统栏后仍保留数值，确保文本
        //  始终不进入刘海/手势条区域，也绝不与四角信息重叠）
        final vp = MediaQuery.viewPaddingOf(context);
        final eff = EdgeInsets.fromLTRB(
          settings.marginLeft.clamp(18.0, 200.0) + vp.left,
          settings.marginTop.clamp(28.0, 200.0) + vp.top,
          settings.marginRight.clamp(18.0, 200.0) + vp.right,
          settings.marginBottom.clamp(32.0, 200.0) + vp.bottom,
        );
        _effMargins = eff;

        // 视口注入（帧末执行，避免 build 期间副作用）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref
                .read(readerControllerProvider.notifier)
                .updateViewport(areaSize, eff);
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
            // 四角信息（时间/电量/进度/页码等，可自定义）
            if (settings.showStatusBar && state.document != null)
              _buildCornerOverlay(state, settings, spec),
            // 菜单浮层
            if (_menuVisible) _buildMenu(state, settings, spec, isDark),
            // 批注操作条（划词选择中 / 编辑已有批注）
            if (!_menuVisible && (_selecting || _activeHighlight != null))
              _buildSelectionOverlay(spec, areaSize),
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

  void _closeMenu() {
    setState(() {
      _menuVisible = false;
      _menuTab = null;
    });
    // 菜单关闭后把焦点交还页面根节点，保证 ESC/翻页键继续生效
    _keyboardFocus.requestFocus();
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final controller = ref.read(readerControllerProvider.notifier);
    if (_menuVisible) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _closeMenu();
      }
      return;
    }
    // 批注选择态：ESC/Enter 先处理选择，不翻页
    if (_selecting || _activeHighlight != null) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          _selStart = null;
          _selEnd = null;
          _activeHighlight = null;
        });
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
      // 电脑端阅读界面：ESC 返回书架
      Navigator.of(context).maybePop();
    } else if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.keyM) {
      setState(() => _menuVisible = true);
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
      // 墨水屏模式：强制无动画
      animType: pageTurnTypeOf(settings.inkMode ? 'none' : settings.pageAnim),
      duration: settings.inkMode
          ? Duration.zero
          : const Duration(milliseconds: 300),
      buildPage: () {
        final s = ref.read(readerControllerProvider);
        final chapterLaid = _laidOf(s);
        if (chapterLaid == null) {
          return Container(color: spec.background);
        }
        final pageIdx = s.pageIndex.clamp(0, chapterLaid.pages.length - 1);
        final page = chapterLaid.pages[pageIdx];
        return PageCanvas(
          key: ValueKey('p-${s.spineIndex}-$pageIdx-${chapterLaid.hashCode}'),
          laid: chapterLaid,
          page: page,
          theme: spec,
          margins: _effMargins,
          resources: doc.resources,
          marks: _marksFor(s.spineIndex, page),
          selection: _selecting
              ? (
                  _selStart! < _selEnd! ? _selStart! : _selEnd!,
                  _selStart! < _selEnd! ? _selEnd! : _selStart!,
                )
              : null,
        );
      },
      onNext: () => controller.nextPage(),
      onPrev: () => controller.prevPage(),
      onTapCenter: _onCenterTap,
      selecting: _selecting || _activeHighlight != null,
      onLongPressStart: _onSelectStart,
      onLongPressMoveUpdate: _onSelectMove,
      onLongPressEnd: _onSelectEnd,
    );
  }

  // ---- 批注：命中 / 选择 / 绘制数据 ----

  /// 当前页命中的批注（供 PageCanvas 绘制）
  List<PageMark> _marksFor(int spineIndex, PageBox page) {
    if (_highlights.isEmpty) return const [];
    final marks = <PageMark>[];
    for (final h in _highlights) {
      if (h.spineIndex != spineIndex) continue;
      if (h.endChar <= page.startChar || h.startChar >= page.endChar) continue;
      marks.add(
        PageMark(
          start: h.startChar,
          end: h.endChar,
          colorIndex: h.colorIndex,
          // 标注统一下划线样式（历史背景/波浪也按直线渲染）
          styleIndex: 1,
        ),
      );
    }
    return marks;
  }

  /// 长按起点：命中图片 → 查看大图；否则定位章内字符并开始选择
  void _onSelectStart(LongPressStartDetails d) {
    // 图片命中检查（长按图片查看大图/保存）
    final s0 = ref.read(readerControllerProvider);
    final laid0 = _laidOf(s0);
    if (laid0 != null && s0.pageIndex < laid0.pages.length) {
      final imgSrc = PageCanvas.hitTestImage(
        laid0,
        laid0.pages[s0.pageIndex],
        _effMargins,
        d.localPosition,
      );
      if (imgSrc != null && imgSrc.isNotEmpty) {
        _showImageViewer(imgSrc);
        return;
      }
    }
    final char = _hitTestChar(d.localPosition);
    if (char == null) return;
    setState(() {
      _selStart = char;
      _selEnd = char;
      _activeHighlight = null;
    });
  }

  // ---- 图片查看器（长按图片：大图缩放 + 保存） ----

  Future<void> _showImageViewer(String src) async {
    final doc = ref.read(readerControllerProvider).document;
    if (doc == null) return;
    final data = await doc.resources.get(src);
    if (data == null || data.isEmpty) {
      if (mounted) {
        showAppSnackBar(context, '图片资源加载失败');
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _ImageViewerDialog(bytes: data),
    );
    // 关闭后焦点交还页面，保证快捷键继续生效
    _keyboardFocus.requestFocus();
  }

  void _onSelectMove(LongPressMoveUpdateDetails d) {
    if (_selStart == null) return;
    final char = _hitTestChar(d.localPosition);
    if (char == null || char == _selEnd) return;
    setState(() => _selEnd = char);
  }

  void _onSelectEnd(LongPressEndDetails d) {
    if (_selStart == null) return;
    if (_selStart == _selEnd) {
      // 未拖出有效范围：取消（保留单点也可以是误触）
      setState(() {
        _selStart = null;
        _selEnd = null;
      });
      return;
    }
    // 长按直接划下划线（默认色），无需再点「划线」按钮
    _saveSelectionHighlight(0, 1);
  }

  /// 局部坐标 → 章内字符偏移
  int? _hitTestChar(Offset local) {
    final s = ref.read(readerControllerProvider);
    final laid = _laidOf(s);
    if (laid == null || s.pageIndex >= laid.pages.length) return null;
    return PageCanvas.hitTestChar(
      laid,
      laid.pages[s.pageIndex],
      _effMargins,
      local,
    );
  }

  /// 中部点按：选择态清除选择；命中有批注则编辑；命中注标弹脚注；否则弹出菜单
  void _onCenterTap(Offset local) {
    if (_selecting || _activeHighlight != null) {
      setState(() {
        _selStart = null;
        _selEnd = null;
        _activeHighlight = null;
      });
      return;
    }
    final char = _hitTestChar(local);
    if (char != null) {
      final s = ref.read(readerControllerProvider);
      for (final h in _highlights) {
        if (h.spineIndex == s.spineIndex &&
            char >= h.startChar &&
            char < h.endChar) {
          setState(() => _activeHighlight = h);
          return;
        }
      }
      // 注标命中：弹出脚注内容（EPUB noteref）
      final doc = s.document;
      if (doc != null && s.spineIndex >= 0 && s.spineIndex < doc.spine.length) {
        final run = doc.spine[s.spineIndex].inlineRunAt(char);
        final refId = run?.refId;
        if (refId != null) {
          final fn = _findFootnote(doc, refId, s.spineIndex);
          if (fn != null) {
            _showFootnote(fn);
            return;
          }
        }
      }
    }
    setState(() => _menuVisible = !_menuVisible);
  }

  // ---- 脚注（EPUB 注标） ----

  /// 注标目标 → 脚注内容：优先当前章，其次全书
  /// （跨文件注标：内容常集中在章末/书末 notes 文件）
  Footnote? _findFootnote(BookDocument doc, String id, int spineIndex) {
    if (spineIndex >= 0 && spineIndex < doc.spine.length) {
      final cur = doc.spine[spineIndex].footnotes[id];
      if (cur != null) return cur;
    }
    for (final c in doc.spine) {
      final f = c.footnotes[id];
      if (f != null) return f;
    }
    return null;
  }

  Future<void> _showFootnote(Footnote fn) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('注释'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 400),
          child: SingleChildScrollView(child: SelectableText(fn.text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    // 关闭后焦点交还页面，保证快捷键继续生效
    _keyboardFocus.requestFocus();
  }

  /// 选中文本内容
  String? get _selectedText {
    final s = ref.read(readerControllerProvider);
    final doc = s.document;
    if (doc == null || !_selecting) return null;
    final start = _selStart! < _selEnd! ? _selStart! : _selEnd!;
    final end = _selStart! < _selEnd! ? _selEnd! : _selStart!;
    if (start >= end || end > doc.spine[s.spineIndex].charLength) return null;
    return doc.spine[s.spineIndex].plainText.substring(start, end);
  }

  // ---- 批注操作条 / 样式选择 / 笔记 ----

  void _clearSelection() {
    setState(() {
      _selStart = null;
      _selEnd = null;
      _activeHighlight = null;
    });
  }

  /// 批注操作条：贴近批注位置悬浮（上方优先，空间不足放下方）。
  /// 长按划词松手即直接保存下划线；操作条仅用于已有批注（笔记/复制/删除）。
  /// 无「取消」按钮：点击屏幕其他区域即自动关闭选择状态。
  Widget _buildSelectionOverlay(ReaderThemeSpec spec, Size areaSize) {
    final active = _activeHighlight;
    if (active == null) return const SizedBox.shrink();
    final actions = <(String, IconData, VoidCallback)>[
      ('笔记', Icons.edit_note_outlined, () => _editNote(active)),
      (
        '复制',
        Icons.copy_outlined,
        () {
          Clipboard.setData(ClipboardData(text: active.text));
          showAppSnackBar(
            context,
            '已复制',
            duration: const Duration(milliseconds: 800),
          );
          _clearSelection();
        },
      ),
      ('删除', Icons.delete_outline, () => _deleteHighlight(active)),
    ];
    final pill = Material(
      color: spec.background,
      elevation: 6,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, icon, onTap) in actions)
              InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: spec.foreground),
                      const SizedBox(width: 5),
                      // forceStrutHeight 锁定行高：修复中英混排时
                      // 部分字符被压缩变小的问题
                      Text(
                        label,
                        strutStyle: const StrutStyle(
                          fontSize: 14,
                          height: 1.2,
                          forceStrutHeight: true,
                        ),
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.2,
                          letterSpacing: 0,
                          fontWeight: FontWeight.w500,
                          color: spec.foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // 计算批注在页面上的包围盒，让操作条出现在划线位置附近
    final s = ref.read(readerControllerProvider);
    final laid = _laidOf(s);
    Rect? anchor;
    if (laid != null && s.pageIndex < laid.pages.length) {
      anchor = PageCanvas.selectionRect(
        laid,
        laid.pages[s.pageIndex],
        _effMargins,
        active.startChar,
        active.endChar,
      );
    }
    if (anchor == null) {
      return Positioned(
        left: 0,
        right: 0,
        bottom: 28,
        child: Center(child: pill),
      );
    }

    // 版心收窄时阅读区在页面中的水平偏移
    final canvasDx = ((MediaQuery.sizeOf(context).width - areaSize.width) / 2)
        .clamp(0.0, double.infinity);
    final rect = Rect.fromLTRB(
      anchor.left + canvasDx,
      anchor.top,
      anchor.right + canvasDx,
      anchor.bottom,
    );
    const pillHeight = 52.0;
    final areaH = areaSize.height;
    final maxY = (areaH - pillHeight - 8).clamp(8.0, double.infinity);
    // 选中位置偏下 → 操作条显示在上方；否则显示在下方
    final showAbove = rect.center.dy > areaH * 0.5;
    final top = showAbove
        ? (rect.top - pillHeight - 8).clamp(8.0, maxY)
        : (rect.bottom + 8).clamp(8.0, maxY);
    // 水平：操作条中心对齐选区中心（Alignment 自动在屏幕边缘截停）
    final alignX =
        ((rect.center.dx / (areaSize.width == 0 ? 1 : areaSize.width)) * 2 - 1)
            .clamp(-1.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Align(alignment: Alignment(alignX, -1), child: pill),
    );
  }

  /// 保存当前划词为批注（统一下划线样式）
  Future<void> _saveSelectionHighlight(int colorIndex, int styleIndex) async {
    final s = ref.read(readerControllerProvider);
    final text = _selectedText;
    if (text == null) return;
    final start = _selStart! < _selEnd! ? _selStart! : _selEnd!;
    final end = _selStart! < _selEnd! ? _selEnd! : _selStart!;
    try {
      await ref
          .read(highlightRepositoryProvider)
          .add(
            bookId: widget.bookId,
            spineIndex: s.spineIndex,
            startChar: start,
            endChar: end,
            colorIndex: colorIndex,
            styleIndex: styleIndex,
            text: text,
          );
      await _loadHighlights();
    } catch (_) {
      // 保存失败不阻塞阅读
    }
    _clearSelection();
  }

  Future<void> _editNote(BookHighlight h) async {
    final ctl = TextEditingController(text: h.note);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(h.isNote ? '编辑笔记' : '添加笔记'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '写下此刻的想法…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      final note = ctl.text.trim();
      try {
        await ref
            .read(highlightRepositoryProvider)
            .updateNote(h.id, note.isEmpty ? null : note);
        await _loadHighlights();
      } catch (_) {}
    }
    _clearSelection();
  }

  Future<void> _deleteHighlight(BookHighlight h) async {
    try {
      await ref.read(highlightRepositoryProvider).remove(h.id);
      await _loadHighlights();
    } catch (_) {}
    _clearSelection();
  }

  LaidOutChapter? _laidOf(ReaderState s) {
    // 直接从控制器 LRU 取（避免状态膨胀）
    return ref
        .read(readerControllerProvider.notifier)
        .laidChapter(s.spineIndex);
  }

  /// 四角信息覆盖层：每个角显示内容可自定义
  /// （0无 1时间 2电量 3进度 4页码 5书名 6章节名）
  Widget _buildCornerOverlay(
    ReaderState state,
    ReaderSettings settings,
    ReaderThemeSpec spec,
  ) {
    final chapterTitle = state.currentChapter?.title ?? '';
    final pageText = '${state.pageIndex + 1}/${state.pageCount}';
    final percentText = '${(state.percent * 100).toStringAsFixed(1)}%';
    final now = DateTime.now();
    final timeText =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final batteryText = _batteryLevel == null
        ? ''
        : _batteryCharging
        ? '⚡$_batteryLevel%'
        : '$_batteryLevel%';

    String contentOf(int option) => switch (option) {
      1 => timeText,
      2 => batteryText,
      3 => percentText,
      4 => '第 $pageText 页',
      5 => state.book?.title ?? '',
      6 => chapterTitle,
      _ => '',
    };

    Widget corner(int option, Alignment alignment) {
      final text = contentOf(option);
      if (option == 0 || text.isEmpty) return const SizedBox.shrink();
      return Align(
        alignment: alignment,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: spec.background.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(4),
          ),
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: spec.secondary),
          ),
        ),
      );
    }

    // 四角信息整体避开系统安全区（刘海/手势条），不再贴屏幕边缘
    final vp = MediaQuery.viewPaddingOf(context);
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          vp.left + 6,
          vp.top + 6,
          vp.right + 6,
          vp.bottom + 6,
        ),
        child: Stack(
          children: [
            corner(settings.cornerTopLeft, Alignment.topLeft),
            corner(settings.cornerTopRight, Alignment.topRight),
            corner(settings.cornerBottomLeft, Alignment.bottomLeft),
            corner(settings.cornerBottomRight, Alignment.bottomRight),
          ],
        ),
      ),
    );
  }

  // ---- 菜单浮层：底部选项栏（左起：目录/阅读主题/翻页动画/排版）+ 可折叠面板 ----

  Widget _buildMenu(
    ReaderState state,
    ReaderSettings settings,
    ReaderThemeSpec spec,
    bool isDark,
  ) {
    final overlayColor = spec.background.withValues(alpha: 0.96);
    final fg = spec.foreground;
    final animDur = settings.inkMode
        ? Duration.zero
        : const Duration(milliseconds: 180);

    Widget? panel;
    switch (_menuTab) {
      case _MenuTab.toc:
        panel = _buildTocPanel(state, spec);
      case _MenuTab.theme:
        panel = _buildThemePanel(spec);
      case _MenuTab.anim:
        panel = _buildAnimPanel(settings, spec);
      case _MenuTab.typography:
        panel = _buildTypographyPanel(settings, spec);
      case null:
        panel = null;
    }

    return Positioned.fill(
      // 无暗化遮罩：菜单贴合阅读界面背景（中间空白区点按关闭菜单）
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            // 顶栏：返回书架 + 书名（设置已并入底部选项栏，无右上角按钮）
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
                ],
              ),
            ),
            // 空白区点按关闭菜单
            Expanded(
              child: GestureDetector(
                onTap: _closeMenu,
                child: Container(color: Colors.transparent),
              ),
            ),
            // 中部面板（按底部选项切换）
            if (panel != null)
              AnimatedSwitcher(
                duration: animDur,
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
            // 进度条：常驻菜单；调整后需手动确认关闭，不自动退出
            Container(
              color: overlayColor,
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
              child: _buildProgressRow(state, spec),
            ),
            // 底部选项栏：左下角起依次为目录、阅读主题、翻页动画、排版
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: overlayColor,
                border: Border(
                  top: BorderSide(
                    color: spec.secondary.withValues(alpha: 0.15),
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    for (final (tab, icon, label) in [
                      (_MenuTab.toc, Icons.format_list_bulleted, '目录'),
                      (_MenuTab.theme, Icons.palette_outlined, '阅读主题'),
                      (_MenuTab.anim, Icons.auto_stories, '翻页动画'),
                      (_MenuTab.typography, Icons.text_fields, '排版'),
                    ])
                      Expanded(
                        child: _MenuOption(
                          icon: icon,
                          label: label,
                          active: _menuTab == tab,
                          spec: spec,
                          onTap: () => setState(() {
                            _menuTab = _menuTab == tab ? null : tab;
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _MenuTab? _menuTab;

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

  /// 进度调整：常驻显示；拖动即时跳转；左右按钮切换上一章/下一章，
  /// 跳转后菜单保持打开（进度随章节变化自动刷新）
  Widget _buildProgressRow(ReaderState state, ReaderThemeSpec spec) {
    return Row(
      children: [
        IconButton(
          tooltip: '上一章',
          icon: Icon(Icons.skip_previous, color: spec.accent, size: 22),
          onPressed: state.spineIndex > 0
              ? () => ref
                    .read(readerControllerProvider.notifier)
                    .jumpToChapter(state.spineIndex - 1)
              : null,
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
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
          style: TextStyle(fontSize: 12, color: spec.foreground),
        ),
        IconButton(
          tooltip: '下一章',
          icon: Icon(Icons.skip_next, color: spec.accent, size: 22),
          onPressed: state.spineIndex + 1 < (state.document?.spine.length ?? 0)
              ? () => ref
                    .read(readerControllerProvider.notifier)
                    .jumpToChapter(state.spineIndex + 1)
              : null,
        ),
      ],
    );
  }

  /// 阅读主题面板
  Widget _buildThemePanel(ReaderThemeSpec spec) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionLabel('阅读主题', spec.secondary),
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
      ],
    );
  }

  /// 翻页动画面板
  Widget _buildAnimPanel(ReaderSettings settings, ReaderThemeSpec spec) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionLabel('翻页动画', spec.secondary),
        if (settings.inkMode)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '已开启墨水屏模式：翻页动画已禁用，关闭后可恢复',
              style: TextStyle(fontSize: 12, color: spec.secondary),
            ),
          ),
        Row(
          children: [
            for (final (label, value) in [
              ('无', 'none'),
              ('覆盖', 'cover'),
              ('平移', 'slide'),
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

  /// 四角显示配置对话框
  Future<void> _showCornerConfig(ReaderSettings settings) async {
    final ctl = ref.read(readerSettingsProvider.notifier);
    var topLeft = settings.cornerTopLeft;
    var topRight = settings.cornerTopRight;
    var bottomLeft = settings.cornerBottomLeft;
    var bottomRight = settings.cornerBottomRight;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('四角显示设置'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _cornerDropdown(
                  '左上角',
                  topLeft,
                  (v) => setDialog(() => topLeft = v),
                ),
                _cornerDropdown(
                  '右上角',
                  topRight,
                  (v) => setDialog(() => topRight = v),
                ),
                _cornerDropdown(
                  '左下角',
                  bottomLeft,
                  (v) => setDialog(() => bottomLeft = v),
                ),
                _cornerDropdown(
                  '右下角',
                  bottomRight,
                  (v) => setDialog(() => bottomRight = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                ctl.update(
                  (s) => s.copyWith(
                    cornerTopLeft: topLeft,
                    cornerTopRight: topRight,
                    cornerBottomLeft: bottomLeft,
                    cornerBottomRight: bottomRight,
                  ),
                );
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (mounted) _keyboardFocus.requestFocus();
  }

  Widget _cornerDropdown(String label, int value, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: DropdownButton<int>(
              value: value,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (var i = 0; i < cornerOptionLabels.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(cornerOptionLabels[i]),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 进度跳转：拖动即时定位；菜单不自动关闭，由用户点「完成」确认
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

    // 面板项较多：限高可滚动，避免小窗口溢出
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: SingleChildScrollView(
        child: Column(
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
            // 四角显示：配置阅读界面四个角显示的内容
            Row(
              children: [
                SizedBox(width: 64, child: Text('四角显示', style: labelStyle)),
                Expanded(
                  child: Text(
                    '${cornerOptionLabels[settings.cornerTopLeft]} · '
                    '${cornerOptionLabels[settings.cornerTopRight]} · '
                    '${cornerOptionLabels[settings.cornerBottomLeft]} · '
                    '${cornerOptionLabels[settings.cornerBottomRight]}',
                    style: TextStyle(fontSize: 12, color: spec.secondary),
                  ),
                ),
                TextButton(
                  onPressed: () => _showCornerConfig(settings),
                  child: const Text('设置'),
                ),
              ],
            ),
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
        ),
      ),
    );
  }
}

/// 菜单底部选项栏的单个选项（图标 + 文字，active 高亮）
class _MenuOption extends StatelessWidget {
  const _MenuOption({
    required this.icon,
    required this.label,
    required this.active,
    required this.spec,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final ReaderThemeSpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? spec.accent : spec.secondary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: active ? spec.accent : spec.foreground,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
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

/// 菜单面板：目录 / 阅读主题 / 翻页动画 / 排版
enum _MenuTab { toc, theme, anim, typography }

/// 图片查看器：全屏黑底 + 缩放拖动 + 保存
class _ImageViewerDialog extends StatelessWidget {
  const _ImageViewerDialog({required this.bytes});

  final List<int> bytes;

  @override
  Widget build(BuildContext context) {
    final data = Uint8List.fromList(bytes);
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          // 大图：双指/滚轮缩放，拖动平移
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 8,
              child: Center(child: Image.memory(data, fit: BoxFit.contain)),
            ),
          ),
          // 顶部操作条
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '保存图片',
                    icon: const Icon(Icons.save_alt, color: Colors.white),
                    onPressed: () => _saveImage(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveImage(BuildContext context) async {
    final ext = _guessExtension(bytes);
    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        fileName: 'image_${DateTime.now().millisecondsSinceEpoch}.$ext',
        type: FileType.image,
      );
    } catch (_) {}
    if (path == null || path.isEmpty) return;
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      if (context.mounted) {
        showAppSnackBar(context, '已保存到 $path');
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(context, '保存失败：$e');
      }
    }
  }

  /// 按魔数猜扩展名（默认 png）
  String _guessExtension(List<int> b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
    if (b.length >= 4 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return 'gif';
    }
    if (b.length >= 4 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46) {
      return 'webp';
    }
    return 'png';
  }
}

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
  bool _chromeVisible = true; // 点按切换顶栏/底栏
  bool _tocOpen = false;

  /// 文档大纲展平后的条目（标题, 目标页码, 层级）
  List<(String, int, int)>? _tocEntries;

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

  // ---- PDF 目录（文档自带大纲） ----

  void _flattenOutline(
    List<PdfOutlineNode> nodes,
    int depth,
    List<(String, int, int)> out,
  ) {
    for (final n in nodes) {
      out.add((n.title, n.dest?.pageNumber ?? -1, depth));
      _flattenOutline(n.children, depth + 1, out);
    }
  }

  Future<void> _toggleToc() async {
    if (_tocOpen) {
      setState(() => _tocOpen = false);
      return;
    }
    if (_tocEntries == null) {
      try {
        final flat = <(String, int, int)>[];
        await _viewerCtl.useDocument((doc) async {
          _flattenOutline(await doc.loadOutline(), 0, flat);
        });
        _tocEntries = flat;
      } catch (_) {
        _tocEntries = const [];
      }
    }
    if (!mounted) return;
    setState(() => _tocOpen = true);
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
                // 点按切换工具条显隐；translucent 保证缩放/链接手势不受影响
                viewerOverlayBuilder: (context, size, handleLinkTap) => [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (d) => handleLinkTap(d.localPosition),
                      onTap: () {
                        if (_tocOpen) {
                          setState(() => _tocOpen = false);
                          return;
                        }
                        setState(() => _chromeVisible = !_chromeVisible);
                      },
                      child: const IgnorePointer(),
                    ),
                  ),
                ],
              ),
            ),
            // 顶栏
            if (_chromeVisible)
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
                      // 文档自带目录
                      IconButton(
                        tooltip: '目录',
                        icon: Icon(Icons.menu_book_outlined, color: fg),
                        onPressed: _toggleToc,
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
            if (_chromeVisible)
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
            // 目录面板（文档自带大纲）
            if (_tocOpen)
              Positioned(
                top: 60,
                right: 8,
                bottom: 60,
                width: 300,
                child: Material(
                  color: spec.background,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: _tocEntries == null
                      ? const Center(child: CircularProgressIndicator())
                      : _tocEntries!.isEmpty
                      ? Center(
                          child: Text(
                            '该文档没有目录',
                            style: TextStyle(fontSize: 13, color: secondary),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: _tocEntries!.length,
                          itemBuilder: (context, i) {
                            final (title, page, depth) = _tocEntries![i];
                            final active = page == _page;
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: EdgeInsets.only(
                                left: 12 + depth * 16.0,
                                right: 12,
                              ),
                              title: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: active ? spec.accent : fg,
                                  fontWeight: active
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                              onTap: () {
                                if (page < 1) return;
                                _jumpToPage(page);
                                setState(() => _tocOpen = false);
                              },
                            );
                          },
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}
