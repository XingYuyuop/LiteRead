import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/reader_theme.dart';
import '../features/reader/logic/reader_settings.dart';
import 'router.dart';
import 'theme_controller.dart';

/// 应用根：Material 3 + 主题联动阅读页
class LiteReadApp extends ConsumerWidget {
  const LiteReadApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeControllerProvider);
    final router = ref.watch(routerProvider);

    // Material 主题由内置阅读主题派生（标题栏/控件随主题着色）
    final lightSpec = BuiltinThemes.byId(themeState.lightThemeId);
    final darkSpec = BuiltinThemes.byId(themeState.darkThemeId);

    return MaterialApp.router(
      title: '轻阅 LiteRead',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      themeMode: themeState.mode == ThemeModeChoice.followSystem
          ? ThemeMode.system
          : ThemeMode.light,
      theme: _materialTheme(lightSpec, Brightness.light),
      darkTheme: _materialTheme(darkSpec, Brightness.dark),
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
          return const LiteReadApp();
        },
      ),
    );
  }
}
