import 'package:flutter/material.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import 'markdown_view.dart';

class ChatTimelineEntry {
  final List<AgentStep> steps;
  final bool isPureToolGroup;

  ChatTimelineEntry(this.steps, {required this.isPureToolGroup});
}

List<ChatTimelineEntry> buildChatTimelineEntries(List<AgentStep> visibleSteps) {
  final out = <ChatTimelineEntry>[];
  for (final step in visibleSteps) {
    final isPureTool =
        step.role != 'user' &&
        step.content.trim().isEmpty &&
        step.toolCalls.every((t) => t.artifactFileName == null);
    if (isPureTool && out.isNotEmpty && out.last.isPureToolGroup) {
      out.last.steps.add(step);
    } else {
      out.add(ChatTimelineEntry([step], isPureToolGroup: isPureTool));
    }
  }
  return out;
}

class ChatEmptyHero extends StatelessWidget {
  final bool isNew;
  final String workspaceName;
  final bool hasMultipleWorkspaces;
  final VoidCallback onSwitchWorkspace;

  const ChatEmptyHero({
    super.key,
    required this.isNew,
    required this.workspaceName,
    required this.hasMultipleWorkspaces,
    required this.onSwitchWorkspace,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    TelemetryColors.accent.withValues(alpha: 0.25),
                    TelemetryColors.cyan.withValues(alpha: 0.12),
                  ],
                ),
                border: Border.all(color: TelemetryColors.accent.withValues(alpha: 0.35)),
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                color: TelemetryColors.accentBright,
                size: 26,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isNew ? 'Запустите новую задачу' : 'Загрузка истории шагов…',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isNew
                  ? 'Агент выполнит задачу локально на вашем Mac и пришлёт запрос подтверждения на телефон.'
                  : 'Выберите существующую сессию на вкладке «Сессии» или отправьте сообщение.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: TelemetryColors.textSecondary,
                height: 1.45,
              ),
            ),
            if (isNew && workspaceName != 'Проект') ...[
              const SizedBox(height: 14),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: hasMultipleWorkspaces ? onSwitchWorkspace : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: TelemetryColors.bgPanel,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: TelemetryColors.borderStrong),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.folder_outlined, size: 15, color: TelemetryColors.cyan),
                      const SizedBox(width: 6),
                      Text(
                        'Проект: $workspaceName',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                      if (hasMultipleWorkspaces) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.unfold_more_rounded,
                          size: 14,
                          color: TelemetryColors.textDim,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ChatStepCard extends StatefulWidget {
  final ChatTimelineEntry entry;
  final BridgeController controller;
  final void Function(String fileName) onOpenArtifact;

  const ChatStepCard({
    super.key,
    required this.entry,
    required this.controller,
    required this.onOpenArtifact,
  });

  @override
  State<ChatStepCard> createState() => _ChatStepCardState();
}

class _ChatStepCardState extends State<ChatStepCard> {
  bool _thinkingOpen = false;

  IconData _iconForTool(String name) {
    final n = name.toLowerCase();
    if (n.contains('command')) return Icons.terminal_rounded;
    if (n.contains('read') || n.contains('view')) return Icons.visibility_outlined;
    if (n.contains('edit') || n.contains('write')) return Icons.code_rounded;
    if (n.contains('search') || n.contains('grep')) return Icons.manage_search_rounded;
    return Icons.build_circle_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.entry.steps;
    final step = steps.first;

    if (step.role == 'user') {
      final isOptimistic = step.isOptimistic;
      final isSending = isOptimistic && step.status == 'SENDING';
      final isQueued = isOptimistic && step.status == 'QUEUED';
      final isSent = isOptimistic && step.status == 'SENT';
      final isFailed = isOptimistic && step.status == 'FAILED';
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF283054), Color(0xFF1E2440)],
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(
              color: isFailed
                  ? TelemetryColors.danger.withValues(alpha: 0.55)
                  : TelemetryColors.accent.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                step.content,
                style: const TextStyle(
                  fontSize: 14.5,
                  height: 1.42,
                  color: TelemetryColors.textPrimary,
                ),
              ),
              if (isSending) ...[
                const SizedBox(height: 4),
                const Text(
                  'Отправка…',
                  style: TextStyle(fontSize: 10.5, color: TelemetryColors.textDim),
                ),
              ] else if (isQueued) ...[
                const SizedBox(height: 4),
                const Text(
                  'В очереди окна…',
                  style: TextStyle(fontSize: 10.5, color: TelemetryColors.warn),
                ),
              ] else if (isSent) ...[
                const SizedBox(height: 4),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.done_all_rounded, size: 12, color: TelemetryColors.live),
                    SizedBox(width: 3),
                    Text(
                      'Доставлено',
                      style: TextStyle(fontSize: 10.5, color: TelemetryColors.live),
                    ),
                  ],
                ),
              ] else if (isFailed) ...[
                const SizedBox(height: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => widget.controller.retryFailedPrompt(step.seq),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded, size: 12, color: TelemetryColors.danger),
                        SizedBox(width: 4),
                        Text(
                          'Не отправлено · Повторить',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: TelemetryColors.danger,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final thinkingBlocks = <String>[];
    final regularTools = <ToolCallInfo>[];
    final artifactTools = <String, ToolCallInfo>{};
    for (final s in steps) {
      if (s.thinking.trim().isNotEmpty) {
        thinkingBlocks.add(s.thinking.trim());
      }
      for (final tc in s.toolCalls) {
        if (tc.artifactFileName != null) {
          artifactTools[tc.artifactFileName!] = tc;
        } else {
          regularTools.add(tc);
        }
      }
    }
    final combinedThinking = thinkingBlocks.join('\n\n───\n\n');
    final finalContent = steps.last.content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (combinedThinking.isNotEmpty) ...[
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _thinkingOpen = !_thinkingOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.psychology_outlined, size: 14, color: TelemetryColors.textDim),
                  const SizedBox(width: 5),
                  const Text(
                    'Размышление',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: TelemetryColors.textDim,
                    ),
                  ),
                  if (thinkingBlocks.length > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '· ${thinkingBlocks.length}',
                      style: const TextStyle(fontSize: 11, color: TelemetryColors.textDim),
                    ),
                  ],
                  const SizedBox(width: 3),
                  Icon(
                    _thinkingOpen
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: TelemetryColors.textDim,
                  ),
                ],
              ),
            ),
          ),
          if (_thinkingOpen)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 3, bottom: 6),
              padding: const EdgeInsets.fromLTRB(11, 7, 10, 7),
              decoration: BoxDecoration(
                color: TelemetryColors.bgPanel.withValues(alpha: 0.65),
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(10),
                  bottomRight: Radius.circular(10),
                ),
                border: const Border(
                  left: BorderSide(color: TelemetryColors.borderStrong, width: 2),
                ),
              ),
              child: SelectableText(
                combinedThinking,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.44,
                  color: TelemetryColors.textSecondary,
                ),
              ),
            ),
        ],
        if (regularTools.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 2, bottom: 4),
            decoration: BoxDecoration(
              color: TelemetryColors.bgPanel,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: TelemetryColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < regularTools.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: TelemetryColors.border),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          _iconForTool(regularTools[i].name),
                          size: 13.5,
                          color: TelemetryColors.cyan,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            regularTools[i].summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: TelemetryColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        for (final artTc in artifactTools.values)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: InlineArtifactPlanCard(
              toolCall: artTc,
              controller: widget.controller,
              onOpenFullScreen: () => widget.onOpenArtifact(artTc.artifactFileName!),
            ),
          ),
        if (finalContent.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: MarkdownBodyView(data: finalContent),
          ),
      ],
    );
  }
}

