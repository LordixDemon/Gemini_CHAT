import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/remote_models.dart';
import '../theme/telemetry_theme.dart';

class DiscoveredBridgeCard extends StatelessWidget {
  final DiscoveredLanBridge bridge;
  final bool isAlreadyPaired;
  final VoidCallback onTap;

  const DiscoveredBridgeCard({
    super.key,
    required this.bridge,
    required this.isAlreadyPaired,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cleanName = TelemetryFormatters.cleanMachineName(bridge.machineName);
    return Material(
      color: TelemetryColors.bgPanel,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: TelemetryColors.live.withValues(alpha: 0.38)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: TelemetryColors.live.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.wifi_tethering_rounded,
                  color: TelemetryColors.live,
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cleanName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${bridge.lanIp}:${bridge.port} • ${bridge.source.toUpperCase()}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: TelemetryColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: isAlreadyPaired
                      ? TelemetryColors.live.withValues(alpha: 0.18)
                      : TelemetryColors.bgElevated,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: isAlreadyPaired
                        ? TelemetryColors.live.withValues(alpha: 0.45)
                        : TelemetryColors.borderStrong,
                  ),
                ),
                child: Text(
                  isAlreadyPaired ? 'Войти' : 'Выбрать',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isAlreadyPaired ? TelemetryColors.live : TelemetryColors.accentBright,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SavedMachineCard extends StatelessWidget {
  final SavedMachine machine;
  final bool isOnlineLan;
  final bool isConnecting;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;

  const SavedMachineCard({
    super.key,
    required this.machine,
    this.isOnlineLan = false,
    this.isConnecting = false,
    required this.busy,
    required this.onConnect,
    this.onEdit,
    required this.onDelete,
  });

  String _compactHost() {
    if (machine.lanUrl.isNotEmpty) {
      return machine.lanUrl.replaceFirst(RegExp(r'^https?://'), '');
    }
    if (machine.cloudflareUrl.isNotEmpty) {
      return machine.cloudflareUrl.replaceFirst(RegExp(r'^https?://'), '');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final cleanName = TelemetryFormatters.cleanMachineName(machine.machineName);
    final lastSeen = TelemetryFormatters.relativeTime(machine.lastConnectedAtMs);
    final hasLan = machine.lanUrl.isNotEmpty;
    final hasCf = machine.cloudflareUrl.isNotEmpty;
    final hostLabel = _compactHost();

    final Color statusColor;
    final String statusText;
    if (isOnlineLan) {
      statusColor = TelemetryColors.live;
      statusText = 'В сети';
    } else if (hasCf) {
      statusColor = TelemetryColors.cyan;
      statusText = 'Cloudflare';
    } else {
      statusColor = TelemetryColors.textDim;
      statusText = 'Офлайн';
    }

    final isFlutterTest = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

    return Material(
      color: TelemetryColors.bgPanel,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: (busy || isConnecting) ? null : onConnect,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isOnlineLan
                  ? TelemetryColors.live.withValues(alpha: 0.42)
                  : TelemetryColors.borderStrong,
              width: isOnlineLan ? 1.2 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: (isOnlineLan ? TelemetryColors.live : TelemetryColors.accent)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      Icons.laptop_mac_rounded,
                      color: isOnlineLan ? TelemetryColors.live : TelemetryColors.accentBright,
                      size: 22,
                    ),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor,
                        border: Border.all(color: TelemetryColors.bgPanel, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            cleanName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (hostLabel.isNotEmpty)
                          Flexible(
                            child: Text(
                              hostLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: TelemetryColors.textSecondary,
                              ),
                            ),
                          ),
                        if (lastSeen.isNotEmpty) ...[
                          if (hostLabel.isNotEmpty)
                            const Text(
                              ' • ',
                              style: TextStyle(fontSize: 11.5, color: TelemetryColors.textDim),
                            ),
                          Text(
                            lastSeen,
                            style: const TextStyle(fontSize: 11.5, color: TelemetryColors.textDim),
                          ),
                        ],
                      ],
                    ),
                    if (hasLan || hasCf) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (hasLan)
                            _TransportBadge(
                              label: 'LAN',
                              active: isOnlineLan,
                              color: TelemetryColors.live,
                            ),
                          if (hasLan && hasCf) const SizedBox(width: 5),
                          if (hasCf)
                            const _TransportBadge(
                              label: 'CF',
                              active: true,
                              color: TelemetryColors.cyan,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (isConnecting)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: isFlutterTest ? 0.65 : null,
                      color: TelemetryColors.accentBright,
                    ),
                  ),
                )
              else ...[
                PopupMenuButton<String>(
                  tooltip: 'Действия',
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    size: 19,
                    color: TelemetryColors.textSecondary,
                  ),
                  onSelected: (action) {
                    if (action == 'connect') {
                      onConnect();
                    } else if (action == 'edit') {
                      onEdit?.call();
                    } else if (action == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'connect',
                      child: Row(
                        children: [
                          Icon(Icons.login_rounded, size: 18),
                          SizedBox(width: 10),
                          Text('Подключиться'),
                        ],
                      ),
                    ),
                    if (onEdit != null)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined, size: 18),
                            SizedBox(width: 10),
                            Text('Изменить'),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline_rounded, size: 18, color: TelemetryColors.danger),
                          SizedBox(width: 10),
                          Text('Удалить', style: TextStyle(color: TelemetryColors.danger)),
                        ],
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: isOnlineLan ? TelemetryColors.live : TelemetryColors.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Войти',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isOnlineLan ? const Color(0xFF031B11) : Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TransportBadge extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;

  const _TransportBadge({
    required this.label,
    required this.active,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = active ? color : TelemetryColors.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: c,
        ),
      ),
    );
  }
}
