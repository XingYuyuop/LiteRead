import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ui/app_snackbar.dart';
import 'update_service.dart';

/// Android 安装桥：MainActivity 中注册，唤起系统安装器
const _channel = MethodChannel('literead/updater');

/// 应用内直接更新：下载安装包 → Android 唤起系统安装器 /
/// Windows 解压替换安装目录并重启。
///
/// 返回 false 表示当前平台没有匹配的安装包附件，
/// 调用方可回退为打开浏览器下载。
Future<bool> runInAppUpdate(BuildContext context, UpdateInfo info) async {
  final url = info.assetForPlatform();
  if (url == null) return false;

  final progress = ValueNotifier<double>(0);
  final phase = ValueNotifier<String>('连接服务器…');
  // 预先取根导航器：关闭进度对话框时不跨越 async 使用 BuildContext
  final rootNavigator = Navigator.of(context, rootNavigator: true);
  // 进度对话框自身的 context：关闭前始终有效。
  // 调用方（「发现新版本」对话框）在启动更新前已被 pop，其 context 会失效，
  // 因此安装阶段一律使用 dialogCtx，避免下载完成后静默返回（不跳安装界面）
  BuildContext? dialogCtx;
  // 应用级 messenger：异步流程中的提示不依赖任何 BuildContext 的存活
  final messenger = ScaffoldMessenger.of(context);

  final dialogFuture = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialogCtx = ctx;
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('正在更新到 v${info.latestVersion}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<String>(
                valueListenable: phase,
                builder: (_, v, _) =>
                    Text(v, style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, _) => LinearProgressIndicator(
                  value: v <= 0 ? null : v.clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, _) => Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    v > 0 ? '${(v * 100).toStringAsFixed(0)}%' : '',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  File? file;
  Object? error;
  try {
    file = await _downloadToTemp(url, progress, phase);
  } catch (e) {
    error = e;
  }

  // 安装阶段的 UI 全部挂在进度对话框的 ctx 上（此时对话框尚未关闭）
  // ignore: use_build_context_synchronously
  final uiCtx = dialogCtx;

  if (error != null) {
    rootNavigator.pop();
    await dialogFuture;
    showAppSnackBarOn(messenger, '更新失败：$error');
    return true;
  }

  try {
    if (Platform.isAndroid) {
      await _installApkAndroid(uiCtx ?? context, file!.path);
    } else if (Platform.isWindows) {
      final restart = await showDialog<bool>(
        context: uiCtx ?? context,
        builder: (ctx) => AlertDialog(
          title: const Text('更新包已下载'),
          content: const Text('应用将自动退出并完成更新，随后会重新启动。是否继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后手动安装'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('立即更新'),
            ),
          ],
        ),
      );
      if (restart == true) {
        showAppSnackBarOn(
          messenger,
          '应用即将退出，替换完成后会自动重新启动…',
          duration: const Duration(seconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _prepareWindowsUpdate(file!);
        exit(0);
      }
    }
  } catch (e) {
    showAppSnackBarOn(messenger, '安装失败：$e');
  }
  rootNavigator.pop();
  await dialogFuture;
  return true;
}

/// Android 安装：直接唤起系统安装器；缺少「安装未知应用」权限时
/// 弹窗引导用户去系统设置授权，返回后自动重试安装。
Future<void> _installApkAndroid(BuildContext context, String path) async {
  try {
    await _channel.invokeMethod('installApk', {'path': path});
    return;
  } on PlatformException catch (e) {
    if (e.code != 'NO_INSTALL_PERMISSION') rethrow;
  }
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('需要安装权限'),
      content: const Text(
        '安装更新需要允许本应用「安装未知应用」。\n点击「去授权」打开系统设置，'
        '开启开关后返回，应用会自动继续安装。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('去授权'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  await _channel.invokeMethod('openInstallPermissionSettings');

  // 等待用户从系统设置返回（3 分钟超时兜底），随后自动重试安装
  final resumed = Completer<void>();
  final listener = AppLifecycleListener(onResume: resumed.complete);
  try {
    await resumed.future.timeout(const Duration(minutes: 3), onTimeout: () {});
  } finally {
    listener.dispose();
  }
  if (!context.mounted) return;
  await _installApkAndroid(context, path);
}

/// 首次启动请求本地存储权限（仅 Android；失败静默，不阻塞启动）
Future<void> requestStoragePermission() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod('requestStoragePermission');
  } catch (_) {
    // 权限请求失败不阻塞启动
  }
}

/// 下载安装包到临时目录，通过 Notifier 上报进度
Future<File> _downloadToTemp(
  String url,
  ValueNotifier<double> progress,
  ValueNotifier<String> phase,
) async {
  final dir = await getTemporaryDirectory();
  final fileName = url.split('/').last.split('?').first;
  final target = File(p.join(dir.path, 'literead_update_$fileName'));
  if (await target.exists()) await target.delete();

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'LiteRead-App');
    final res = await req.close().timeout(const Duration(minutes: 10));
    if (res.statusCode != 200) {
      throw Exception('下载失败（HTTP ${res.statusCode}）');
    }
    final total = res.contentLength;
    final sink = target.openWrite();
    var received = 0;
    await for (final chunk in res) {
      received += chunk.length;
      sink.add(chunk);
      if (total > 0) {
        progress.value = received / total;
        phase.value =
            '下载中 ${(received / (1 << 20)).toStringAsFixed(1)} / '
            '${(total / (1 << 20)).toStringAsFixed(1)} MB';
      } else {
        phase.value = '下载中 ${(received / (1 << 20)).toStringAsFixed(1)} MB';
      }
    }
    await sink.flush();
    await sink.close();
    phase.value = '下载完成';
    return target;
  } finally {
    client.close(force: true);
  }
}

/// Windows 更新：解压 zip → 写替换脚本（等本进程退出后覆盖安装目录并重启）→
/// 分离进程运行脚本 → 调用方 exit(0)
Future<void> _prepareWindowsUpdate(File zip) async {
  final tmp = await getTemporaryDirectory();
  final updateDir = Directory(p.join(tmp.path, 'literead_update'));
  if (await updateDir.exists()) {
    await updateDir.delete(recursive: true);
  }
  await updateDir.create(recursive: true);

  // zip 为扁平结构（应用文件直接位于根级）
  final bytes = await zip.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final f in archive) {
    final outPath = p.join(updateDir.path, f.name);
    if (f.isFile) {
      final out = File(outPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>);
    } else {
      await Directory(outPath).create(recursive: true);
    }
  }

  final exePath = Platform.resolvedExecutable;
  final installDir = p.dirname(exePath);
  final exeName = p.basename(exePath);
  final currentPid = pid;
  final bat = File(p.join(updateDir.path, 'update.bat'));
  await bat.writeAsString('''
@echo off
:wait
tasklist /FI "PID eq $currentPid" | find "$currentPid" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
xcopy /E /Y /I "${updateDir.path}\\*" "$installDir\\"
start "" "$installDir\\$exeName"
del "%~f0"
''', flush: true);

  await Process.start('cmd.exe', [
    '/c',
    bat.path,
  ], mode: ProcessStartMode.detached);
}
