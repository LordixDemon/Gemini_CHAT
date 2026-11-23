import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bridge_controller.dart';
import '../theme/telemetry_theme.dart';
import 'chat_view.dart';

final RegExp _ansiEscRe = RegExp(r'\x1B\[([0-9;]*)([A-Za-z])|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');

String stripAnsi(String input) => input.replaceAll(_ansiEscRe, '');

List<InlineSpan> parseAnsiSpans(String input) {
  if (!input.contains('\x1B')) {
    return [TextSpan(text: input)];
  }
  const palette = <int, Color>{
    30: Color(0xFF475569),
    31: Color(0xFFF87171),
    32: Color(0xFF4ADE80),
    33: Color(0xFFFBBF24),
    34: Color(0xFF60A5FA),
    35: Color(0xFFC084FC),
    36: Color(0xFF38BDF8),
    37: Color(0xFFE2E8F0),
    90: Color(0xFF64748B),
    91: Color(0xFFFCA5A5),
    92: Color(0xFF86EFAC),
    93: Color(0xFFFDE047),
    94: Color(0xFF93C5FD),
    95: Color(0xFFD8B4FE),
    96: Color(0xFF67E8F9),
    97: Color(0xFFF8FAFC),
  };

  final spans = <InlineSpan>[];
  var cursor = 0;
  Color? currentColor;
  var bold = false;

  for (final m in _ansiEscRe.allMatches(input)) {
    if (m.start > cursor) {
      spans.add(
        TextSpan(
          text: input.substring(cursor, m.start),
          style: TextStyle(
            color: currentColor,
            fontWeight: bold ? FontWeight.w700 : null,
          ),
        ),
      );
    }
    final cmd = m.group(2);
    if (cmd == 'm') {
      final rawParams = m.group(1) ?? '';
      final codes = rawParams.isEmpty
          ? const [0]
          : rawParams.split(';').map((s) => int.tryParse(s) ?? 0).toList();
      for (final code in codes) {
        if (code == 0) {
          currentColor = null;
          bold = false;
        } else if (code == 1) {
          bold = true;
        } else if (code == 22) {
          bold = false;
        } else if (code == 39) {
          currentColor = null;
        } else if (palette.containsKey(code)) {
          currentColor = palette[code];
        }
      }
    }
    cursor = m.end;
  }

  if (cursor < input.length) {
    spans.add(
      TextSpan(
        text: input.substring(cursor),
        style: TextStyle(
          color: currentColor,
          fontWeight: bold ? FontWeight.w700 : null,
        ),
      ),
    );
  }
  return spans.isEmpty ? const [TextSpan(text: '')] : spans;
}

class TerminalView extends StatefulWidget {
  final BridgeController controller;

  const TerminalView({super.key, required this.controller});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  static const List<String> _defaultPresets = [
    'git status -sb',
    'npm test',
    'flutter analyze',
    'git log -n 5 --oneline',
    'ls -la',
  ];

  final _cmdCtrl = TextEditingController();
  final _outputScrollCtrl = ScrollController();
  bool _wrapLines = true;
  String _lastOutput = '';

  @override
  void dispose() {
    _cmdCtrl.dispose();
    _outputScrollCtrl.dispose();
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
    if (ctrl.terminalOutput != _lastOutput) {
      _lastOutput = ctrl.terminalOutput;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_outputScrollCtrl.hasClients) return;
        _outputScrollCtrl.animateTo(
          _outputScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      });
    }

    final historySet = ctrl.terminalHistory.toSet();
    final chips = <(String, bool)>[
      for (final h in ctrl.terminalHistory) (h, true),
      for (final p in _defaultPresets)
        if (!historySet.contains(p)) (p, false),
    ];

    return Column(
      children: [
        // Preset + History Chips Bar
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final chip in chips)
                Padding(
                  padding: const EdgeInsets.only(right: 7, top: 6, bottom: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: ctrl.terminalBusy ? null : () => _submit(chip.$1),
                    onLongPress: () {
                      _cmdCtrl.text = chip.$1;
                      _cmdCtrl.selection = TextSelection.collapsed(offset: chip.$1.length);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: TelemetryColors.bgPanel,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: chip.$2
                              ? TelemetryColors.accent.withValues(alpha: 0.35)
                              : TelemetryColors.border,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (chip.$2) ...[
                            const Icon(
                              Icons.history_rounded,
                              size: 12,
                              color: TelemetryColors.accentBright,
                            ),
                            const SizedBox(width: 4),
                          ] else
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
                            chip.$1,
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
                            setState(() => _wrapLines = !_wrapLines);
                          },
                          child: Tooltip(
                            message: _wrapLines ? 'Горизонтальный скролл' : 'Перенос строк',
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                _wrapLines
                                    ? Icons.wrap_text_rounded
                                    : Icons.swap_horiz_rounded,
                                size: 15,
                                color: TelemetryColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
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
                            Clipboard.setData(ClipboardData(text: stripAnsi(ctrl.terminalOutput)));
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
                    controller: _outputScrollCtrl,
                    padding: const EdgeInsets.all(14),
                    child: _wrapLines
                        ? SelectableText.rich(
                            TextSpan(
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5 * ctrl.chatFontScale,
                                height: 1.48,
                                color: const Color(0xFFD8DEE9),
                              ),
                              children: parseAnsiSpans(ctrl.terminalOutput),
                            ),
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SelectableText.rich(
                              TextSpan(
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12.5 * ctrl.chatFontScale,
                                  height: 1.48,
                                  color: const Color(0xFFD8DEE9),
                                ),
                                children: parseAnsiSpans(ctrl.terminalOutput),
                              ),
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

