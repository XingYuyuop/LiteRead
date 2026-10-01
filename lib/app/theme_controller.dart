import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../../core/theme/reader_theme.dart';

/// 全局数据库 Provider
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// 主题模式：跟随系统 / 固定某套主题
enum ThemeModeChoice { followSystem, fixed }

/// 主题状态
class ThemeState {
  const ThemeState({
    this.mode = ThemeModeChoice.followSystem,
    this.lightThemeId = 'paper',
    this.darkThemeId = 'dark',
  });

  final ThemeModeChoice mode;
  final String lightThemeId;
  final String darkThemeId;

  /// 解析当前应使用的主题（[systemDark] 为系统当前暗色状态）
  ReaderThemeSpec resolve(bool systemDark) {
    switch (mode) {
      case ThemeModeChoice.followSystem:
        return BuiltinThemes.byId(systemDark ? darkThemeId : lightThemeId);
      case ThemeModeChoice.fixed:
        return BuiltinThemes.byId(systemDark ? darkThemeId : lightThemeId);
    }
  }

  ThemeState copyWith({
    ThemeModeChoice? mode,
    String? lightThemeId,
    String? darkThemeId,
  }) {
    return ThemeState(
      mode: mode ?? this.mode,
      lightThemeId: lightThemeId ?? this.lightThemeId,
      darkThemeId: darkThemeId ?? this.darkThemeId,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.index,
    'light': lightThemeId,
    'dark': darkThemeId,
  };

  static ThemeState fromJson(Map<String, dynamic> j) => ThemeState(
    mode: ThemeModeChoice.values[j['mode'] as int? ?? 0],
    lightThemeId: j['light'] as String? ?? 'paper',
    darkThemeId: j['dark'] as String? ?? 'dark',
  );
}

/// 主题控制器：持久化到 settings_kv
class ThemeController extends Notifier<ThemeState> {
  static const _key = 'app.theme';

  @override
  ThemeState build() {
    _load();
    return const ThemeState();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final raw = await db.getSetting(_key);
    if (raw != null) {
      state = ThemeState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
  }

  Future<void> _persist() async {
    final db = ref.read(appDatabaseProvider);
    await db.setSetting(_key, jsonEncode(state.toJson()));
  }

  Future<void> setMode(ThemeModeChoice mode) async {
    state = state.copyWith(mode: mode);
    await _persist();
  }

  Future<void> setLightTheme(String id) async {
    state = state.copyWith(lightThemeId: id);
    await _persist();
  }

  Future<void> setDarkTheme(String id) async {
    state = state.copyWith(darkThemeId: id);
    await _persist();
  }
}

final themeControllerProvider = NotifierProvider<ThemeController, ThemeState>(
  ThemeController.new,
);
