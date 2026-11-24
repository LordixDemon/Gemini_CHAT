import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';

class SessionsView extends StatefulWidget {
  final BridgeController controller;
  final void Function(String sessionId) onSelectSession;
  final VoidCallback onStartNewSession;

  const SessionsView({
    super.key,
    required this.controller,
    required this.onSelectSession,
    required this.onStartNewSession,
  });

  @override
  State<SessionsView> createState() => _SessionsViewState();
}

class _SessionsViewState extends State<SessionsView> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _statusFilter = 'all'; // 'all' | 'working' | 'pinned'
  String? _lastMachineId;

  @override
  void initState() {
    super.initState();
    _lastMachineId = widget.controller.activeMachine?.machineId;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> _collectWorkspaceNames(BridgeController ctrl) {
    final score = <String, int>{};
    final latestMs = <String, int>{};
    final openInIde = <String>{};
    final activeName = ctrl.activeWorkspaceName;

    bool isHiddenOrNoise(String name) {
      final n = name.trim();
      if (n.isEmpty || n.startsWith('.')) return true;
      return false;
    }

    for (final w in ctrl.workspaces) {
      if (isHiddenOrNoise(w.name)) continue;
      score[w.name] = (score[w.name] ?? 0) + w.sessionCount;
      if (w.isOpenInHost) openInIde.add(w.name);
    }
    for (final s in ctrl.sessions) {
      if (isHiddenOrNoise(s.workspaceName)) continue;
      score[s.workspaceName] = (score[s.workspaceName] ?? 0) + 1;
      final prevMs = latestMs[s.workspaceName] ?? 0;
      if (s.updatedAtMs > prevMs) latestMs[s.workspaceName] = s.updatedAtMs;
    }

    final list = score.keys.toList();
    list.sort((a, b) {
      final aActive = a.toLowerCase() == activeName.toLowerCase();
      final bActive = b.toLowerCase() == activeName.toLowerCase();
      if (aActive != bActive) return aActive ? -1 : 1;
      final aOpen = openInIde.contains(a);
      final bOpen = openInIde.contains(b);
      if (aOpen != bOpen) return aOpen ? -1 : 1;
      final cDiff = (score[b] ?? 0).compareTo(score[a] ?? 0);
      if (cDiff != 0) return cDiff;
      final tDiff = (latestMs[b] ?? 0).compareTo(latestMs[a] ?? 0);
      if (tDiff != 0) return tDiff;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return list;
  }

  void _showSessionActionsSheet(BuildContext context, BridgeController ctrl, SessionSummary sess) {
    final isPinned = ctrl.isSessionPinned(sess.id);
    final isWorking = sess.status == 'working';
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
              const SizedBox(height: 12),
              Text(
                TelemetryFormatters.cleanSessionTitle(sess.title),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                leading: Icon(
                  isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  color: TelemetryColors.warn,
                ),
                title: Text(isPinned ? 'Открепить сессию' : 'Закрепить сессию'),
                onTap: () {
                  Navigator.pop(ctx);
                  ctrl.togglePinSession(sess.id);
                },
              ),
              if (isWorking)
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: const Icon(Icons.stop_circle_outlined, color: TelemetryColors.danger),
                  title: const Text('Остановить задачу'),
                  onTap: () {
                    Navigator.pop(ctx);
                    ctrl.stopSession(sess.id);
                  },
                ),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                leading: const Icon(Icons.copy_rounded, color: TelemetryColors.textSecondary),
                title: const Text('Скопировать ID сессии'),
                subtitle: Text(
                  sess.id,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: sess.id));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(
                      content: Text('ID сессии скопирован'),
                      duration: Duration(milliseconds: 1100),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
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
    final currentMachineId = ctrl.activeMachine?.machineId;
    if (currentMachineId != _lastMachineId) {
      _lastMachineId = currentMachineId;
      _query = '';
      _statusFilter = 'all';
      if (_searchCtrl.text.isNotEmpty) {
        _searchCtrl.clear();
      }
    }
    final q = _query.trim();
    final filtered = ctrl.filterAndSortSessions(
      query: q,
      statusFilter: _statusFilter,
    );
    final workingCount = ctrl.sessions.where((s) => s.status == 'working').length;
    final pinnedCount = ctrl.sessions.where((s) => ctrl.isSessionPinned(s.id)).length;
    final wsNames = _collectWorkspaceNames(ctrl);
    final isOffline = ctrl.phase != ConnectionPhase.connected;
    final cleanHost = TelemetryFormatters.cleanMachineName(ctrl.activeMachine?.machineName ?? 'ПК');
    final hasConnError = ctrl.lastError != null && ctrl.lastError!.isNotEmpty;
    final inTest = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

    return Column(
      children: [
        // Search + New Session Bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Поиск сессий и текста…',
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        size: 19,
                        color: TelemetryColors.textDim,
                      ),
                      suffixIcon: q.isEmpty
                          ? null
                          : IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 17,
                                color: TelemetryColors.textDim,
                              ),
                            ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      filled: true,
                      fillColor: TelemetryColors.bgPanel,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: TelemetryColors.border),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 42,
                child: FilledButton.icon(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    widget.onStartNewSession();
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 19),
                  label: const Text('Новый'),
                ),
              ),
            ],
          ),
        ),

        // Status & Workspace Filter Chips (#20 & #21)
        if (ctrl.sessions.isNotEmpty || wsNames.isNotEmpty)
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              children: [
                _FilterChipPill(
                  label: 'Все (${ctrl.sessions.length})',
                  active: _statusFilter == 'all' && ctrl.selectedWorkspaceFilter.isEmpty,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _statusFilter = 'all');
                    ctrl.setWorkspaceFilter('');
                  },
                ),
                if (workingCount > 0 || _statusFilter == 'working')
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: _FilterChipPill(
                      icon: Icons.bolt_rounded,
                      iconColor: TelemetryColors.live,
                      label: 'В работе ($workingCount)',
                      active: _statusFilter == 'working',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _statusFilter = _statusFilter == 'working' ? 'all' : 'working';
                        });
                      },
                    ),
                  ),
                if (pinnedCount > 0 || _statusFilter == 'pinned')
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: _FilterChipPill(
                      icon: Icons.push_pin_rounded,
                      iconColor: TelemetryColors.warn,
                      label: 'Закреплённые ($pinnedCount)',
                      active: _statusFilter == 'pinned',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _statusFilter = _statusFilter == 'pinned' ? 'all' : 'pinned';
                        });
                      },
                    ),
                  ),
                for (final wsName in wsNames)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: _FilterChipPill(
                      icon: Icons.folder_outlined,
                      iconColor: TelemetryColors.cyan,
                      label: wsName,
                      active: ctrl.selectedWorkspaceFilter.toLowerCase() ==
                          wsName.toLowerCase(),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        final already = ctrl.selectedWorkspaceFilter.toLowerCase() ==
                            wsName.toLowerCase();
                        ctrl.setWorkspaceFilter(already ? '' : wsName);
                      },
                    ),
                  ),
              ],
            ),
          ),

        if (hasConnError && (filtered.isNotEmpty || !isOffline))
          Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            decoration: BoxDecoration(
              color: TelemetryColors.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TelemetryColors.danger.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 17, color: TelemetryColors.danger),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isOffline && ctrl.sessionsFromCache)
                        const Text(
                          'Показан кэш (офлайн)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: TelemetryColors.warn,
                          ),
                        ),
                      Text(
                        ctrl.lastError!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: TelemetryColors.textPrimary),
                      ),
                    ],
                  ),
                ),
                if (isOffline) ...[
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: TelemetryColors.accentBright,
                    ),
                    onPressed: ctrl.reconnectNow,
                    child: const Text('Повторить', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      foregroundColor: TelemetryColors.textSecondary,
                    ),
                    onPressed: ctrl.disconnect,
                    child: const Text('Сменить ПК', style: TextStyle(fontSize: 12)),
                  ),
                ] else
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                    onPressed: ctrl.clearError,
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: TelemetryColors.textSecondary,
                    ),
                  ),
              ],
            ),
          )
        else if (!hasConnError && (isOffline || ctrl.loadingSessions) && filtered.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: TelemetryColors.bgPanel,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: TelemetryColors.borderStrong),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: inTest ? 0.65 : null,
                    color: TelemetryColors.accentBright,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    isOffline && ctrl.sessionsFromCache
                        ? 'Показан кэш · Подключение к $cleanHost…'
                        : (isOffline
                              ? 'Подключение к $cleanHost…'
                              : 'Обновление списка чатов…'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: TelemetryColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),

        Expanded(
          child: RefreshIndicator(
            color: TelemetryColors.accentBright,
            backgroundColor: TelemetryColors.bgElevated,
            onRefresh: () async {
              if (ctrl.phase != ConnectionPhase.connected) {
                ctrl.reconnectNow();
              }
              ctrl.sendRpc('sessions.list', const {});
              ctrl.sendRpc('workspaces.list', const {});
              await Future<void>.delayed(const Duration(milliseconds: 350));
            },
            child: filtered.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(height: MediaQuery.of(context).size.height * 0.16),
                      if (q.isEmpty &&
                          _statusFilter == 'all' &&
                          ctrl.selectedWorkspaceFilter.isEmpty &&
                          hasConnError &&
                          isOffline) ...[
                        const Icon(
                          Icons.cloud_off_rounded,
                          size: 42,
                          color: TelemetryColors.danger,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Не удалось подключиться к $cleanHost',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: TelemetryColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            ctrl.lastError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12.5, color: TelemetryColors.textSecondary),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: ctrl.reconnectNow,
                              icon: const Icon(Icons.refresh_rounded, size: 17),
                              label: const Text('Повторить'),
                            ),
                            OutlinedButton.icon(
                              onPressed: ctrl.disconnect,
                              icon: const Icon(Icons.devices_rounded, size: 17),
                              label: const Text('Выбрать другой ПК'),
                            ),
                          ],
                        ),
                      ] else if (q.isEmpty &&
                          _statusFilter == 'all' &&
                          ctrl.selectedWorkspaceFilter.isEmpty &&
                          (isOffline || ctrl.loadingSessions)) ...[
                        Center(
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.6,
                              value: inTest ? 0.65 : null,
                              color: TelemetryColors.accentBright,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          isOffline ? 'Подключение к $cleanHost…' : 'Загрузка чатов…',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: TelemetryColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 40),
                          child: Text(
                            'Получаем список сессий с компьютера.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: TelemetryColors.textSecondary),
                          ),
                        ),
                      ] else ...[
                        Icon(
                          q.isEmpty && _statusFilter == 'all' && ctrl.selectedWorkspaceFilter.isEmpty
                              ? Icons.auto_awesome_mosaic_outlined
                              : Icons.search_off_rounded,
                          size: 42,
                          color: TelemetryColors.textDim,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          q.isEmpty && _statusFilter == 'all' && ctrl.selectedWorkspaceFilter.isEmpty
                              ? 'Сессий пока нет'
                              : (q.isNotEmpty
                                  ? 'По запросу «$_query» ничего не найдено'
                                  : 'По выбранному фильтру ничего не найдено'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: TelemetryColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Text(
                            q.isEmpty && _statusFilter == 'all' && ctrl.selectedWorkspaceFilter.isEmpty
                                ? 'Нажмите «Новый», чтобы запустить новую задачу Antigravity с телефона.'
                                : 'Попробуйте сбросить фильтры или изменить поисковый запрос.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, color: TelemetryColors.textSecondary),
                          ),
                        ),
                      ],
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 92),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, idx) {
                      final sess = filtered[idx];
                      return _SessionTile(
                        session: sess,
                        isSelected: sess.id == ctrl.activeConversationId,
                        isPinned: ctrl.isSessionPinned(sess.id),
                        showCachedBadge: isOffline && ctrl.isSessionCached(sess.id),
                        onTogglePin: () {
                          HapticFeedback.selectionClick();
                          ctrl.togglePinSession(sess.id);
                        },
                        onStop: sess.status == 'working'
                            ? () {
                                HapticFeedback.mediumImpact();
                                ctrl.stopSession(sess.id);
                              }
                            : null,
                        onLongPress: () => _showSessionActionsSheet(context, ctrl, sess),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          widget.onSelectSession(sess.id);
                        },
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _FilterChipPill extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterChipPill({
    this.icon,
    this.iconColor,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? TelemetryColors.accent.withValues(alpha: 0.18)
          : TelemetryColors.bgPanel,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: active
                  ? TelemetryColors.accent.withValues(alpha: 0.6)
                  : TelemetryColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 13,
                  color: active ? TelemetryColors.accentBright : (iconColor ?? TelemetryColors.textSecondary),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? TelemetryColors.textPrimary : TelemetryColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final SessionSummary session;
  final bool isSelected;
  final bool isPinned;
  final bool showCachedBadge;
  final VoidCallback onTogglePin;
  final VoidCallback? onStop;
  final VoidCallback? onLongPress;
  final VoidCallback onTap;

  const _SessionTile({
    required this.session,
    required this.isSelected,
    required this.isPinned,
    required this.showCachedBadge,
    required this.onTogglePin,
    this.onStop,
    this.onLongPress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isWorking = session.status == 'working';
    final isError = session.status == 'error';
    final statusColor = isWorking
        ? TelemetryColors.live
        : isError
            ? TelemetryColors.danger
            : TelemetryColors.textDim;

    final timeStr = TelemetryFormatters.relativeTime(session.updatedAtMs);
    final activityStr = TelemetryFormatters.cleanActivity(session.lastActivity);
    final displayTitle = TelemetryFormatters.cleanSessionTitle(session.title);

    return Material(
      color: isSelected ? TelemetryColors.bgElevated : TelemetryColors.bgPanel,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: isSelected
                  ? TelemetryColors.accent.withValues(alpha: 0.65)
                  : isPinned
                      ? TelemetryColors.warn.withValues(alpha: 0.35)
                      : TelemetryColors.border,
              width: isSelected ? 1.2 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5, right: 9),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor,
                        boxShadow: isWorking
                            ? [
                                BoxShadow(
                                  color: TelemetryColors.live.withValues(alpha: 0.6),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                        letterSpacing: -0.2,
                        color: TelemetryColors.textPrimary,
                      ),
                    ),
                  ),
                  if (timeStr.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        timeStr,
                        style: const TextStyle(
                          fontSize: 11,
                          color: TelemetryColors.textDim,
                        ),
                      ),
                    ),
                  ],
                  if (isWorking && onStop != null) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Остановить сессию',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: onStop,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: TelemetryColors.danger.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: TelemetryColors.danger.withValues(alpha: 0.45),
                            ),
                          ),
                          child: const Icon(
                            Icons.stop_rounded,
                            size: 14,
                            color: TelemetryColors.danger,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: onTogglePin,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      child: Icon(
                        isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                        size: 16,
                        color: isPinned ? TelemetryColors.warn : TelemetryColors.textDim,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 17, right: 4),
                child: Text(
                  activityStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isWorking ? TelemetryColors.live : TelemetryColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 17, right: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (session.workspaceName.isNotEmpty)
                      _MetaPill(
                        icon: Icons.folder_outlined,
                        label: session.workspaceName,
                        accent: TelemetryColors.cyan,
                      ),
                    _MetaPill(
                      icon: Icons.bolt_rounded,
                      label: '${session.stepCount} шагов',
                    ),
                    if (session.artifactCount > 0)
                      _MetaPill(
                        icon: Icons.description_outlined,
                        label: '${session.artifactCount} док.',
                        accent: TelemetryColors.accentBright,
                      ),
                    if (showCachedBadge)
                      const _MetaPill(
                        icon: Icons.offline_pin_outlined,
                        label: 'Офлайн-кэш',
                        accent: TelemetryColors.live,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? accent;

  const _MetaPill({required this.icon, required this.label, this.accent});

  @override
  Widget build(BuildContext context) {
    final c = accent ?? TelemetryColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: TelemetryColors.bgCanvas.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: TelemetryColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
