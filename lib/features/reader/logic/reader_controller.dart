import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Locator;

import '../../../core/storage/app_database.dart';
import '../../../core/theme/reader_theme.dart';
import '../../../engine/ir/book_document.dart';
import '../../../engine/pagination/text_paginator.dart';
import '../../../engine/parsers/book_parser.dart';
import '../../library/data/book_repository.dart';
import 'reader_settings.dart';

/// 阅读页状态
class ReaderState {
  const ReaderState({
    this.book,
    this.document,
    this.spineIndex = 0,
    this.pageIndex = 0,
    this.pageCount = 0,
    this.loading = false,
    this.error,
    this.percent = 0,
  });

  final Book? book;
  final BookDocument? document;
  final int spineIndex;
  final int pageIndex;

  /// 当前章总页数
  final int pageCount;
  final bool loading;
  final String? error;

  /// 全书进度 0-1
  final double percent;

  ReaderState copyWith({
    Book? book,
    BookDocument? document,
    int? spineIndex,
    int? pageIndex,
    int? pageCount,
    bool? loading,
    String? error,
    bool clearError = false,
    double? percent,
  }) {
    return ReaderState(
      book: book ?? this.book,
      document: document ?? this.document,
      spineIndex: spineIndex ?? this.spineIndex,
      pageIndex: pageIndex ?? this.pageIndex,
      pageCount: pageCount ?? this.pageCount,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      percent: percent ?? this.percent,
    );
  }

  Chapter? get currentChapter {
    final doc = document;
    if (doc == null || spineIndex >= doc.spine.length) return null;
    return doc.spine[spineIndex];
  }
}

/// 阅读会话控制器：一个活动书籍。
/// 分页缓存按章 LRU（保留当前 ±2 章），排版参数变更时整库失效并保位重排。
class ReaderController extends Notifier<ReaderState> {
  static const _maxCachedChapters = 5;

  final Map<int, LaidOutChapter> _lru = {};
  final Map<String, double> _imageAspects = {};

  /// 排版代数：排版参数变更后递增；缓存章带代数标记，代数不符的重排。
  /// 旧一代缓存保留显示（字号调整瞬间不白屏），新布局就绪后原位替换。
  int _layoutGen = 0;
  final Map<int, int> _lruGen = {};

  /// 排版重排防抖：字号/行距等连续调整（滑块拖动、A+/A- 连点）时
  /// 只在停顿后重排一次，避免每次变更都全章重新测量导致掉帧。
  Timer? _repagDebounce;

  /// 阅读区尺寸（页面 Widget 布局后注入）
  Size _viewport = const Size(400, 700);

  /// 有效边距（设置边距与系统安全区取大后注入）：
  /// 分页（_buildConfig）与绘制（PageCanvas）共用，保证测/绘边界一致
  EdgeInsets effectiveMargins = const EdgeInsets.fromLTRB(16, 24, 16, 24);

  /// 当前主题（测量时烘焙颜色；主题切换触发重排）
  ReaderThemeSpec? _activeSpec;
  Timer? _saveDebounce;

  /// 阅读会话代号：open/close 时递增。
  /// 所有跨 await 的状态写入前必须校验会话未变，防止换书竞态
  /// （慢解析的旧书异步回调覆盖新书的 state）。
  int _session = 0;

  // ---- 阅读时长统计 ----
  /// 本次计时起点；每 30 秒心跳落库一次（应用被杀最多丢 30 秒）
  DateTime? _readingStart;
  Timer? _readingTimer;

  @override
  ReaderState build() {
    ref.listen(readerSettingsProvider, (prev, next) {
      if (prev == null) return;
      if (prev == next) return;
      _onSettingsChanged(prev, next);
    });
    ref.onDispose(() {
      _saveDebounce?.cancel();
      _repagDebounce?.cancel();
      _readingTimer?.cancel();
      _flushReadingTime();
      _saveProgressNow();
    });
    return const ReaderState();
  }

  BookRepository get _repo => ref.read(bookRepositoryProvider);

  // ---- 打开 / 关闭 ----

