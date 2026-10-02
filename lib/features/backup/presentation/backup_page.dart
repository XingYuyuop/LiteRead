import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme_controller.dart';
import '../data/backup_service.dart';
import '../data/lan_sync.dart';
import '../data/remote_store.dart';
import '../logic/backup_config.dart';

/// 备份与恢复页：本地文件夹 / WebDAV / S3 / 局域网设备
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  BackupConfig _cfg = const BackupConfig();
  bool _busy = false;
  String _busyText = '';
  bool _scanning = false;
  List<LanDevice> _devices = const [];
  bool _sharing = false;

  late final TextEditingController _folderCtrl;
  late final TextEditingController _webdavUrlCtrl;
  late final TextEditingController _webdavUserCtrl;
  late final TextEditingController _webdavPassCtrl;
  late final TextEditingController _s3EndpointCtrl;
  late final TextEditingController _s3BucketCtrl;
  late final TextEditingController _s3KeyCtrl;
  late final TextEditingController _s3SecretCtrl;
  late final TextEditingController _s3RegionCtrl;

  @override
  void initState() {
    super.initState();
    _folderCtrl = TextEditingController();
    _webdavUrlCtrl = TextEditingController();
    _webdavUserCtrl = TextEditingController();
    _webdavPassCtrl = TextEditingController();
    _s3EndpointCtrl = TextEditingController();
    _s3BucketCtrl = TextEditingController();
    _s3KeyCtrl = TextEditingController();
    _s3SecretCtrl = TextEditingController();
    _s3RegionCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _folderCtrl.dispose();
    _webdavUrlCtrl.dispose();
    _webdavUserCtrl.dispose();
    _webdavPassCtrl.dispose();
    _s3EndpointCtrl.dispose();
    _s3BucketCtrl.dispose();
    _s3KeyCtrl.dispose();
    _s3SecretCtrl.dispose();
    _s3RegionCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await BackupConfig.load(ref.read(appDatabaseProvider));
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _folderCtrl.text = cfg.folderName;
      _webdavUrlCtrl.text = cfg.webdavUrl;
      _webdavUserCtrl.text = cfg.webdavUser;
      _webdavPassCtrl.text = cfg.webdavPass;
      _s3EndpointCtrl.text = cfg.s3Endpoint;
      _s3BucketCtrl.text = cfg.s3Bucket;
      _s3KeyCtrl.text = cfg.s3AccessKey;
      _s3SecretCtrl.text = cfg.s3SecretKey;
      _s3RegionCtrl.text = cfg.s3Region;
      _sharing = ref.read(lanSyncServerProvider).running;
    });
  }

  void _update(BackupConfig Function(BackupConfig) fn) {
    setState(() => _cfg = fn(_cfg));
    _cfg.save(ref.read(appDatabaseProvider));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String get _rootName =>
      _cfg.folderName.trim().isEmpty ? 'literead' : _cfg.folderName.trim();

  /// 按当前配置构建存储目标；配置不完整时提示并返回 null
  RemoteStore? _safeStore() {
    try {
      return _buildStore();
    } on BackupException catch (e) {
      _toast(e.message);
      return null;
    }
  }

  RemoteStore _buildStore() {
    switch (_cfg.type) {
      case BackupTargetType.local:
        if (_cfg.localPath.isEmpty) {
          throw const BackupException('请先选择本地备份位置');
        }
        return LocalFolderStore(Directory(_cfg.localPath), _rootName);
      case BackupTargetType.webdav:
        if (_cfg.webdavUrl.trim().isEmpty) {
          throw const BackupException('请填写 WebDAV 服务器地址');
        }
        return WebDavStore(
          baseUrl: _cfg.webdavUrl.trim(),
          rootFolder: _rootName,
          username: _cfg.webdavUser.trim().isEmpty ? null : _cfg.webdavUser,
          password: _cfg.webdavPass,
        );
      case BackupTargetType.s3:
        if (_cfg.s3Endpoint.trim().isEmpty || _cfg.s3Bucket.trim().isEmpty) {
          throw const BackupException('请填写 S3 端点与存储桶');
        }
        return S3Store(
          endpoint: _cfg.s3Endpoint.trim(),
          bucket: _cfg.s3Bucket.trim(),
          accessKey: _cfg.s3AccessKey.trim(),
          secretKey: _cfg.s3SecretKey.trim(),
          region: _cfg.s3Region.trim().isEmpty ? 'us-east-1' : _cfg.s3Region,
          rootFolder: _rootName,
          pathStyle: _cfg.s3PathStyle,
        );
      case BackupTargetType.lan:
        if (_cfg.lanAddress.isEmpty) {
          throw const BackupException('请先扫描并选择局域网设备');
        }
        return LanStore(_cfg.lanAddress, _cfg.lanPort);
    }
  }

  // ---- 操作 ----

  Future<void> _runOp(
    String title,
    Future<BackupResult> Function(BackupService, RemoteStore) op,
  ) async {
    final store = _safeStore();
    if (store == null) return;
    setState(() {
      _busy = true;
      _busyText = title;
    });
    try {
      final r = await op(ref.read(backupServiceProvider), store);
      _toast('${r.summary()}（$title完成）');
    } catch (e) {
      _toast('$title失败：$e');
    } finally {
      await store.dispose();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _onRestore() async {
    final store = _safeStore();
    if (store == null) return;
    setState(() {
      _busy = true;
      _busyText = '读取备份清单';
    });
    try {
      final manifests = await ref
          .read(backupServiceProvider)
          .listManifests(store);
      if (!mounted) return;
      if (manifests.isEmpty) {
        _toast('远端没有找到备份清单');
        return;
      }
      final name = await _pickManifest(manifests);
      if (name == null) return;
      if (mounted) {
        setState(() => _busyText = '正在恢复');
      }
      final r = await ref
          .read(backupServiceProvider)
          .restore(store, manifestName: name);
      _toast('恢复完成：${r.summary()}');
    } catch (e) {
      _toast('恢复失败：$e');
    } finally {
      await store.dispose();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<String?> _pickManifest(List<(String, BackupManifest)> manifests) {
    final sorted = [...manifests]
      ..sort((a, b) => b.$2.createdAt.compareTo(a.$2.createdAt));
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '选择要恢复的备份',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final (name, m) in sorted)
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(m.deviceName),
                subtitle: Text(
                  '${_fmtTime(m.createdAt)} · ${m.books.length} 本书籍',
                ),
                onTap: () => Navigator.pop(ctx, name),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }

  // ---- 局域网 ----

  Future<void> _toggleSharing(bool v) async {
    final server = ref.read(lanSyncServerProvider);
    try {
      if (v) {
        await server.start();
      } else {
        await server.stop();
      }
      await ref
          .read(appDatabaseProvider)
          .setSetting('backup.lanSharing', v ? 'true' : 'false');
      if (mounted) {
        setState(() => _sharing = server.running);
      }
      _toast(v ? '共享已开启，端口 ${server.port}' : '共享已关闭');
    } catch (e) {
      _toast('共享开启失败：$e');
    }
  }

  Future<void> _scanDevices() async {
    setState(() => _scanning = true);
    try {
      final found = await LanScanner.scan();
      if (!mounted) return;
      setState(() => _devices = found);
      if (found.isEmpty) {
        _toast('未发现局域网设备，请确认对端已开启「共享本机书库」');
      }
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<void> _pickLocalDir() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择备份位置',
    );
    if (path != null) {
      _update((c) => c.copyWith(localPath: path));
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (_busy) ...[
            LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(_busyText, style: TextStyle(color: cs.primary)),
            ),
          ],
          const _SectionHeader('存储文件夹'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: TextField(
              controller: _folderCtrl,
              decoration: const InputDecoration(
                labelText: '文件夹名称',
                hintText: 'literead',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => _update((c) => c.copyWith(folderName: v)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '备份文件（含设备名与时间）放在此文件夹下，'
              '书籍文件、进度、封面分别存放在 book/、progress/、covers/ 子文件夹。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const _SectionHeader('备份目标'),
          for (final t in BackupTargetType.values)
            ListTile(
              dense: true,
              leading: Icon(
                _cfg.type == t
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: _cfg.type == t
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(t.label),
              onTap: () => _update((c) => c.copyWith(type: t)),
            ),
          ..._buildTargetConfig(),
          const _SectionHeader('操作'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _runOp('备份', (svc, s) => svc.backup(s)),
                  icon: const Icon(Icons.upload_outlined),
                  label: const Text('立即备份'),
                ),
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: _busy
                      ? null
                      : () => _runOp('同步', (svc, s) => svc.sync(s)),
                  icon: const Icon(Icons.sync_outlined),
                  label: const Text('同步（自动检索差异）'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _onRestore,
                  icon: const Icon(Icons.restore_outlined),
                  label: const Text('从备份恢复'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTargetConfig() {
    switch (_cfg.type) {
      case BackupTargetType.local:
        return [
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('备份位置'),
            subtitle: Text(
              _cfg.localPath.isEmpty ? '未选择（点击选择目录）' : _cfg.localPath,
            ),
            onTap: _pickLocalDir,
          ),
        ];
      case BackupTargetType.webdav:
        return [
          _TextField(
            controller: _webdavUrlCtrl,
            label: '服务器地址',
            hint: 'https://dav.example.com/dav/',
            onChanged: (v) => _update((c) => c.copyWith(webdavUrl: v)),
          ),
          _TextField(
            controller: _webdavUserCtrl,
            label: '账号（可选）',
            onChanged: (v) => _update((c) => c.copyWith(webdavUser: v)),
          ),
          _TextField(
            controller: _webdavPassCtrl,
            label: '密码（可选）',
            obscure: true,
            onChanged: (v) => _update((c) => c.copyWith(webdavPass: v)),
          ),
        ];
      case BackupTargetType.s3:
        return [
          _TextField(
            controller: _s3EndpointCtrl,
            label: '端点 Endpoint',
            hint: 'https://s3.example.com',
            onChanged: (v) => _update((c) => c.copyWith(s3Endpoint: v)),
          ),
          _TextField(
            controller: _s3BucketCtrl,
            label: '存储桶 Bucket',
            onChanged: (v) => _update((c) => c.copyWith(s3Bucket: v)),
          ),
          _TextField(
            controller: _s3KeyCtrl,
            label: 'Access Key',
            onChanged: (v) => _update((c) => c.copyWith(s3AccessKey: v)),
          ),
          _TextField(
            controller: _s3SecretCtrl,
            label: 'Secret Key',
            obscure: true,
            onChanged: (v) => _update((c) => c.copyWith(s3SecretKey: v)),
          ),
          _TextField(
            controller: _s3RegionCtrl,
            label: '区域 Region',
            hint: 'us-east-1',
            onChanged: (v) => _update((c) => c.copyWith(s3Region: v)),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('路径风格（Path-Style）'),
            subtitle: const Text('MinIO / R2 / 自建服务开启；AWS 关闭'),
            value: _cfg.s3PathStyle,
            onChanged: (v) => _update((c) => c.copyWith(s3PathStyle: v)),
          ),
        ];
      case BackupTargetType.lan:
        return _buildLanConfig();
    }
  }

  List<Widget> _buildLanConfig() {
    final server = ref.read(lanSyncServerProvider);
    return [
      SwitchListTile(
        title: const Text('共享本机书库'),
        subtitle: Text(
          _sharing
              ? '端口 ${server.port} 已开放，其他设备可扫描到本机'
              : '开启后开放端口，供其他 LiteRead 设备扫描连接',
        ),
        value: _sharing,
        onChanged: _busy ? null : _toggleSharing,
      ),
      ListTile(
        leading: _scanning
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_find_outlined),
        title: const Text('扫描局域网设备'),
        subtitle: const Text('自动发现开启共享的 LiteRead 设备'),
        onTap: _scanning ? null : _scanDevices,
      ),
      for (final d in _devices)
        ListTile(
          dense: true,
          leading: Icon(
            _cfg.lanAddress == d.address && _cfg.lanPort == d.port
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            color: _cfg.lanAddress == d.address && _cfg.lanPort == d.port
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          title: Text(d.name),
          subtitle: Text('${d.address}:${d.port}'),
          trailing: const Icon(Icons.devices_other_outlined),
          onTap: () => _update(
            (c) => c.copyWith(lanAddress: d.address, lanPort: d.port),
          ),
        ),
      if (_cfg.lanAddress.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '当前选择：${_cfg.lanAddress}:${_cfg.lanPort}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    required this.onChanged,
    this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: onChanged,
      ),
    );
  }
}
