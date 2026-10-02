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

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  runApp(const AppScope());
}
