import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/telemetry_theme.dart';

/// Lightweight, 120fps native Markdown renderer tailored for Antigravity messages & plans:
/// - Headings (`#`, `##`, `###`, `####`)
/// - Fenced code blocks (` ```lang ... ``` `) with multi-language syntax highlighting,
///   non-copied line numbers, horizontal scroll, one-tap copy, and folding >28 lines
/// - GitHub-Flavored Markdown Tables (`| Col | Col |`) with horizontal scroll
/// - GitHub-Flavored Alerts (`> [!IMPORTANT]`, `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]`, `> [!CAUTION]`) & Blockquotes
/// - Bullet & numbered lists (`- `, `* `, `1. `)
/// - Inline `**bold**`, `*italic*`, `` `code` ``, and clean `[file](file:///...)` chips!
class MarkdownBodyView extends StatelessWidget {
  final String data;
  final double fontSize;
  final Color textColor;

  const MarkdownBodyView({
    super.key,
    required this.data,
    this.fontSize = 14.5,
    this.textColor = TelemetryColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) SizedBox(height: blocks[i].topSpacing),
          blocks[i].build(context, fontSize: fontSize, textColor: textColor),
        ],
      ],
    );
  }

  static bool _isTableSeparatorLine(String s) {
    final t = s.trim();
    if (!t.contains('|') || !t.contains('-')) return false;
    final cells = _splitTableRow(t);
    if (cells.isEmpty) return false;
    return cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c.trim()));
  }

  static List<String> _splitTableRow(String rawLine) {
    var s = rawLine.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|')) s = s.substring(0, s.length - 1);
    return s.split('|').map((c) => c.trim()).toList();
  }

  List<_MdBlock> _parseBlocks(String raw) {
    final lines = raw.replaceAll('\r\n', '\n').split('\n');
    final out = <_MdBlock>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // Horizontal rule
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        out.add(const _DividerBlock());
        i++;
        continue;
      }

      // Fenced code block (3 or 4 backticks)
      final fenceMatch = RegExp(r'^(`{3,})(.*)$').firstMatch(trimmed);
      if (fenceMatch != null) {
        final fenceTicks = fenceMatch.group(1)!;
        final lang = fenceMatch.group(2)!.trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith(fenceTicks)) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // skip closing fence
        out.add(_CodeFenceBlock(language: lang, code: codeLines.join('\n')));
        continue;
      }

      // GFM Table (Header row containing '|' followed by separator row '| --- | --- |')
      if (trimmed.contains('|') && i + 1 < lines.length && _isTableSeparatorLine(lines[i + 1])) {
        final headers = _splitTableRow(trimmed);
        i += 2; // skip header + separator
        final rows = <List<String>>[];
        while (i < lines.length) {
          final rowTrim = lines[i].trim();
          if (rowTrim.isEmpty || !rowTrim.contains('|') || rowTrim.startsWith('```')) {
            break;
          }
          if (!_isTableSeparatorLine(rowTrim)) {
            rows.add(_splitTableRow(rowTrim));
          }
          i++;
        }
        if (headers.isNotEmpty) {
          out.add(_TableBlock(headers: headers, rows: rows));
          continue;
        }
      }

      // Heading (#, ##, ###, ####)
      final headingMatch = RegExp(r'^(#{1,4})\s+(.+)$').firstMatch(trimmed);
      if (headingMatch != null) {
        out.add(_HeadingBlock(
          level: headingMatch.group(1)!.length,
          text: headingMatch.group(2)!.trim(),
        ));
        i++;
        continue;
      }

      // Blockquote / GFM Alert (> ...)
      if (trimmed.startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          quoteLines.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        out.add(_QuoteBlock(lines: quoteLines));
        continue;
      }

      // Bullet or numbered list item
      final listMatch = RegExp(r'^(\s*)([-*•]|\d+\.)\s+(.+)$').firstMatch(line);
      if (listMatch != null) {
        final indent = (listMatch.group(1)!.length / 2).floor().clamp(0, 3);
        final marker = listMatch.group(2)!;
        final itemLines = <String>[listMatch.group(3)!.trim()];
        i++;
        while (i < lines.length) {
          final next = lines[i];
          final nextTrim = next.trim();
          if (nextTrim.isEmpty ||
              nextTrim.startsWith('```') ||
              nextTrim.startsWith('#') ||
              nextTrim.startsWith('>') ||
              (nextTrim.contains('|') &&
                  i + 1 < lines.length &&
                  _isTableSeparatorLine(lines[i + 1])) ||
              RegExp(r'^(\s*)([-*•]|\d+\.)\s+').hasMatch(next)) {
            break;
          }
          itemLines.add(nextTrim);
          i++;
        }
        out.add(_ListItemBlock(
          indent: indent,
          bullet: RegExp(r'^\d+\.$').hasMatch(marker) ? marker : '•',
          text: itemLines.join(' '),
        ));
        continue;
      }

      // Standard paragraph
      final paraLines = <String>[trimmed];
      i++;
      while (i < lines.length) {
        final next = lines[i];
        final nextTrim = next.trim();
        if (nextTrim.isEmpty ||
            nextTrim.startsWith('```') ||
            nextTrim.startsWith('#') ||
            nextTrim.startsWith('>') ||
            (nextTrim.contains('|') &&
                i + 1 < lines.length &&
                _isTableSeparatorLine(lines[i + 1])) ||
            RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(nextTrim) ||
            RegExp(r'^(\s*)([-*•]|\d+\.)\s+').hasMatch(next)) {
          break;
        }
        paraLines.add(nextTrim);
        i++;
      }
      out.add(_ParagraphBlock(text: paraLines.join('\n')));
    }

    return out;
  }
}

