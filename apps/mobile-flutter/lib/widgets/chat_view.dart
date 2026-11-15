import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import 'markdown_view.dart';

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
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.72,
          ),
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

class AgentChatView extends StatefulWidget {
  final BridgeController controller;
  final void Function(String fileName) onOpenArtifact;
  final bool isActiveTab;

  const AgentChatView({
    super.key,
    required this.controller,
    required this.onOpenArtifact,
    this.isActiveTab = true,
  });

  @override
  State<AgentChatView> createState() => _AgentChatViewState();
}

class _AgentChatViewState extends State<AgentChatView> {
  final _promptCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  int _lastRenderedCount = 0;
  String? _lastConvId;
  bool _wasActiveTab = false;
  bool _hasText = false;
  bool _showJumpToLatest = false;

  @override
  void initState() {
    super.initState();
    _wasActiveTab = widget.isActiveTab;
    _promptCtrl.addListener(() {
      final nonEmpty = _promptCtrl.text.trim().isNotEmpty;
      if (nonEmpty != _hasText && mounted) {
        setState(() => _hasText = nonEmpty);
      }
    });
    _scrollCtrl.addListener(() {
      if (!_scrollCtrl.hasClients) return;
      final shouldShow = _scrollCtrl.offset > 220;
      if (shouldShow != _showJumpToLatest && mounted) {
        setState(() => _showJumpToLatest = shouldShow);
      }
    });
  }

  @override
  void didUpdateWidget(covariant AgentChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActiveTab && !_wasActiveTab) {
      _jumpToLatest();
    }
    _wasActiveTab = widget.isActiveTab;
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _jumpToLatest({bool animated = false, bool fromBuild = false}) {
    if (!fromBuild && _scrollCtrl.hasClients) {
      if (animated) {
        _scrollCtrl.animateTo(
          0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollCtrl.jumpTo(0.0);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients || animated) return;
      _scrollCtrl.jumpTo(0.0);
    });
  }

  void _handleSend() {
    final ctrl = widget.controller;
    final text = _promptCtrl.text.trim();
    if (text.isEmpty && !ctrl.hasReadyAttachments) return;
    if (ctrl.hasUploadingAttachments) return;
    HapticFeedback.lightImpact();
    _promptCtrl.clear();
    FocusScope.of(context).unfocus();
    ctrl.sendPrompt(text);
    _jumpToLatest(animated: true);
  }

  void _handleStop() {
    HapticFeedback.mediumImpact();
    widget.controller.stopActiveSession();
  }

