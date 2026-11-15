import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import 'chat_view.dart';

class TerminalView extends StatefulWidget {
  final BridgeController controller;

  const TerminalView({super.key, required this.controller});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final _cmdCtrl = TextEditingController();

  @override
  void dispose() {
    _cmdCtrl.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final clean = raw.trim();
    if (clean.isEmpty || widget.controller.terminalBusy) return;
    HapticFeedback.lightImpact();
    widget.controller.runQuickCommand(clean);
    _cmdCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;

    return Column(
      children: [
        // Preset Chips Bar
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final preset in const [
                'git status -sb',
                'npm test',
                'flutter analyze',
                'git log -n 5 --oneline',
                'ls -la',
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 7, top: 6, bottom: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: ctrl.terminalBusy ? null : () => _submit(preset),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: TelemetryColors.bgPanel,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: TelemetryColors.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            '\$ ',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: TelemetryColors.live,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            preset,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: TelemetryColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Warp-style Console Window
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            decoration: BoxDecoration(
              color: TelemetryColors.bgCode,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: TelemetryColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Console Chrome Bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: const BoxDecoration(
                    color: TelemetryColors.bgPanel,
                    border: Border(bottom: BorderSide(color: TelemetryColors.border)),
                  ),
                  child: Row(
                    children: [
                      _dot(const Color(0xFFFF5F56)),
                      const SizedBox(width: 6),
                      _dot(const Color(0xFFFFBD2E)),
                      const SizedBox(width: 6),
                      _dot(const Color(0xFF27C93F)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: ctrl.workspaces.isEmpty
                              ? null
                              : () => showWorkspacePickerSheet(context, ctrl),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    ctrl.workspacePath.isEmpty
                                        ? (ctrl.activeWorkspace.isEmpty
                                            ? 'zsh • remote'
                                            : ctrl.activeWorkspace)
                                        : ctrl.workspacePath,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: TelemetryColors.textSecondary,
                                    ),
                                  ),
                                ),
                                if (ctrl.workspaces.length > 1)
                                  const Icon(
                                    Icons.arrow_drop_down_rounded,
                                    size: 15,
                                    color: TelemetryColors.textDim,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (ctrl.terminalBusy)
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: TelemetryColors.cyan,
                          ),
                        )
                      else ...[
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            ctrl.clearTerminalOutput();
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.delete_sweep_outlined,
                              size: 15,
                              color: TelemetryColors.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: ctrl.terminalOutput));
                            HapticFeedback.selectionClick();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Вывод терминала скопирован'),
                                duration: Duration(milliseconds: 1100),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.copy_rounded,
                              size: 14,
                              color: TelemetryColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(14),
                    child: SelectableText(
                      ctrl.terminalOutput,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.48,
                        color: Color(0xFFD8DEE9),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Unified Rounded Capsule Command Input Bar
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          decoration: const BoxDecoration(
            color: TelemetryColors.bgCanvas,
            border: Border(top: BorderSide(color: TelemetryColors.border)),
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 5, 5, 5),
            decoration: BoxDecoration(
              color: TelemetryColors.bgPanel,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: TelemetryColors.borderStrong),
            ),
            child: Row(
              children: [
                const Text(
                  '\$',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: TelemetryColors.live,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _cmdCtrl,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5),
                    decoration: const InputDecoration(
                      hintText: 'Введите shell-команду…',
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 7),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    onSubmitted: _submit,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ctrl.terminalBusy ? TelemetryColors.bgElevated : TelemetryColors.accent,
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: 'Выполнить команду',
                    onPressed: ctrl.terminalBusy ? null : () => _submit(_cmdCtrl.text),
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      size: 20,
                      color: ctrl.terminalBusy ? TelemetryColors.textDim : Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dot(Color c) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(shape: BoxShape.circle, color: c),
      );
}