abstract class _MdBlock {
  final double topSpacing;
  const _MdBlock({this.topSpacing = 8});

  Widget build(BuildContext context, {required double fontSize, required Color textColor});
}

class _DividerBlock extends _MdBlock {
  const _DividerBlock() : super(topSpacing: 12);

  @override
  Widget build(BuildContext context, {required double fontSize, required Color textColor}) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Divider(height: 1, color: TelemetryColors.border),
    );
  }
}

class _HeadingBlock extends _MdBlock {
  final int level;
  final String text;

  const _HeadingBlock({required this.level, required this.text}) : super(topSpacing: 12);

  @override
  Widget build(BuildContext context, {required double fontSize, required Color textColor}) {
    final scale = level == 1
        ? 1.24
        : level == 2
            ? 1.12
            : 1.04;
    return SelectableText.rich(
      TextSpan(
        style: TextStyle(
          fontSize: fontSize * scale,
          fontWeight: FontWeight.w700,
          color: TelemetryColors.textPrimary,
          height: 1.32,
          letterSpacing: -0.25,
        ),
        children: _parseInlineSpans(text, fontSize * scale, TelemetryColors.textPrimary),
      ),
    );
  }
}

class _ParagraphBlock extends _MdBlock {
  final String text;
  const _ParagraphBlock({required this.text}) : super(topSpacing: 8);

  @override
  Widget build(BuildContext context, {required double fontSize, required Color textColor}) {
    return SelectableText.rich(
      TextSpan(
        style: TextStyle(fontSize: fontSize, color: textColor, height: 1.48),
        children: _parseInlineSpans(text, fontSize, textColor),
      ),
    );
  }
}

class _QuoteBlock extends _MdBlock {
  final List<String> lines;
  const _QuoteBlock({required this.lines}) : super(topSpacing: 8);

