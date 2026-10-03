import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/reader_theme.dart';
import '../features/backup/data/lan_sync.dart';
import '../features/backup/logic/backup_config.dart';
import '../features/reader/logic/reader_settings.dart';
import 'router.dart';
import 'theme_controller.dart';

/// 应用根：Material 3 + 主题联动阅读页
class LiteReadApp extends ConsumerStatefulWidget {
  const LiteReadApp({super.key});

  @override
  ConsumerState<LiteReadApp> createState() => _LiteReadAppState();
}

class _LiteReadAppState extends ConsumerState<LiteReadApp> {
  // 桌面端全局 ESC：焦点挂在路由容器上，未被子页面/输入框消费的 ESC
  // 冒泡到这里触发 maybePop（返回上一页 / 关闭对话框）
  final _escFocus = FocusNode();

  // 对端同步进度弹窗：本机作为接收方时全局展示（任务：局域网同步双方都有弹窗）
  bool _peerSyncDialogOpen = false;
  VoidCallback? _peerSyncListener;
  ValueNotifier<LanSyncProgress?>? _peerSyncNotifier;

  @override
  void initState() {
    super.initState();
    final notifier = ref.read(lanSyncServerProvider).syncProgress;
    _peerSyncNotifier = notifier;
    _peerSyncListener = () => _onPeerSyncProgress(notifier);
    notifier.addListener(_peerSyncListener!);
  }

  @override
  void dispose() {
    if (_peerSyncListener != null) {
      _peerSyncNotifier?.removeListener(_peerSyncListener!);
    }
    _escFocus.dispose();
    super.dispose();
  }

  /// 对端推送的同步进度 → 全局弹窗（进度值随 notifier 实时刷新，
  /// finished 后服务端 3 秒清空 → 自动关闭）
  void _onPeerSyncProgress(ValueNotifier<LanSyncProgress?> notifier) {
    final nav = rootNavigatorKey.currentState;
    final p = notifier.value;
    if (p == null) {
      if (_peerSyncDialogOpen && nav != null && nav.canPop()) {
        nav.pop();
      }
      return;
    }
    if (_peerSyncDialogOpen || nav == null) return;
    _peerSyncDialogOpen = true;
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) {
      _peerSyncDialogOpen = false;
      return;
    }
    nav
        .push(
          DialogRoute<void>(
            context: ctx,
            barrierDismissible: false,
            barrierColor: Colors.black54,
            builder: (_) => PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Text('备份同步中'),
                content: ValueListenableBuilder<LanSyncProgress?>(
                  valueListenable: notifier,
                  builder: (ctx, p, _) {
                    final v =
                        p ??
                        const LanSyncProgress(
                          phase: '完成',
                          done: 1,
                          total: 1,
                          finished: true,
                        );
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          v.phase.isEmpty ? '对端正在同步…' : v.phase,
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: v.total > 0 ? v.value : null,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            v.total > 0 ? '${v.done} / ${v.total}' : '',
                            style: const TextStyle(
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        )
        .whenComplete(() => _peerSyncDialogOpen = false);
  }

  void _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      rootNavigatorKey.currentState?.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeControllerProvider);
    final router = ref.watch(routerProvider);

    // Material 主题由内置阅读主题派生（标题栏/控件随主题着色）
    final lightSpec = BuiltinThemes.byId(themeState.lightThemeId);
    final darkSpec = BuiltinThemes.byId(themeState.darkThemeId);
    // 固定模式：日/夜 Material 主题均派生自同一套固定主题
    final fixedSpec = themeState.mode == ThemeModeChoice.fixed
        ? BuiltinThemes.byId(themeState.fixedThemeId ?? themeState.lightThemeId)
        : null;

    return MaterialApp.router(
      title: 'LiteRead',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      builder: (context, child) => KeyboardListener(
        focusNode: _escFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: child!,
      ),
      themeMode: themeState.mode == ThemeModeChoice.followSystem
          ? ThemeMode.system
          : (fixedSpec!.isDark ? ThemeMode.dark : ThemeMode.light),
      theme: _materialTheme(fixedSpec ?? lightSpec, Brightness.light),
      darkTheme: _materialTheme(fixedSpec ?? darkSpec, Brightness.dark),
    );
  }

  ThemeData _materialTheme(ReaderThemeSpec spec, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: spec.accent,
      brightness: brightness,
      surface: spec.background,
      onSurface: spec.foreground,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: null,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: spec.background,
        foregroundColor: spec.foreground,
      ),
      scaffoldBackgroundColor: spec.background,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 全局 ProviderScope 容器（含 ReaderController 生命周期观察）
class AppScope extends StatelessWidget {
  const AppScope({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: Consumer(
        builder: (context, ref, _) {
          // 预热设置
          ref.watch(readerSettingsProvider);
          // 恢复局域网共享开关状态（上次开启过则自动开放端口）
          ref.watch(lanBootstrapProvider);
          return const LiteReadApp();
        },
      ),
    );
  }
}
