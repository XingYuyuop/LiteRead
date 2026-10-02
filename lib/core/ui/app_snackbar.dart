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
  showAppSnackBarOn(
    ScaffoldMessenger.of(context),
    message,
    duration: duration,
    action: action,
  );
}

/// 基于 [ScaffoldMessengerState] 的提示条变体：
/// 供异步流程在 BuildContext 可能已失效时使用（messenger 为应用级单例，
/// 不随页面销毁失效）
void showAppSnackBarOn(
  ScaffoldMessengerState messenger,
  String message, {
  Duration? duration,
  SnackBarAction? action,
}) {
  messenger
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
            const Text(
              '← 左右滑动可关闭 →',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        action: action,
      ),
    );
}