class InlineArtifactPlanCard extends StatefulWidget {
  final ToolCallInfo toolCall;
  final BridgeController controller;
  final VoidCallback onOpenFullScreen;

  const InlineArtifactPlanCard({
    super.key,
    required this.toolCall,
    required this.controller,
    required this.onOpenFullScreen,
  });

  @override
  State<InlineArtifactPlanCard> createState() => _InlineArtifactPlanCardState();
}

class _InlineArtifactPlanCardState extends State<InlineArtifactPlanCard> {
  bool _expanded = false;
  bool _loading = false;
  String? _markdown;

  Future<void> _toggleInline() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() {
      _expanded = true;
      if (_markdown == null) _loading = true;
    });
    if (_markdown == null) {
      final fetched = await widget.controller.fetchArtifactMarkdown(
        widget.toolCall.artifactFileName!,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _markdown = fetched ?? 'Не удалось загрузить содержимое документа.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.toolCall.artifactFileName ?? 'plan.md';
    final summary = widget.toolCall.artifactSummary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TelemetryColors.bgElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TelemetryColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: TelemetryColors.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.article_outlined,
                  size: 16,
                  color: TelemetryColors.accentBright,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: TelemetryColors.textPrimary,
                      ),
                    ),
                    const Text(
                      'Документ / план сессии',
                      style: TextStyle(fontSize: 11, color: TelemetryColors.textDim),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _toggleInline,
                icon: Icon(
                  _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 16,
                ),
                label: Text(
                  _expanded ? 'Свернуть план' : 'Развернуть полный план',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: TelemetryColors.textSecondary,
                ),
                onPressed: widget.onOpenFullScreen,
                icon: const Icon(Icons.open_in_full_rounded, size: 14),
                label: const Text(
                  'Весь экран',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (summary != null && summary.isNotEmpty && !_expanded) ...[
            const SizedBox(height: 8),
            Text(
              summary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: TelemetryColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
          if (_expanded) ...[
            const Divider(height: 18, color: TelemetryColors.border),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_markdown != null)
              MarkdownBodyView(data: _markdown!, fontSize: 13.5),
          ],
        ],
      ),
    );
  }
}
