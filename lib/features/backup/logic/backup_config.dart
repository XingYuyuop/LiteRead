import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme_controller.dart';
import '../../../core/storage/app_database.dart';
import '../../library/data/book_repository.dart';
import '../data/backup_service.dart';
import '../data/lan_sync.dart';

/// 备份目标类型
enum BackupTargetType { local, webdav, s3, lan }

extension BackupTargetTypeX on BackupTargetType {
  String get label => switch (this) {
    BackupTargetType.local => '本地文件夹',
    BackupTargetType.webdav => 'WebDAV',
    BackupTargetType.s3 => 'S3 对象存储',
    BackupTargetType.lan => '局域网设备',
  };
}

/// 备份配置（持久化于 settings_kv：'backup.folderName' / 'backup.config'）
class BackupConfig {
  const BackupConfig({
    this.folderName = 'LiteRead',
    this.type = BackupTargetType.local,
    this.localPath = '',
    this.webdavUrl = '',
    this.webdavUser = '',
    this.webdavPass = '',
    this.s3Endpoint = '',
    this.s3Bucket = '',
    this.s3AccessKey = '',
    this.s3SecretKey = '',
    this.s3Region = 'us-east-1',
    this.s3PathStyle = true,
    this.lanAddress = '',
    this.lanPort = lanSyncPort,
    this.ignoreTheme = false,
    this.ignoreReader = false,
    this.ignoreStats = false,
    this.ignoreBackupCfg = false,
  });

  /// 备份根目录名（备份文件在其下，book/、progress/、covers/ 子目录也在这里）
  final String folderName;
  final BackupTargetType type;

  // 本地文件夹
  final String localPath;

  // WebDAV
  final String webdavUrl;
  final String webdavUser;
  final String webdavPass;

  // S3
  final String s3Endpoint;
  final String s3Bucket;
  final String s3AccessKey;
  final String s3SecretKey;
  final String s3Region;
  final bool s3PathStyle;

  // 局域网设备
  final String lanAddress;
  final int lanPort;

  // 忽略列表：这些数据不参与备份/恢复
  final bool ignoreTheme; // 主题设置
  final bool ignoreReader; // 阅读界面设置
  final bool ignoreStats; // 阅读统计
  final bool ignoreBackupCfg; // 本机备份目标配置

  /// 转为备份服务选项
  BackupOptions toOptions() => BackupOptions(
    ignoreTheme: ignoreTheme,
    ignoreReader: ignoreReader,
    ignoreStats: ignoreStats,
    ignoreBackupCfg: ignoreBackupCfg,
  );

  BackupConfig copyWith({
    String? folderName,
    BackupTargetType? type,
    String? localPath,
    String? webdavUrl,
    String? webdavUser,
    String? webdavPass,
    String? s3Endpoint,
    String? s3Bucket,
    String? s3AccessKey,
    String? s3SecretKey,
    String? s3Region,
    bool? s3PathStyle,
    String? lanAddress,
    int? lanPort,
    bool? ignoreTheme,
    bool? ignoreReader,
    bool? ignoreStats,
    bool? ignoreBackupCfg,
  }) => BackupConfig(
    folderName: folderName ?? this.folderName,
    type: type ?? this.type,
    localPath: localPath ?? this.localPath,
    webdavUrl: webdavUrl ?? this.webdavUrl,
    webdavUser: webdavUser ?? this.webdavUser,
    webdavPass: webdavPass ?? this.webdavPass,
    s3Endpoint: s3Endpoint ?? this.s3Endpoint,
    s3Bucket: s3Bucket ?? this.s3Bucket,
    s3AccessKey: s3AccessKey ?? this.s3AccessKey,
    s3SecretKey: s3SecretKey ?? this.s3SecretKey,
    s3Region: s3Region ?? this.s3Region,
    s3PathStyle: s3PathStyle ?? this.s3PathStyle,
    lanAddress: lanAddress ?? this.lanAddress,
    lanPort: lanPort ?? this.lanPort,
    ignoreTheme: ignoreTheme ?? this.ignoreTheme,
    ignoreReader: ignoreReader ?? this.ignoreReader,
    ignoreStats: ignoreStats ?? this.ignoreStats,
    ignoreBackupCfg: ignoreBackupCfg ?? this.ignoreBackupCfg,
  );

