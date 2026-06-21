import 'package:flutter/material.dart';

/// CrossLink 品牌设计 token —— 深空链路 (Deep Space Link)
///
/// 调性：深邃、安全、互联。以深空黑为底，电光青/蓝为强调色，
/// 模拟终端窗口与跨端链路的光轨质感。
class CrossLinkTheme {
  CrossLinkTheme._();

  // ── 品牌核心色 ─────────────────────────────────────────
  static const Color deepSpace = Color(0xFF0A0B0F);
  static const Color deepSpaceElevated = Color(0xFF12141C);
  static const Color panel = Color(0xFF1A1D28);
  static const Color panelHover = Color(0xFF222636);
  static const Color linkCyan = Color(0xFF00E5FF);
  static const Color linkBlue = Color(0xFF2979FF);
  static const Color linkPurple = Color(0xFF7C4DFF);
  static const Color alertAmber = Color(0xFFFFB300);
  static const Color successGreen = Color(0xFF00E676);
  static const Color errorRed = Color(0xFFFF5252);

  // ── 工具语义色 ─────────────────────────────────────────
  static const Color toolBash = Color(0xFFFFD54F);
  static const Color toolRead = Color(0xFF82B1FF);
  static const Color toolWrite = Color(0xFFFFB74D);
  static const Color toolGrep = Color(0xFF69F0AE);
  static const Color toolGlob = Color(0xFFB388FF);
  static const Color toolWebSearch = Color(0xFF84FFFF);
  static const Color toolWebFetch = Color(0xFF80CBC4);

  // ── 渐变 ───────────────────────────────────────────────
  static const LinearGradient linkGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [linkCyan, linkBlue, linkPurple],
    stops: [0.0, 0.55, 1.0],
  );

  static const LinearGradient surfaceGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [deepSpaceElevated, deepSpace],
  );

  static const RadialGradient glowRadial = RadialGradient(
    center: Alignment.topCenter,
    radius: 0.8,
    colors: [Color(0x152979FF), Colors.transparent],
  );

  // ── 阴影 ───────────────────────────────────────────────
  static List<BoxShadow> get panelShadow => [
        BoxShadow(
          color: const Color(0x40000000),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ];

  static List<BoxShadow> get linkGlow => const [
        BoxShadow(
          color: Color(0x6600E5FF),
          blurRadius: 12,
          spreadRadius: -2,
        ),
      ];

  // ── 圆角 ───────────────────────────────────────────────
  static const double radiusXs = 6;
  static const double radiusSm = 10;
  static const double radiusMd = 14;
  static const double radiusLg = 20;
  static const double radiusXl = 28;

  // ── 间距 ───────────────────────────────────────────────
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;
  static const double spaceXxl = 32;

  // ── 动画 ───────────────────────────────────────────────
  static const Duration durationFast = Duration(milliseconds: 150);
  static const Duration durationNormal = Duration(milliseconds: 250);
  static const Duration durationSlow = Duration(milliseconds: 400);
  static const Curve curveDefault = Curves.easeOutCubic;

  // ── ThemeData 工厂 ─────────────────────────────────────
  static ThemeData darkTheme(Color seed) {
    final cs = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: deepSpace,
      primary: linkBlue,
      secondary: linkCyan,
      error: errorRed,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      scaffoldBackgroundColor: deepSpace,
      appBarTheme: AppBarTheme(
        backgroundColor: deepSpace.withAlpha(200),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: const BorderSide(color: Color(0x22FFFFFF), width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          borderSide: const BorderSide(color: Color(0x22FFFFFF), width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          borderSide: const BorderSide(color: linkCyan, width: 1.5),
        ),
        hintStyle: const TextStyle(color: Color(0x80FFFFFF)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: panelHover,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: deepSpaceElevated.withAlpha(240),
        indicatorColor: linkBlue.withAlpha(60),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
        titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
        bodyMedium: TextStyle(fontSize: 14, color: Color(0xE6FFFFFF)),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xB3FFFFFF)),
        labelSmall: TextStyle(fontSize: 10, color: Color(0x80FFFFFF)),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0x18FFFFFF),
        thickness: 1,
      ),
    );
  }
}

/// 常用工具扩展
extension ToolColor on String {
  Color get toolColor {
    switch (this) {
      case 'Bash':
        return CrossLinkTheme.toolBash;
      case 'Read':
        return CrossLinkTheme.toolRead;
      case 'Write':
      case 'Edit':
        return CrossLinkTheme.toolWrite;
      case 'Grep':
        return CrossLinkTheme.toolGrep;
      case 'Glob':
        return CrossLinkTheme.toolGlob;
      case 'WebSearch':
        return CrossLinkTheme.toolWebSearch;
      case 'WebFetch':
        return CrossLinkTheme.toolWebFetch;
      default:
        return CrossLinkTheme.linkBlue;
    }
  }

  IconData get toolIcon {
    switch (this) {
      case 'Read':
        return Icons.menu_book_rounded;
      case 'Write':
      case 'Edit':
        return Icons.edit_note_rounded;
      case 'Bash':
        return Icons.terminal_rounded;
      case 'Grep':
        return Icons.search_rounded;
      case 'Glob':
        return Icons.folder_open_rounded;
      case 'WebSearch':
        return Icons.public_rounded;
      case 'WebFetch':
        return Icons.download_rounded;
      case 'Task':
        return Icons.assignment_rounded;
      default:
        return Icons.build_circle_rounded;
    }
  }
}

extension GlowX on Color {
  BoxShadow get softGlow => BoxShadow(
        color: withAlpha(80),
        blurRadius: 12,
        spreadRadius: -2,
      );
}
