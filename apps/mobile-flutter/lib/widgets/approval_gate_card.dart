import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../theme/telemetry_theme.dart';

class ApprovalGateCard extends StatefulWidget {
  final ApprovalRequest request;
  final List<ApprovalRequest> queue;
  final int pendingTotal;
  final void Function(String decision) onDecide;
  final void Function(String id, String decision)? onDecideItem;
  final void Function(String decision)? onDecideAll;

  const ApprovalGateCard({
    super.key,
    required this.request,
    this.queue = const [],
    required this.pendingTotal,
    required this.onDecide,
    this.onDecideItem,
    this.onDecideAll,
  });

  @override
  State<ApprovalGateCard> createState() => _ApprovalGateCardState();
}

class _ApprovalGateCardState extends State<ApprovalGateCard> {
  Timer? _countdownTimer;
  bool _expandedCommand = false;

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant ApprovalGateCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.id != widget.request.id) {
      _expandedCommand = false;
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  IconData _toolIcon(String name) {
    final n = name.toLowerCase();
    if (n.contains('command')) return Icons.terminal_rounded;
    if (n.contains('write') || n.contains('edit')) return Icons.edit_document;
    return Icons.shield_outlined;
  }

  bool _isFileTool(String name) {
    final n = name.toLowerCase();
    return n.contains('write') || n.contains('edit');
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final items = widget.queue.isNotEmpty ? widget.queue : [request];
    final total = widget.pendingTotal > items.length ? widget.pendingTotal : items.length;
    final isBatch = items.length > 1;
    final allFiles = items.every((r) => _isFileTool(r.toolName));

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final totalDur = request.totalDurationMs;
    final leftMs = (request.expiresAtMs - nowMs).clamp(0, totalDur);
    final leftSec = (leftMs / 1000).ceil();
    final progress = (leftMs / totalDur).clamp(0.0, 1.0);
    final isLongCommand = request.commandLine.length > 90 || request.commandLine.contains('\n');

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF151824),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TelemetryColors.warn.withValues(alpha: 0.55), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.65),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: TelemetryColors.warn.withValues(alpha: 0.14),
            blurRadius: 20,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: progress,
            minHeight: 3,
            backgroundColor: TelemetryColors.warn.withValues(alpha: 0.12),
            valueColor: const AlwaysStoppedAnimation<Color>(TelemetryColors.warn),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: TelemetryColors.warn.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        _toolIcon(request.toolName),
                        size: 17,
                        color: TelemetryColors.warn,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Запрос разрешения',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              letterSpacing: -0.2,
                            ),
                          ),
                          Text(
                            request.toolName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: TelemetryColors.warn,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (total > 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: TelemetryColors.warn.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '+${total - 1}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: TelemetryColors.warn,
                            ),
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: TelemetryColors.bgCode,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: TelemetryColors.border),
                      ),
                      child: Text(
                        '${leftSec}s',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: TelemetryColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (isBatch)
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 148),
                    decoration: BoxDecoration(
                      color: TelemetryColors.bgCode,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: TelemetryColors.border),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: TelemetryColors.border),
                      itemBuilder: (context, idx) {
                        final item = items[idx];
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                _toolIcon(item.toolName),
                                size: 14,
                                color: TelemetryColors.textDim,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item.commandLine.isNotEmpty ? item.commandLine : item.toolName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: TelemetryColors.cyan,
                                  ),
                                ),
                              ),
                              if (widget.onDecideItem != null) ...[
                                InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () {
                                    HapticFeedback.mediumImpact();
                                    widget.onDecideItem!(item.id, 'deny');
                                  },
                                  child: const Tooltip(
                                    message: 'Отклонить',
                                    child: Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 16,
                                        color: TelemetryColors.danger,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    widget.onDecideItem!(item.id, 'allow');
                                  },
                                  child: const Tooltip(
                                    message: 'Разрешить',
                                    child: Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.check_rounded,
                                        size: 16,
                                        color: TelemetryColors.live,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: TelemetryColors.bgCode,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: TelemetryColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: _expandedCommand ? 260 : 110),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                            child: SelectableText(
                              request.commandLine,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                height: 1.4,
                                color: TelemetryColors.cyan,
                              ),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.fromLTRB(10, 2, 6, 4),
                          decoration: const BoxDecoration(
                            border: Border(top: BorderSide(color: TelemetryColors.border)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (isLongCommand)
                                InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () => setState(() => _expandedCommand = !_expandedCommand),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _expandedCommand
                                              ? Icons.unfold_less_rounded
                                              : Icons.unfold_more_rounded,
                                          size: 14,
                                          color: TelemetryColors.accentBright,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          _expandedCommand ? 'Свернуть' : 'Развернуть',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: TelemetryColors.accentBright,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () {
                                  Clipboard.setData(ClipboardData(text: request.commandLine));
                                  HapticFeedback.selectionClick();
                                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                    const SnackBar(
                                      content: Text('Команда скопирована'),
                                      duration: Duration(milliseconds: 1100),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                },
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.copy_rounded,
                                        size: 13,
                                        color: TelemetryColors.textSecondary,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'Копия',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: TelemetryColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (request.cwd.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.folder_outlined, size: 13, color: TelemetryColors.textDim),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          request.cwd,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: TelemetryColors.textDim,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 13),
                if (isBatch && widget.onDecideAll != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: TelemetryColors.live,
                        foregroundColor: const Color(0xFF031B11),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        widget.onDecideAll!('allow');
                      },
                      icon: const Icon(Icons.done_all_rounded, size: 18),
                      label: Text(
                        allFiles
                            ? 'Сохранить всё (${items.length})'
                            : 'Разрешить всё (${items.length})',
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: TelemetryColors.danger,
                          side: BorderSide(color: TelemetryColors.danger.withValues(alpha: 0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          widget.onDecide('deny');
                        },
                        child: const Text('Блок', style: TextStyle(fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          widget.onDecide('allow_session');
                        },
                        child: const Text('В сессии', style: TextStyle(fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 5,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: TelemetryColors.live,
                          foregroundColor: const Color(0xFF031B11),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          widget.onDecide('allow');
                        },
                        icon: const Icon(Icons.check_rounded, size: 17),
                        label: const Text(
                          'Разрешить',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
