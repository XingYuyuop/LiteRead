import '../../../core/storage/app_database.dart';

/// 应用通用偏好（settings_kv 存储）

/// 「启动时打开上次阅读的书」设置键
const kAutoOpenLastBookKey = 'app.autoOpenLastBook';

/// 读取「启动时打开上次阅读的书」（未设置时默认开启）
Future<bool> loadAutoOpenLastBook(AppDatabase db) async {
  final raw = await db.getSetting(kAutoOpenLastBookKey);
  return raw == null || raw == 'true';
}

/// 保存「启动时打开上次阅读的书」
Future<void> saveAutoOpenLastBook(AppDatabase db, bool value) =>
    db.setSetting(kAutoOpenLastBookKey, value ? 'true' : 'false');
