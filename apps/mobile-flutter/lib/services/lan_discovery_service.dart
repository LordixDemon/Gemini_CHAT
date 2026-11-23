import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/remote_models.dart';

/// Discovers Antigravity Remote Bridge instances on the local Wi-Fi network via:
/// 1. UDP Broadcast (`AGY_REMOTE_DISCOVER_V1` on port 7445)
/// 2. Android `NsdManager` mDNS/Bonjour (`_agy-remote._tcp.`)
/// 3. `/api/ping` verification (also heals DHCP IP changes automatically)
class LanDiscoveryService {
  static const int defaultDiscoveryUdpPort = 7445;
  static const String discoveryProbeMagic = 'AGY_REMOTE_DISCOVER_V1';
  static const MethodChannel _androidChannel = MethodChannel('dev.antigravity.remote/android');

  final http.Client? _injectedClient;
  final http.Client Function()? httpClientProvider;
  final Future<List<DiscoveredLanBridge>> Function()? customScanner;

  LanDiscoveryService({
    http.Client? httpClient,
    this.httpClientProvider,
    this.customScanner,
  }) : _injectedClient = httpClient;

  Future<List<DiscoveredLanBridge>> discover({
    Duration timeout = const Duration(milliseconds: 1150),
    int udpPort = defaultDiscoveryUdpPort,
  }) async {
    if (customScanner != null) {
      return customScanner!();
    }
    if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
      return const <DiscoveredLanBridge>[];
    }

    final results = <String, DiscoveredLanBridge>{};

    try {
      await Future.wait<void>([
        _discoverViaUdpBroadcast(timeout: timeout, udpPort: udpPort, out: results),
        _discoverViaNativeMdns(timeout: timeout, out: results),
      ]).timeout(timeout + const Duration(milliseconds: 900));
    } catch (_) {}

    return results.values.toList()
      ..sort((a, b) => a.machineName.toLowerCase().compareTo(b.machineName.toLowerCase()));
  }

  Future<void> _discoverViaUdpBroadcast({
    required Duration timeout,
    required int udpPort,
    required Map<String, DiscoveredLanBridge> out,
  }) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      sub = socket.listen((event) {
        if (event != RawSocketEvent.read || socket == null) return;
        Datagram? dg;
        while ((dg = socket.receive()) != null) {
          try {
            final text = utf8.decode(dg!.data, allowMalformed: true);
            final map = jsonDecode(text) as Map<String, dynamic>;
            if (map['type'] != 'bridge.beacon') continue;
            final port = (map['port'] as num?)?.toInt() ?? 7443;
            final ip = dg.address.address.isNotEmpty
                ? dg.address.address
                : (map['lanIp'] ?? '').toString();
            if (ip.isEmpty || port <= 0) continue;
            final machineId = (map['machineId'] ?? '').toString();
            final machineName = (map['machineName'] ?? ip).toString();
            final lanUrl = 'http://$ip:$port';
            final key = machineId.isNotEmpty ? machineId : lanUrl;
            out[key] = DiscoveredLanBridge(
              machineId: machineId,
              machineName: machineName,
              lanUrl: lanUrl,
              lanIp: ip,
              port: port,
              source: 'udp',
            );
          } catch (_) {}
        }
      });

      final targets = await _collectBroadcastTargets();
      final payload = utf8.encode(discoveryProbeMagic);

      void sendProbeBurst() {
        for (final addr in targets) {
          try {
            socket?.send(payload, addr, udpPort);
          } catch (_) {}
        }
      }

      sendProbeBurst();
      final halfMs = (timeout.inMilliseconds * 0.45).round().clamp(120, 600);
      await Future<void>.delayed(Duration(milliseconds: halfMs));
      sendProbeBurst();
      final remMs = (timeout.inMilliseconds - halfMs).clamp(100, 2000);
      await Future<void>.delayed(Duration(milliseconds: remMs));
    } catch (_) {
      // Ignore socket permission / network unavailable errors
    } finally {
      await sub?.cancel();
      socket?.close();
    }
  }

  Future<List<InternetAddress>> _collectBroadcastTargets() async {
    final targets = <String, InternetAddress>{
      '255.255.255.255': InternetAddress('255.255.255.255'),
    };
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final subnetBcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            targets[subnetBcast] = InternetAddress(subnetBcast);
          }
        }
      }
    } catch (_) {}
    return targets.values.toList();
  }

  Future<void> _discoverViaNativeMdns({
    required Duration timeout,
    required Map<String, DiscoveredLanBridge> out,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final rawList = await _androidChannel
          .invokeMethod<List<dynamic>>(
            'discoverMdns',
            {'timeoutMs': timeout.inMilliseconds},
          )
          .timeout(
            timeout + const Duration(milliseconds: 600),
            onTimeout: () => null,
          );
      if (rawList == null) return;

      final verifyFutures = <Future<void>>[];
      final ownsClient = _injectedClient == null && httpClientProvider == null;
      final client = httpClientProvider?.call() ?? _injectedClient ?? http.Client();
      try {
        for (final item in rawList) {
          if (item is! Map) continue;
          final host = (item['host'] ?? '').toString().trim();
          final port = (item['port'] as num?)?.toInt() ?? 0;
          if (host.isEmpty || port <= 0) continue;
          final lanUrl = 'http://$host:$port';
          final initialId = (item['machineId'] ?? '').toString();
          final initialName = (item['machineName'] ?? host).toString();

          verifyFutures.add(() async {
            var resolvedId = initialId;
            var resolvedName = initialName;
            try {
              final res = await client
                  .get(Uri.parse('$lanUrl/api/ping'))
                  .timeout(const Duration(milliseconds: 900));
              if (res.statusCode == 200) {
                final ping = jsonDecode(res.body) as Map<String, dynamic>;
                resolvedId = (ping['machineId'] ?? resolvedId).toString();
                resolvedName = (ping['machineName'] ?? resolvedName).toString();
              }
            } catch (_) {}
            final key = resolvedId.isNotEmpty ? resolvedId : lanUrl;
            out.putIfAbsent(
              key,
              () => DiscoveredLanBridge(
                machineId: resolvedId,
                machineName: resolvedName,
                lanUrl: lanUrl,
                lanIp: host,
                port: port,
                source: 'mdns',
              ),
            );
          }());
        }
        await Future.wait(verifyFutures);
      } finally {
        if (ownsClient) {
          client.close();
        }
      }
    } catch (_) {
      // MissingPluginException in tests or unsupported device
    }
  }
}
