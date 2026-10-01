import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:literead/app/app.dart';
import 'package:literead/app/theme_controller.dart';
import 'package:literead/core/storage/app_database.dart';
import 'package:literead/core/theme/reader_theme.dart';

/// 测试用数据库：仅覆盖设置读写。
/// Drift 执行器是惰性的——测试只调用被覆写的 getSetting/setSetting，
/// 不会真正打开 SQLite / 触发平台通道。
class _FakeDb extends AppDatabase {
  _FakeDb() : super();

  final _kv = <String, String>{};

  @override
  Future<String?> getSetting(String key) async => _kv[key];

  @override
  Future<void> setSetting(String key, String valueJson) async {
    _kv[key] = valueJson;
  }
}

Widget _app() => ProviderScope(
  overrides: [appDatabaseProvider.overrideWithValue(_FakeDb())],
  child: const LiteReadApp(),
);

void main() {
  testWidgets('应用启动冒烟：书架首帧渲染（防「打不开」回归）', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // 书架骨架：标题 + 搜索 + 导入按钮 + 空状态
    expect(find.text('轻阅'), findsOneWidget);
    expect(find.byTooltip('搜索'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.text('导入书籍'), findsOneWidget);
    expect(find.text('书架空空如也'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页可打开且包含主题与关于区块', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('日间主题'), findsOneWidget);
    expect(find.text('夜间主题'), findsOneWidget);
    // 「关于」区块在默认视口之外，ListView 懒渲染——先滚动到可见
    await tester.scrollUntilVisible(
      find.text('关于'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('关于'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('ThemeState：固定模式解析到指定主题（快捷切换修复的回归测试）', () {
    const state = ThemeState(
      mode: ThemeModeChoice.fixed,
      lightThemeId: 'paper',
      darkThemeId: 'dark',
      fixedThemeId: 'oled',
    );
    // 无论系统明暗，固定模式都应返回固定主题
    expect(state.resolve(false).id, 'oled');
    expect(state.resolve(true).id, 'oled');
  });

  test('ThemeState：JSON 序列化往返保留 fixedThemeId', () {
    const state = ThemeState(
      mode: ThemeModeChoice.fixed,
      fixedThemeId: 'bamboo',
    );
    final restored = ThemeState.fromJson(state.toJson());
    expect(restored.mode, ThemeModeChoice.fixed);
    expect(restored.fixedThemeId, 'bamboo');
    expect(restored.resolve(true).id, 'bamboo');
  });

  test('ThemeState：旧版本数据（无 fixed 键）可正常解析', () {
    final restored = ThemeState.fromJson({
      'mode': 0,
      'light': 'sepia',
      'dark': 'dark',
    });
    expect(restored.fixedThemeId, isNull);
    expect(restored.resolve(false).id, 'sepia');
    expect(restored.resolve(true).id, 'dark');
  });

  test('内置主题：5 套主题 id 唯一且可反查', () {
    final ids = BuiltinThemes.all.map((t) => t.id).toSet();
    expect(ids.length, BuiltinThemes.all.length);
    expect(BuiltinThemes.byId('dark').isDark, isTrue);
    expect(BuiltinThemes.byId('不存在').id, 'paper');
  });
}
