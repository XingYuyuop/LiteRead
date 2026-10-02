import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme_controller.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/theme/reader_theme.dart';
import '../data/book_repository.dart';

/// 书架视图偏好（排序 / 网格切换），持久化到 settings_kv
class BookshelfPrefs {
  const BookshelfPrefs({this.sort = BookSort.lastRead, this.grid = true});

  final BookSort sort;
  final bool grid;

  BookshelfPrefs copyWith({BookSort? sort, bool? grid}) =>
      BookshelfPrefs(sort: sort ?? this.sort, grid: grid ?? this.grid);

  Map<String, dynamic> toJson() => {'sort': sort.index, 'grid': grid};

  static BookshelfPrefs fromJson(Map<String, dynamic> j) => BookshelfPrefs(
    sort: BookSort.values[j['sort'] as int? ?? 0],
    grid: j['grid'] as bool? ?? true,
  );
}

class BookshelfPrefsController extends Notifier<BookshelfPrefs> {
  static const _key = 'bookshelf.view';

  @override
  BookshelfPrefs build() {
    _load();
    return const BookshelfPrefs();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final raw = await db.getSetting(_key);
    if (raw != null) {
      state = BookshelfPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
  }

  Future<void> update(BookshelfPrefs Function(BookshelfPrefs) fn) async {
    state = fn(state);
    final db = ref.read(appDatabaseProvider);
    await db.setSetting(_key, jsonEncode(state.toJson()));
  }
}

final bookshelfPrefsProvider =
    NotifierProvider<BookshelfPrefsController, BookshelfPrefs>(
      BookshelfPrefsController.new,
    );

/// 支持拖入/选择的书籍扩展名
const _supportedExtensions = [
  'epub',
  'pdf',
  'mobi',
  'azw3',
  'prc',
  'azw',
  'kf8',
  'md',
  'markdown',
  'txt',
];

/// 书架页（计划书 FR-A01/02/04/06）
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  String _keyword = '';
  bool _importing = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeControllerProvider);
    final spec = themeState.resolve(
      MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    );
    final prefs = ref.watch(bookshelfPrefsProvider);
    final repo = ref.watch(bookRepositoryProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text(
          '轻阅',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 2),
        ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => _showSearch(context),
          ),
          PopupMenuButton<BookSort>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            onSelected: (s) => ref
                .read(bookshelfPrefsProvider.notifier)
                .update((p) => p.copyWith(sort: s)),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: BookSort.lastRead,
                child: Text('最近阅读'),
              ),
              const PopupMenuItem(value: BookSort.addedAt, child: Text('添加时间')),
              const PopupMenuItem(value: BookSort.title, child: Text('书名')),
            ],
          ),
          IconButton(
            tooltip: '视图',
            icon: Icon(prefs.grid ? Icons.view_list : Icons.grid_view),
            onPressed: () => ref
                .read(bookshelfPrefsProvider.notifier)
                .update((p) => p.copyWith(grid: !p.grid)),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: DropTarget(
        // 桌面端拖拽导入（FR-A03）
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          final paths = details.files
              .map((f) => f.path)
              .where(
                (p) => _supportedExtensions.contains(
                  p.toLowerCase().split('.').last,
                ),
              )
              .toList();
          if (paths.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('暂不支持该文件格式')),
            );
            return;
          }
          _importPaths(paths);
        },
        child: Stack(
          children: [
            StreamBuilder<List<Book>>(
              stream: repo.watchBooks(sort: prefs.sort),
              builder: (context, snap) {
                var books = snap.data ?? const <Book>[];
                if (_keyword.isNotEmpty) {
                  final k = _keyword.toLowerCase();
                  books = books
                      .where(
                        (b) =>
                            b.title.toLowerCase().contains(k) ||
                            (b.author ?? '').toLowerCase().contains(k),
                      )
                      .toList();
                }
                if (books.isEmpty) {
                  return _EmptyState(importing: _importing);
                }
                return RefreshIndicator(
                  onRefresh: () async {},
                  child: prefs.grid
                      ? GridView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 140,
                                mainAxisSpacing: 24,
                                crossAxisSpacing: 20,
                                childAspectRatio: 0.58,
                              ),
                          itemCount: books.length,
                          itemBuilder: (context, i) =>
                              _BookCard(book: books[i], spec: spec),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                          itemCount: books.length,
                          itemBuilder: (context, i) =>
                              _BookTile(book: books[i], spec: spec),
                        ),
                );
              },
            ),
            // 拖拽悬停提示层
            if (_dragging) _DropOverlay(spec: spec),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'import',
        onPressed: _importing ? null : _importBooks,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_importing ? '导入中…' : '导入书籍'),
      ),
    );
  }

  Future<void> _importBooks() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _supportedExtensions,
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    await _importPaths(result.files.map((f) => f.path!).toList());
  }

  Future<void> _importPaths(List<String> paths) async {
    if (paths.isEmpty || _importing) return;
    setState(() => _importing = true);
    try {
      final repo = ref.read(bookRepositoryProvider);
      var imported = 0;
      var failed = 0;
      var duplicated = 0;
      String? lastError;
      for (final path in paths) {
        try {
          final outcome = await repo.importFile(path);
          if (outcome.duplicated) {
            duplicated++;
          } else {
            imported++;
          }
        } catch (e) {
          failed++;
          lastError = e.toString();
        }
      }
      if (mounted) {
        final msg = failed > 0
            ? '导入 $imported 本，失败 $failed 本：${lastError ?? ''}'
            : duplicated > 0
            ? '导入 $imported 本（$duplicated 本已存在）'
            : '导入 $imported 本';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _showSearch(BuildContext context) async {
    final keyword = await showDialog<String>(
      context: context,
      builder: (context) {
        final ctl = TextEditingController(text: _keyword);
        return AlertDialog(
          title: const Text('搜索书库'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '书名 / 作者 / 格式'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('清除'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text),
              child: const Text('搜索'),
            ),
          ],
        );
      },
    );
    if (keyword != null) setState(() => _keyword = keyword.trim());
  }
}

/// 拖拽悬停提示层
class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.spec});

  final ReaderThemeSpec spec;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: spec.background.withValues(alpha: 0.85),
        padding: const EdgeInsets.all(20),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: spec.accent, width: 2),
            color: spec.accent.withValues(alpha: 0.06),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.library_add, size: 48, color: spec.accent),
              const SizedBox(height: 12),
              Text(
                '松开导入书籍',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: spec.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '支持 EPUB / PDF / MOBI / AZW3 / Markdown / TXT',
                style: TextStyle(fontSize: 12, color: spec.secondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.importing});

  final bool importing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primary.withValues(alpha: 0.08),
            ),
            child: Icon(
              Icons.auto_stories,
              size: 56,
              color: cs.primary.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            importing ? '正在导入…' : '书架空空如也',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '支持 EPUB / PDF / MOBI / AZW3 / Markdown / TXT\n点击右下角导入，或将文件拖入窗口',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }
}

