import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import 'chat_step_cards.dart';
import 'workspace_picker_sheet.dart';

export 'workspace_picker_sheet.dart' show showWorkspacePickerSheet;

class AgentChatView extends StatefulWidget {
  final BridgeController controller;
  final void Function(String fileName) onOpenArtifact;
  final void Function(String path)? onOpenFileDiff;
  final bool isActiveTab;

  const AgentChatView({
    super.key,
    required this.controller,
    required this.onOpenArtifact,
    this.onOpenFileDiff,
    this.isActiveTab = true,
  });

  @override
  State<AgentChatView> createState() => _AgentChatViewState();
}

class _AgentChatViewState extends State<AgentChatView> {
  final _promptCtrl = TextEditingController();
  final _chatSearchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final Map<String, String> _draftsBySession = {};
  int _lastRenderedCount = 0;
  String? _lastConvId;
  bool _wasActiveTab = false;
  bool _hasText = false;
  bool _showJumpToLatest = false;
  bool _searchOpen = false;
  String _chatSearchQuery = '';
  List<AgentStep>? _memoSourceSteps;
  String? _memoConvId;
  List<AgentStep> _memoVisibleSteps = const [];
  List<ChatTimelineEntry> _memoTimelineEntries = const [];

  @override
  void initState() {
    super.initState();
    _wasActiveTab = widget.isActiveTab;
    _lastConvId = widget.controller.activeConversationId;
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
    _chatSearchCtrl.dispose();
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
    _draftsBySession.remove(ctrl.activeConversationId ?? '');
    _promptCtrl.clear();
    FocusScope.of(context).unfocus();
    ctrl.sendPrompt(text);
    _jumpToLatest(animated: true);
  }

  void _insertIntoComposer(String snippet) {
    _promptCtrl.text = snippet;
    _promptCtrl.selection = TextSelection.collapsed(offset: snippet.length);
  }

