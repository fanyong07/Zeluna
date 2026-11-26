import 'package:flutter/material.dart';

/// Shared visual tokens for Zeluna v3.0 — neutral matte cinema surfaces
/// designed to pair cleanly with default monochrome black/white AND any
/// user-selected spectrum or custom HSV accent color.
class AppColors {
  const AppColors._();

  // Dark canvas — matte carbon neutral (OLED #000000 is enabled via theme)
  static const bg = Color(0xFF0F0F11);
  static const bg2 = Color(0xFF151518);
  static const panel = Color(0xFF1A1A1E);
  static const panelHigh = Color(0xFF232328);
  static const panelHover = Color(0xFF2C2C33);
  static const overlay = Color(0xE609090B);

  // Subtle neutral hairlines
  static const border = Color(0xFF27272D);
  static const borderBright = Color(0xFF3A3A44);

  // Default monochrome primary & restrained semantic companions
  static const primary = Color(0xFFFFFFFF);
  static const primary2 = Color(0xFFD4D4DC);
  static const accentDeep = Color(0xFF111114);

  static const cyan = Color(0xFF06B6D4);
  static const gold = Color(0xFFF5C451);
  static const goldLight = Color(0xFFC98A00);
  static const rose = Color(0xFFFB7299);
  static const violet = Color(0xFF8B5CF6);
  static const celadonDeep = Color(0xFF1A2A2D);
  static const wisteriaDeep = Color(0xFF241F33);

  static const primarySurface = Color(0xFF26262C);
  static const secondarySurface = Color(0xFF202026);

  // Neutral dark text scale
  static const text = Color(0xFFF4F4F6);
  static const muted = Color(0xFF9E9EA8);
  static const faint = Color(0xFF6E6E78);

  // Functional semantic status colors (only where meaning matters)
  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);

  // Light canvas — crisp monochrome paper
  static const lightBg = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightPanel = Color(0xFFF4F4F6);
  static const lightPanelHigh = Color(0xFFEBEBEF);
  static const lightBorder = Color(0xFFE4E4EA);
  static const lightText = Color(0xFF111114);
  static const lightMuted = Color(0xFF5A5A64);
  static const lightFaint = Color(0xFF8A8A96);
  static const lightPrimary = Color(0xFF111114);
  static const lightSecondary = Color(0xFF3F3F46);
  static const lightRose = Color(0xFFDB2777);

  // Theater canvas (video player surface)
  static const theaterBg = Color(0xFF09090B);
  static const theaterPanel = Color(0xFF121215);
  static const theaterPanelHigh = Color(0xFF1C1C21);
  static const theaterInk = Color(0xFFF6F6F8);
  static const theaterMuted = Color(0xC7D4D4DC);
  static const theaterFaint = Color(0x999E9EA8);
  static const theaterBorder = Color(0xFF25252B);
  static const theaterBorderBright = Color(0xFF3A3A44);
  static const theaterScrim = Color(0xFF000000);
}

/// Neutral cinema scrims and overlays — zero color cast over posters.
class AppOverlays {
  const AppOverlays._();

  static Color scrim([double opacity = 0.72]) =>
      AppColors.theaterScrim.withValues(alpha: opacity.clamp(0.0, 1.0));

  static Color scrimSoft([double opacity = 0.36]) => scrim(opacity);

  static Color scrimStrong([double opacity = 0.88]) => scrim(opacity);

  static Color theaterBar([double opacity = 0.78]) =>
      AppColors.theaterBg.withValues(alpha: opacity.clamp(0.0, 1.0));

  static const posterBottom = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0x52000000), Color(0xE6000000)],
    stops: [0.40, 0.74, 1],
  );

  static const mediaCaption = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0xEA000000)],
  );

  static const playerChromeVertical = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xD9000000),
      Color(0x00000000),
      Color(0x00000000),
      Color(0xE8000000),
    ],
    stops: [0, 0.22, 0.62, 1],
  );

  static const playerTopFade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xE0000000), Color(0x78000000), Color(0x00000000)],
  );

  static const playerBottomFade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0x78000000), Color(0xE0000000)],
  );

  static const heroLeading = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xEA0B0B0D), Color(0x990B0B0D), Color(0x1F0B0B0D)],
  );

  static const heroLeadingSoft = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xE60E0E11), Color(0x7A0E0E11), Color(0x3D0E0E11)],
  );

  static const heroCompact = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xF00B0B0D), Color(0x990B0B0D), Color(0x260B0B0D)],
    stops: [0, 0.56, 1],
  );

  static const heroDetailWide = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xF20B0B0D), Color(0xA60B0B0D), Color(0x290B0B0D)],
  );

  static const categoryCard = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x3D000000), Color(0xD6000000)],
  );

  static Color labelPlate([double opacity = 0.72]) =>
      AppColors.theaterScrim.withValues(alpha: opacity.clamp(0.0, 1.0));
}

