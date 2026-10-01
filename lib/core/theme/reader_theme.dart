import 'dart:ui';

/// 阅读主题规格（计划书 §3.6 ReaderThemeSpec）。
///
/// 「一切皆可调」的数据基础：所有影响阅读观感的颜色集中在 spec 中，
/// 渲染层只认 spec，不认具体主题。
class ReaderThemeSpec {
  const ReaderThemeSpec({
    required this.id,
    required this.name,
    required this.background,
    required this.foreground,
    required this.secondary,
    required this.accent,
    required this.highlightPalette,
    this.overlayOpacity = 0.9,
    this.isDark = false,
  });

  final String id;
  final String name;

  /// 页面背景
  final Color background;

  /// 正文
  final Color foreground;

  /// 次级文字（页眉页脚、章节信息）
  final Color secondary;

  /// 强调色（链接、选中、滑块）
  final Color accent;

  /// 4 色高亮调色板
  final List<Color> highlightPalette;

  /// 菜单浮层不透明度（毛玻璃底色 alpha）
  final double overlayOpacity;

  final bool isDark;

  ReaderThemeSpec copyWith({
    String? id,
    String? name,
    Color? background,
    Color? foreground,
    Color? secondary,
    Color? accent,
    List<Color>? highlightPalette,
    double? overlayOpacity,
    bool? isDark,
  }) {
    return ReaderThemeSpec(
      id: id ?? this.id,
      name: name ?? this.name,
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      secondary: secondary ?? this.secondary,
      accent: accent ?? this.accent,
      highlightPalette: highlightPalette ?? this.highlightPalette,
      overlayOpacity: overlayOpacity ?? this.overlayOpacity,
      isDark: isDark ?? this.isDark,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'background': background.toARGB32(),
    'foreground': foreground.toARGB32(),
    'secondary': secondary.toARGB32(),
    'accent': accent.toARGB32(),
    'highlightPalette': highlightPalette.map((c) => c.toARGB32()).toList(),
    'overlayOpacity': overlayOpacity,
    'isDark': isDark,
  };

  static ReaderThemeSpec fromJson(Map<String, dynamic> j) => ReaderThemeSpec(
    id: j['id'] as String,
    name: j['name'] as String,
    background: Color(j['background'] as int),
    foreground: Color(j['foreground'] as int),
    secondary: Color(j['secondary'] as int),
    accent: Color(j['accent'] as int),
    highlightPalette: (j['highlightPalette'] as List)
        .map((c) => Color(c as int))
        .toList(),
    overlayOpacity: (j['overlayOpacity'] as num?)?.toDouble() ?? 0.9,
    isDark: j['isDark'] as bool? ?? false,
  );
}

/// 内置 5 套主题（计划书附录 B 默认色值表）。
abstract final class BuiltinThemes {
  static const paper = ReaderThemeSpec(
    id: 'paper',
    name: '纸白',
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF1F2328),
    secondary: Color(0xFF6E7781),
    accent: Color(0xFF2F6FED),
    highlightPalette: [
      Color(0x66A8CBFF), // 蓝
      Color(0x66B5E8C2), // 绿
      Color(0x66FFE28A), // 黄
      Color(0x66FFB8D1), // 粉
    ],
  );

  static const sepia = ReaderThemeSpec(
    id: 'sepia',
    name: '米黄',
    background: Color(0xFFF7F0DF),
    foreground: Color(0xFF5B4636),
    secondary: Color(0xFF8C7A6B),
    accent: Color(0xFFB07B3F),
    highlightPalette: [
      Color(0x66A8CBFF),
      Color(0x66B5E8C2),
      Color(0x66FFE28A),
      Color(0x66FFB8D1),
    ],
  );

  static const dark = ReaderThemeSpec(
    id: 'dark',
    name: '夜间',
    background: Color(0xFF16181D),
    foreground: Color(0xFFD7DBE0),
    secondary: Color(0xFF9AA1AB),
    accent: Color(0xFF7AA2F7),
    highlightPalette: [
      Color(0x593B5FA8),
      Color(0x593F7A4F),
      Color(0x59A89A3F),
      Color(0x59A84F6E),
    ],
    isDark: true,
  );

  static const oled = ReaderThemeSpec(
    id: 'oled',
    name: '墨黑',
    background: Color(0xFF000000),
    foreground: Color(0xFFC6CBD1),
    secondary: Color(0xFF8A9096),
    accent: Color(0xFF7AA2F7),
    highlightPalette: [
      Color(0x593B5FA8),
      Color(0x593F7A4F),
      Color(0x59A89A3F),
      Color(0x59A84F6E),
    ],
    isDark: true,
  );

  static const bamboo = ReaderThemeSpec(
    id: 'bamboo',
    name: '青竹',
    background: Color(0xFFE4EFE2),
    foreground: Color(0xFF33413A),
    secondary: Color(0xFF6E8078),
    accent: Color(0xFF3E7D5A),
    highlightPalette: [
      Color(0x66A8CBFF),
      Color(0x66B5E8C2),
      Color(0x66FFE28A),
      Color(0x66FFB8D1),
    ],
  );

  static const List<ReaderThemeSpec> all = [paper, sepia, dark, oled, bamboo];

  static ReaderThemeSpec byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => paper);
}
