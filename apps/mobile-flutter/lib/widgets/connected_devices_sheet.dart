import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';

Future<void> showConnectedDevicesSheet(
  BuildContext context,
  BridgeController ctrl,
) async {
  HapticFeedback.selectionClick();
  ctrl.requestDevicesList();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.74,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (_, scrollController) => _ConnectedDevicesSheetBody(
        controller: ctrl,
        scrollController: scrollController,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

class _ConnectedDevicesSheetBody extends StatelessWidget {
  final BridgeController controller;
  final ScrollController scrollController;
  final VoidCallback onClose;

  const _ConnectedDevicesSheetBody({
    required this.controller,
    required this.scrollController,
    required this.onClose,
  });

  IconData _platformIcon(String platform) {
    final p = platform.toLowerCase();
    if (p.contains('ios') || p.contains('iphone') || p.contains('ipad')) {
      return Icons.phone_iphone_rounded;
    }
    if (p.contains('web') || p.contains('browser')) {
      return Icons.language_rounded;
    }
    return Icons.phone_android_rounded;
  }

  Future<void> _confirmRevoke(BuildContext context, PairedMobileDevice dev) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отвязать устройство?'),
        content: Text('Отключить и отозвать доступ для «${dev.name}»?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TelemetryColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Отвязать'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      controller.revokePairedDevice(dev.id);
    }
  }

  void _copyEndpoint(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('$label скопирован'),
        duration: const Duration(milliseconds: 1100),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final machine = controller.activeMachine;
        final cleanHost = TelemetryFormatters.cleanMachineName(
          machine?.machineName ?? 'Antigravity Mac',
        );
        final isLive = controller.phase == ConnectionPhase.connected;
        final hasConnError =
            !isLive && controller.lastError != null && controller.lastError!.isNotEmpty;
        final statusColor = isLive
            ? TelemetryColors.live
            : (hasConnError ? TelemetryColors.danger : TelemetryColors.warn);
        final otherMachines = controller.savedMachines
            .where((m) => m.machineId != machine?.machineId)
            .toList();
        final devices = controller.pairedDevices;

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TelemetryColors.borderStrong,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Устройства и подключение',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Обновить список',
                    onPressed: controller.requestDevicesList,
                    icon: const Icon(Icons.refresh_rounded, size: 19),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    // 1. Current Active Computer
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: TelemetryColors.bgElevated,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(
                                  Icons.laptop_mac_rounded,
                                  size: 20,
                                  color: statusColor,
                                ),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      cleanHost,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    ValueListenableBuilder<int?>(
                                      valueListenable: controller.latencyNotifier,
                                      builder: (_, latency, _) {
                                        final pingStr = latency != null ? ' · $latency мс' : '';
                                        return Text(
                                          isLive
                                              ? '${controller.activeTransport}$pingStr • Подключён'
                                              : (hasConnError
                                                    ? 'Ошибка подключения'
                                                    : 'Подключение…'),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: statusColor,
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: TelemetryColors.accentBright,
                                ),
                                onPressed: controller.reconnectNow,
                                icon: const Icon(Icons.sync_rounded, size: 16),
                                label: const Text('Обновить', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                          if (hasConnError) ...[
                            const SizedBox(height: 8),
                            Text(
                              controller.lastError!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFFFECDD3),
                              ),
                            ),
                          ],
                          if (machine != null &&
                              (machine.lanUrl.isNotEmpty || machine.cloudflareUrl.isNotEmpty)) ...[
                            const SizedBox(height: 10),
                            const Divider(height: 1, color: TelemetryColors.border),
                            const SizedBox(height: 8),
                            if (machine.lanUrl.isNotEmpty)
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _copyEndpoint(context, 'LAN адрес', machine.lanUrl),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 3),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.lan_outlined, size: 14, color: TelemetryColors.live),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Text(
                                          machine.lanUrl,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11.5,
                                            color: TelemetryColors.textSecondary,
                                          ),
                                        ),
                                      ),
                                      const Icon(Icons.copy_rounded, size: 13, color: TelemetryColors.textDim),
                                    ],
                                  ),
                                ),
                              ),
                            if (machine.cloudflareUrl.isNotEmpty)
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _copyEndpoint(
                                  context,
                                  'Cloudflare URL',
                                  machine.cloudflareUrl,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 3),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.cloud_outlined, size: 14, color: TelemetryColors.cyan),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Text(
                                          machine.cloudflareUrl,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11.5,
                                            color: TelemetryColors.textSecondary,
                                          ),
                                        ),
                                      ),
                                      const Icon(Icons.copy_rounded, size: 13, color: TelemetryColors.textDim),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),

                    // 2. Paired Mobile Devices on This Mac
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'ПОДКЛЮЧЁННЫЕ УСТРОЙСТВА (${devices.length})',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: TelemetryColors.textDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (devices.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                        decoration: BoxDecoration(
                          color: TelemetryColors.bgElevated,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: TelemetryColors.border),
                        ),
                        child: const Text(
                          'Список устройств загружается или пока пуст.',
                          style: TextStyle(fontSize: 12.5, color: TelemetryColors.textSecondary),
                        ),
                      )
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: TelemetryColors.bgElevated,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: TelemetryColors.border),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            for (var i = 0; i < devices.length; i++) ...[
                              if (i > 0) const Divider(height: 1, color: TelemetryColors.border),
                              Builder(
                                builder: (_) {
                                  final dev = devices[i];
                                  final isThisDevice = dev.id.isNotEmpty &&
                                      dev.id == controller.currentDeviceId;
                                  final seen = TelemetryFormatters.relativeTime(dev.lastSeenAtMs);
                                  return Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 34,
                                          height: 34,
                                          decoration: BoxDecoration(
                                            color: (dev.online
                                                    ? TelemetryColors.live
                                                    : TelemetryColors.bgPanel)
                                                .withValues(alpha: dev.online ? 0.14 : 1.0),
                                            borderRadius: BorderRadius.circular(9),
                                          ),
                                          child: Icon(
                                            _platformIcon(dev.platform),
                                            size: 18,
                                            color: dev.online
                                                ? TelemetryColors.live
                                                : TelemetryColors.textSecondary,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      dev.name,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 13.5,
                                                        fontWeight: FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                  if (isThisDevice) ...[
                                                    const SizedBox(width: 6),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 1.5,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: TelemetryColors.accent
                                                            .withValues(alpha: 0.18),
                                                        borderRadius: BorderRadius.circular(99),
                                                      ),
                                                      child: const Text(
                                                        'Это устройство',
                                                        style: TextStyle(
                                                          fontSize: 10,
                                                          fontWeight: FontWeight.w700,
                                                          color: TelemetryColors.accentBright,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                  if (dev.online) ...[
                                                    const SizedBox(width: 6),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 1.5,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: TelemetryColors.live
                                                            .withValues(alpha: 0.15),
                                                        borderRadius: BorderRadius.circular(99),
                                                      ),
                                                      child: const Text(
                                                        'Онлайн',
                                                        style: TextStyle(
                                                          fontSize: 10,
                                                          fontWeight: FontWeight.w700,
                                                          color: TelemetryColors.live,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                [
                                                  dev.platform,
                                                  if (dev.remoteAddress.isNotEmpty) dev.remoteAddress,
                                                  if (seen.isNotEmpty) seen,
                                                ].join(' · '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 11.5,
                                                  color: TelemetryColors.textDim,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (!isThisDevice)
                                          IconButton(
                                            visualDensity: VisualDensity.compact,
                                            tooltip: 'Отвязать устройство',
                                            onPressed: () => _confirmRevoke(context, dev),
                                            icon: const Icon(
                                              Icons.link_off_rounded,
                                              size: 18,
                                              color: TelemetryColors.danger,
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),

                    // 3. Switch Other Saved Computers
                    if (otherMachines.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        'ДРУГИЕ КОМПЬЮТЕРЫ',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: TelemetryColors.textDim,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final m in otherMachines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: TelemetryColors.bgElevated,
                            borderRadius: BorderRadius.circular(13),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(13),
                              onTap: () {
                                onClose();
                                controller.connectToMachine(m);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.laptop_mac_rounded,
                                      size: 18,
                                      color: TelemetryColors.accentBright,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        TelemetryFormatters.cleanMachineName(m.machineName),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const Text(
                                      'Переключиться',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: TelemetryColors.accentBright,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],

                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: () {
                        onClose();
                        controller.disconnect();
                      },
                      icon: const Icon(Icons.add_to_queue_rounded, size: 18),
                      label: const Text('К списку компьютеров / Добавить ПК'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