  Future<void> _showAttachmentPickerSheet() async {
    HapticFeedback.selectionClick();
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: TelemetryColors.bgPanel,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
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
                  'Отправить вложение агенту',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Файл сохранится в папку .antigravity-uploads на вашем Mac и будет передан агенту.',
                  style: TextStyle(fontSize: 12.5, color: TelemetryColors.textSecondary),
                ),
                const SizedBox(height: 14),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: TelemetryColors.bgElevated,
                  leading: const Icon(Icons.photo_library_outlined, color: TelemetryColors.accentBright),
                  title: const Text('Фото или скриншот', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text(
                    'Отправить снимок бага, макет или фото для анализа',
                    style: TextStyle(fontSize: 12, color: TelemetryColors.textSecondary),
                  ),
                  onTap: () => Navigator.pop(ctx, 'image'),
                ),
                const SizedBox(height: 8),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: TelemetryColors.bgElevated,
                  leading: const Icon(Icons.attach_file_rounded, color: TelemetryColors.cyan),
                  title: const Text('Файл или лог', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text(
                    'JSON, лог, ТЗ, PDF, архив или исходный код (до 20 МБ)',
                    style: TextStyle(fontSize: 12, color: TelemetryColors.textSecondary),
                  ),
                  onTap: () => Navigator.pop(ctx, 'file'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    await widget.controller.pickAndUploadAttachment(kind: chosen);
  }

  Future<void> _showWorkspacePickerSheet() =>
      showWorkspacePickerSheet(context, widget.controller);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final visibleSteps = ctrl.activeSteps.where((s) => s.role != 'tool_result').toList();

    if (ctrl.activeConversationId != _lastConvId) {
      _lastConvId = ctrl.activeConversationId;
      _lastRenderedCount = visibleSteps.length;
      _jumpToLatest(fromBuild: true);
    } else if (visibleSteps.length != _lastRenderedCount) {
      final wasEmpty = _lastRenderedCount == 0;
      _lastRenderedCount = visibleSteps.length;
      if (wasEmpty || (visibleSteps.isNotEmpty && visibleSteps.last.role == 'user')) {
        _jumpToLatest(fromBuild: true);
      }
    }

    final currentSession = ctrl.sessions
        .where((s) => s.id == ctrl.activeConversationId)
        .cast<SessionSummary?>()
        .firstWhere((_) => true, orElse: () => null);
    final isWorking = currentSession?.status == 'working';
    final canSend = (_hasText || ctrl.hasReadyAttachments) && !ctrl.hasUploadingAttachments;
    final headerWorkspaceLabel = (currentSession != null &&
            currentSession.workspaceName.isNotEmpty &&
            !currentSession.workspaceName.startsWith('.'))
        ? currentSession.workspaceName
        : ctrl.activeWorkspaceName;
    final timelineEntries = _buildTimelineEntries(visibleSteps);

    return Column(
      children: [
        // Clean session context bar + workspace selector + optional artifacts strip
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 6, 12, 6),
          decoration: const BoxDecoration(
            color: TelemetryColors.bgCanvas,
            border: Border(bottom: BorderSide(color: TelemetryColors.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isWorking)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 8, left: 2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: TelemetryColors.live,
                        boxShadow: [
                          BoxShadow(
                            color: TelemetryColors.live.withValues(alpha: 0.65),
                            blurRadius: 7,
                          ),
                        ],
                      ),
                    )
                  else ...[
                    Icon(
                      currentSession == null
                          ? Icons.edit_square
                          : Icons.chat_bubble_outline_rounded,
                      size: 14,
                      color: TelemetryColors.accentBright,
                    ),
                    const SizedBox(width: 7),
                  ],
                  Expanded(
                    child: Text(
                      TelemetryFormatters.cleanSessionTitle(currentSession?.title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: TelemetryColors.textPrimary,
                      ),
                    ),
                  ),
                  if (ctrl.workspaces.isNotEmpty || headerWorkspaceLabel != 'Проект') ...[
                    const SizedBox(width: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _showWorkspacePickerSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: TelemetryColors.bgElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: TelemetryColors.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.folder_outlined,
                              size: 12,
                              color: TelemetryColors.cyan,
                            ),
                            const SizedBox(width: 4),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 118),
                              child: Text(
                                headerWorkspaceLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: TelemetryColors.textSecondary,
                                ),
                              ),
                            ),
                            if (ctrl.workspaces.length > 1) ...[
                              const SizedBox(width: 1),
                              const Icon(
                                Icons.arrow_drop_down_rounded,
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
              if (ctrl.activeArtifacts.isNotEmpty) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 26,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: ctrl.activeArtifacts.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, idx) {
                      final art = ctrl.activeArtifacts[idx];
                      return InkWell(
                        borderRadius: BorderRadius.circular(7),
                        onTap: () => widget.onOpenArtifact(art.fileName),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                          decoration: BoxDecoration(
                            color: TelemetryColors.bgElevated,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(color: TelemetryColors.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.article_outlined,
                                size: 12,
                                color: TelemetryColors.accentBright,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                art.fileName,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),

        // Conversation Timeline (reverse: true guarantees offset 0.0 is ALWAYS the latest message!)
        Expanded(
          child: timelineEntries.isEmpty
              ? _EmptyChatHero(
                  isNew: ctrl.activeConversationId == null,
                  workspaceName: ctrl.activeWorkspaceName,
                  hasMultipleWorkspaces: ctrl.workspaces.length > 1,
                  onSwitchWorkspace: _showWorkspacePickerSheet,
                  onPickStarter: (prompt) {
                    _promptCtrl.text = prompt;
                    _promptCtrl.selection = TextSelection.collapsed(offset: prompt.length);
                  },
                )
              : Stack(
                  children: [
                    ListView.separated(
                      controller: _scrollCtrl,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                      itemCount: timelineEntries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, idx) {
                        final entry = timelineEntries[timelineEntries.length - 1 - idx];
                        final firstStep = entry.steps.first;
                        return _StepCard(
                          key: ValueKey('entry_${firstStep.seq}_${firstStep.stepIndex}'),
                          entry: entry,
                          controller: ctrl,
                          onOpenArtifact: widget.onOpenArtifact,
                        );
                      },
                    ),
                    if (_showJumpToLatest)
                      Positioned(
                        right: 14,
                        bottom: 12,
                        child: Material(
                          color: TelemetryColors.bgElevated,
                          elevation: 6,
                          borderRadius: BorderRadius.circular(99),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              _jumpToLatest(animated: true);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(
                                  color: TelemetryColors.accent.withValues(alpha: 0.45),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    size: 17,
                                    color: TelemetryColors.accentBright,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'К последним',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: TelemetryColors.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),

        if (ctrl.lastError != null && ctrl.lastError!.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: TelemetryColors.warn.withValues(alpha: 0.12),
              border: const Border(top: BorderSide(color: TelemetryColors.border)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 15, color: TelemetryColors.warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ctrl.lastError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: TelemetryColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),

        // Modern Capsule Composer + Attachment Preview Strip + Slash Suggestions
        Container(
          padding: const EdgeInsets.fromLTRB(12, 5, 12, 8),
          decoration: const BoxDecoration(
            color: TelemetryColors.bgCanvas,
            border: Border(top: BorderSide(color: TelemetryColors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ctrl.pendingAttachments.isNotEmpty) ...[
                SizedBox(
                  height: 50,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: ctrl.pendingAttachments.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, idx) {
                      final att = ctrl.pendingAttachments[idx];
                      return Container(
                        padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
                        decoration: BoxDecoration(
                          color: TelemetryColors.bgElevated,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: TelemetryColors.borderStrong),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: att.isImage && att.previewBytes != null
                                  ? Image.memory(
                                      att.previewBytes!,
                                      width: 36,
                                      height: 36,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        width: 36,
                                        height: 36,
                                        color: TelemetryColors.bgPanel,
                                        child: const Icon(
                                          Icons.image_outlined,
                                          size: 18,
                                          color: TelemetryColors.accentBright,
                                        ),
                                      ),
                                    )
                                  : Container(
                                      width: 36,
                                      height: 36,
                                      color: TelemetryColors.bgPanel,
                                      child: Icon(
                                        att.isImage
                                            ? Icons.image_outlined
                                            : Icons.insert_drive_file_outlined,
                                        size: 18,
                                        color: TelemetryColors.cyan,
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 130),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    att.fileName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (att.uploading) ...[
                                        const SizedBox(
                                          width: 10,
                                          height: 10,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.6,
                                            color: TelemetryColors.accentBright,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Text(
                                          'Загрузка…',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: TelemetryColors.textDim,
                                          ),
                                        ),
                                      ] else ...[
                                        const Icon(
                                          Icons.check_circle_rounded,
                                          size: 11,
                                          color: TelemetryColors.live,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          _formatBytes(att.sizeBytes),
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            color: TelemetryColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            InkWell(
                              borderRadius: BorderRadius.circular(99),
                              onTap: () => ctrl.removeAttachment(att.id),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 15,
                                  color: TelemetryColors.textDim,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 6),
              ],
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: _showJumpToLatest
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SizedBox(
                          height: 25,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final item in const [
                                ('/plan ', 'План'),
                                ('/boost ', 'Boost'),
                                ('/compact', 'Сжать контекст'),
                                ('Проверь git status и запусти тесты', 'Тесты'),
                              ])
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(99),
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      _promptCtrl.text = item.$1;
                                      _promptCtrl.selection =
                                          TextSelection.collapsed(offset: item.$1.length);
                                    },
                                    child: Container(
                                      padding:
                                          const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: TelemetryColors.bgPanel,
                                        borderRadius: BorderRadius.circular(99),
                                        border: Border.all(color: TelemetryColors.border),
                                      ),
                                      child: Text(
                                        item.$2,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: TelemetryColors.textSecondary,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
                decoration: BoxDecoration(
                  color: TelemetryColors.bgPanel,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: canSend
                        ? TelemetryColors.accent.withValues(alpha: 0.55)
                        : TelemetryColors.borderStrong,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: 'Прикрепить фото или файл',
                        onPressed: _showAttachmentPickerSheet,
                        icon: const Icon(
                          Icons.add_circle_outline_rounded,
                          size: 21,
                          color: TelemetryColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: TextField(
                        controller: _promptCtrl,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.newline,
                        style: const TextStyle(fontSize: 14.5, height: 1.36),
                        decoration: InputDecoration(
                          hintText: isWorking
                              ? 'Добавить сообщение в очередь…'
                              : 'Сообщение для Antigravity…',
                          filled: false,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 7),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (isWorking && !canSend)
                      Material(
                        color: TelemetryColors.danger,
                        borderRadius: BorderRadius.circular(99),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(99),
                          onTap: _handleStop,
                          child: const SizedBox(
                            height: 34,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.stop_rounded, size: 17, color: Colors.white),
                                  SizedBox(width: 3),
                                  Text(
                                    'Стоп',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    else ...[
                      if (isWorking) ...[
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: TelemetryColors.danger.withValues(alpha: 0.16),
                            border: Border.all(
                              color: TelemetryColors.danger.withValues(alpha: 0.55),
                            ),
                          ),
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: 'Остановить агента',
                            onPressed: _handleStop,
                            icon: const Icon(
                              Icons.stop_rounded,
                              size: 18,
                              color: TelemetryColors.danger,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: canSend ? TelemetryColors.accent : TelemetryColors.bgElevated,
                        ),
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: isWorking ? 'Отправить в очередь' : 'Отправить',
                          onPressed: canSend ? _handleSend : null,
                          icon: Icon(
                            Icons.arrow_upward_rounded,
                            size: 19,
                            color: canSend ? Colors.white : TelemetryColors.textDim,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimelineEntry {
  final List<AgentStep> steps;
  final bool isPureToolGroup;

  _TimelineEntry(this.steps, {required this.isPureToolGroup});
}

List<_TimelineEntry> _buildTimelineEntries(List<AgentStep> visibleSteps) {
  final out = <_TimelineEntry>[];
  for (final step in visibleSteps) {
    final isPureTool = step.role != 'user' &&
        step.content.trim().isEmpty &&
        step.toolCalls.every((t) => t.artifactFileName == null);
    if (isPureTool && out.isNotEmpty && out.last.isPureToolGroup) {
      out.last.steps.add(step);
    } else {
      out.add(_TimelineEntry([step], isPureToolGroup: isPureTool));
    }
  }
  return out;
}

class _EmptyChatHero extends StatelessWidget {
  final bool isNew;
  final String workspaceName;
  final bool hasMultipleWorkspaces;
  final VoidCallback onSwitchWorkspace;
  final void Function(String) onPickStarter;

  const _EmptyChatHero({
    required this.isNew,
    required this.workspaceName,
    required this.hasMultipleWorkspaces,
    required this.onSwitchWorkspace,
    required this.onPickStarter,
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

class _StepCard extends StatefulWidget {
  final _TimelineEntry entry;
  final BridgeController controller;
  final void Function(String fileName) onOpenArtifact;

  const _StepCard({
    super.key,
    required this.entry,
    required this.controller,
    required this.onOpenArtifact,
  });

  @override
  State<_StepCard> createState() => _StepCardState();
}

class _StepCardState extends State<_StepCard> {
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
      final isOptimistic = step.stepIndex == 999999;
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
        // Collapsible Thinking Pill (coalesced across consecutive tool-only steps)
        if (combinedThinking.isNotEmpty) ...[
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _thinkingOpen = !_thinkingOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.psychology_outlined,
                    size: 14,
                    color: TelemetryColors.textDim,
                  ),
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
                      style: const TextStyle(
                        fontSize: 11,
                        color: TelemetryColors.textDim,
                      ),
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
                border:
                    const Border(left: BorderSide(color: TelemetryColors.borderStrong, width: 2)),
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

        // Unified Compact Tool Timeline Card (single sleek container instead of stacked boxes!)
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

        // Inline Expandable Artifact / Plan Cards
        for (final artTc in artifactTools.values)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: _InlineArtifactPlanCard(
              toolCall: artTc,
              controller: widget.controller,
              onOpenFullScreen: () => widget.onOpenArtifact(artTc.artifactFileName!),
            ),
          ),

        // Formatted Assistant Markdown Response
        if (finalContent.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: MarkdownBodyView(data: finalContent),
          ),
      ],
    );
  }
}

class _InlineArtifactPlanCard extends StatefulWidget {
  final ToolCallInfo toolCall;
  final BridgeController controller;
  final VoidCallback onOpenFullScreen;

  const _InlineArtifactPlanCard({
    required this.toolCall,
    required this.controller,
    required this.onOpenFullScreen,
  });

  @override
  State<_InlineArtifactPlanCard> createState() => _InlineArtifactPlanCardState();
}

class _InlineArtifactPlanCardState extends State<_InlineArtifactPlanCard> {
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
      final fetched =
          await widget.controller.fetchArtifactMarkdown(widget.toolCall.artifactFileName!);
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
