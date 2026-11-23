import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TelemetryColors {
  // Deep AMOLED-friendly Obsidian surface hierarchy
  static const Color bgCanvas = Color(0xFF090A0F);
  static const Color bgPanel = Color(0xFF11131C);
  static const Color bgElevated = Color(0xFF181B26);
  static const Color bgHover = Color(0xFF212636);
  static const Color bgCode = Color(0xFF0C0E14);

  // Crisp 1px glass hairlines instead of heavy colored borders
  static const Color border = Color(0x16FFFFFF);
  static const Color borderStrong = Color(0x28FFFFFF);

  // Refined brand & semantic accents
  static const Color accent = Color(0xFF6E7BF2);
  static const Color accentBright = Color(0xFF818CF8);
  static const Color cyan = Color(0xFF38BDF8);
  static const Color live = Color(0xFF10B981);
  static const Color warn = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFF43F5E);

  // High-contrast readable typography hierarchy
  static const Color textPrimary = Color(0xFFF3F5FA);
  static const Color textSecondary = Color(0xFF9BA3B8);
  static const Color textDim = Color(0xFF636B82);

  static const SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  );
}

class TelemetryFormatters {
  static String cleanMachineName(String raw) {
    var s = raw.trim();
    if (s.endsWith('.local')) {
      s = s.substring(0, s.length - 6);
    }
    return s.isEmpty ? 'Antigravity Mac' : s;
  }

  static String relativeTime(int epochMs) {
    if (epochMs <= 0) return '';
    final diffSec = ((DateTime.now().millisecondsSinceEpoch - epochMs) / 1000).round();
    if (diffSec < 45) return 'только что';
    final diffMin = (diffSec / 60).round();
    if (diffMin < 60) return '$diffMin мин';
    final diffHr = (diffMin / 60).round();
    if (diffHr < 24) return '$diffHr ч';
    final diffDays = (diffHr / 24).round();
    if (diffDays < 7) return '$diffDays дн';
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    const months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
    return '${dt.day} ${months[dt.month - 1]}';
  }

  static String cleanActivity(String raw) {
    final oneLine = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty || oneLine == 'Idle') return 'Готов к работе';
    if (oneLine == 'Replied') return 'Ответ получен';
    if (oneLine == 'User prompt received') return 'Обработка запроса…';
    return oneLine;
  }

  static final RegExp _rawSessionTitleRe =
      RegExp(r'^Session\s+([a-f0-9]{6,})', caseSensitive: false);

  static String cleanSessionTitle(String? raw, {String fallback = 'Новая задача Antigravity'}) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return fallback;
    final m = _rawSessionTitleRe.firstMatch(s);
    if (m != null) {
      final shortHash = m.group(1)!.substring(0, 6);
      return 'Диалог #$shortHash';
    }
    return s;
  }
}

ThemeData buildTelemetryTheme() {
  const scheme = ColorScheme.dark(
    surface: TelemetryColors.bgPanel,
    primary: TelemetryColors.accent,
    secondary: TelemetryColors.cyan,
    tertiary: TelemetryColors.live,
    error: TelemetryColors.danger,
    onPrimary: Colors.white,
    onSurface: TelemetryColors.textPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: TelemetryColors.bgCanvas,
    colorScheme: scheme,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: TelemetryColors.bgCanvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: TelemetryColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: TelemetryColors.overlayStyle,
    ),
    cardTheme: CardThemeData(
      color: TelemetryColors.bgPanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: TelemetryColors.border),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: TelemetryColors.bgPanel,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: TelemetryColors.bgPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: TelemetryColors.bgElevated,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: const TextStyle(color: TelemetryColors.textDim, fontSize: 14),
      labelStyle: const TextStyle(color: TelemetryColors.textSecondary, fontSize: 13),
      floatingLabelStyle: const TextStyle(color: TelemetryColors.accentBright, fontSize: 12.5),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: TelemetryColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: TelemetryColors.accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: TelemetryColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, letterSpacing: -0.1),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TelemetryColors.textPrimary,
        side: const BorderSide(color: TelemetryColors.borderStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: -0.1),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: TelemetryColors.bgElevated,
      side: const BorderSide(color: TelemetryColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: const TextStyle(color: TelemetryColors.textPrimary, fontSize: 12.5),
    ),
    dividerColor: TelemetryColors.border,
  );
}
