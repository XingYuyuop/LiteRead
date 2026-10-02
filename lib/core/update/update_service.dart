import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../storage/app_database.dart';

/// 当前应用版本（X.Y.Z；与 pubspec.yaml 的 version 保持同步）
const kAppVersion = '1.0.1';

/// GitHub 仓库（owner/name）
const kGitHubRepo = 'XingYuyuop/LiteRead';

/// 检查更新结果
class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.changelog,
    required this.releaseUrl,
    required this.publishedAt,
  });

  final String latestVersion;
  final String changelog;
  final String releaseUrl;
  final DateTime? publishedAt;

  bool get isNewer {
    final cur = _parseVersion(kAppVersion);
    final latest = _parseVersion(latestVersion);
    if (cur == null || latest == null) return false;
    for (var i = 0; i < 3; i++) {
      if (latest[i] != cur[i]) return latest[i] > cur[i];
    }
    return false;
  }

  static List<int>? _parseVersion(String v) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
    if (m == null) return null;
    return [int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
  }
}

/// 应用内检查更新（GitHub Releases）
///
/// - `checkNow()`：手动立即检查
/// - `maybeAutoCheck()`：按用户配置的周期自动检查（每次启动 / 每周 / 从不）
class UpdateService {
  UpdateService(this._db);

  final AppDatabase _db;

  static const _keyInterval = 'update.checkIntervalDays'; // 0=从不 1=每次启动 7=每周
  static const _keyLastCheck = 'update.lastCheckMs';

  /// 检查间隔（天）；0 = 从不
  Future<int> loadIntervalDays() async {
    final raw = await _db.getSetting(_keyInterval);
    if (raw == null || raw.isEmpty) return 7;
    final v = int.tryParse(raw.replaceAll('"', ''));
    return v ?? 7;
  }

  Future<void> saveIntervalDays(int days) =>
      _db.setSetting(_keyInterval, days.toString());

  /// 距上次检查是否已超过 [intervalDays] 天（intervalDays<=0 表示不自动检查）
  Future<bool> shouldAutoCheck(int intervalDays) async {
    if (intervalDays <= 0) return false;
    final raw = await _db.getSetting(_keyLastCheck);
    final last = int.tryParse(raw?.replaceAll('"', '') ?? '') ?? 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    return elapsed >= intervalDays * 24 * 3600 * 1000;
  }

  /// 周期内自动检查：满足条件时请求 GitHub，有新版本返回 UpdateInfo
  Future<UpdateInfo?> maybeAutoCheck() async {
    final interval = await loadIntervalDays();
    if (!await shouldAutoCheck(interval)) return null;
    try {
      return await checkNow();
    } catch (_) {
      // 网络失败静默（不打扰用户）
      return null;
    }
  }

  /// 立即检查最新 Release
  Future<UpdateInfo> checkNow() async {
    await _db.setSetting(
      _keyLastCheck,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$kGitHubRepo/releases/latest'),
      );
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set('User-Agent', 'LiteRead-App');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw Exception('GitHub API 返回 ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      return UpdateInfo(
        latestVersion: (j['tag_name'] as String? ?? '').replaceFirst('v', ''),
        changelog: j['body'] as String? ?? '',
        releaseUrl:
            j['html_url'] as String? ??
            'https://github.com/$kGitHubRepo/releases/latest',
        publishedAt: DateTime.tryParse(j['published_at'] as String? ?? ''),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// 用系统默认浏览器打开更新页面（无 url_launcher 依赖；失败抛异常）
Future<void> openReleasePage(String url) async {
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [url]);
  } else {
    throw UnsupportedError('当前平台无法自动打开浏览器');
  }
}
