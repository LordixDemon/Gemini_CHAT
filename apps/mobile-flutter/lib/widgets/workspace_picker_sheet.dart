import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';

Future<void> showWorkspacePickerSheet(BuildContext context, BridgeController ctrl) async {
  final visibleWorkspaces = ctrl.workspaces
      .where((ws) => ws.isDefault || ws.isOpenInHost || !ws.name.startsWith('.'))
      .toList();
  if (visibleWorkspaces.isEmpty) {
    ctrl.sendRpc('workspaces.list', const {});
    return;
  }
  HapticFeedback.selectionClick();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: TelemetryColors.bgPanel,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 14),
                const Text(
                  'Рабочий проект на Mac',
                  style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Выберите проект для новых задач, Git Diff и удалённого терминала.',
                  style: TextStyle(fontSize: 12.5, color: TelemetryColors.textSecondary),
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: visibleWorkspaces.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final ws = visibleWorkspaces[i];
                      final isCurrent = ws.path == ctrl.activeWorkspace || ws.isDefault;
                      return Material(
                        color: isCurrent
                            ? TelemetryColors.accent.withValues(alpha: 0.14)
                            : TelemetryColors.bgElevated,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            HapticFeedback.lightImpact();
                            ctrl.selectWorkspace(ws.path);
                            Navigator.pop(ctx);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            child: Row(
                              children: [
                                Icon(
                                  ws.isOpenInHost
                                      ? Icons.folder_special_outlined
                                      : Icons.folder_outlined,
                                  size: 20,
                                  color: TelemetryColors.accentBright,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              ws.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          if (ws.isOpenInHost) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 1.5,
                                              ),
                                              decoration: BoxDecoration(
                                                color: TelemetryColors.live.withValues(alpha: 0.14),
                                                borderRadius: BorderRadius.circular(99),
                                              ),
                                              child: const Text(
                                                'Открыт в IDE',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w600,
                                                  color: TelemetryColors.live,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        ws.path,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          color: TelemetryColors.textDim,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isCurrent)
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    size: 19,
                                    color: TelemetryColors.accentBright,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
