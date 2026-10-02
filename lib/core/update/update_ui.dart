import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'update_service.dart';

/// 更新提示弹窗（设置页手动检查与启动自动检查共用）：
/// 版本号对比 + 更新日志 + 前往下载
Future<void> showUpdateFoundDialog(
  BuildContext context,
  UpdateInfo info,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
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
              SelectableText(
                info.changelog.trim().isEmpty
                    ? '（该版本未提供更新日志）'
                    : info.changelog.trim(),
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('稍后再说'),
        ),
        FilledButton.icon(
          onPressed: () async {
            final url = info.releaseUrl;
            Navigator.pop(context);
            try {
              await openReleasePage(url);
            } catch (_) {
              // 无法自动打开浏览器 → 复制链接兜底
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('下载链接已复制：$url')),
                );
              }
            }
          },
          icon: const Icon(Icons.download_outlined, size: 18),
          label: const Text('前往下载'),
        ),
      ],
    ),
  );
}
