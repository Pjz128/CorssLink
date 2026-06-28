import 'package:flutter/material.dart';

/// CrossLink 品牌设计 token —— 曜黑 (Obsidian)
///
/// 简约但不简单。以深邃曜石黑为底，微妙层次区分空间。
/// 单一强调色链路蓝，克制使用。圆角统一、间距呼吸。
class CrossLinkTheme {
  CrossLinkTheme._();

  // ── 背景层 ─────────────────────────────────────────────
  /// 根背景 — 最深处
  static const Color bg = Color(0xFF0D0E12);
  /// 表层 — 卡片、面板
  static const Color surface = Color(0xFF16171D);
  /// 悬停 — 列表项按下
  static const Color surfaceHover = Color(0xFF1E1F27);
  /// 输入区背景
  static const Color inputBg = Color(0xFF121318);

  // ── 文字层 ─────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFEBECF0);
  static const Color textSecondary = Color(0xFF9DA0B0);
  static const Color textMuted = Color(0xFF5C6072);

  // ── 强调色 ─────────────────────────────────────────────
  /// 主强调 — 链路蓝
  static const Color accent = Color(0xFF4C82FB);
  /// 成功
  static const Color success = Color(0xFF34C759);
  /// 警告
  static const Color warning = Color(0xFFFF9F0A);
  /// 错误
  static const Color error = Color(0xFFFF453A);

  // ── 工具语义色 ─────────────────────────────────────────
  static const Color toolBash = Color(0xFFF5C842);
  static const Color toolRead = Color(0xFF6EA8FE);
  static const Color toolWrite = Color(0xFFF5A623);
  static const Color toolEdit = Color(0xFFBF7AF0);
  static const Color toolGrep = Color(0xFF56D492);
  static const Color toolGlob = Color(0xFFC084FC);
  static const Color toolSearch = Color(0xFF22D3EE);

  // ── 边框 ───────────────────────────────────────────────
  static const Color border = Color(0x1AFFFFFF);
  static const Color borderFocus = Color(0x4D4C82FB);

  // ── 圆角 ───────────────────────────────────────────────
  static const double rXs = 4;
  static const double rSm = 8;
  static const double rMd = 12;
  static const double rLg = 16;
  static const double rXl = 24;

  // ── 间距 ───────────────────────────────────────────────
  static const double sXs = 4;
  static const double sSm = 8;
  static const double sMd = 12;
  static const double sLg = 16;
  static const double sXl = 24;
  static const double sXxl = 32;

  // ── 动画 ───────────────────────────────────────────────
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
  static const Curve curve = Curves.easeOutCubic;

  // ── 阴影 ───────────────────────────────────────────────
  static List<BoxShadow> get cardShadow => const [
        BoxShadow(color: Color(0x18000000), blurRadius: 12, offset: Offset(0, 4)),
      ];

  static List<BoxShadow> get glowShadow => const [
        BoxShadow(color: Color(0x334C82FB), blurRadius: 16, spreadRadius: -4),
      ];

  // ── ThemeData ──────────────────────────────────────────
  static ThemeData darkTheme(Color seed) {
    final cs = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: surface,
      primary: accent,
      secondary: accent.withAlpha(180),
      error: error,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      scaffoldBackgroundColor: bg,
      appBarTheme: AppBarTheme(
        backgroundColor: bg.withAlpha(230),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontSize: 17, fontWeight: FontWeight.w600, color: textPrimary, letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rLg),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rLg),
          borderSide: const BorderSide(color: border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rLg),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted, fontSize: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: surfaceHover,
          foregroundColor: textPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSm)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSm)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bg.withAlpha(240),
        indicatorColor: accent.withAlpha(40),
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(rLg)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg)),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: textPrimary, letterSpacing: -0.4),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textPrimary, letterSpacing: -0.2),
        titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary),
        bodyMedium: TextStyle(fontSize: 14, color: textPrimary, height: 1.5),
        bodySmall: TextStyle(fontSize: 12, color: textSecondary, height: 1.4),
        labelSmall: TextStyle(fontSize: 10, color: textMuted),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
    );
  }
}

/// 工具扩展
extension ToolColor on String {
  Color get toolColor {
    switch (this) {
      case 'Bash': return CrossLinkTheme.toolBash;
      case 'Read': return CrossLinkTheme.toolRead;
      case 'Write': return CrossLinkTheme.toolWrite;
      case 'Edit': return CrossLinkTheme.toolEdit;
      case 'Grep': return CrossLinkTheme.toolGrep;
      case 'Glob': return CrossLinkTheme.toolGlob;
      case 'WebSearch': case 'WebFetch': return CrossLinkTheme.toolSearch;
      default: return CrossLinkTheme.accent;
    }
  }

  IconData get toolIcon {
    switch (this) {
      case 'Bash': return Icons.terminal_rounded;
      case 'Read': return Icons.menu_book_rounded;
      case 'Write': case 'Edit': return Icons.edit_note_rounded;
      case 'Grep': return Icons.search_rounded;
      case 'Glob': return Icons.folder_open_rounded;
      case 'WebSearch': return Icons.public_rounded;
      case 'WebFetch': return Icons.download_rounded;
      default: return Icons.build_circle_rounded;
    }
  }
}
