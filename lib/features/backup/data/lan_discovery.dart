import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 局域网同步服务端口（发现 UDP 与 HTTP 服务共用同一端口段约定）
const lanSyncPort = 47816;

/// 本机局域网 IPv4 地址（排除回环与虚拟网卡），用于展示传书网址。
/// 存在 WiFi 接口（wlan*）时只展示 WiFi 网段，
/// 隐藏蜂窝流量（rmnet*）等局域网内不可达的链接。
Future<List<String>> localIPv4Addresses() async {
  final out = <String>[];
  final wifi = <String>[];
  try {
    for (final ni in await NetworkInterface.list()) {
      final n = ni.name.toLowerCase();
      final virtual =
          n.contains('vethernet') ||
          n.contains('virtualbox') ||
          n.contains('vmware') ||
          n.contains('loopback') ||
          n.contains('wsl') ||
          n.contains('tap') ||
          n.contains('tun') ||
          n.contains('hamachi') ||
          n.contains('hyper-v');
      if (virtual) continue;
      final isWifi = n.startsWith('wlan');
      for (final a in ni.addresses) {
        if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
          out.add(a.address);
          if (isWifi) wifi.add(a.address);
        }
      }
    }
  } catch (_) {}
  // 有 WiFi 连接时只展示 WiFi 网段地址
  return wifi.isNotEmpty ? wifi : out;
}

/// 本机全部 IPv4 地址（含回环与虚拟网卡）：扫描结果据此过滤自身设备
Future<Set<String>> allLocalIPv4s() async {
  final out = <String>{'127.0.0.1'};
  try {
    for (final ni in await NetworkInterface.list()) {
      for (final a in ni.addresses) {
        if (a.type == InternetAddressType.IPv4) out.add(a.address);
      }
    }
  } catch (_) {}
  return out;
}

/// UDP 广播目标：受限广播 + 各物理网卡 /24 定向广播。
/// 发现走 beacon 模式（双方各自周期广播，无需应答回包），
/// 双向广播都要发全，任一方向通即可互相发现。
Future<List<String>> broadcastAddresses() async {
  final targets = <String>{'255.255.255.255'};
  try {
    for (final ni in await NetworkInterface.list()) {
      if (LanScanner._isVirtualInterface(ni.name)) continue;
      for (final a in ni.addresses) {
        if (a.type != InternetAddressType.IPv4 || a.isLoopback) continue;
        final parts = a.address.split('.');
        if (parts.length != 4) continue;
        targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
      }
    }
  } catch (_) {}
  return targets.toList();
}

/// 局域网设备信息
class LanDevice {
  const LanDevice({
    required this.address,
    required this.port,
    required this.name,
    this.addrs = const [],
  });

  final String address;
  final int port;
  final String name;

  /// 对端报告的本机全部地址（用于扫描端排除自身设备，
  /// 以及连接失败时换用其他网卡地址重试）
  final List<String> addrs;
}

