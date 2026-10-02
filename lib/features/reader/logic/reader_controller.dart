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

  /// 阅读区尺寸（页面 Widget 布局后注入）
  Size _viewport = const Size(400, 700);

  /// 当前主题（测量时烘焙颜色；主题切换触发重排）
  ReaderThemeSpec? _activeSpec;
  Timer? _saveDebounce;

  /// 阅读会话代号：open/close 时递增。
  /// 所有跨 await 的状态写入前必须校验会话未变，防止换书竞态
  /// （慢解析的旧书异步回调覆盖新书的 state）。
  int _session = 0;

  @override
  ReaderState build() {
    ref.listen(readerSettingsProvider, (prev, next) {
      if (prev == null) return;
      if (prev == next) return;
      _onSettingsChanged(prev, next);
    });
    ref.onDispose(() {
      _saveDebounce?.cancel();
      _saveProgressNow();
    });
    return const ReaderState();
  }

  BookRepository get _repo => ref.read(bookRepositoryProvider);

  // ---- 打开 / 关闭 ----

  Future<void> open(String bookId, {Size? viewport}) async {
    if (viewport != null) _viewport = viewport;
    final session = ++_session;

    // 换书前把上一本书的进度落盘（快照先取，避免状态被重置后丢失）
    final prevBook = state.book;
    final prevLocator = currentLocator;
    final prevPercent = state.percent;
    if (prevBook != null && prevLocator != null) {
      try {
        await _repo.saveProgress(prevBook.id, prevLocator, prevPercent);
      } catch (_) {}
    }
    if (session != _session) return;

    _lru.clear();
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

  /// 关闭阅读器（回书架前保存进度）。
  /// 先同步清空状态再异步落盘：保证下一本书打开时绝看不到上一本的内容。
  Future<void> close() async {
    _session++;
    final book = state.book;
    final locator = currentLocator;
    final percent = state.percent;
    _saveDebounce?.cancel();
    _lru.clear();
    state = const ReaderState();
    if (book != null && locator != null) {
      try {
        await _repo.saveProgress(book.id, locator, percent);
      } catch (_) {}
    }
  }

  // ---- 视口 ----

  void updateViewport(Size size) {
    if (size == _viewport || size.width < 40 || size.height < 40) return;
    final offset = currentCharOffset;
    _viewport = size;
    _lru.clear();
    if (state.document != null) {
      _repaginateCurrent(restoreChar: offset ?? 0);
    }
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
    if (_lru.containsKey(index)) return _lru[index];
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
    return laid;
  }

  LayoutConfig _buildConfig() {
    final s = ref.read(readerSettingsProvider);
    return LayoutConfig(
      fontSize: s.fontSize,
      lineHeight: s.lineHeight,
      letterSpacing: s.letterSpacing,
      paragraphSpacing: s.paragraphSpacing,
      contentWidth: _viewport.width - s.margins.horizontal,
      contentHeight: _viewport.height - s.margins.vertical,
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
      final offset = currentCharOffset ?? 0;
      _lru.clear();
      if (state.document != null) {
        await _repaginateCurrent(restoreChar: offset);
      }
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
    final offset = currentCharOffset ?? 0;
    _lru.clear();
    if (state.document != null) {
      _repaginateCurrent(restoreChar: offset);
    }
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