  Map<String, dynamic> toJson() => {
    'folderName': folderName,
    'type': type.name,
    'localPath': localPath,
    'webdavUrl': webdavUrl,
    'webdavUser': webdavUser,
    'webdavPass': webdavPass,
    's3Endpoint': s3Endpoint,
    's3Bucket': s3Bucket,
    's3AccessKey': s3AccessKey,
    's3SecretKey': s3SecretKey,
    's3Region': s3Region,
    's3PathStyle': s3PathStyle,
    'lanAddress': lanAddress,
    'lanPort': lanPort,
    'ignoreTheme': ignoreTheme,
    'ignoreReader': ignoreReader,
    'ignoreStats': ignoreStats,
    'ignoreBackupCfg': ignoreBackupCfg,
  };

  static BackupConfig fromJson(Map<String, dynamic> j) => BackupConfig(
    folderName: j['folderName'] as String? ?? 'LiteRead',
    type:
        BackupTargetType.values.asNameMap()[j['type']] ??
        BackupTargetType.local,
    localPath: j['localPath'] as String? ?? '',
    webdavUrl: j['webdavUrl'] as String? ?? '',
    webdavUser: j['webdavUser'] as String? ?? '',
    webdavPass: j['webdavPass'] as String? ?? '',
    s3Endpoint: j['s3Endpoint'] as String? ?? '',
    s3Bucket: j['s3Bucket'] as String? ?? '',
    s3AccessKey: j['s3AccessKey'] as String? ?? '',
    s3SecretKey: j['s3SecretKey'] as String? ?? '',
    s3Region: j['s3Region'] as String? ?? 'us-east-1',
    s3PathStyle: j['s3PathStyle'] as bool? ?? true,
    lanAddress: j['lanAddress'] as String? ?? '',
    lanPort: j['lanPort'] as int? ?? lanSyncPort,
    ignoreTheme: j['ignoreTheme'] as bool? ?? false,
    ignoreReader: j['ignoreReader'] as bool? ?? false,
    ignoreStats: j['ignoreStats'] as bool? ?? false,
    ignoreBackupCfg: j['ignoreBackupCfg'] as bool? ?? false,
  );

  static const _keyConfig = 'backup.config';

  Future<void> save(AppDatabase db) async {
    await db.setSetting(_keyConfig, jsonEncode(toJson()));
    await db.setSetting('backup.folderName', jsonEncode(folderName));
  }

  static Future<BackupConfig> load(AppDatabase db) async {
    final raw = await db.getSetting(_keyConfig);
    if (raw == null) return const BackupConfig();
    try {
      return BackupConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const BackupConfig();
    }
  }
}

/// 备份服务（应用级单例）
final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    ref.watch(bookRepositoryProvider),
    ref.watch(appDatabaseProvider),
  );
});

/// 局域网同步服务（应用级单例，页面切换不中断共享）
final lanSyncServerProvider = Provider<LanSyncServer>((ref) {
  return LanSyncServer(
    ref.watch(bookRepositoryProvider),
    ref.watch(appDatabaseProvider),
  );
});

/// 应用启动时恢复局域网共享开关状态（上次开启过则自动开放端口）
/// 延迟 2 秒执行：避免 socket 绑定与首帧渲染争抢资源，加快启动
final lanBootstrapProvider = Provider<void>((ref) {
  final server = ref.watch(lanSyncServerProvider);
  final db = ref.watch(appDatabaseProvider);
  unawaited(() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      if (await db.getSetting('backup.lanSharing') == 'true') {
        await server.start();
      }
    } catch (_) {
      // 启动失败静默处理，进入备份页时可再次开启
    }
  }());
});
