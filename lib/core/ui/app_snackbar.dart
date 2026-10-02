import 'package:flutter/material.dart';

/// 应用统一提示条：
/// - 支持左滑/右滑关闭（floating 行为下才可滑动关闭）
/// - 附带「滑动可关闭」提示
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  SnackBarAction? action,
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 3),
        dismissDirection: DismissDirection.horizontal,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 2),
            Text(
              '← 左右滑动可关闭 →',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        action: action,
      ),
    );
}
