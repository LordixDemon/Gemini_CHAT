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
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: TelemetryColors.live.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: TelemetryColors.live.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.wifi_tethering_rounded,
                  color: TelemetryColors.live,
                  size: 20,
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
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isAlreadyPaired
                      ? TelemetryColors.live.withValues(alpha: 0.18)
                      : TelemetryColors.bgElevated,
                  borderRadius: BorderRadius.circular(8),
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
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDelete;

  const SavedMachineCard({
    super.key,
    required this.machine,
    required this.busy,
    required this.onConnect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cleanName = TelemetryFormatters.cleanMachineName(machine.machineName);
    final lastSeen = TelemetryFormatters.relativeTime(machine.lastConnectedAtMs);

    return Material(
      color: TelemetryColors.bgPanel,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: busy ? null : onConnect,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: TelemetryColors.borderStrong),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: TelemetryColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.laptop_mac_rounded,
                  color: TelemetryColors.accentBright,
                  size: 21,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cleanName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (machine.lanUrl.isNotEmpty)
                          Flexible(
                            child: Text(
                              machine.lanUrl.replaceFirst(RegExp(r'^https?://'), ''),
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
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Удалить устройство',
                onPressed: onDelete,
                icon: const Icon(Icons.close_rounded, size: 18, color: TelemetryColors.textDim),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: TelemetryColors.accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Text(
                  'Войти',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