  Future<void> open(String bookId, {Size? viewport}) async {
    if (viewport != null) _viewport = viewport;
    final session = ++_session;

    // 换书前把上一本书的进度与阅读时长落盘（快照先取，避免状态被重置后丢失）
    final prevBook = state.book;
    final prevLocator = currentLocator;
    final prevPercent = state.percent;
    if (prevBook != null && prevLocator != null) {
      try {
        await _repo.saveProgress(prevBook.id, prevLocator, prevPercent);
      } catch (_) {}
    }
    if (prevBook != null) await _flushReadingTime(bookId: prevBook.id);
    if (session != _session) return;

    _lru.clear();
    _lruGen.clear();
    _imageAspects.clear();
    state = const ReaderState(loading: true);

    try {
      final book = await _repo.getBook(bookId);
      if (session != _session) return;
      if (book == null) {
        state = state.copyWith(loading: false, error: '书籍不存在（可能已被删除）');
        return;
      }
      final output = await const BookParser().parseFile(book.filePath);
      if (session != _session) return;
      state = state.copyWith(
        book: book,
        document: output.document,
        loading: false,
        clearError: true,
      );
      // 开始计时：心跳每 30 秒把增量写入阅读时长表
      _readingStart = DateTime.now();
      _readingTimer?.cancel();
      _readingTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _flushReadingTime(),
      );
      // 恢复进度
      final saved = await _repo.getProgress(bookId);
      if (session != _session) return;
      if (saved != null && saved.spineIndex < output.document.spine.length) {
        await _gotoChapter(
          saved.spineIndex,
          charOffset: saved.charOffset.clamp(0, 1 << 30),
        );
      } else {
        await _gotoChapter(0);
      }
    } on BookParseException catch (e) {
      if (session != _session) return;
      state = state.copyWith(loading: false, error: e.message);
    } catch (e) {
      if (session != _session) return;
      state = state.copyWith(loading: false, error: '打开失败：$e');
    }
  }

  /// 关闭阅读器（回书架前保存进度与阅读时长）。
  /// 先同步清空状态再异步落盘：保证下一本书打开时绝看不到上一本的内容。
  Future<void> close() async {
    _session++;
    final book = state.book;
    final locator = currentLocator;
    final percent = state.percent;
    _saveDebounce?.cancel();
    _repagDebounce?.cancel();
    _readingTimer?.cancel();
    _readingTimer = null;
    await _flushReadingTime(bookId: book?.id, keepClock: false);
    _readingStart = null;
    _lru.clear();
    _lruGen.clear();
    state = const ReaderState();
    if (book != null && locator != null) {
      try {
        await _repo.saveProgress(book.id, locator, percent);
      } catch (_) {}
    }
  }

  // ---- 视口 ----

  void updateViewport(Size size, EdgeInsets margins) {
    final changed = size != _viewport || margins != effectiveMargins;
    if (!changed || size.width < 40 || size.height < 40) return;
    _viewport = size;
    effectiveMargins = margins;
    // 视口变化等同排版变更：走防抖重排，旧布局保留显示避免闪烁
    _scheduleRepaginate();
  }

  // ---- 定位 ----

  int? get currentCharOffset {
    final laid = _lru[state.spineIndex];
    if (laid == null || state.pageIndex >= laid.pages.length) return null;
    return laid.pages[state.pageIndex].startChar;
  }

  /// 当前页的 Locator
  Locator? get currentLocator {
    final doc = state.document;
    if (doc == null) return null;
    final offset = currentCharOffset;
    if (offset == null) return null;
    return Locator(
      spineIndex: state.spineIndex,
      charOffset: offset,
      chapterLength: doc.spine[state.spineIndex].charLength,
    );
  }

  Future<void> _gotoChapter(int index, {int charOffset = 0}) async {
    final doc = state.document;
    if (doc == null || index < 0 || index >= doc.spine.length) return;
    final session = _session;
    final laid = await _getLaidChapter(index);
    if (session != _session || laid == null) return;
    final page = laid.pageIndexForChar(charOffset);
    state = state.copyWith(
      spineIndex: index,
      pageIndex: page.clamp(0, laid.pages.length - 1),
      pageCount: laid.pages.length,
    );
    _updatePercent();
    _scheduleSaveProgress();
    _evictLru();
  }

  Future<void> jumpToChapter(int index, {int charOffset = 0}) =>
      _gotoChapter(index, charOffset: charOffset);

  /// 精确跳转到章内字符偏移
  Future<void> jumpToChar(int spineIndex, int charOffset) =>
      _gotoChapter(spineIndex, charOffset: charOffset);

  // ---- 翻页 ----

  /// 返回是否发生了翻页（ false 表示已到边界）
  Future<bool> nextPage() async {
    final laid = _lru[state.spineIndex];
    if (laid == null) return false;
    if (state.pageIndex + 1 < laid.pages.length) {
      state = state.copyWith(pageIndex: state.pageIndex + 1);
      _afterPageTurn();
      return true;
    }
    // 章尾 → 下一章
    final doc = state.document;
    if (doc != null && state.spineIndex + 1 < doc.spine.length) {
      await _gotoChapter(state.spineIndex + 1);
      return true;
    }
    return false;
  }

  Future<bool> prevPage() async {
    if (state.pageIndex > 0) {
      state = state.copyWith(pageIndex: state.pageIndex - 1);
      _afterPageTurn();
      return true;
    }
    // 章首 → 上一章末页
    if (state.spineIndex > 0) {
      final laid = await _getLaidChapter(state.spineIndex - 1);
      if (laid != null) {
        state = state.copyWith(
          spineIndex: state.spineIndex - 1,
          pageIndex: laid.pages.length - 1,
          pageCount: laid.pages.length,
        );
        _updatePercent();
        _scheduleSaveProgress();
        _evictLru();
        return true;
      }
    }
    return false;
  }

  void _afterPageTurn() {
    _updatePercent();
    _scheduleSaveProgress();
    _evictLru();
    _prefetchNeighborChapters();
  }

  void _updatePercent() {
    final doc = state.document;
    if (doc == null || doc.totalChars == 0) return;
    final laid = _lru[state.spineIndex];
    var char = 0;
    if (laid != null && state.pageIndex < laid.pages.length) {
      char = laid.pages[state.pageIndex].startChar;
    }
    final global = doc.globalCharsBefore(state.spineIndex) + char;
    state = state.copyWith(percent: (global / doc.totalChars).clamp(0.0, 1.0));
  }

  // ---- 分页 ----

  Future<LaidOutChapter?> _getLaidChapter(int index) async {
    final cached = _lru[index];
    if (cached != null && _lruGen[index] == _layoutGen) return cached;
    final doc = state.document;
    if (doc == null || index >= doc.spine.length) return null;

    final cfg = _buildConfig();
    final styles = _buildStyles(cfg);
    await _loadImageAspects(doc, index);
    final paginator = const TextPaginator();
    final laid = await paginator.paginate(
      chapter: doc.spine[index],
      spineIndex: index,
      styles: styles,
      imageAspects: _imageAspects,
    );
    _lru[index] = laid;
    _lruGen[index] = _layoutGen;
    return laid;
  }

  LayoutConfig _buildConfig() {
    final s = ref.read(readerSettingsProvider);
    return LayoutConfig(
      fontSize: s.fontSize,
      lineHeight: s.lineHeight,
      letterSpacing: s.letterSpacing,
      paragraphSpacing: s.paragraphSpacing,
      contentWidth: _viewport.width - effectiveMargins.horizontal,
      contentHeight: _viewport.height - effectiveMargins.vertical,
      indentChars: s.indentChars,
      justify: s.justify,
      fontFamily: s.fontFamily,
    );
  }

  LayoutStyleSet _buildStyles(LayoutConfig cfg) {
    final spec = _activeSpec;
    return LayoutStyleSet(
      config: cfg,
      foreground: spec?.foreground ?? const ui.Color(0xFF1F2328),
      secondary: spec?.secondary ?? const ui.Color(0xFF6E7781),
      accent: spec?.accent ?? const ui.Color(0xFF2F6FED),
    );
  }

  /// 主题切换（由阅读页注入）。颜色变化需要重排（颜色烘焙在 TextPainter 中）。
  Future<void> updateTheme(ReaderThemeSpec spec) async {
    final prev = _activeSpec;
    _activeSpec = spec;
    if (prev != null &&
        (prev.foreground != spec.foreground ||
            prev.accent != spec.accent ||
            prev.secondary != spec.secondary)) {
      _scheduleRepaginate();
    }
  }

  Future<void> _loadImageAspects(BookDocument doc, int spineIndex) async {
    for (final block in doc.spine[spineIndex].blocks) {
      if (block.type != BlockType.image) continue;
      final src = block.imageSrc;
      if (src == null || _imageAspects.containsKey(src)) continue;
      try {
        final data = await doc.resources.get(src);
        if (data == null || data.isEmpty) {
          _imageAspects[src] = 0.72;
          continue;
        }
        final codec = await ui.instantiateImageCodec(
          Uint8List.fromList(data),
          targetWidth: 24,
        );
        final frame = await codec.getNextFrame();
        _imageAspects[src] = frame.image.width / frame.image.height;
        frame.image.dispose();
        codec.dispose();
      } catch (_) {
        _imageAspects[src] = 0.72;
      }
    }
  }

  void _evictLru() {
    while (_lru.length > _maxCachedChapters) {
      // 淘汰距当前章最远的缓存
      final keys = _lru.keys.toList()
        ..sort(
          (a, b) => (a - state.spineIndex).abs().compareTo(
            (b - state.spineIndex).abs(),
          ),
        );
      _lru.remove(keys.last);
      _lruGen.remove(keys.last);
    }
  }

  void _prefetchNeighborChapters() {
    final doc = state.document;
    if (doc == null) return;
    for (final idx in [state.spineIndex + 1, state.spineIndex - 1]) {
      if (idx >= 0 && idx < doc.spine.length && !_lru.containsKey(idx)) {
        _getLaidChapter(idx);
        break; // 每次只预取一章，避免抖动
      }
    }
  }

  // ---- 排版变更 ----

  void _onSettingsChanged(ReaderSettings prev, ReaderSettings next) {
    final affectsLayout =
        prev.fontSize != next.fontSize ||
        prev.lineHeight != next.lineHeight ||
        prev.letterSpacing != next.letterSpacing ||
        prev.paragraphSpacing != next.paragraphSpacing ||
        prev.marginTop != next.marginTop ||
        prev.marginBottom != next.marginBottom ||
        prev.marginLeft != next.marginLeft ||
        prev.marginRight != next.marginRight ||
        prev.indentChars != next.indentChars ||
        prev.justify != next.justify ||
        prev.fontFamily != next.fontFamily ||
        prev.contentWidthScale != next.contentWidthScale;
    if (!affectsLayout) return;
    // 防抖：连续调整（滑块拖动/A±连点）只在停顿 200ms 后重排一次，
    // 期间旧布局继续显示（无白屏），保证调整过程不掉帧
    _scheduleRepaginate();
  }

  /// 防抖触发保位重排：递增排版代数使旧缓存失效，但保留旧布局供显示
  void _scheduleRepaginate() {
    _repagDebounce?.cancel();
    _repagDebounce = Timer(const Duration(milliseconds: 200), () {
      if (state.document == null) return;
      _layoutGen++;
      final offset = currentCharOffset ?? 0;
      _repaginateCurrent(restoreChar: offset);
    });
  }

  Future<void> _repaginateCurrent({required int restoreChar}) async {
    final spineIndex = state.spineIndex;
    final laid = await _getLaidChapter(spineIndex);
    if (laid == null) return;
    state = state.copyWith(
      pageIndex: laid
          .pageIndexForChar(restoreChar)
          .clamp(0, laid.pages.length - 1),
      pageCount: laid.pages.length,
    );
    _updatePercent();
    _scheduleSaveProgress();
    _prefetchNeighborChapters();
  }

  // ---- 进度保存 ----

  void _scheduleSaveProgress() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _saveProgressNow);
  }

  Future<void> _saveProgressNow() async {
    final book = state.book;
    final locator = currentLocator;
    if (book == null || locator == null) return;
    try {
      await _repo.saveProgress(book.id, locator, state.percent);
    } catch (_) {
      // 进度保存失败不阻塞阅读
    }
  }

  // ---- 阅读时长 ----

  /// 结算自上次心跳以来的阅读时长写入统计表。
  /// [bookId] 缺省取当前书；[keepClock] 为 false 时结算后不重置起点（退出场景）。
  Future<void> _flushReadingTime({String? bookId, bool keepClock = true}) async {
    final start = _readingStart;
    if (start == null) return;
    final id = bookId ?? state.book?.id;
    if (id == null) return;
    if (keepClock) _readingStart = DateTime.now();
    // 单次结算上限 5 分钟：防止休眠唤醒后一次性计入过长时长
    final secs = DateTime.now().difference(start).inSeconds.clamp(0, 300);
    if (secs <= 0) return;
    try {
      await _repo.addReadingTime(id, secs);
    } catch (_) {
      // 统计失败不影响阅读
    }
  }

  /// 章内字符总长（目录显示用）
  int chapterLength(int index) {
    final doc = state.document;
    if (doc == null || index >= doc.spine.length) return 0;
    return doc.spine[index].charLength;
  }

  /// 渲染层取当前章的排版结果（LRU 缓存命中与否）
  LaidOutChapter? laidChapter(int spineIndex) => _lru[spineIndex];
}

final readerControllerProvider =
    NotifierProvider<ReaderController, ReaderState>(ReaderController.new);
