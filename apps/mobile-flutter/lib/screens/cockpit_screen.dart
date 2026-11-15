import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import '../widgets/approval_gate_card.dart';
import '../widgets/chat_view.dart';
import '../widgets/git_diff_view.dart';
import '../widgets/markdown_view.dart';
import '../widgets/sessions_view.dart';
import '../widgets/terminal_view.dart';

class CockpitScreen extends StatefulWidget {
  final BridgeController controller;

  const CockpitScreen({super.key, required this.controller});

  @override
  State<CockpitScreen> createState() => _CockpitScreenState();
}

class _CockpitScreenState extends State<CockpitScreen> {
  int _tabIndex = 0;
  bool _creatingNewSession = false;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.controller.pendingApprovals.isNotEmpty && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  (String, IconData, Color) _modeMeta(String mode) {
    switch (mode) {
      case 'auto-safe':
        return ('Авто-безоп.', Icons.verified_user_outlined, TelemetryColors.live);
      case 'observe':
        return ('Наблюдение', Icons.visibility_outlined, TelemetryColors.textSecondary);
      default:
        return ('Спросить', Icons.shield_outlined, TelemetryColors.warn);
    }
  }

  void _selectSession(String id) {
    _creatingNewSession = false;
    widget.controller.openSession(id);
    setState(() => _tabIndex = 1);
  }

  void _startNewSession() {
    _creatingNewSession = true;
    widget.controller.prepareNewSession();
    setState(() => _tabIndex = 1);
  }

  Future<void> _showApprovalModeSheet() async {
    HapticFeedback.selectionClick();
    final ctrl = widget.controller;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
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
                const SizedBox(height: 16),
                const Text(
                  'Режим проверки PreToolUse',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Управляет тем, когда команды и запись файлов требуют вашего подтверждения с телефона.',
                  style: TextStyle(fontSize: 13, color: TelemetryColors.textSecondary),
                ),
                const SizedBox(height: 16),
                for (final opt in const [
                  (
                    'ask-mobile',
                    'Спросить телефон',
                    'Каждая команда и запись файла запрашивает разрешение на телефоне',
                    Icons.shield_outlined,
                    TelemetryColors.warn,
                  ),
                  (
                    'auto-safe',
                    'Авто-безопасный',
                    'Безопасные чтения и тесты выполняются сразу, запись — через телефон',
                    Icons.verified_user_outlined,
                    TelemetryColors.live,
                  ),
                  (
                    'observe',
                    'Наблюдение',
                    'Только мониторинг и чат без задержки десктопных инструментов',
                    Icons.visibility_outlined,
                    TelemetryColors.accentBright,
                  ),
                ]) ...[
                  _ModeOptionTile(
                    selected: ctrl.approvalMode == opt.$1,
                    title: opt.$2,
                    subtitle: opt.$3,
                    icon: opt.$4,
                    accent: opt.$5,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      ctrl.setApprovalMode(opt.$1);
                      setState(() {});
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openArtifactModal(String fileName) async {
    HapticFeedback.selectionClick();
    final content = await widget.controller.fetchArtifactMarkdown(fileName);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        maxChildSize: 0.95,
        builder: (_, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
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
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.article_outlined, size: 18, color: TelemetryColors.accentBright),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fileName,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const Divider(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsets.only(bottom: 24),
                  child: MarkdownBodyView(
                    data: content ?? 'Не удалось загрузить содержимое документа.',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => _buildScaffold(context, ctrl),
    );
  }

  Widget _buildScaffold(BuildContext context, BridgeController ctrl) {
    final cleanHost = TelemetryFormatters.cleanMachineName(
      ctrl.activeMachine?.machineName ?? 'Antigravity Mac',
    );
    final isLive = ctrl.phase == ConnectionPhase.connected;
    final latencyTag = ctrl.latencyMs != null ? ' · ${ctrl.latencyMs} мс' : '';
    final (modeLabel, modeIcon, modeColor) = _modeMeta(ctrl.approvalMode);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        titleSpacing: 14,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: TelemetryColors.border),
        ),
        title: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: isLive
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  ctrl.reconnectNow();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: TelemetryColors.bgPanel,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: TelemetryColors.border),
                  ),
                  child: Center(
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isLive ? TelemetryColors.live : TelemetryColors.warn,
                        boxShadow: [
                          BoxShadow(
                            color: (isLive ? TelemetryColors.live : TelemetryColors.warn)
                                .withValues(alpha: 0.65),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
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
                          letterSpacing: -0.25,
                        ),
                      ),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              isLive
                                  ? '${ctrl.activeTransport}$latencyTag'
                                  : (ctrl.sessions.isNotEmpty
                                      ? 'Офлайн-кэш · Переподключение…'
                                      : 'Переподключение…'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: isLive ? TelemetryColors.textSecondary : TelemetryColors.warn,
                              ),
                            ),
                          ),
                          if (!isLive) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.refresh_rounded,
                              size: 13,
                              color: TelemetryColors.warn,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          // Tactile Mode Selector Pill
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _showApprovalModeSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: modeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: modeColor.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(modeIcon, size: 14, color: modeColor),
                    const SizedBox(width: 5),
                    Text(
                      modeLabel,
                      style: TextStyle(
                        color: modeColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Сменить компьютер',
            icon: const Icon(Icons.power_settings_new_rounded, size: 20, color: TelemetryColors.textSecondary),
            onPressed: ctrl.disconnect,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          IndexedStack(
            index: _tabIndex,
            children: [
              SessionsView(
                controller: ctrl,
                onSelectSession: _selectSession,
                onStartNewSession: _startNewSession,
              ),
              AgentChatView(
                controller: ctrl,
                onOpenArtifact: _openArtifactModal,
                isActiveTab: _tabIndex == 1,
              ),
              GitDiffView(controller: ctrl),
              TerminalView(controller: ctrl),
            ],
          ),
          if (ctrl.pendingApprovals.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: ApprovalGateCard(
                request: ctrl.pendingApprovals.first,
                queue: ctrl.pendingApprovals,
                pendingTotal: ctrl.pendingApprovals.length,
                onDecide: (decision) =>
                    ctrl.decideApproval(ctrl.pendingApprovals.first.id, decision),
                onDecideItem: ctrl.decideApproval,
                onDecideAll: ctrl.decideAllApprovals,
              ),
            ),
        ],
      ),
      bottomNavigationBar: _ModernBottomBar(
        selectedIndex: _tabIndex,
        gitCount: ctrl.gitFiles.length,
        hasPendingApproval: ctrl.pendingApprovals.isNotEmpty,
        onSelect: (idx) {
          HapticFeedback.selectionClick();
          if (idx == 1 &&
              !_creatingNewSession &&
              ctrl.activeConversationId == null &&
              ctrl.sessions.isNotEmpty) {
            ctrl.openSession(ctrl.sessions.first.id);
          }
          setState(() => _tabIndex = idx);
          if (idx == 0) ctrl.sendRpc('sessions.list', const {});
          if (idx == 2) ctrl.sendRpc('workspace.status', const {});
        },
      ),
    );
  }
}

