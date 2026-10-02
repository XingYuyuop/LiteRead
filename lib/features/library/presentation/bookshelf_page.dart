import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme_controller.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/theme/reader_theme.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../../core/update/app_updater.dart';
import '../../../core/update/update_service.dart';
import '../../../core/update/update_ui.dart';
import '../../backup/data/lan_sync.dart';
import '../../backup/logic/backup_config.dart';
import '../../settings/logic/app_prefs.dart';
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

/// 启动自动跳转上次阅读书籍的进程级防重（书架重建不重复触发）
bool _autoOpenTried = false;

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

  // ---- 导入进度（t2：逐本反馈，避免长批次无响应感） ----
  int _importDone = 0;
  int _importTotal = 0;
  String _importCurrent = '';

  // ---- 批量管理模式 ----
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  // ---- 分组筛选（null = 全部） ----
  String? _filterGroup;

  @override
  void initState() {
    super.initState();
    // 启动后按配置周期自动检查更新（有新版本才弹提示）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoUpdateCheck();
      _autoOpenLastBook();
      _requestStoragePermissionOnce();
    });
  }

  /// 设置开启时，启动后自动进入最近阅读的书籍（每次应用进程仅一次）
  Future<void> _autoOpenLastBook() async {
    if (_autoOpenTried) return;
    _autoOpenTried = true;
    try {
      final db = ref.read(appDatabaseProvider);
      if (!await loadAutoOpenLastBook(db)) return;
      final books = await ref.read(bookRepositoryProvider).listBooks();
      for (final b in books) {
        if (b.lastReadAt != null) {
          // 稍等书架首帧渲染完成再跳转，避免白屏观感
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!mounted) return;
          context.push('/reader/${b.id}');
          return;
        }
      }
    } catch (_) {
      // 自动跳转失败静默，不打扰使用
    }
  }

  /// Android 首次启动请求本地存储权限（读取插图/封面等场景）
  Future<void> _requestStoragePermissionOnce() async {
    if (!Platform.isAndroid) return;
    try {
      final db = ref.read(appDatabaseProvider);
      if (await db.getSetting('perm.storageAsked') != null) return;
      await db.setSetting('perm.storageAsked', 'true');
      await requestStoragePermission();
    } catch (_) {
      // 权限流程失败不影响启动
    }
  }

  Future<void> _autoUpdateCheck() async {
    try {
      final svc = UpdateService(ref.read(appDatabaseProvider));
      final info = await svc.maybeAutoCheck();
      if (info != null && info.isNewer && mounted) {
        await showUpdateFoundDialog(context, info);
      }
    } catch (_) {
      // 更新检查失败静默
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeControllerProvider);
    final spec = themeState.resolve(
      MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    );
    final prefs = ref.watch(bookshelfPrefsProvider);
    final repo = ref.watch(bookRepositoryProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      // 批量模式下先退出批量模式
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) {
          setState(() {
            _selectionMode = false;
            _selectedIds.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: _selectionMode
            ? _buildSelectionAppBar()
            : AppBar(
                // 标题下方挂排序切换；顶栏操作区只留高频功能
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'LiteRead',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                        height: 1.15,
                      ),
                    ),
                    _SortSelector(
                      current: prefs.sort,
                      onSelected: (s) => ref
                          .read(bookshelfPrefsProvider.notifier)
                          .update((p) => p.copyWith(sort: s)),
                    ),
                  ],
                ),
                backgroundColor: Colors.transparent,
                actions: [
                  _appBarBtn(Icons.search, '搜索', () => _showSearch(context)),
                  _appBarBtn(
                    prefs.grid ? Icons.view_list : Icons.grid_view,
                    '视图',
                    () => ref
                        .read(bookshelfPrefsProvider.notifier)
                        .update((p) => p.copyWith(grid: !p.grid)),
                  ),
                  _appBarBtn(
                    Icons.query_stats,
                    '阅读统计',
                    () => context.push('/stats'),
                  ),
                  _appBarBtn(
                    Icons.wifi,
                    'WiFi 传书',
                    () => _showWifiTransfer(context),
                  ),
                  _appBarBtn(
                    Icons.settings_outlined,
                    '设置',
                    () => context.push('/settings'),
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
              showAppSnackBar(context, '暂不支持该文件格式');
              return;
            }
            _importPaths(paths);
          },
          child: Stack(
            children: [
              StreamBuilder<List<Book>>(
                stream: repo.watchBooks(sort: prefs.sort),
                builder: (context, snap) {
                  final all = snap.data ?? const <Book>[];
                  // 分组列表实时从书籍数据推导
                  final groups =
                      all
                          .map((b) => b.groupName)
                          .whereType<String>()
                          .where((g) => g.isNotEmpty)
                          .toSet()
                          .toList()
                        ..sort();
                  var books = all;
                  if (_filterGroup != null) {
                    books = books.where(_matchGroup).toList();
                  }
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
                  if (all.isEmpty) {
                    return _EmptyState(importing: _importing);
                  }
                  return Column(
                    children: [
                      // 分组筛选条（有分组时显示）
                      if (groups.isNotEmpty && !_selectionMode)
                        _buildGroupChips(groups, all),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: () async {},
                          child: prefs.grid
                              ? GridView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    6,
                                    12,
                                    96,
                                  ),
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: 104,
                                        mainAxisSpacing: 14,
                                        crossAxisSpacing: 12,
                                        childAspectRatio: 0.60,
                                      ),
                                  itemCount: books.length,
                                  itemBuilder: (context, i) => _BookCard(
                                    book: books[i],
                                    spec: spec,
                                    selectionMode: _selectionMode,
                                    selected: _selectedIds.contains(
                                      books[i].id,
                                    ),
                                    onTap: () => _onBookTap(
                                      books[i],
                                      selectionMode: _selectionMode,
                                    ),
                                    onLongPress: () =>
                                        _onBookLongPress(books[i]),
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    4,
                                    8,
                                    96,
                                  ),
                                  itemCount: books.length,
                                  itemBuilder: (context, i) => _BookTile(
                                    book: books[i],
                                    spec: spec,
                                    selectionMode: _selectionMode,
                                    selected: _selectedIds.contains(
                                      books[i].id,
                                    ),
                                    onTap: () => _onBookTap(
                                      books[i],
                                      selectionMode: _selectionMode,
                                    ),
                                    onLongPress: () =>
                                        _onBookLongPress(books[i]),
                                  ),
                                ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              // 导入进度条（顶部细线 + FAB 计数）
              if (_importing)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value: _importTotal > 0 ? _importDone / _importTotal : null,
                  ),
                ),
              // 拖拽悬停提示层
              if (_dragging) _DropOverlay(spec: spec),
            ],
          ),
        ),
        floatingActionButton: _selectionMode
            ? _buildSelectionActions()
            : FloatingActionButton.extended(
                heroTag: 'import',
                onPressed: _importing ? null : _importBooks,
                tooltip: _importing && _importCurrent.isNotEmpty
                    ? '正在导入：$_importCurrent'
                    : '导入书籍',
                icon: _importing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(
                  _importing ? '导入中 $_importDone/$_importTotal' : '导入书籍',
                ),
              ),
      ),
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final cs = Theme.of(context).colorScheme;
    final count = _selectedIds.length;
    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        icon: const Icon(Icons.close),
        onPressed: () => setState(() {
          _selectionMode = false;
          _selectedIds.clear();
        }),
      ),
      title: Text('已选 $count 本'),
      backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
    );
  }

  /// 批量管理右下角操作面板：全选 / 移动分组 / 删除 / 查看书籍信息（仅单选）
  Widget _buildSelectionActions() {
    final cs = Theme.of(context).colorScheme;
    final count = _selectedIds.length;
    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      Color? color,
    }) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(
            backgroundColor: cs.surfaceContainerHighest,
            foregroundColor: color ?? cs.onSurface,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        action(icon: Icons.select_all, label: '全选', onTap: _toggleSelectAll),
        action(
          icon: Icons.drive_file_move_outline,
          label: '分组',
          onTap: count == 0 ? null : _batchMoveToGroup,
        ),
        action(
          icon: Icons.delete_outline,
          label: '删除',
          color: cs.error,
          onTap: count == 0 ? null : _batchDelete,
        ),
        // 书籍信息仅在选择单本书时提供
        if (count == 1)
          action(
            icon: Icons.info_outline,
            label: '信息',
            onTap: () {
              final id = _selectedIds.single;
              ref.read(bookRepositoryProvider).getBook(id).then((b) {
                if (b == null || !mounted) return;
                showBookDetails(context, ref, b);
              });
            },
          ),
      ],
    );
  }

  Widget _buildGroupChips(List<String> groups, List<Book> all) {
    final counts = <String, int>{};
    for (final b in all) {
      final g = b.groupName;
      if (g != null && g.isNotEmpty) {
        counts[g] = (counts[g] ?? 0) + 1;
      }
    }
    Widget chip(String? label, String? value, int count) {
      final selected = _filterGroup == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text('$label $count'),
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          onSelected: (_) => setState(() => _filterGroup = value),
        ),
      );
    }

    final ungrouped = all
        .where((b) => b.groupName == null || b.groupName!.isEmpty)
        .length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip('全部', null, all.length),
            for (final g in groups) chip(g, g, counts[g] ?? 0),
            if (ungrouped > 0) chip('未分组', '', ungrouped),
          ],
        ),
      ),
    );
  }

  /// 分组过滤：_filterGroup 为 null = 全部；'' = 未分组（groupName 为 null 或空）；
  /// 其他 = 指定分组名。计数与列表过滤统一走这里，避免「未分组 x 个但列表为空」
  bool _matchGroup(Book b) {
    final g = _filterGroup;
    if (g == null) return true;
    if (g.isEmpty) return b.groupName == null || b.groupName!.isEmpty;
    return b.groupName == g;
  }

  void _onBookTap(Book book, {required bool selectionMode}) {
    if (selectionMode) {
      setState(() {
        if (_selectedIds.contains(book.id)) {
          _selectedIds.remove(book.id);
        } else {
          _selectedIds.add(book.id);
        }
      });
      return;
    }
    context.push('/reader/${book.id}');
  }

  void _onBookLongPress(Book book) {
    if (_selectionMode) {
      _onBookTap(book, selectionMode: true);
      return;
    }
    // 长按直接进入批量管理模式（默认选中该书）
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(book.id);
    });
  }

  void _toggleSelectAll() {
    // 全选当前筛选下可见的书
    final prefs = ref.read(bookshelfPrefsProvider);
    ref.read(bookRepositoryProvider).listBooks(sort: prefs.sort).then((all) {
      var filtered = all;
      if (_filterGroup != null) {
        filtered = filtered.where(_matchGroup).toList();
      }
      if (_keyword.isNotEmpty) {
        final k = _keyword.toLowerCase();
        filtered = filtered
            .where(
              (b) =>
                  b.title.toLowerCase().contains(k) ||
                  (b.author ?? '').toLowerCase().contains(k),
            )
            .toList();
      }
      final allSelected =
          filtered.isNotEmpty &&
          filtered.every((b) => _selectedIds.contains(b.id));
      if (!mounted) return;
      setState(() {
        if (allSelected) {
          _selectedIds.clear();
        } else {
          _selectedIds.addAll(filtered.map((b) => b.id));
        }
      });
    });
  }

  Future<void> _batchDelete() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定删除选中的 ${ids.length} 本书籍？\n书籍文件、阅读进度与批注将一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(bookRepositoryProvider).deleteBooks(ids);
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
    showAppSnackBar(context, '已删除 ${ids.length} 本书籍');
  }

  Future<void> _batchMoveToGroup() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final group = await _pickGroupDialog(initialGroup: null);
    if (group == null) return; // 取消
    await ref.read(bookRepositoryProvider).setGroups(ids, group);
    if (!mounted) return;
    showAppSnackBar(
      context,
      group.isEmpty ? '已移出分组（${ids.length} 本）' : '已移入「$group」（${ids.length} 本）',
    );
  }

  /// 分组选择对话框：返回 null = 取消；'' = 未分组；其他 = 分组名
  Future<String?> _pickGroupDialog({String? initialGroup}) async {
    final repo = ref.read(bookRepositoryProvider);
    final groups = await repo.listGroups();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (context) =>
          GroupPickerDialog(groups: groups, initialGroup: initialGroup ?? ''),
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

  /// 顶栏紧凑按钮：缩小图标与点击区域，保证标题「LiteRead」在窄屏完整显示
  Widget _appBarBtn(IconData icon, String tooltip, VoidCallback onTap) =>
      IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );

  /// WiFi 传书：确保局域网服务已开启，弹出访问网址卡片（图 4 风格）。
  /// 长按/点击网址即复制；「取消」关闭服务并不再随启动自开。
  Future<void> _showWifiTransfer(BuildContext context) async {
    final server = ref.read(lanSyncServerProvider);
    final db = ref.read(appDatabaseProvider);
    if (!server.running) {
      try {
        await server.start();
        await db.setSetting('backup.lanSharing', 'true');
      } catch (e) {
        if (!context.mounted) return;
        showAppSnackBar(context, '开启 WLAN 服务失败：$e');
        return;
      }
    }
    final ips = await localIPv4Addresses();
    final urls = [for (final ip in ips) 'http://$ip:${server.port}'];
    if (!context.mounted || urls.isEmpty) return;

    Future<void> copy(String text) async {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        showAppSnackBar(context, '网址已复制：$text');
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              Text(
                'WLAN 传书已开启',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.primary.withValues(alpha: 0.12),
                ),
                child: Icon(Icons.wifi, size: 32, color: cs.primary),
              ),
              const SizedBox(height: 12),
              Text(
                '请在电脑浏览器地址栏完整输入',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              for (final url in urls)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => copy(url),
                    onLongPress: () => copy(url),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              url,
                              style: TextStyle(
                                fontSize: 14,
                                color: cs.primary,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.copy_outlined,
                            size: 14,
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              // 传书状态：已接收数量 + 最近书名
              ValueListenableBuilder<LanTransferStats>(
                valueListenable: server.transferStats,
                builder: (context, stats, _) {
                  final last = stats.lastTitle;
                  return Text(
                    stats.received == 0
                        ? '等待传书…'
                        : '已接收 ${stats.received} 本'
                              '${last == null ? '' : ' · 《$last》'}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  );
                },
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () async {
                    await server.stop();
                    await db.setSetting('backup.lanSharing', 'false');
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('取消'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importPaths(List<String> paths) async {
    if (paths.isEmpty || _importing) return;
    setState(() {
      _importing = true;
      _importDone = 0;
      _importTotal = paths.length;
      _importCurrent = '';
    });
    try {
      final repo = ref.read(bookRepositoryProvider);
      var imported = 0;
      var failed = 0;
      var duplicated = 0;
      String? lastError;
      for (final path in paths) {
        final name = path.split(Platform.pathSeparator).last;
        if (mounted) {
          setState(() => _importCurrent = name);
        }
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
        if (mounted) {
          setState(() => _importDone++);
        }
      }
      if (mounted) {
        final msg = failed > 0
            ? '导入 $imported 本，失败 $failed 本：${lastError ?? ''}'
            : duplicated > 0
            ? '导入 $imported 本（$duplicated 本已存在）'
            : '导入 $imported 本';
        showAppSnackBar(context, msg);
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
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

/// 标题下方的排序切换（紧凑下拉，替代顶栏排序按钮）
class _SortSelector extends StatelessWidget {
  const _SortSelector({required this.current, required this.onSelected});

  final BookSort current;
  final ValueChanged<BookSort> onSelected;

  static const _labels = {
    BookSort.lastRead: '最近阅读',
    BookSort.addedAt: '添加时间',
    BookSort.title: '书名',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<BookSort>(
      tooltip: '排序方式',
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final s in BookSort.values)
          PopupMenuItem(
            value: s,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  s == current ? Icons.check : Icons.sort,
                  size: 15,
                  color: s == current ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(_labels[s] ?? '', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort, size: 13, color: cs.primary),
            const SizedBox(width: 4),
            Text(
              _labels[current] ?? '',
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                color: cs.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 15, color: cs.primary),
          ],
        ),
      ),
    );
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

/// 选中态角标
class _SelectionBadge extends StatelessWidget {
  const _SelectionBadge({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: selected ? color : Colors.black45,
        shape: BoxShape.circle,
      ),
      child: Icon(
        selected ? Icons.check : Icons.circle_outlined,
        size: 16,
        color: Colors.white,
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.spec,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Book book;
  final ReaderThemeSpec spec;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      border: selectionMode && selected
                          ? Border.all(color: cs.primary, width: 2)
                          : null,
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withValues(alpha: 0.15),
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: CoverView(book: book, spec: spec),
                  ),
                ),
                if (selectionMode)
                  Positioned(
                    top: 3,
                    right: 3,
                    child: _SelectionBadge(
                      selected: selected,
                      color: cs.primary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.2),
          ),
        ],
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.spec,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Book book;
  final ReaderThemeSpec spec;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: selected
          ? cs.primaryContainer.withValues(alpha: 0.5)
          : cs.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Stack(
          children: [
            SizedBox(
              width: 44,
              height: 60,
              child: CoverView(book: book, spec: spec),
            ),
            if (selectionMode)
              Positioned(
                top: 0,
                right: 0,
                child: _SelectionBadge(selected: selected, color: cs.primary),
              ),
          ],
        ),
        title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${book.author ?? '佚名'} · ${book.format}'
          '${(book.groupName?.isNotEmpty ?? false) ? ' · ${book.groupName}' : ''}',
          maxLines: 1,
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
        trailing: selectionMode
            ? null
            : IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: onLongPress,
              ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}

/// 书籍详情页：醒目的半屏弹层（封面 + 元数据 + 简介）
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

  final cs = Theme.of(context).colorScheme;
  // 封面用当前明暗状态对应的阅读主题（书架卡片同源）
  final spec = ref
      .read(themeControllerProvider)
      .resolve(MediaQuery.platformBrightnessOf(context) == Brightness.dark);
  final chapters = meta['chapterCount'];
  final chars = meta['charCount'];
  final pages = meta['pageCount'];
  final description = meta['description'] as String?;
  final added = DateTime.fromMillisecondsSinceEpoch(book.addedAt);
  final dateStr =
      '${added.year}-${added.month.toString().padLeft(2, '0')}-${added.day.toString().padLeft(2, '0')}';

  Widget stat(String label, String value) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(fontSize: 11, color: cs.outline)),
    ],
  );

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.92,
        minChildSize: 0.5,
        builder: (context, scrollController) => Column(
          children: [
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                children: [
                  // 头部：封面 + 基本信息块
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        height: 154,
                        child: CoverView(book: book, spec: spec),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              book.author ?? '佚名',
                              style: TextStyle(fontSize: 13, color: cs.outline),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                _MetaChip(label: book.format),
                                if (book.groupName?.isNotEmpty ?? false)
                                  _MetaChip(
                                    label: book.groupName!,
                                    icon: Icons.folder_outlined,
                                  ),
                                if (book.language?.isNotEmpty ?? false)
                                  _MetaChip(label: book.language!),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // 统计条
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        stat(
                          '进度',
                          percent == null
                              ? '未开始'
                              : '${(percent * 100).toStringAsFixed(1)}%',
                        ),
                        if (book.fileSize != null)
                          stat('大小', formatBytes(book.fileSize!)),
                        if (pages != null)
                          stat('页数', '$pages')
                        else if (chapters != null)
                          stat('章节', '$chapters'),
                        if (chars != null && (chars as int) > 0)
                          stat(
                            '字数',
                            chars >= 10000
                                ? '${(chars / 10000).toStringAsFixed(1)}万'
                                : '$chars',
                          ),
                        stat('导入', dateStr),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // 简介
                  Text(
                    '简介',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    (description == null || description.trim().isEmpty)
                        ? '（该书籍未提供简介信息）'
                        : description.trim(),
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.7,
                      color: cs.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
            // 底部操作
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('关闭'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          context.push('/reader/${book.id}');
                        },
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: const Text('继续阅读'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 详情页元信息小标签
class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: cs.primary),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: cs.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分组选择对话框：返回 null = 取消；'' = 未分组；其他 = 分组名（可新建）
class GroupPickerDialog extends StatefulWidget {
  const GroupPickerDialog({
    super.key,
    required this.groups,
    this.initialGroup = '',
  });

  final List<String> groups;
  final String initialGroup;

  @override
  State<GroupPickerDialog> createState() => _GroupPickerDialogState();
}

class _GroupPickerDialogState extends State<GroupPickerDialog> {
  late String _selected = widget.initialGroup;
  final _newGroupCtl = TextEditingController();

  @override
  void dispose() {
    _newGroupCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('移动到分组'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final g in ['', ...widget.groups])
                      ListTile(
                        dense: true,
                        leading: Icon(
                          g.isEmpty
                              ? Icons.folder_off_outlined
                              : Icons.folder_outlined,
                          size: 20,
                          color: _selected == g
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        title: Text(
                          g.isEmpty ? '（未分组）' : g,
                          style: const TextStyle(fontSize: 14),
                        ),
                        trailing: _selected == g
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        onTap: () => setState(() => _selected = g),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _newGroupCtl,
              decoration: const InputDecoration(
                labelText: '新建分组',
                hintText: '输入名称，确定时优先使用',
                isDense: true,
              ),
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
            final name = _newGroupCtl.text.trim();
            Navigator.pop(context, name.isNotEmpty ? name : _selected);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
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
