import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/crash/crash_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 崩溃日志：捕获 Flutter 框架错误与未捕获 Dart 异常写入本地文件
  CrashLogger.init();

  // 桌面端窗口初始化（计划书 §4.5：窗口记忆 M4 完善）
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1180, 780),
      minimumSize: Size(640, 480),
      center: true,
      title: '轻阅 LiteRead',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Edge-to-edge：内容绘制到状态栏/导航栏后面，系统栏保持透明。
  // 部分 ROM 即使进入沉浸模式也无法隐藏状态栏——透明化后系统栏下方
  // 仍是应用内容，不会再出现状态栏位置的黑色条块（兼容更多设备）。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  runApp(const AppScope());
}