  @override
  Widget build(BuildContext context, {required double fontSize, required Color textColor}) {
    Color borderColor = TelemetryColors.accent;
    String? badgeLabel;
    var bodyLines = lines;

    if (lines.isNotEmpty) {
      final alertMatch =
          RegExp(r'^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$', caseSensitive: false)
              .firstMatch(lines.first);
      if (alertMatch != null) {
        final kind = alertMatch.group(1)!.toUpperCase();
        final trailing = alertMatch.group(2)!.trim();
        switch (kind) {
          case 'IMPORTANT':
            borderColor = TelemetryColors.accentBright;
            badgeLabel = 'ВАЖНО';
            break;
          case 'TIP':
            borderColor = TelemetryColors.live;
            badgeLabel = 'СОВЕТ';
            break;
          case 'WARNING':
            borderColor = TelemetryColors.warn;
            badgeLabel = 'ВНИМАНИЕ';
            break;
          case 'CAUTION':
            borderColor = TelemetryColors.danger;
            badgeLabel = 'ОСТОРОЖНО';
            break;
          default:
            borderColor = TelemetryColors.cyan;
            badgeLabel = 'ЗАМЕТКА';
            break;
        }
        bodyLines = [
          if (trailing.isNotEmpty) trailing,
          ...lines.skip(1),
        ];
      }
    }

    final bodyText = bodyLines.join('\n').trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: borderColor.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(10),
          bottomRight: Radius.circular(10),
        ),
        border: Border(left: BorderSide(color: borderColor, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (badgeLabel != null)
            Padding(
              padding: EdgeInsets.only(bottom: bodyText.isEmpty ? 0 : 4),
              child: Text(
                badgeLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: borderColor,
                ),
              ),
            ),
          if (bodyText.isNotEmpty)
            SelectableText.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: fontSize - 0.5,
                  color: TelemetryColors.textSecondary,
                  height: 1.45,
                ),
                children:
                    _parseInlineSpans(bodyText, fontSize - 0.5, TelemetryColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _TableBlock extends _MdBlock {
  final List<String> headers;
  final List<List<String>> rows;

  const _TableBlock({required this.headers, required this.rows}) : super(topSpacing: 10);

  @override
  Widget build(BuildContext context, {required double fontSize, required Color textColor}) {
    final colCount = headers.length;
    if (colCount == 0) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: TelemetryColors.bgPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TelemetryColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: const TableBorder(
            horizontalInside: BorderSide(color: TelemetryColors.border),
            verticalInside: BorderSide(color: TelemetryColors.border),
          ),
          children: [
            TableRow(
              decoration: const BoxDecoration(color: TelemetryColors.bgElevated),
              children: [
                for (var c = 0; c < colCount; c++)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 84, maxWidth: 280),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: SelectableText.rich(
                        TextSpan(
                          style: TextStyle(
                            fontSize: fontSize - 1.5,
                            fontWeight: FontWeight.w700,
                            color: TelemetryColors.textPrimary,
                            height: 1.35,
                          ),
                          children: _parseInlineSpans(
                            headers[c],
                            fontSize - 1.5,
                            TelemetryColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            for (final row in rows)
              TableRow(
                children: [
                  for (var c = 0; c < colCount; c++)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 84, maxWidth: 280),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        child: SelectableText.rich(
                          TextSpan(
                            style: TextStyle(
                              fontSize: fontSize - 1.5,
                              color: TelemetryColors.textSecondary,
                              height: 1.4,
                            ),
                            children: _parseInlineSpans(
                              c < row.length ? row[c] : '',
                              fontSize - 1.5,
                              TelemetryColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ListItemBlock extends _MdBlock {
  final int indent;
  final String bullet;
  final String text;

  const _ListItemBlock({
    required this.indent,
    required this.bullet,
    required this.text,
  }) : super(topSpacing: 5);

  @override
  Widget build(BuildContext context, {required double fontSize, required Color textColor}) {
    return Padding(
      padding: EdgeInsets.only(left: indent * 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: bullet == '•' ? 16 : 24,
            child: Text(
              bullet,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: TelemetryColors.accentBright,
                height: 1.46,
              ),
            ),
          ),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                style: TextStyle(fontSize: fontSize, color: textColor, height: 1.46),
                children: _parseInlineSpans(text, fontSize, textColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeFenceBlock extends _MdBlock {
  final String language;
  final String code;

  const _CodeFenceBlock({required this.language, required this.code}) : super(topSpacing: 10);

  @override
  Widget build(BuildContext context, {required double fontSize, required Color textColor}) {
    return _CollapsibleCodeFenceView(language: language, code: code);
  }
}

class _CollapsibleCodeFenceView extends StatefulWidget {
  static const int collapseThresholdLines = 28;
  static const int collapsedPreviewLines = 20;

  final String language;
  final String code;

  const _CollapsibleCodeFenceView({
    required this.language,
    required this.code,
  });

  @override
  State<_CollapsibleCodeFenceView> createState() => _CollapsibleCodeFenceViewState();
}

class _CollapsibleCodeFenceViewState extends State<_CollapsibleCodeFenceView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final allLines = widget.code.split('\n');
    final totalLines = allLines.length;
    final canCollapse = totalLines > _CollapsibleCodeFenceView.collapseThresholdLines;
    final visibleLines = (canCollapse && !_expanded)
        ? allLines.sublist(0, _CollapsibleCodeFenceView.collapsedPreviewLines)
        : allLines;
    final visibleCode = visibleLines.join('\n');
    final lineNums = List<String>.generate(visibleLines.length, (i) => '${i + 1}').join('\n');
    final langLabel = widget.language.isEmpty ? 'code' : widget.language;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: TelemetryColors.bgCode,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TelemetryColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF131620),
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: TelemetryColors.border)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          langLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: TelemetryColors.accentBright,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (totalLines > 1) ...[
                        const SizedBox(width: 6),
                        Text(
                          '· $totalLines стр.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: TelemetryColors.textDim,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.code));
                    HapticFeedback.selectionClick();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Код скопирован'),
                        duration: Duration(milliseconds: 1200),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded, size: 13, color: TelemetryColors.textSecondary),
                        SizedBox(width: 4),
                        Text(
                          'Копия',
                          style: TextStyle(fontSize: 11, color: TelemetryColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (totalLines > 1) ...[
                  ExcludeSemantics(
                    child: Text(
                      lineNums,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.0,
                        height: 1.48,
                        color: Color(0xFF4B5568),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                SelectableText.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.45,
                      color: Color(0xFFE2E8F0),
                    ),
                    children: CodeSyntaxHighlighter.highlight(visibleCode, widget.language),
                  ),
                ),
              ],
            ),
          ),
          if (canCollapse)
            InkWell(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _expanded = !_expanded);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
                decoration: const BoxDecoration(
                  color: Color(0xFF131620),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
                  border: Border(top: BorderSide(color: TelemetryColors.border)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
                      size: 15,
                      color: TelemetryColors.accentBright,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _expanded
                          ? 'Свернуть код'
                          : 'Развернуть все $totalLines строк',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: TelemetryColors.accentBright,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Fast single-pass regex syntax highlighter for Dart, JS/TS, Python, Rust, Bash,
/// JSON, YAML, SQL, Go, Kotlin, Swift, and C/C++.
class CodeSyntaxHighlighter {
  static const Color _commentColor = Color(0xFF64748B);
  static const Color _stringColor = Color(0xFF86EFAC);
  static const Color _keywordColor = Color(0xFFC084FC);
  static const Color _typeColor = Color(0xFF38BDF8);
  static const Color _numberColor = Color(0xFFFBBF24);
  static const Color _annotationColor = Color(0xFFF472B6);
  static const Color _keyColor = Color(0xFF93C5FD);

  static const Set<String> _keywords = {
    // Dart / JS / TS / Kotlin / Swift / Java / C++
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do',
    'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external',
    'factory', 'false', 'final', 'finally', 'for', 'from', 'function', 'get',
    'hide', 'if', 'implements', 'import', 'in', 'interface', 'is', 'late',
    'let', 'library', 'mixin', 'new', 'null', 'of', 'on', 'operator', 'override',
    'package', 'part', 'private', 'protected', 'public', 'readonly', 'required',
    'rethrow', 'return', 'sealed', 'set', 'show', 'static', 'struct', 'super',
    'switch', 'sync', 'this', 'throw', 'true', 'try', 'type', 'typedef',
    'typeof', 'undefined', 'var', 'void', 'when', 'while', 'with', 'yield',
    // Python / Rust / Go / Bash / SQL
    'and', 'def', 'del', 'elif', 'except', 'fn', 'func', 'global', 'go', 'impl',
    'lambda', 'loop', 'match', 'mod', 'mut', 'nonlocal', 'not', 'or', 'pass',
    'pub', 'raise', 'ref', 'self', 'Self', ' crate', 'trait', 'unsafe', 'use',
    'where', 'select', 'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'UPDATE',
    'DELETE', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'GROUP', 'BY', 'ORDER', 'LIMIT',
    'CREATE', 'TABLE', 'ALTER', 'DROP', 'AND', 'OR', 'NOT', 'NULL', 'AS', 'ON',
    'then', 'fi', 'esac', 'done', 'echo', 'local', 'sudo',
  };

  static final RegExp _tokenRe = RegExp(
    r'(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|--[^\n]*)' // 1: comments
    r'|("(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27|`(?:\\.|[^`\\])*`)' // 2: strings
    r'|(@[A-Za-z_]\w*)' // 3: annotations/decorators
    r'|(\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?\b)' // 4: numbers
    r'|([A-Za-z_]\w*(?=\s*:))' // 5: YAML/object property keys
    r'|(\b[A-Z][A-Za-z0-9_]*\b)' // 6: PascalCase types
    r'|(\b[a-z_][A-Za-z0-9_]*\b)', // 7: identifiers / keywords
    multiLine: true,
  );

  static List<InlineSpan> highlight(String code, String language) {
    if (code.isEmpty) return const [TextSpan(text: '')];
    final lang = language.trim().toLowerCase();
    if (lang == 'text' || lang == 'plaintext' || lang == 'txt') {
      return [TextSpan(text: code)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final m in _tokenRe.allMatches(code)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: code.substring(cursor, m.start)));
      }
      final full = m.group(0)!;
      if (m.group(1) != null) {
        spans.add(TextSpan(
          text: full,
          style: const TextStyle(color: _commentColor, fontStyle: FontStyle.italic),
        ));
      } else if (m.group(2) != null) {
        // In JSON, `"key":` is a string followed by `:`
        final afterIdx = m.end;
        final isJsonKey = (lang == 'json' || lang == 'jsonc') &&
            afterIdx < code.length &&
            RegExp(r'^\s*:').hasMatch(code.substring(afterIdx));
        spans.add(TextSpan(
          text: full,
          style: TextStyle(color: isJsonKey ? _keyColor : _stringColor),
        ));
      } else if (m.group(3) != null) {
        spans.add(TextSpan(
          text: full,
          style: const TextStyle(color: _annotationColor),
        ));
      } else if (m.group(4) != null) {
        spans.add(TextSpan(
          text: full,
          style: const TextStyle(color: _numberColor),
        ));
      } else if (m.group(5) != null) {
        if (_keywords.contains(full)) {
          spans.add(TextSpan(
            text: full,
            style: const TextStyle(color: _keywordColor, fontWeight: FontWeight.w600),
          ));
        } else {
          spans.add(TextSpan(
            text: full,
            style: const TextStyle(color: _keyColor),
          ));
        }
      } else if (m.group(6) != null) {
        if (_keywords.contains(full)) {
          spans.add(TextSpan(
            text: full,
            style: const TextStyle(color: _keywordColor, fontWeight: FontWeight.w600),
          ));
        } else {
          spans.add(TextSpan(
            text: full,
            style: const TextStyle(color: _typeColor),
          ));
        }
      } else if (m.group(7) != null) {
        if (_keywords.contains(full)) {
          spans.add(TextSpan(
            text: full,
            style: const TextStyle(color: _keywordColor, fontWeight: FontWeight.w600),
          ));
        } else {
          spans.add(TextSpan(text: full));
        }
      } else {
        spans.add(TextSpan(text: full));
      }
      cursor = m.end;
    }

    if (cursor < code.length) {
      spans.add(TextSpan(text: code.substring(cursor)));
    }
    return spans;
  }
}

final RegExp _inlineTokenRe = RegExp(
  r'`([^`\n]+)`|\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*|\*([^*\n]+)\*',
);

List<InlineSpan> _parseInlineSpans(String input, double fontSize, Color baseColor) {
  final spans = <InlineSpan>[];
  var cursor = 0;

  for (final match in _inlineTokenRe.allMatches(input)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: input.substring(cursor, match.start)));
    }

    final inlineCode = match.group(1);
    final linkLabel = match.group(2);
    final linkTarget = match.group(3);
    final boldText = match.group(4);
    final italicText = match.group(5);

    if (inlineCode != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 0.5),
            decoration: BoxDecoration(
              color: TelemetryColors.bgHover,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: TelemetryColors.border),
            ),
            child: Text(
              inlineCode,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: fontSize - 2.0,
                color: TelemetryColors.cyan,
                height: 1.15,
              ),
            ),
          ),
        ),
      );
    } else if (linkLabel != null && linkTarget != null) {
      final isFileOrInternal = linkTarget.startsWith('file://') ||
          linkTarget.startsWith('customization://') ||
          linkTarget.startsWith('sidecar://');
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: TelemetryColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: TelemetryColors.accent.withValues(alpha: 0.32)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isFileOrInternal ? Icons.insert_drive_file_outlined : Icons.open_in_new_rounded,
                  size: 11.5,
                  color: TelemetryColors.accentBright,
                ),
                const SizedBox(width: 3.5),
                Flexible(
                  child: Text(
                    linkLabel,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: fontSize - 2.0,
                      fontWeight: FontWeight.w600,
                      color: TelemetryColors.accentBright,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else if (boldText != null) {
      spans.add(
        TextSpan(
          text: boldText,
          style: const TextStyle(fontWeight: FontWeight.w700, color: TelemetryColors.textPrimary),
        ),
      );
    } else if (italicText != null) {
      spans.add(
        TextSpan(
          text: italicText,
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    }

    cursor = match.end;
  }

  if (cursor < input.length) {
    spans.add(TextSpan(text: input.substring(cursor)));
  }

  return spans;
}
