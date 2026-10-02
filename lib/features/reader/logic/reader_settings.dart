import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme_controller.dart';

/// 阅读排版与行为设置（计划书 §3.6 / 附录 A）。
/// Locator 与排版无关，因此修改任何字段都不会使进度漂移。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.6,
    this.letterSpacing = 0.0,
    this.paragraphSpacing = 0.5,
    this.marginTop = 24,
    this.marginBottom = 24,
    this.marginLeft = 16,
    this.marginRight = 16,
    this.indentChars = 2,
    this.justify = true,
    this.fontFamily,
    this.contentWidthScale = 1.0,
    this.pageAnim = 'cover',
    this.showStatusBar = true,
    this.keepScreenOn = true,
  });

  final double fontSize; // 12–36
  final double lineHeight; // 1.0–2.5
  final double letterSpacing; // -0.5–2.0
  final double paragraphSpacing; // 0–2 × 行高
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;
  final int indentChars; // 0–4
  final bool justify;
  final String? fontFamily; // null = 系统默认

  /// 版心宽度比例（0.5–1.0）：阅读区占窗口宽度的比例，桌面端可收窄成书页
  final double contentWidthScale;

  final String pageAnim; // none|cover|slide|fade
  final bool showStatusBar;
  final bool keepScreenOn;

  EdgeInsets get margins =>
      EdgeInsets.fromLTRB(marginLeft, marginTop, marginRight, marginBottom);

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    double? paragraphSpacing,
    double? marginTop,
    double? marginBottom,
    double? marginLeft,
    double? marginRight,
    int? indentChars,
    bool? justify,
    String? fontFamily,
    bool clearFont = false,
    double? contentWidthScale,
    String? pageAnim,
    bool? showStatusBar,
    bool? keepScreenOn,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      marginTop: marginTop ?? this.marginTop,
      marginBottom: marginBottom ?? this.marginBottom,
      marginLeft: marginLeft ?? this.marginLeft,
      marginRight: marginRight ?? this.marginRight,
      indentChars: indentChars ?? this.indentChars,
      justify: justify ?? this.justify,
      fontFamily: clearFont ? null : (fontFamily ?? this.fontFamily),
      contentWidthScale: contentWidthScale ?? this.contentWidthScale,
      pageAnim: pageAnim ?? this.pageAnim,
      showStatusBar: showStatusBar ?? this.showStatusBar,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    );
  }

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'letterSpacing': letterSpacing,
    'paragraphSpacing': paragraphSpacing,
    'marginTop': marginTop,
    'marginBottom': marginBottom,
    'marginLeft': marginLeft,
    'marginRight': marginRight,
    'indentChars': indentChars,
    'justify': justify,
    'fontFamily': fontFamily,
    'contentWidthScale': contentWidthScale,
    'pageAnim': pageAnim,
    'showStatusBar': showStatusBar,
    'keepScreenOn': keepScreenOn,
  };

  static ReaderSettings fromJson(Map<String, dynamic> j) => ReaderSettings(
    fontSize: (j['fontSize'] as num?)?.toDouble() ?? 18,
    lineHeight: (j['lineHeight'] as num?)?.toDouble() ?? 1.6,
    letterSpacing: (j['letterSpacing'] as num?)?.toDouble() ?? 0,
    paragraphSpacing: (j['paragraphSpacing'] as num?)?.toDouble() ?? 0.5,
    marginTop: (j['marginTop'] as num?)?.toDouble() ?? 24,
    marginBottom: (j['marginBottom'] as num?)?.toDouble() ?? 24,
    marginLeft: (j['marginLeft'] as num?)?.toDouble() ?? 16,
    marginRight: (j['marginRight'] as num?)?.toDouble() ?? 16,
    indentChars: j['indentChars'] as int? ?? 2,
    justify: j['justify'] as bool? ?? true,
    fontFamily: j['fontFamily'] as String?,
    contentWidthScale: (j['contentWidthScale'] as num?)?.toDouble() ?? 1.0,
    pageAnim: j['pageAnim'] as String? ?? 'cover',
    showStatusBar: j['showStatusBar'] as bool? ?? true,
    keepScreenOn: j['keepScreenOn'] as bool? ?? true,
  );
}

class ReaderSettingsController extends Notifier<ReaderSettings> {
  static const _key = 'reader.settings';

  @override
  ReaderSettings build() {
    _load();
    return const ReaderSettings();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final raw = await db.getSetting(_key);
    if (raw != null) {
      state = ReaderSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
  }

  Future<void> update(ReaderSettings Function(ReaderSettings) fn) async {
    state = fn(state);
    final db = ref.read(appDatabaseProvider);
    await db.setSetting(_key, jsonEncode(state.toJson()));
  }
}

final readerSettingsProvider =
    NotifierProvider<ReaderSettingsController, ReaderSettings>(
      ReaderSettingsController.new,
    );