/// 局域网设备扫描：UDP 广播 + UDP 单播扫射 + TCP 端口探测三法并发、结果合并。
/// 手动输入 IP 可达而扫描不到的常见原因：
/// - 广播被路由器/AP 隔离丢弃 → 单播 UDP 与 TCP 探测仍可达；
/// - 入站 UDP 被防火墙拦截 → TCP 探测仍可达（与手动连接同一通道）。
class LanScanner {
  /// 扫描局域网设备（约 3 秒）。
  /// UDP 发现的设备会补一次 ping 以获取对端全部网卡地址（[LanDevice.addrs]），
  /// 连接阶段的多地址回退依赖该信息。
  static Future<List<LanDevice>> scan() async {
    final devices = <String, LanDevice>{};
    final results = await Future.wait([_udpSweep(), _tcpScan()]);
    for (final list in results) {
      for (final d in list) {
        devices['${d.address}:${d.port}'] = d;
      }
    }
    // TCP 探测结果自带 addrs；UDP 发现的补 ping 充实 addrs
    final out = <LanDevice>[];
    await Future.wait(
      devices.values.map((d) async {
        if (d.addrs.isNotEmpty) {
          out.add(d);
          return;
        }
        try {
          final v = await LanStorePing.ping(d.address, d.port);
          out.add(v ?? d);
        } catch (_) {
          out.add(d);
        }
      }),
    );
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// 连接前地址仲裁：优先原地址，逐个 ping 设备上报的全部地址
  /// （多网卡/VPN/热点场景下，扫描得到的应答源地址可能不可达，
  /// 对端其他接口地址仍可连）。全部不通返回 null。
  static Future<LanDevice?> resolveReachable(LanDevice d) async {
    final tried = <String>{};
    for (final addr in [d.address, ...d.addrs]) {
      if (!tried.add(addr)) continue;
      try {
        final v = await LanStorePing.ping(addr, d.port);
        if (v != null) return v;
      } catch (_) {}
    }
    return null;
  }

  /// 是否虚拟/回环网卡（WSL、虚拟机、VPN TAP 等，子网内不会有同步设备）
  static bool _isVirtualInterface(String name) {
    final n = name.toLowerCase();
    return n.contains('vethernet') ||
        n.contains('virtualbox') ||
        n.contains('vmware') ||
        n.contains('loopback') ||
        n.contains('wsl') ||
        n.contains('tap') ||
        n.contains('tun') ||
        n.contains('hamachi') ||
        n.contains('hyper-v');
  }

  /// 本机物理网卡的 /24 网段候选 IP（排除自身与虚拟网卡）
  static Future<List<String>> _candidateIPs() async {
    final localIps = await allLocalIPv4s();
    final prefixes = <String>{};
    try {
      for (final ni in await NetworkInterface.list()) {
        if (_isVirtualInterface(ni.name)) continue;
        for (final a in ni.addresses) {
          if (a.type != InternetAddressType.IPv4 || a.isLoopback) continue;
          final parts = a.address.split('.');
          if (parts.length != 4) continue;
          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    } catch (_) {}
    return [
      for (final prefix in prefixes)
        for (var i = 1; i <= 254; i++)
          if (!localIps.contains('$prefix.$i')) '$prefix.$i',
    ];
  }

  /// UDP 发现：广播 + 对全网段候选 IP 单播扫射（两路并发收应答）
  static Future<List<LanDevice>> _udpSweep() async {
    final out = <LanDevice>[];
    final localIps = await allLocalIPv4s();
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      // 广播地址（各网段定向广播 + 受限广播）
      final broadcastAddrs = <String>{'255.255.255.255'};
      for (final ni in await NetworkInterface.list()) {
        if (_isVirtualInterface(ni.name)) continue;
        for (final a in ni.addresses) {
          if (a.type != InternetAddressType.IPv4) continue;
          final parts = a.address.split('.');
          if (parts.length != 4) continue;
          broadcastAddrs.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      final unicastAddrs = await _candidateIPs();
      final packet = utf8.encode('LITEREAD_DISCOVER');
      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        // 过滤自身应答（广播环回）
        if (localIps.contains(dg.address.address)) return;
        try {
          final j =
              jsonDecode(utf8.decode(dg.data, allowMalformed: true))
                  as Map<String, dynamic>;
          if (j['app'] == 'literead') {
            // 自排除：对端报告的任一地址与本机地址集有交集 → 是自身
            //（应答源地址可能因路由/热点接口而与本机接口枚举不一致）
            final reported = <String>{
              for (final a in (j['addrs'] as List<dynamic>? ?? const []))
                a as String,
            };
            if (reported.any(localIps.contains)) return;
            final key = '${dg.address.address}:${j['port'] ?? lanSyncPort}';
            if (out.any((d) => '${d.address}:${d.port}' == key)) return;
            out.add(
              LanDevice(
                address: dg.address.address,
                port: j['port'] as int? ?? lanSyncPort,
                name: j['name'] as String? ?? '未知设备',
                addrs: [
                  for (final a in (j['addrs'] as List<dynamic>? ?? const []))
                    a as String,
                ],
              ),
            );
          }
        } catch (_) {}
      });
      // 连发 3 轮：广播 + 全网段单播（首轮包常因 ARP/Wi-Fi 省电被丢弃）。
      // 单播扫射绕过「路由器/AP 隔离拦截广播」的常见故障，可靠性显著更高。
      for (var round = 0; round < 3; round++) {
        for (final addr in broadcastAddrs) {
          socket.send(packet, InternetAddress(addr), lanSyncPort);
        }
        for (final addr in unicastAddrs) {
          socket.send(packet, InternetAddress(addr), lanSyncPort);
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      // 再等 400ms 收尾末轮应答
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } catch (_) {
      // UDP 不可用（被防火墙拦截等）时由 TCP 扫描兜底
    } finally {
      unawaited(sub?.cancel());
      socket?.close();
    }
    return out;
  }

  /// TCP 逐 IP 端口探测本机所在 /24 网段（UDP 全挂时的兜底）
  static Future<List<LanDevice>> _tcpScan() async {
    final out = <LanDevice>[];
    final localIps = await allLocalIPv4s();
    final candidates = await _candidateIPs();
    if (candidates.isEmpty) return out;

    var index = 0;
    Future<void> worker() async {
      while (index < candidates.length) {
        final ip = candidates[index++];
        final device = await _probe(ip);
        if (device == null) continue;
        // 自排除：对端报告的地址与本机地址集有交集 → 是自身
        if (device.addrs.any(localIps.contains)) continue;
        out.add(device);
      }
    }

    await Future.wait([for (var i = 0; i < 64; i++) worker()]);
    return out;
  }

  /// 探测单台设备：TCP 连上且 /api/ping 返回 literead 才算命中。
  /// 服务端固定端口被占用时会向后顺延（最多 +9），因此探测基础端口后
  /// 再试一个顺延端口；600ms 连接超时兼顾 Wi-Fi 上的连接建立延迟。
  static Future<LanDevice?> _probe(String ip) async {
    for (var p = lanSyncPort; p <= lanSyncPort + 1; p++) {
      try {
        final socket = await Socket.connect(
          ip,
          p,
          timeout: const Duration(milliseconds: 600),
        );
        socket.destroy();
      } catch (_) {
        continue;
      }
      final device = await LanStorePing.ping(ip, p);
      if (device != null) return device;
    }
    return null;
  }

  /// 确保 Windows 防火墙已放行本应用（入站允许规则）。
  /// 先无提权检查：程序规则指向当前 exe，或端口规则（TCP/UDP 47816 起）
  /// 已存在——端口规则不随便携版换目录失效，优先依赖。
  /// 不满足时经 UAC 提权重建（同名规则 add 前必须 delete）：
  /// 程序规则 + TCP 端口段规则 + UDP 发现端口规则一次装齐。
  /// 返回 null 表示已放行，否则为失败原因。
  static Future<String?> ensureWindowsFirewallRule() async {
    if (!Platform.isWindows) return null;
    const ruleName = 'LiteRead Sync';
    final exe = Platform.resolvedExecutable;

    /// 检查放行规则是否已满足（必须 verbose 才输出 Protocol/LocalPort 字段；
    /// netsh 输出可能按列宽换行，去掉全部空白后比较）
    /// 要求：程序规则（覆盖全部协议/端口），或 TCP+UDP 端口规则同时存在——
    /// 缺 UDP 规则时 beacon 发现会被拦，需重建规则补齐。
    Future<bool> ruleOk() async {
      final check = await Process.run('netsh', [
        'advfirewall',
        'firewall',
        'show',
        'rule',
        'name=$ruleName',
        'verbose',
      ]);
      final flat = (check.stdout as String)
          .replaceAll(RegExp(r'\s'), '')
          .toLowerCase();
      final hasProgram = flat.contains(
        exe.replaceAll(RegExp(r'\s'), '').toLowerCase(),
      );
      final hasTcpPort =
          flat.contains('localport:47816-47825') ||
          flat.contains('localport:47816');
      final hasUdpPort =
          hasTcpPort && flat.contains('protocol:udp');
      return hasProgram || hasUdpPort;
    }

    try {
      if (await ruleOk()) return null;
      // UAC 提权：先 delete 清掉旧规则，再补程序规则 + 端口规则
      final ps =
          'Start-Process -FilePath cmd -Verb RunAs -Wait -ArgumentList '
          "'/c netsh advfirewall firewall delete rule name=\"$ruleName\" & "
          'netsh advfirewall firewall add rule name="$ruleName" dir=in '
          'action=allow program="$exe" enable=yes & '
          'netsh advfirewall firewall add rule name="$ruleName" dir=in '
          'action=allow protocol=TCP localport=47816-47825 & '
          'netsh advfirewall firewall add rule name="$ruleName" dir=in '
          'action=allow protocol=UDP localport=47816 enable=yes\'';
      final r = await Process.run('powershell', ['-Command', ps]);
      if (r.exitCode != 0) {
        final err = (r.stderr as String?) ?? '';
        if (err.contains('canceled') || err.contains('取消')) {
          return '已取消授权（未添加防火墙规则）';
        }
        return '添加防火墙规则失败：$err';
      }
      // 复验规则确实生效（UAC 同意但 netsh 失败的情况）
      return await ruleOk() ? null : '规则添加未生效，请手动在防火墙设置中放行本应用';
    } catch (e) {
      return '防火墙检查失败：$e';
    }
  }
}

/// 独立的 ping 工具（避免与 LanStore 依赖循环）
class LanStorePing {
  /// 返回设备信息；非 LiteRead 设备或不可达时返回 null。
  /// Wi-Fi 省电/ARP 未就绪时首个包易丢，自动重试一次。
  static Future<LanDevice?> ping(String host, int port) async {
    var first = true;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3);
        try {
          final req = await client.getUrl(
            Uri.parse('http://$host:$port/api/ping'),
          );
          final res = await req.close().timeout(const Duration(seconds: 5));
          if (res.statusCode != 200) return null;
          final body = await res.transform(utf8.decoder).join();
          final j = jsonDecode(body) as Map<String, dynamic>;
          if (j['app'] != 'literead') return null;
          return LanDevice(
            address: host,
            port: j['port'] as int? ?? port,
            name: j['name'] as String? ?? '未知设备',
            addrs: [
              for (final a in (j['addrs'] as List<dynamic>? ?? const []))
                a as String,
            ],
          );
        } finally {
          client.close();
        }
      } catch (_) {
        // 仅首轮失败后重试一次
        if (!first) return null;
        first = false;
      }
    }
    return null;
  }
}

/// 连接失败原因 → 用户可读提示（含排查建议）
String lanConnectErrorText(Object e) {
  final s = e.toString();
  if (s.contains('TimedOutException') || s.contains('timed out')) {
    return '设备无响应（超时）。\n请确认两台设备连的是同一个网络（同一 WiFi/热点），'
        '对端已进入「备份 → 局域网设备」（进入即自动开启共享）。';
  }
  if (s.contains('Connection refused') || s.contains('拒绝')) {
    return '设备拒绝连接（端口未开放）。\n请确认对端 LiteRead 已进入「备份 → 局域网设备」'
        '（进入即自动开启共享）。';
  }
  if (s.contains('Network is unreachable') || s.contains('无法访问')) {
    return '网络不可达。\n请检查两台设备是否在同一网段，或改用手动输入 IP 连接。';
  }
  return '连接设备失败：$e';
}

/// 扫描/连接共用的轻量日志（debug 构建可见，便于现场排查）
void lanLog(String message) {
  assert(() {
    debugPrint('[lan] $message');
    return true;
  }());
}
