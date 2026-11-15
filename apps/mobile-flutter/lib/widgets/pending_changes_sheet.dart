import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';

String formatFilesCountRu(int count) {
  final mod100 = count % 100;
  final mod10 = count % 10;
  if (mod100 >= 11 && mod100 <= 14) return '$count файлов';
  if (mod10 == 1) return '$count файл';
  if (mod10 >= 2 && mod10 <= 4) return '$count файла';
  return '$count файлов';
}

/// Native Antigravity-style docked summary strip ("Изменённые файлы · Сохранить всё")
/// shown whenever workspace files have been edited or created by the agent.
class PendingChangesBar extends StatelessWidget {
  final List<PendingFileChange> changes;
  final VoidCallback onOpenList;
  final VoidCallback onSaveAll;

  const PendingChangesBar({
    super.key,
    required this.changes,
    required this.onOpenList,
    required this.onSaveAll,
  });

  @override
  Widget build(BuildContext context) {
    if (changes.isEmpty) return const SizedBox.shrink();

    var totalAdd = 0;
    var totalDel = 0;
    for (final c in changes) {
      totalAdd += c.additions;
      totalDel += c.deletions;
    }

    return Container(
      decoration: BoxDecoration(
        color: TelemetryColors.bgElevated,
        border: Border(
          top: BorderSide(color: TelemetryColors.live.withValues(alpha: 0.42), width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                HapticFeedback.selectionClick();
                onOpenList();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: TelemetryColors.live.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: TelemetryColors.live.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.difference_outlined,
                            size: 13,
                            color: TelemetryColors.live,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            formatFilesCountRu(changes.length),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: TelemetryColors.live,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          children: [
                            TextSpan(
                              text: '+$totalAdd ',
                              style: const TextStyle(color: Color(0xFF6EE7B7)),
                            ),
                            TextSpan(
                              text: '-$totalDel',
                              style: const TextStyle(color: Color(0xFFFDA4AF)),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_up_rounded,
                      size: 18,
                      color: TelemetryColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: TelemetryColors.live,
              foregroundColor: const Color(0xFF031B11),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              HapticFeedback.lightImpact();
              onSaveAll();
            },
            icon: const Icon(Icons.done_all_rounded, size: 16),
            label: const Text(
              'Сохранить всё',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showPendingChangesSheet(
  BuildContext context,
  BridgeController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (_, scrollController) => PendingChangesSheetBody(
        controller: controller,
        scrollController: scrollController,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

class PendingChangesSheetBody extends StatelessWidget {
  final BridgeController controller;
  final ScrollController scrollController;
  final VoidCallback onClose;

  const PendingChangesSheetBody({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.onClose,
  });

  (Color, String) _statusStyle(String status) {
    switch (status.toUpperCase()) {
      case 'NEW':
        return (TelemetryColors.live, 'NEW');
      case 'DEL':
        return (TelemetryColors.danger, 'DEL');
      default:
        return (TelemetryColors.warn, 'MOD');
    }
  }

  (String, String) _splitPath(String full) {
    final normalized = full.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx == -1) return ('', normalized);
    return (normalized.substring(0, idx + 1), normalized.substring(idx + 1));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final files = controller.pendingChanges;
        var totalAdd = 0;
        var totalDel = 0;
        for (final f in files) {
          totalAdd += f.additions;
          totalDel += f.deletions;
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Изменённые файлы (${files.length})',
                          style: const TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              '+$totalAdd',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF6EE7B7),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '-$totalDel',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFFDA4AF),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Flexible(
                              child: Text(
                                'Нажмите на файл для просмотра diff',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: TelemetryColors.textDim),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              if (files.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: TelemetryColors.danger,
                          side: BorderSide(color: TelemetryColors.danger.withValues(alpha: 0.45)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          controller.revertChanges(all: true);
                          onClose();
                        },
                        icon: const Icon(Icons.undo_rounded, size: 16),
                        label: const Text('Откатить всё', style: TextStyle(fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 6,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: TelemetryColors.live,
                          foregroundColor: const Color(0xFF031B11),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          controller.saveAllChanges();
                          onClose();
                        },
                        icon: const Icon(Icons.done_all_rounded, size: 17),
                        label: const Text(
                          'Сохранить всё',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: files.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 40,
                              color: TelemetryColors.live,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Все изменения сохранены',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: onClose,
                              child: const Text('Закрыть'),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: files.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final file = files[index];
                          final isExpanded = controller.pendingChangeDiffPath == file.path;
                          final (badgeColor, badgeText) = _statusStyle(file.status);
                          final (dirPart, baseName) = _splitPath(file.path);

                          return Container(
                            decoration: BoxDecoration(
                              color: TelemetryColors.bgElevated,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isExpanded
                                    ? TelemetryColors.accent.withValues(alpha: 0.55)
                                    : TelemetryColors.border,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                InkWell(
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    controller.requestPendingChangeDiff(file.path);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 36,
                                          alignment: Alignment.center,
                                          padding: const EdgeInsets.symmetric(vertical: 3),
                                          decoration: BoxDecoration(
                                            color: badgeColor.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            badgeText,
                                            style: TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              color: badgeColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                baseName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              Row(
                                                children: [
                                                  if (dirPart.isNotEmpty)
                                                    Flexible(
                                                      child: Text(
                                                        dirPart,
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: const TextStyle(
                                                          fontFamily: 'monospace',
                                                          fontSize: 11,
                                                          color: TelemetryColors.textDim,
                                                        ),
                                                      ),
                                                    ),
                                                  if (dirPart.isNotEmpty) const SizedBox(width: 6),
                                                  Text(
                                                    '+${file.additions}',
                                                    style: const TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontSize: 11,
                                                      color: Color(0xFF6EE7B7),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    '-${file.deletions}',
                                                    style: const TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontSize: 11,
                                                      color: Color(0xFFFDA4AF),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          tooltip: 'Откатить файл',
                                          onPressed: () {
                                            HapticFeedback.mediumImpact();
                                            controller.revertChanges(paths: [file.path]);
                                          },
                                          icon: const Icon(
                                            Icons.undo_rounded,
                                            size: 18,
                                            color: TelemetryColors.danger,
                                          ),
                                        ),
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          tooltip: 'Сохранить файл',
                                          onPressed: () {
                                            HapticFeedback.lightImpact();
                                            controller.saveAllChanges(paths: [file.path]);
                                          },
                                          icon: const Icon(
                                            Icons.check_circle_outline_rounded,
                                            size: 19,
                                            color: TelemetryColors.live,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (isExpanded) ...[
                                  const Divider(height: 1, color: TelemetryColors.border),
                                  _CompactDiffPreview(diff: controller.pendingChangeDiffContent),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CompactDiffPreview extends StatelessWidget {
  final String diff;

  const _CompactDiffPreview({required this.diff});

  @override
  Widget build(BuildContext context) {
    final lines = diff.replaceAll('\r\n', '\n').split('\n');
    return Container(
      color: TelemetryColors.bgCode,
      constraints: const BoxConstraints(maxHeight: 240),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in lines) _renderLine(line),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _renderLine(String line) {
    final isAdd = line.startsWith('+') && !line.startsWith('+++');
    final isDel = line.startsWith('-') && !line.startsWith('---');
    final isHunk = line.startsWith('@@') || line.startsWith('+++') || line.startsWith('---');

    Color bg = Colors.transparent;
    Color fg = TelemetryColors.textSecondary;
    if (isAdd) {
      bg = TelemetryColors.live.withValues(alpha: 0.13);
      fg = const Color(0xFF6EE7B7);
    } else if (isDel) {
      bg = TelemetryColors.danger.withValues(alpha: 0.14);
      fg = const Color(0xFFFDA4AF);
    } else if (isHunk) {
      bg = TelemetryColors.accent.withValues(alpha: 0.14);
      fg = TelemetryColors.accentBright;
    }

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1.5),
      child: Text(
        line.isEmpty ? ' ' : line,
        style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.38, color: fg),
      ),
    );
  }
}
