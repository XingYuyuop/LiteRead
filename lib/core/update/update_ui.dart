import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/app_snackbar.dart';
import 'app_updater.dart';
import 'update_service.dart';

/// 更新日志按行拆分为列表条目：去 Markdown 前缀（# / - / * / • / 1.）与空白行
List<String> changelogItems(String raw) {
  return raw
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .map((l) => l.replaceFirst(RegExp(r'^(?:#{1,6}|[-*•]|\d+[.、)])\s*'), ''))
      .where((l) => l.isNotEmpty)
      .toList();
}

/// 更新提示弹窗（设置页手动检查与启动自动检查共用）：
/// 版本号对比 + 更新日志 + 应用内直接更新
Future<void> showUpdateFoundDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text('发现新版本 v${info.latestVersion}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前版本 v$kAppVersion → 最新版本 v${info.latestVersion}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '更新日志',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              _ChangelogList(info.changelog),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: const Text('稍后再说'),
        ),
        FilledButton.icon(
          onPressed: () async {
            // 关闭本对话框后，用页面 context（长活）启动更新流程；
            // 更新内部的后续 UI 由进度对话框自身的 context 承载
            Navigator.pop(dialogCtx);
            // 应用内直接更新（下载 → 安装/替换）；无匹配附件时回退浏览器
            final started = await runInAppUpdate(context, info);
            if (!started && context.mounted) {
              try {
                await openReleasePage(info.releaseUrl);
              } catch (_) {
                await Clipboard.setData(ClipboardData(text: info.releaseUrl));
                if (context.mounted) {
                  showAppSnackBar(context, '下载链接已复制：${info.releaseUrl}');
                }
              }
            }
          },
          icon: const Icon(Icons.download_outlined, size: 18),
          label: const Text('直接更新'),
        ),
      ],
    ),
  );
}

/// 更新日志列表：每条一行、带圆点前缀，内容可选中复制
class _ChangelogList extends StatelessWidget {
  const _ChangelogList(this.changelog);

  final String changelog;

  @override
  Widget build(BuildContext context) {
    final items = changelogItems(changelog);
    if (items.isEmpty) {
      return const SelectableText(
        '（该版本未提供更新日志）',
        style: TextStyle(fontSize: 13, height: 1.6),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  ', style: TextStyle(fontSize: 13, height: 1.6)),
                Expanded(
                  child: SelectableText(
                    item,
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
