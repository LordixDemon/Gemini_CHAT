import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/remote_models.dart';
import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import 'chat_view.dart';
import 'pending_changes_sheet.dart';

class GitDiffView extends StatefulWidget {
  final BridgeController controller;

  const GitDiffView({super.key, required this.controller});

  @override
  State<GitDiffView> createState() => _GitDiffViewState();
}

class _GitDiffViewState extends State<GitDiffView> {
  final _filterCtrl = TextEditingController();
  String _fileQuery = '';
  bool _wrapLines = false;

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  (Color, String) _statusStyle(String rawStatus) {
    final s = rawStatus.trim();
    if (s.contains('?') || s.contains('A')) return (TelemetryColors.live, 'NEW');
    if (s.contains('D')) return (TelemetryColors.danger, 'DEL');
    return (TelemetryColors.warn, 'MOD');
  }

  (String, String) _splitPath(String full) {
    final normalized = full.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx == -1) return ('', normalized);
    return (normalized.substring(0, idx + 1), normalized.substring(idx + 1));
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final fq = _fileQuery.trim().toLowerCase();
    final visibleFiles = fq.isEmpty
        ? ctrl.gitFiles
        : ctrl.gitFiles.where((f) => f.path.toLowerCase().contains(fq)).toList();

    return RefreshIndicator(
      color: TelemetryColors.accentBright,
      backgroundColor: TelemetryColors.bgElevated,
      onRefresh: () async {
        ctrl.sendRpc('workspace.status', const {});
        await Future<void>.delayed(const Duration(milliseconds: 400));
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 92),
        children: [
          // Project + Branch + Changed Files Summary Card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: TelemetryColors.bgPanel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: TelemetryColors.border),
            ),
            child: Row(
              children: [
                if (ctrl.workspaces.isNotEmpty || ctrl.activeWorkspaceName != 'Проект') ...[
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => showWorkspacePickerSheet(context, ctrl),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
                            size: 13,
                            color: TelemetryColors.cyan,
                          ),
                          const SizedBox(width: 5),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 112),
                            child: Text(
                              ctrl.activeWorkspaceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: TelemetryColors.textPrimary,
                              ),
                            ),
                          ),
                          if (ctrl.workspaces.length > 1) ...[
                            const SizedBox(width: 1),
                            const Icon(
                              Icons.arrow_drop_down_rounded,
                              size: 15,
                              color: TelemetryColors.textDim,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: TelemetryColors.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.account_tree_outlined,
                        size: 13,
                        color: TelemetryColors.accentBright,
                      ),
                      const SizedBox(width: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 92),
                        child: Text(
                          ctrl.gitBranch,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: TelemetryColors.accentBright,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '${ctrl.gitFiles.length} изм.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: TelemetryColors.textSecondary),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Обновить Git статус',
                  onPressed: () => ctrl.sendRpc('workspace.status', const {}),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          if (ctrl.gitFiles.length > 8) ...[
            SizedBox(
              height: 38,
              child: TextField(
                controller: _filterCtrl,
                onChanged: (v) => setState(() => _fileQuery = v),
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: 'Фильтр по имени или папке файла…',
                  prefixIcon: const Icon(
                    Icons.filter_list_rounded,
                    size: 18,
                    color: TelemetryColors.textDim,
                  ),
                  suffixIcon: fq.isEmpty
                      ? null
                      : IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            _filterCtrl.clear();
                            setState(() => _fileQuery = '');
                          },
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: TelemetryColors.textDim,
                          ),
                        ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  filled: true,
                  fillColor: TelemetryColors.bgPanel,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(11),
                    borderSide: const BorderSide(color: TelemetryColors.border),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],

          if (ctrl.pendingChanges.isNotEmpty) ...[
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showPendingChangesSheet(context, ctrl),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: TelemetryColors.bgElevated,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: TelemetryColors.borderStrong),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.history_edu_rounded, size: 17, color: TelemetryColors.live),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Правки текущей задачи: ${formatFilesCountRu(ctrl.pendingChanges.length)}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 18, color: TelemetryColors.textDim),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],

          if (ctrl.gitFiles.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 38, horizontal: 20),
              decoration: BoxDecoration(
                color: TelemetryColors.bgPanel,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: TelemetryColors.border),
              ),
              child: Column(
                children: [
                  const Icon(Icons.check_circle_outline_rounded, size: 36, color: TelemetryColors.live),
                  const SizedBox(height: 10),
                  const Text(
                    'Рабочее дерево чистое',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  if (ctrl.workspacePath.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      ctrl.workspacePath,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: TelemetryColors.textDim,
                      ),
                    ),
                  ],
                ],
              ),
            )
          else if (visibleFiles.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
              decoration: BoxDecoration(
                color: TelemetryColors.bgPanel,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: TelemetryColors.border),
              ),
              child: Text(
                'Файлы по фильтру «$_fileQuery» не найдены',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13.5, color: TelemetryColors.textSecondary),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: TelemetryColors.bgPanel,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: TelemetryColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < visibleFiles.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: TelemetryColors.border),
                    _buildFileRow(ctrl, visibleFiles[i]),
                  ],
                ],
              ),
            ),

          if (ctrl.selectedDiffPath != null) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                const Icon(Icons.difference_outlined, size: 16, color: TelemetryColors.cyan),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    ctrl.selectedDiffPath!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: TelemetryColors.textSecondary,
                  ),
                  onPressed: () => setState(() => _wrapLines = !_wrapLines),
                  icon: Icon(
                    _wrapLines ? Icons.wrap_text_rounded : Icons.swap_horiz_rounded,
                    size: 15,
                  ),
                  label: Text(_wrapLines ? 'Перенос' : 'Скролл', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _UnifiedDiffBox(diff: ctrl.selectedDiffContent, wrapLines: _wrapLines),
          ],
        ],
      ),
    );
  }

  Widget _buildFileRow(BridgeController ctrl, GitFileChange file) {
    final isSelected = ctrl.selectedDiffPath == file.path;
    final (badgeColor, badgeText) = _statusStyle(file.status);
    final (dirPart, baseName) = _splitPath(file.path);

    return Material(
      color: isSelected ? TelemetryColors.accent.withValues(alpha: 0.12) : Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          ctrl.requestFileDiff(file.path);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 38,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.14),
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
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      baseName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? TelemetryColors.accentBright
                            : TelemetryColors.textPrimary,
                      ),
                    ),
                    if (dirPart.isNotEmpty)
                      Text(
                        dirPart,
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
              Icon(
                isSelected ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded,
                size: 18,
                color: TelemetryColors.textDim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnifiedDiffBox extends StatelessWidget {
  final String diff;
  final bool wrapLines;

  const _UnifiedDiffBox({required this.diff, required this.wrapLines});

  @override
  Widget build(BuildContext context) {
    final lines = diff.replaceAll('\r\n', '\n').split('\n');

    Widget buildRows() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++) _buildLine(i + 1, lines[i]),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: TelemetryColors.bgCode,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TelemetryColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: wrapLines
          ? Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: buildRows())
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicWidth(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 34),
                    child: buildRows(),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildLine(int index, String line) {
    final isAdd = line.startsWith('+') && !line.startsWith('+++');
    final isDel = line.startsWith('-') && !line.startsWith('---');
    final isHunk = line.startsWith('@@');

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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '$index',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: TelemetryColors.textDim,
              ),
            ),
          ),
          if (wrapLines)
            Expanded(
              child: Text(
                line.isEmpty ? ' ' : line,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4, color: fg),
              ),
            )
          else
            Text(
              line.isEmpty ? ' ' : line,
              style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4, color: fg),
            ),
        ],
      ),
    );
  }
}