/// 封面视图：有封面文件用图片，否则生成占位封面
class CoverView extends StatelessWidget {
  const CoverView({super.key, required this.book, required this.spec});

  final Book book;
  final ReaderThemeSpec spec;

  @override
  Widget build(BuildContext context) {
    final coverPath = book.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(coverPath),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    final gradients = [
      [const Color(0xFF5B7FB9), const Color(0xFF3D5A8F)],
      [const Color(0xFFB98A5B), const Color(0xFF8F6B3D)],
      [const Color(0xFF6BAF8A), const Color(0xFF3D8F6B)],
      [const Color(0xFF9B7BB9), const Color(0xFF6B4D8F)],
      [const Color(0xFFB97B7B), const Color(0xFF8F4D4D)],
    ];
    final g = gradients[book.title.hashCode.abs() % gradients.length];
    final ch = book.title.isEmpty ? '书' : book.title.characters.first;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g,
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            ch,
            style: const TextStyle(
              fontSize: 32,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookCard extends ConsumerWidget {
  const _BookCard({required this.book, required this.spec});

  final Book book;
  final ReaderThemeSpec spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => context.push('/reader/${book.id}'),
      onLongPress: () => showBookActions(context, ref, book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: cs.shadow.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: CoverView(book: book, spec: spec),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _BookTile extends ConsumerWidget {
  const _BookTile({required this.book, required this.spec});

  final Book book;
  final ReaderThemeSpec spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: SizedBox(
          width: 44,
          height: 60,
          child: CoverView(book: book, spec: spec),
        ),
        title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${book.author ?? '佚名'} · ${book.format}',
          maxLines: 1,
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: () => showBookActions(context, ref, book),
        ),
        onTap: () => context.push('/reader/${book.id}'),
      ),
    );
  }
}

/// 书籍操作菜单（长按封面 / 列表右侧按钮）
void showBookActions(BuildContext context, WidgetRef ref, Book book) {
  showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('书籍详情'),
            onTap: () {
              Navigator.pop(context);
              showBookDetails(context, ref, book);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('删除书籍'),
            onTap: () async {
              Navigator.pop(context);
              final repo = ref.read(bookRepositoryProvider);
              await repo.deleteBook(book.id, deleteManagedFile: true);
            },
          ),
        ],
      ),
    ),
  );
}

/// 书籍详情弹窗：元数据 + 阅读进度
Future<void> showBookDetails(
  BuildContext context,
  WidgetRef ref,
  Book book,
) async {
  final repo = ref.read(bookRepositoryProvider);
  final percent = await repo.getPercent(book.id);
  Map<String, dynamic> meta = const {};
  try {
    if (book.metaJson != null) {
      meta = jsonDecode(book.metaJson!) as Map<String, dynamic>;
    }
  } catch (_) {}

  if (!context.mounted) return;

  Widget row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    ),
  );

  final chapters = meta['chapterCount'];
  final chars = meta['charCount'];
  final pages = meta['pageCount'];
  final added = DateTime.fromMillisecondsSinceEpoch(book.addedAt);

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(book.title, style: const TextStyle(fontSize: 18)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('作者', book.author ?? '佚名'),
          row('格式', book.format),
          if (book.fileSize != null) row('大小', formatBytes(book.fileSize!)),
          if (pages != null)
            row('页数', '$pages 页')
          else if (chapters != null)
            row('章节', '$chapters 章'),
          if (chars != null && (chars as int) > 0) row('字数', '$chars 字'),
          row(
            '进度',
            percent == null ? '未开始' : '${(percent * 100).toStringAsFixed(1)}%',
          ),
          row(
            '导入时间',
            '${added.year}-${added.month.toString().padLeft(2, '0')}-${added.day.toString().padLeft(2, '0')}',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            context.push('/reader/${book.id}');
          },
          child: const Text('继续阅读'),
        ),
      ],
    ),
  );
}

/// 字节数人类可读化
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
