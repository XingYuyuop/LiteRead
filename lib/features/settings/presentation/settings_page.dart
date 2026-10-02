import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme_controller.dart';
import '../../../core/crash/crash_logger.dart';
import '../../../core/theme/reader_theme.dart';
import '../../../core/update/update_service.dart';
import '../../../core/update/update_ui.dart';
import '../../reader/logic/reader_settings.dart';

/// 设置中心（M1：主题/排版/关于；完整 45 项随 M2 扩展）
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  void initState() {
    super.initState();
    _loadUpdateInterval();
  }

  Future<void> _loadUpdateInterval() async {
    final svc = UpdateService(ref.read(appDatabaseProvider));
    final v = await svc.loadIntervalDays();
    if (!mounted) return;
    setState(() {
      _updateService = svc;
      _updateInterval = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeControllerProvider);
    final settings = ref.watch(readerSettingsProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('外观'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('日间主题'),
            trailing: DropdownButton<String>(
              value: themeState.lightThemeId,
              underline: const SizedBox.shrink(),
              items: [
                for (final t in BuiltinThemes.all.where((t) => !t.isDark))
                  DropdownMenuItem(value: t.id, child: Text(t.name)),
              ],
              onChanged: (v) {
                if (v != null) {
                  ref.read(themeControllerProvider.notifier).setLightTheme(v);
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('夜间主题'),
            trailing: DropdownButton<String>(
              value: themeState.darkThemeId,
              underline: const SizedBox.shrink(),
              items: [
                for (final t in BuiltinThemes.all.where((t) => t.isDark))
                  DropdownMenuItem(value: t.id, child: Text(t.name)),
              ],
              onChanged: (v) {
                if (v != null) {
                  ref.read(themeControllerProvider.notifier).setDarkTheme(v);
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_auto_outlined),
            title: const Text('跟随系统切换明暗'),
            trailing: Switch(
              value: themeState.mode == ThemeModeChoice.followSystem,
              onChanged: (v) {
                final ctl = ref.read(themeControllerProvider.notifier);
                if (!v) {
                  // 切到固定模式时以当前主题初始化，避免观感跳变
                  final spec = themeState.resolve(
                    MediaQuery.platformBrightnessOf(context) == Brightness.dark,
                  );
                  ctl.setFixedTheme(spec.id);
                } else {
                  ctl.setMode(ThemeModeChoice.followSystem);
                }
              },
            ),
          ),
          // 固定模式下的当前主题
          if (themeState.mode == ThemeModeChoice.fixed)
            ListTile(
              leading: const Icon(Icons.format_paint_outlined),
              title: const Text('当前主题'),
              trailing: DropdownButton<String>(
                value: themeState.fixedThemeId ?? themeState.lightThemeId,
                underline: const SizedBox.shrink(),
                items: [
                  for (final t in BuiltinThemes.all)
                    DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (v) {
                  if (v != null) {
                    ref.read(themeControllerProvider.notifier).setFixedTheme(v);
                  }
                },
              ),
            ),
          const _SectionHeader('阅读排版'),
          ListTile(
            leading: const Icon(Icons.format_size),
            title: const Text('默认字号'),
            subtitle: Text('${settings.fontSize.round()} sp'),
          ),
          ListTile(
            leading: const Icon(Icons.format_line_spacing),
            title: const Text('默认行距'),
            subtitle: Text(settings.lineHeight.toStringAsFixed(1)),
          ),
          ListTile(
            leading: const Icon(Icons.format_align_justify),
            title: const Text('两端对齐'),
            trailing: Switch(
              value: settings.justify,
              onChanged: (v) => ref
                  .read(readerSettingsProvider.notifier)
                  .update((s) => s.copyWith(justify: v)),
            ),
          ),
          const _SectionHeader('阅读体验'),
          ListTile(
            leading: const Icon(Icons.grain),
            title: const Text('墨水屏模式'),
            subtitle: const Text('去除所有动画与过渡效果，适合电子墨水屏设备'),
            trailing: Switch(
              value: settings.inkMode,
              onChanged: (v) => ref
                  .read(readerSettingsProvider.notifier)
                  .update((s) => s.copyWith(inkMode: v)),
            ),
          ),
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('阅读统计'),
            subtitle: const Text('每日 / 每周 / 累计阅读时长与历史记录'),
            onTap: () => context.push('/stats'),
          ),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('备份与恢复'),
            subtitle: const Text('本地文件夹 / WebDAV / S3 / 局域网同步'),
            onTap: () => context.push('/backup'),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('查看崩溃日志'),
            subtitle: const Text('最近一次应用异常退出的详细信息'),
            onTap: () => _showCrashLog(context),
          ),
          const _SectionHeader('关于'),
          ListTile(
            leading: const Icon(Icons.local_library_outlined),
            title: const Text('LiteRead'),
            subtitle: Text('v$kAppVersion · 本地优先 · 无广告无追踪'),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('检查更新'),
            subtitle: const Text('读取 GitHub Releases 最新版本与更新日志'),
            onTap: () => _checkUpdate(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('自动检查更新'),
            trailing: DropdownButton<int>(
              value: _updateInterval,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 1, child: Text('每次启动')),
                DropdownMenuItem(value: 7, child: Text('每周')),
                DropdownMenuItem(value: 30, child: Text('每月')),
                DropdownMenuItem(value: 0, child: Text('从不')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _updateInterval = v);
                _updateService?.saveIntervalDays(v);
              },
            ),
          ),
          SizedBox(height: cs.hashCode.isNegative ? 0 : 24),
        ],
      ),
    );
  }

  // ---- 更新检查 ----

  UpdateService? _updateService;
  int _updateInterval = 7;

  /// 手动检查更新：结果弹窗展示更新日志
  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    final db = ref.read(appDatabaseProvider);
    final svc = _updateService ??= UpdateService(db);
    var cancelled = false;
    // 加载提示（至少出现 400ms，避免闪烁）
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 60,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    ).then((_) => cancelled = true);
    final sw = Stopwatch()..start();
    UpdateInfo? info;
    String? error;
    try {
      info = await svc.checkNow();
    } catch (e) {
      error = e.toString();
    }
    while (sw.elapsedMilliseconds < 400 && !cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    await dialogFuture;
    if (!context.mounted) return;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新失败：$error')),
      );
      return;
    }
    if (info == null) return;
    if (!info.isNewer) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已是最新版本（v$kAppVersion）')),
      );
      return;
    }
    await showUpdateFoundDialog(context, info);
  }

  /// 查看崩溃日志：展示最近一次崩溃详情，可复制 / 清除
  Future<void> _showCrashLog(BuildContext context) async {
    final text = await CrashLogger.lastCrashText();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('崩溃日志'),
        content: SizedBox(
          width: 480,
          height: 380,
          child: text == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified_outlined,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 10),
                      const Text('最近没有崩溃记录'),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ),
        ),
        actions: [
          if (text != null) ...[
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('崩溃日志已复制到剪贴板')),
                  );
                }
              },
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () async {
                await CrashLogger.clear();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('清除'),
            ),
          ],
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