class _ModernBottomBar extends StatelessWidget {
  final int selectedIndex;
  final int gitCount;
  final bool hasPendingApproval;
  final void Function(int) onSelect;

  const _ModernBottomBar({
    required this.selectedIndex,
    required this.gitCount,
    required this.hasPendingApproval,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.grid_view_rounded, Icons.grid_view_outlined, 'Сессии', 0),
      (Icons.auto_awesome_rounded, Icons.auto_awesome_outlined, 'Чат', hasPendingApproval ? -1 : 0),
      (Icons.difference_rounded, Icons.difference_outlined, 'Git Diff', gitCount),
      (Icons.terminal_rounded, Icons.terminal_outlined, 'Терминал', 0),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: TelemetryColors.bgPanel,
        border: Border(top: BorderSide(color: TelemetryColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onSelect(i),
                    child: _buildItem(
                      active: selectedIndex == i,
                      activeIcon: items[i].$1,
                      inactiveIcon: items[i].$2,
                      label: items[i].$3,
                      countOrDot: items[i].$4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem({
    required bool active,
    required IconData activeIcon,
    required IconData inactiveIcon,
    required String label,
    required int countOrDot,
  }) {
    final fg = active ? TelemetryColors.textPrimary : TelemetryColors.textDim;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: active ? TelemetryColors.accent.withValues(alpha: 0.18) : Colors.transparent,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Icon(
                active ? activeIcon : inactiveIcon,
                size: 21,
                color: active ? TelemetryColors.accentBright : fg,
              ),
            ),
            if (countOrDot > 0)
              Positioned(
                right: 0,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: TelemetryColors.bgHover,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: TelemetryColors.borderStrong),
                  ),
                  child: Text(
                    '$countOrDot',
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: TelemetryColors.textSecondary,
                    ),
                  ),
                ),
              )
            else if (countOrDot == -1)
              Positioned(
                right: 4,
                top: 0,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: TelemetryColors.warn,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: fg,
          ),
        ),
      ],
    );
  }
}

class _ModeOptionTile extends StatelessWidget {
  final bool selected;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  const _ModeOptionTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? accent.withValues(alpha: 0.12) : TelemetryColors.bgElevated,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.55) : TelemetryColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: TelemetryColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: accent, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
