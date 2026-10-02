import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme_controller.dart';
import '../../../core/ui/app_snackbar.dart';
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

  // ---- 操作进度（t10：进度动画 + 百分比） ----
  int _opDone = 0;
  int _opTotal = 0;
  String _opPhase = '';

  bool _scanning = false;
  List<LanDevice> _devices = const [];
  bool _sharing = false;

  late final TextEditingController _localPathCtrl;
  late final TextEditingController _lanAddrCtrl;
  late final TextEditingController _webdavUrlCtrl;
  late final TextEditingController _webdavUserCtrl;
  late final TextEditingController _webdavPassCtrl;
  late final TextEditingController _s3EndpointCtrl;
  late final TextEditingController _s3BucketCtrl;
  late final TextEditingController _s3KeyCtrl;
  late final TextEditingController _s3SecretCtrl;
  late final TextEditingController _s3RegionCtrl;

  /// 默认备份路径（留空时使用，页面提示用）
  String _defaultPathHint = '';

  @override
  void initState() {
    super.initState();
    _localPathCtrl = TextEditingController();
    _lanAddrCtrl = TextEditingController();
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
    _localPathCtrl.dispose();
    _lanAddrCtrl.dispose();
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
    final defPath = await defaultBackupPath();
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _localPathCtrl.text = cfg.localPath;
      _defaultPathHint = defPath;
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
    _autoScanIfNeeded();
  }

  void _update(BackupConfig Function(BackupConfig) fn) {
    setState(() => _cfg = fn(_cfg));
    _cfg.save(ref.read(appDatabaseProvider));
  }

  void _toast(String msg) {
    if (!mounted) return;
    showAppSnackBar(context, msg);
  }

  String get _rootName =>
      _cfg.folderName.trim().isEmpty ? 'LiteRead' : _cfg.folderName.trim();

  /// 按当前配置构建存储目标；配置不完整时提示并返回 null
  Future<RemoteStore?> _safeStore() async {
    try {
      return await _buildStore();
    } on BackupException catch (e) {
      _toast(e.message);
      return null;
    }
  }

  Future<RemoteStore> _buildStore() async {
    switch (_cfg.type) {
      case BackupTargetType.local:
        // 路径留空 → 默认目录；目录不存在时备份流程会自动逐级创建
        var path = _cfg.localPath.trim();
        if (path.isEmpty) path = await defaultBackupPath();
        return LocalFolderStore(Directory(path), '');
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

  /// 进度回调：同步操作步数到状态（含百分比），驱动进度条动画
  BackupProgressCallback get _onProgress => (done, total, phase) {
    if (!mounted) return;
    setState(() {
      _opDone = done;
      _opTotal = total;
      _opPhase = phase;
    });
  };

  /// 当前忽略列表选项
  BackupOptions get _opts => _cfg.toOptions();

  void _resetProgress() {
    _opDone = 0;
    _opTotal = 0;
    _opPhase = '';
  }

  Future<void> _runOp(
    String title,
    Future<BackupResult> Function(
      BackupService,
      RemoteStore,
      BackupProgressCallback,
    )
    op,
  ) async {
    final store = await _safeStore();
    if (store == null) return;
    setState(() {
      _busy = true;
      _busyText = title;
      _resetProgress();
    });
    final prog = _OpProgress();
    String? resultMsg;
    try {
      final shown = _showProgressDialog(title, prog);
      try {
        final r = await op(ref.read(backupServiceProvider), store, (
          done,
          total,
          phase,
        ) {
          prog.update(done, total, phase);
          if (mounted) {
            setState(() {
              _opDone = done;
              _opTotal = total;
              _opPhase = phase;
            });
          }
        });
        resultMsg = '${r.summary()}（$title完成）';
      } finally {
        await _closeProgressDialog(shown);
      }
    } catch (e) {
      resultMsg = '$title失败：$e';
    } finally {
      prog.dispose();
      await store.dispose();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    _toast(resultMsg);
  }

  /// 操作进度弹窗（不可手动关闭，操作完成后自动关闭）。
  /// 返回对话框 Future，供关闭时等待退场动画结束。
  Future<void> _showProgressDialog(String title, _OpProgress prog) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('$title中…'),
          content: ListenableBuilder(
            listenable: Listenable.merge([prog.done, prog.total, prog.phase]),
            builder: (ctx, _) {
              final total = prog.total.value;
              final done = prog.done.value;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prog.phase.value.isEmpty ? '准备中…' : prog.phase.value,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      total > 0 ? '$done / $total' : '',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 关闭进度弹窗并等待退场动画完成（保证 toast 在弹窗关闭后弹出）
  Future<void> _closeProgressDialog(Future<void> shown) async {
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) nav.pop();
    await shown;
  }

  Future<void> _onRestore() async {
    final store = await _safeStore();
    if (store == null) return;
    setState(() {
      _busy = true;
      _busyText = '读取备份清单';
    });
    List<(String, BackupManifest)> manifests;
    try {
      manifests = await ref.read(backupServiceProvider).listManifests(store);
    } catch (e) {
      await store.dispose();
      if (mounted) {
        setState(() => _busy = false);
      }
      _toast('读取备份清单失败：$e');
      return;
    }
    if (!mounted) {
      await store.dispose();
      return;
    }
    if (manifests.isEmpty) {
      setState(() => _busy = false);
      await store.dispose();
      _toast('远端没有找到备份清单');
      return;
    }
    final name = await _pickManifest(manifests);
    if (name == null) {
      await store.dispose();
      if (mounted) {
        setState(() => _busy = false);
      }
      return;
    }
    if (mounted) {
      setState(() => _busyText = '正在恢复');
    }

    final prog = _OpProgress();
    String resultMsg;
    try {
      final shown = _showProgressDialog('恢复', prog);
      try {
        final r = await ref
            .read(backupServiceProvider)
            .restore(
              store,
              manifestName: name,
              onProgress: (done, total, phase) {
                prog.update(done, total, phase);
                if (mounted) {
                  setState(() {
                    _opDone = done;
                    _opTotal = total;
                    _opPhase = phase;
                  });
                }
              },
              opts: _opts,
            );
        resultMsg = '恢复完成：${r.summary()}';
      } finally {
        await _closeProgressDialog(shown);
      }
    } catch (e) {
      resultMsg = '恢复失败：$e';
    } finally {
      prog.dispose();
      await store.dispose();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    _toast(resultMsg);
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
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_fmtTime(m.createdAt)} · ${m.books.length} 本书籍'),
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(ctx).colorScheme.outline,
                      ),
                    ),
                  ],
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
        _toast(
          '未发现局域网设备：请确认对端已开启「共享本机书库」、'
          '两台设备连同一网络${Platform.isWindows ? '，并尝试下方「防火墙放行」' : ''}',
        );
      }
    } catch (e) {
      _toast('扫描失败：$e');
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  /// 手动输入设备地址直连（扫描被路由器/防火墙拦截时的兜底）
  Future<void> _connectManual() async {
    if (_busy) return;
    final raw = _lanAddrCtrl.text.trim();
    if (raw.isEmpty) {
      _toast('请输入设备地址，例如 192.168.1.100');
      return;
    }
    var host = raw;
    var port = lanSyncPort;
    final idx = raw.lastIndexOf(':');
    if (idx > 0 && !raw.startsWith('[')) {
      host = raw.substring(0, idx);
      port = int.tryParse(raw.substring(idx + 1)) ?? lanSyncPort;
    }
    setState(() => _busy = true);
    try {
      final device = await LanStorePing.ping(host, port);
      if (!mounted) return;
      if (device == null) {
        _toast('连接失败：$host 未响应，请确认对端已开启共享且地址正确');
        return;
      }
      await _confirmSyncWithDevice(device);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Windows 防火墙放行（UAC 提权添加入站允许规则）
  Future<void> _allowFirewall() async {
    _toast('正在请求管理员权限添加防火墙规则…');
    final err = await LanScanner.allowThroughWindowsFirewall();
    _toast(err ?? '防火墙已放行，其他设备现在可以扫描到本机了');
  }

  /// 进入局域网配置或首次加载时自动扫描一次
  void _autoScanIfNeeded() {
    if (_cfg.type == BackupTargetType.lan &&
        _devices.isEmpty &&
        !_scanning &&
        !_busy) {
      _scanDevices();
    }
  }

  /// 点按设备：读取对端清单 → 弹出同步确认对话框 → 执行确认的动作
  Future<void> _confirmSyncWithDevice(LanDevice d) async {
    final svc = ref.read(backupServiceProvider);
    // 记住选中设备（「同步」按钮也可对它使用）
    _update((c) => c.copyWith(lanAddress: d.address, lanPort: d.port));

    setState(() {
      _busy = true;
      _busyText = '连接 ${d.name}…';
    });
    LanDiff? diff;
    LanStore? store;
    try {
      store = LanStore(d.address, d.port);
      diff = await svc.diffWithRemote(store);
    } catch (e) {
      await store?.dispose();
      if (mounted) setState(() => _busy = false);
      _toast('连接设备失败：$e');
      return;
    }
    if (!mounted) {
      await store.dispose();
      return;
    }
    setState(() => _busy = false);

    final plan = await _showSyncConfirmDialog(d, diff);
    if (plan == null || !mounted) {
      await store.dispose();
      return;
    }
    if (!plan.pull &&
        !plan.push &&
        plan.deleteLocalIds.isEmpty &&
        plan.deleteRemoteIds.isEmpty) {
      await store.dispose();
      return;
    }
    setState(() {
      _busy = true;
      _busyText = '正在与 ${d.name} 同步…';
      _resetProgress();
    });
    try {
      final r = await svc.applyLanDiff(
        store,
        diff,
        pull: plan.pull,
        push: plan.push,
        deleteLocalIds: plan.deleteLocalIds.toList(),
        deleteRemoteIds: plan.deleteRemoteIds.toList(),
        onProgress: _onProgress,
      );
      _toast('同步完成：${r.summary()}');
    } catch (e) {
      _toast('同步失败：$e');
    } finally {
      await store.dispose();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 同步确认对话框：拉取 / 推送 / 删除本机多余 / 删除远端指定
  Future<_SyncPlan?> _showSyncConfirmDialog(LanDevice d, LanDiff diff) {
    final plan = _SyncPlan();
    final cs = Theme.of(context).colorScheme;
    return showDialog<_SyncPlan>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          final canSubmit =
              plan.pull ||
              plan.push ||
              plan.deleteLocalIds.isNotEmpty ||
              plan.deleteRemoteIds.isNotEmpty;
          return AlertDialog(
            title: Text('与「${diff.remoteDeviceName}」同步'),
            content: SizedBox(
              width: 420,
              child: ListView(
                shrinkWrap: true,
                children: [
                  CheckboxListTile(
                    dense: true,
                    value: plan.pull,
                    enabled: diff.remoteOnly.isNotEmpty,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      diff.remoteOnly.isEmpty
                          ? '对端没有本机缺少的书籍'
                          : '拉取对端独有书籍（${diff.remoteOnly.length} 本）',
                      style: TextStyle(
                        color: diff.remoteOnly.isEmpty ? cs.outline : null,
                      ),
                    ),
                    onChanged: (v) => setDialog(() => plan.pull = v ?? false),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: plan.push,
                    enabled: diff.localOnly.isNotEmpty,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      diff.localOnly.isEmpty
                          ? '本机没有对端缺少的书籍'
                          : '推送本机独有书籍（${diff.localOnly.length} 本）',
                      style: TextStyle(
                        color: diff.localOnly.isEmpty ? cs.outline : null,
                      ),
                    ),
                    onChanged: (v) => setDialog(() => plan.push = v ?? false),
                  ),
                  if (diff.localOnly.isNotEmpty)
                    Theme(
                      data: Theme.of(
                        ctx,
                      ).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 4),
                        title: Text(
                          '删除本机多余书籍（已选 ${plan.deleteLocalIds.length}）',
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          '谨慎勾选：将同时删除进度与标注',
                          style: TextStyle(fontSize: 12),
                        ),
                        children: [
                          for (final b in diff.localOnly)
                            CheckboxListTile(
                              dense: true,
                              value: plan.deleteLocalIds.contains(b.id),
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                b.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              onChanged: (v) => setDialog(() {
                                v == true
                                    ? plan.deleteLocalIds.add(b.id)
                                    : plan.deleteLocalIds.remove(b.id);
                              }),
                            ),
                        ],
                      ),
                    ),
                  if (diff.remoteOnly.isNotEmpty)
                    Theme(
                      data: Theme.of(
                        ctx,
                      ).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 4),
                        title: Text(
                          '删除对端指定书籍（已选 ${plan.deleteRemoteIds.length}）',
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          '将在「${diff.remoteDeviceName}」上删除所选书籍',
                          style: const TextStyle(fontSize: 12),
                        ),
                        children: [
                          for (final b in diff.remoteOnly)
                            CheckboxListTile(
                              dense: true,
                              value: plan.deleteRemoteIds.contains(b['id']),
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                '${b['title'] ?? '未命名'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              onChanged: (v) => setDialog(() {
                                final id = b['id'] as String;
                                v == true
                                    ? plan.deleteRemoteIds.add(id)
                                    : plan.deleteRemoteIds.remove(id);
                              }),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: canSubmit ? () => Navigator.pop(ctx, plan) : null,
                icon: const Icon(Icons.sync_outlined, size: 18),
                label: const Text('开始同步'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickLocalDir() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择备份位置',
    );
    if (path != null) {
      _localPathCtrl.text = path;
      _update((c) => c.copyWith(localPath: path));
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      // 条目9：备份/恢复进行中不可直接退出，防止误触打断操作
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_busy) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('退出确认'),
            content: Text('「$_busyText」正在进行，退出可能会打断操作，导致备份/恢复不完整。确定要退出吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('继续等待'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('退出'),
              ),
            ],
          ),
        );
        if (ok == true && mounted) {
          // 操作本身不中断（后台继续），仅允许离开页面
          // ignore:use_build_context_synchronously
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('备份与恢复')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (_busy) ...[
              // 进度条：已知总步数时显示确定进度与百分比，否则走动画
              LinearProgressIndicator(
                minHeight: 3,
                value: _opTotal > 0
                    ? (_opDone / _opTotal).clamp(0.0, 1.0)
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _opPhase.isNotEmpty ? _opPhase : _busyText,
                        style: TextStyle(color: cs.primary),
                      ),
                    ),
                    if (_opTotal > 0)
                      Text(
                        '${(_opDone / _opTotal * 100).toStringAsFixed(0)}%'
                        ' · $_opDone/$_opTotal',
                        style: TextStyle(
                          color: cs.primary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (_cfg.type == BackupTargetType.local) ...[
              const _SectionHeader('存储文件夹'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: TextField(
                  controller: _localPathCtrl,
                  decoration: InputDecoration(
                    hintText: _defaultPathHint.isEmpty
                        ? '留空使用默认备份文件夹'
                        : '留空使用 $_defaultPathHint',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: '选择文件夹',
                      icon: const Icon(Icons.folder_open_outlined),
                      onPressed: _pickLocalDir,
                    ),
                  ),
                  onChanged: (v) =>
                      _update((c) => c.copyWith(localPath: v.trim())),
                ),
              ),
            ],
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
                onTap: () {
                  _update((c) => c.copyWith(type: t));
                  if (t == BackupTargetType.lan) {
                    _autoScanIfNeeded();
                  }
                },
              ),
            ..._buildTargetConfig(),
            // 忽略列表入口：点击弹窗查看/编辑（勾选的数据不参与备份与恢复）
            ListTile(
              dense: true,
              leading: const Icon(Icons.filter_alt_outlined),
              title: const Text('忽略列表'),
              subtitle: const Text('选择不参与备份与恢复的数据'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showIgnoreList,
            ),
            const _SectionHeader('操作'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runOp(
                            '备份',
                            (svc, s, cb) =>
                                svc.backup(s, onProgress: cb, opts: _opts),
                          ),
                    icon: const Icon(Icons.upload_outlined),
                    label: const Text('立即备份'),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: _busy
                        ? null
                        : () => _runOp(
                            '同步',
                            (svc, s, cb) =>
                                svc.sync(s, onProgress: cb, opts: _opts),
                          ),
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
      ),
    );
  }

  /// 忽略列表弹窗：勾选的数据不参与备份与恢复
  Future<void> _showIgnoreList() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('忽略列表'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '勾选的数据不参与备份与恢复（例如换机时不覆盖本机设置）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('主题设置'),
                  value: _cfg.ignoreTheme,
                  onChanged: (v) {
                    _update((c) => c.copyWith(ignoreTheme: v));
                    setDialog(() {});
                  },
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('阅读界面设置'),
                  value: _cfg.ignoreReader,
                  onChanged: (v) {
                    _update((c) => c.copyWith(ignoreReader: v));
                    setDialog(() {});
                  },
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('阅读统计'),
                  value: _cfg.ignoreStats,
                  onChanged: (v) {
                    _update((c) => c.copyWith(ignoreStats: v));
                    setDialog(() {});
                  },
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('本机备份配置'),
                  subtitle: const Text('包含备份目标地址、账号等，恢复时保留本机填写的内容'),
                  value: _cfg.ignoreBackupCfg,
                  isThreeLine: true,
                  onChanged: (v) {
                    _update((c) => c.copyWith(ignoreBackupCfg: v));
                    setDialog(() {});
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTargetConfig() {
    switch (_cfg.type) {
      case BackupTargetType.local:
        // 存储文件夹路径输入在页面顶部「存储文件夹」区（输入即备份位置）
        return const [];
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
      // 手动地址直连（扫描被路由器/防火墙拦截时的兜底）
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _lanAddrCtrl,
                decoration: const InputDecoration(
                  labelText: '设备地址',
                  hintText: '192.168.1.100 或 192.168.1.100:47816',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _connectManual(),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : _connectManual,
              child: const Text('连接'),
            ),
          ],
        ),
      ),
      if (Platform.isWindows)
        ListTile(
          dense: true,
          leading: const Icon(Icons.security_outlined),
          title: const Text('防火墙放行'),
          subtitle: const Text('其他设备扫描不到本机时点击（需管理员权限）'),
          onTap: _allowFirewall,
        ),
      for (final d in _devices)
        ListTile(
          dense: true,
          leading: Icon(
            _cfg.lanAddress == d.address && _cfg.lanPort == d.port
                ? Icons.computer
                : Icons.computer_outlined,
            color: _cfg.lanAddress == d.address && _cfg.lanPort == d.port
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          title: Text(d.name),
          subtitle: Text('${d.address}:${d.port}'),
          trailing: const Icon(Icons.sync_outlined),
          onTap: _busy ? null : () => _confirmSyncWithDevice(d),
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

/// 局域网同步计划：用户在确认对话框中勾选的动作
class _SyncPlan {
  bool pull = false;
  bool push = false;
  final deleteLocalIds = <String>{};
  final deleteRemoteIds = <String>{};
}

/// 操作进度（备份/恢复弹窗用）：ValueNotifier 三件套驱动对话框刷新
class _OpProgress {
  final done = ValueNotifier<int>(0);
  final total = ValueNotifier<int>(0);
  final phase = ValueNotifier<String>('');

  void update(int d, int t, String p) {
    done.value = d;
    total.value = t;
    phase.value = p;
  }

  void dispose() {
    done.dispose();
    total.dispose();
    phase.dispose();
  }
}
