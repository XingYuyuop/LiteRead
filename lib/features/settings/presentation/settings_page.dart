import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme_controller.dart';
import '../../../core/theme/reader_theme.dart';
import '../../reader/logic/reader_settings.dart';

/// 设置中心（M1：主题/排版/关于；完整 45 项随 M2 扩展）
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              onChanged: (v) => ref
                  .read(themeControllerProvider.notifier)
                  .setMode(
                    v ? ThemeModeChoice.followSystem : ThemeModeChoice.fixed,
                  ),
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
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('备份与恢复'),
            subtitle: const Text('v1.x 提供（计划书 FR-F03）'),
            onTap: () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('备份功能将于 v1.x 提供')));
            },
          ),
          const _SectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.local_library_outlined),
            title: Text('轻阅 LiteRead'),
            subtitle: Text('v0.1.0 · 本地优先 · 无广告无追踪'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('检查更新'),
            subtitle: const Text('读取 GitHub Releases（M4 接入）'),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('更新检查将于 v0.4（M4）接入')),
              );
            },
          ),
          SizedBox(height: cs.hashCode.isNegative ? 0 : 24),
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