  void _handleLinkTap(String target, String label) {
    final ctrl = widget.controller;
    final lower = target.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      ctrl.openExternalUrl(target).then((opened) {
        if (!opened && mounted) {
          Clipboard.setData(ClipboardData(text: target));
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('Ссылка скопирована'),
              duration: Duration(milliseconds: 1200),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      });
      return;
    }

    var cleanPath = target;
    if (lower.startsWith('file://')) {
      final parsed = Uri.tryParse(target);
      if (parsed != null && parsed.path.isNotEmpty) {
        cleanPath = parsed.path;
      } else {
        cleanPath = target.substring(7);
      }
    }
    final normTarget = cleanPath.replaceAll('\\', '/');
    GitFileChange? matchedGitFile;
    for (final gf in ctrl.gitFiles) {
      final normGf = gf.path.replaceAll('\\', '/');
      if (normTarget == normGf || normTarget.endsWith('/$normGf')) {
        matchedGitFile = gf;
        break;
      }
    }
    if (matchedGitFile != null && widget.onOpenFileDiff != null) {
      widget.onOpenFileDiff!(matchedGitFile.path);
      return;
    }
    Clipboard.setData(ClipboardData(text: cleanPath));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Путь скопирован: $label'),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  bool _entryMatchesSearch(ChatTimelineEntry entry, String queryLower) {
    for (final s in entry.steps) {
      if (s.content.toLowerCase().contains(queryLower)) return true;
      if (s.thinking.toLowerCase().contains(queryLower)) return true;
      for (final tc in s.toolCalls) {
        if (tc.summary.toLowerCase().contains(queryLower) ||
            (tc.artifactFileName?.toLowerCase().contains(queryLower) ?? false)) {
          return true;
        }
      }
    }
    return false;
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
                  leading: const Icon(
                    Icons.photo_library_outlined,
                    color: TelemetryColors.accentBright,
                  ),
                  title: const Text(
                    'Фото или скриншот',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
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

  Future<void> _showWorkspacePickerSheet() => showWorkspacePickerSheet(context, widget.controller);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    if (!identical(ctrl.activeSteps, _memoSourceSteps) ||
        ctrl.activeConversationId != _memoConvId) {
      _memoSourceSteps = ctrl.activeSteps;
      _memoConvId = ctrl.activeConversationId;
      _memoVisibleSteps = ctrl.activeSteps.where((s) => s.role != 'tool_result').toList();
      _memoTimelineEntries = buildChatTimelineEntries(_memoVisibleSteps);
    }
    final visibleSteps = _memoVisibleSteps;

    if (ctrl.activeConversationId != _lastConvId) {
      final prevKey = _lastConvId ?? '';
      final currentDraft = _promptCtrl.text;
      if (currentDraft.trim().isEmpty) {
        _draftsBySession.remove(prevKey);
      } else {
        _draftsBySession[prevKey] = currentDraft;
      }
      _lastConvId = ctrl.activeConversationId;
      _lastRenderedCount = visibleSteps.length;
      final nextKey = ctrl.activeConversationId ?? '';
      final restoredDraft = _draftsBySession[nextKey] ?? '';
      if (_promptCtrl.text != restoredDraft) {
        _promptCtrl.text = restoredDraft;
        _promptCtrl.selection = TextSelection.collapsed(offset: restoredDraft.length);
        _hasText = restoredDraft.trim().isNotEmpty;
      }
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
    final headerWorkspaceLabel =
        (currentSession != null &&
            currentSession.workspaceName.isNotEmpty &&
            !currentSession.workspaceName.startsWith('.'))
        ? currentSession.workspaceName
        : ctrl.activeWorkspaceName;
    final timelineEntries = _memoTimelineEntries;
    final sq = _chatSearchQuery.trim().toLowerCase();
    final filteredEntries = sq.isEmpty
        ? timelineEntries
        : timelineEntries.where((e) => _entryMatchesSearch(e, sq)).toList();
    final hasWorkingIndicator = isWorking && sq.isEmpty && timelineEntries.isNotEmpty;
    final hasLoadOlderButton = ctrl.activeHasMoreSteps && sq.isEmpty && timelineEntries.isNotEmpty;
    final totalListItems =
        filteredEntries.length + (hasWorkingIndicator ? 1 : 0) + (hasLoadOlderButton ? 1 : 0);

    return Column(
      children: [
        // Session context bar + workspace selector + optional artifacts strip
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
                  if (timelineEntries.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _searchOpen = !_searchOpen;
                          if (!_searchOpen) {
                            _chatSearchCtrl.clear();
                            _chatSearchQuery = '';
                          }
                        });
                      },
                      child: Tooltip(
                        message: 'Поиск в чате',
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: _searchOpen
                                ? TelemetryColors.accent.withValues(alpha: 0.18)
                                : TelemetryColors.bgElevated,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _searchOpen
                                  ? TelemetryColors.accent.withValues(alpha: 0.5)
                                  : TelemetryColors.border,
                            ),
                          ),
                          child: Icon(
                            Icons.search_rounded,
                            size: 14,
                            color: _searchOpen
                                ? TelemetryColors.accentBright
                                : TelemetryColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (_searchOpen) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 34,
                        child: TextField(
                          controller: _chatSearchCtrl,
                          autofocus: true,
                          onChanged: (v) => setState(() => _chatSearchQuery = v),
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Поиск по сообщениям чата…',
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 16,
                              color: TelemetryColors.textDim,
                            ),
                            suffixIcon: sq.isEmpty
                                ? null
                                : IconButton(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    onPressed: () {
                                      _chatSearchCtrl.clear();
                                      setState(() => _chatSearchQuery = '');
                                    },
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 15,
                                      color: TelemetryColors.textDim,
                                    ),
                                  ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                        ),
                      ),
                    ),
                    if (sq.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${filteredEntries.length}/${timelineEntries.length}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: TelemetryColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
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

        // Conversation Timeline (reverse: true guarantees offset 0.0 is ALWAYS the latest message)
        Expanded(
          child: timelineEntries.isEmpty
              ? ChatEmptyHero(
                  isNew: ctrl.activeConversationId == null,
                  isLoading: ctrl.loadingSessionDetail,
                  workspaceName: ctrl.activeWorkspaceName,
                  hasMultipleWorkspaces: ctrl.workspaces.length > 1,
                  onSwitchWorkspace: _showWorkspacePickerSheet,
                  onRefresh: ctrl.activeConversationId == null
                      ? null
                      : () => ctrl.openSession(ctrl.activeConversationId!),
                )
              : filteredEntries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.search_off_rounded,
                              size: 36,
                              color: TelemetryColors.textDim,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'В чате ничего не найдено по «$_chatSearchQuery»',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: TelemetryColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Stack(
                      children: [
                        ListView.separated(
                          controller: _scrollCtrl,
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                          itemCount: totalListItems,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (_, idx) {
                            if (hasWorkingIndicator && idx == 0) {
                              return _LiveAgentWorkingCard(
                                activity: TelemetryFormatters.cleanActivity(
                                  currentSession?.lastActivity ?? '',
                                ),
                              );
                            }
                            final entrySlot = idx - (hasWorkingIndicator ? 1 : 0);
                            if (hasLoadOlderButton && entrySlot == filteredEntries.length) {
                              final remaining =
                                  (ctrl.activeVisibleStepCount - ctrl.activeSteps.length).clamp(0, 9999);
                              return Center(
                                child: ctrl.loadingOlderSteps
                                    ? Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            value: (!kIsWeb &&
                                                    Platform.environment.containsKey('FLUTTER_TEST'))
                                                ? 0.65
                                                : null,
                                            color: TelemetryColors.accentBright,
                                          ),
                                        ),
                                      )
                                    : OutlinedButton.icon(
                                        onPressed: () {
                                          HapticFeedback.selectionClick();
                                          ctrl.loadOlderSteps();
                                        },
                                        icon: const Icon(Icons.history_rounded, size: 16),
                                        label: Text(
                                          remaining > 0
                                              ? 'Загрузить ранние шаги (+$remaining)'
                                              : 'Загрузить ранние шаги',
                                          style: const TextStyle(fontSize: 12.5),
                                        ),
                                      ),
                              );
                            }
                            final entry =
                                filteredEntries[filteredEntries.length - 1 - entrySlot];
                            final firstStep = entry.steps.first;
                            return ChatStepCard(
                              key: ValueKey('entry_${firstStep.seq}_${firstStep.stepIndex}'),
                              entry: entry,
                              controller: ctrl,
                              onOpenArtifact: widget.onOpenArtifact,
                              onCopyToComposer: _insertIntoComposer,
                              onTapLink: _handleLinkTap,
                              fontScale: ctrl.chatFontScale,
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
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
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
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: 'Скрыть ошибку',
                  onPressed: ctrl.clearError,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: TelemetryColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

        // Capsule Composer + Attachment Preview Strip + Slash Suggestions
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

class _LiveAgentWorkingCard extends StatefulWidget {
  final String activity;

  const _LiveAgentWorkingCard({required this.activity});

  @override
  State<_LiveAgentWorkingCard> createState() => _LiveAgentWorkingCardState();
}

class _LiveAgentWorkingCardState extends State<_LiveAgentWorkingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      value: 1.0,
    );
    if (kIsWeb || !Platform.environment.containsKey('FLUTTER_TEST')) {
      _pulseCtrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: TelemetryColors.bgPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TelemetryColors.live.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          FadeTransition(
            opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_pulseCtrl),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: TelemetryColors.live,
                boxShadow: [
                  BoxShadow(
                    color: TelemetryColors.live.withValues(alpha: 0.65),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Агент работает: ${widget.activity}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: TelemetryColors.live,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