class AppStatusColors {
  const AppStatusColors._();

  static const available = AppColors.success;
  static const probing = AppColors.warning;
  static const failed = AppColors.danger;
  static const selected = AppColors.primary;
}

class AppTypography {
  const AppTypography._();

  static const serifFamily = 'NotoSerifSC';
  static const serifFallback = <String>[
    'Source Han Serif SC',
    'Noto Serif SC',
    'Songti SC',
    'SimSun',
    'Georgia',
  ];

  static const sansFamily = 'Microsoft YaHei UI';
  static const sansFallback = <String>[
    'NotoSansSC',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
  ];
}

class AppSpacing {
  const AppSpacing._();

  static const xxs = 4.0;
  static const xs = 6.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const section = 28.0;
  static const hero = 36.0;
}

class AppRadius {
  const AppRadius._();

  static const xs = 6.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const pill = 999.0;
}

class AppBreakpoints {
  const AppBreakpoints._();

  static const mobile = 600.0;
  static const compact = 760.0;
  static const desktop = 960.0;
  static const wide = 1180.0;
  static const extraWide = 1400.0;

  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < mobile;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktop;
}

class AppLayout {
  const AppLayout._();

  static const maxContentWidth = 1720.0;
  static const sideNavigationWidth = 216.0;
  static const sideRailCollapsedWidth = 72.0;
  static const topBarHeight = 58.0;
  static const mobileNavigationHeight = 58.0;

  static double mobileNavigationHeightFor(BuildContext context) =>
      mobileNavigationHeight +
      (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(0.0, 32.0);

  static EdgeInsets pagePaddingForWidth(double width) {
    if (width < AppBreakpoints.mobile) {
      return const EdgeInsets.fromLTRB(12, 8, 12, 20);
    }
    if (width < AppBreakpoints.desktop) {
      return const EdgeInsets.fromLTRB(18, 12, 18, 24);
    }
    if (width < AppBreakpoints.extraWide) {
      return const EdgeInsets.fromLTRB(24, 14, 24, 28);
    }
    return const EdgeInsets.fromLTRB(28, 16, 28, 32);
  }

  static EdgeInsets pagePadding(BuildContext context) =>
      pagePaddingForWidth(MediaQuery.sizeOf(context).width);
}

class AppMotion {
  const AppMotion._();

  static const quick = Duration(milliseconds: 140);
  static const standard = Duration(milliseconds: 220);
  static const relaxed = Duration(milliseconds: 340);
}

class AppShadows {
  const AppShadows._();

  static const panel = <BoxShadow>[
    BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2)),
  ];

  static const elevated = <BoxShadow>[
    BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 6)),
  ];

  static const primaryGlow = <BoxShadow>[];

  static const poster = <BoxShadow>[
    BoxShadow(color: Color(0x1E000000), blurRadius: 10, offset: Offset(0, 4)),
  ];

  static const posterHover = <BoxShadow>[
    BoxShadow(color: Color(0x36000000), blurRadius: 18, offset: Offset(0, 8)),
  ];
}

class AppGradients {
  const AppGradients._();

  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF27272D), Color(0xFF141418)],
  );

  static const page = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppColors.bg, AppColors.bg],
  );

  static const pageLight = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppColors.lightBg, AppColors.lightBg],
  );

  static const accent = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFFFFFFF), Color(0xFFE4E4EA)],
  );

  static const coolAccent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFD4D4DC), Color(0xFF9E9EA8)],
  );

  static const starlight = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.gold, Color(0xFFEAB308)],
  );

  static const lunarBanner = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1A1A1E), Color(0xFF141418)],
  );

  static const mediaScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0x18000000), Color(0xD8000000)],
    stops: [0, 0.58, 1],
  );
}

extension AppContextDesign on BuildContext {
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  Color get ink => Theme.of(this).colorScheme.onSurface;
  Color get inkMuted => Theme.of(this).colorScheme.onSurfaceVariant;
  Color get inkFaint => Theme.of(this).colorScheme.outline;

  Color get gold => isDarkMode ? AppColors.gold : AppColors.goldLight;
  Color get accentCyan => Theme.of(this).colorScheme.secondary;
  Color get sakura => isDarkMode ? AppColors.rose : AppColors.lightRose;

  bool get isMobileLayout =>
      MediaQuery.sizeOf(this).width < AppBreakpoints.mobile;

  bool get isDesktopLayout =>
      MediaQuery.sizeOf(this).width >= AppBreakpoints.desktop;

  EdgeInsets get pagePadding => AppLayout.pagePadding(this);
}
