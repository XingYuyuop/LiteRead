import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 崩溃日志：捕获 Dart 层未捕获异常与 Flutter 框架错误，写入本地文件。
///
/// - 日志文件：`<应用支持目录>/literead/logs/crash.log`（追加，超 512KB 自动清空重写）
/// - 写入采用同步 IO：进程崩溃退出前保证落盘
/// - 设置页提供「查看崩溃日志」入口读取最近一次崩溃详情
class CrashLogger {
  CrashLogger._();

  static String? _logPath;
  static const _maxLogBytes = 512 * 1024;

  /// 安装全局错误钩子（main 中 runApp 前调用一次）
  static void init() {
    try {
      final support = getApplicationSupportDirectory();
      // path_provider 返回 Future；这里用 then 异步补齐路径，
      // 在路径就绪前的崩溃走控制台（与 Flutter 默认行为一致）
      support
          .then((dir) {
            final logDir = Directory(p.join(dir.path, 'literead', 'logs'));
            return logDir.create(recursive: true).then((_) {
              _logPath = p.join(logDir.path, 'crash.log');
            });
          })
          .catchError((_) => null);
    } catch (_) {}

    // Flutter 框架层错误（build/layout/paint 等回调抛出）
    final originalFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      _writeSync(
        kind: 'FLUTTER_ERROR',
        message: details.exceptionAsString(),
        stack: details.stack,
        extra: [
          if (details.library != null) 'library: ${details.library}',
          if (details.context != null)
            'context: ${details.context!.toDescription()}',
        ].join('\n'),
      );
      originalFlutterError?.call(details);
    };

    // Dart 未捕获异步异常（root zone 之外漏出的错误）
    PlatformDispatcher.instance.onError = (error, stack) {
      _writeSync(
        kind: 'UNCAUGHT_ERROR',
        message: error.toString(),
        stack: stack,
      );
      // 返回 false：错误继续沿默认流程处理（保持崩溃语义，不吞错）
      return false;
    };
  }

  /// 同步写入一条崩溃记录（失败静默，避免二次异常）
  static void _writeSync({
    required String kind,
    required String message,
    StackTrace? stack,
    String? extra,
  }) {
    final path = _logPath;
    if (path == null) return;
    try {
      final f = File(path);
      if (f.lengthSync() > _maxLogBytes) {
        f.deleteSync();
      }
      final buf = StringBuffer()
        ..writeln('=' * 64)
        ..writeln('time   : ${DateTime.now().toIso8601String()}')
        ..writeln('kind   : $kind')
        ..writeln(
          'os     : ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}',
        )
        ..writeln('version: ${Platform.version}');
      if (extra != null && extra.isNotEmpty) {
        buf.writeln(extra);
      }
      buf
        ..writeln('--- exception ---')
        ..writeln(message)
        ..writeln('--- stack ---')
        ..writeln(stack == null ? '（无堆栈）' : stack.toString())
        ..writeln();
      f.writeAsStringSync(buf.toString(), mode: FileMode.append);
    } catch (_) {}
  }

  /// 读取最近一次崩溃日志（无记录返回 null）
  static Future<String?> lastCrashText() async {
    final path = _logPath;
    if (path == null) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// 清除崩溃日志
  static Future<void> clear() async {
    final path = _logPath;
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
