import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/reader_theme.dart';
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

  @override
  void dispose() {
    _escFocus.dispose();
    super.dispose();
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
