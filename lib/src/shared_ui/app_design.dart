import 'package:flutter/material.dart';

/// Shared visual tokens for the media experience.
///
/// Monochrome gallery + theater. Backgrounds are pure black / white; neutral
/// grays provide hierarchy, while artwork keeps its original colors. Use the
/// theme ColorScheme for browsing controls and theater tokens during playback.
class AppColors {
  const AppColors._();

  static const bg = Color(0xFF000000);
  static const bg2 = Color(0xFF000000);
  static const panel = Color(0xFF101010);
  static const panelHigh = Color(0xFF191919);
  static const panelHover = Color(0xFF242424);
  static const overlay = Color(0xE6000000);

  static const border = Color(0xFF292929);
  static const borderBright = Color(0xFF424242);

  // Legacy fixed accents stay readable against either background; new UI uses
  // ColorScheme.primary (white in dark mode, black in light mode).
  static const primary = Color(0xFF767676);
  static const primary2 = Color(0xFFFFFFFF);
  static const accentDeep = Color(0xFF000000);

  static const cyan = Color(0xFFD4D4D4);
  static const rose = Color(0xFFBBBBBB);
  static const celadonDeep = Color(0xFF333333);
  static const wisteriaDeep = Color(0xFF444444);

  static const primarySurface = Color(0xFF242424);
  static const secondarySurface = Color(0xFF191919);

  static const text = Color(0xFFFFFFFF);
  static const muted = Color(0xFFB8B8B8);
  static const faint = Color(0xFF929292);

  static const success = Color(0xFF888888);
  static const warning = Color(0xFF999999);
  static const danger = Color(0xFF888888);

  static const lightBg = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightPanel = Color(0xFFF5F5F5);
  static const lightPanelHigh = Color(0xFFEBEBEB);
  static const lightBorder = Color(0xFFE3E3E3);
  static const lightText = Color(0xFF000000);
  static const lightMuted = Color(0xFF555555);
  static const lightFaint = Color(0xFF717171);

  static const theaterBg = Color(0xFF000000);
  static const theaterPanel = Color(0xFF0C0C0C);
  static const theaterPanelHigh = Color(0xFF1C1C1C);
  static const theaterInk = Color(0xFFFFFFFF);
  static const theaterMuted = Color(0xBFFFFFFF);
  static const theaterFaint = Color(0x99FFFFFF);
  static const theaterBorder = Color(0xFF292929);
  static const theaterBorderBright = Color(0xFF4A4A4A);
  static const theaterScrim = Color(0xFF000000);
}

/// Shared scrims and media washes. Prefer these over page-local `0x1B1A18`
/// gradients so light/dark browsing stays on one temperature.
class AppOverlays {
  const AppOverlays._();

  static Color scrim([double opacity = 0.72]) =>
      AppColors.theaterScrim.withValues(alpha: opacity.clamp(0.0, 1.0));

  static Color scrimSoft([double opacity = 0.40]) => scrim(opacity);

  static Color scrimStrong([double opacity = 0.88]) => scrim(opacity);

  static Color theaterBar([double opacity = 0.78]) =>
      AppColors.theaterBg.withValues(alpha: opacity.clamp(0.0, 1.0));

  /// Bottom-heavy wash for posters and hero art (gallery surfaces).
  static const posterBottom = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x001A1A1A), Color(0x661A1A1A), Color(0xE61A1A1A)],
    stops: [0.35, 0.72, 1],
  );

  /// Two-stop caption plate used on history / library cards.
  static const mediaCaption = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x001A1A1A), Color(0xEE1A1A1A)],
  );

  /// Top + bottom control wash for the player (theater only).
  static const playerChromeVertical = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xD9161616),
      Color(0x00161616),
      Color(0x00161616),
      Color(0xE6161616),
    ],
    stops: [0, 0.22, 0.62, 1],
  );

  static const playerTopFade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xE6161616), Color(0x8F161616), Color(0x00161616)],
  );

  static const playerBottomFade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00161616), Color(0x78161616), Color(0xD9161616)],
  );

  /// Left-heavy wash for wide heroes (catalog rail / profile banner).
  static const heroLeading = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xF01A1A1A), Color(0xCC1A1A1A), Color(0x551A1A1A)],
  );

  /// Softer left wash used on profile hero cards.
  static const heroLeadingSoft = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xEE1A1A1A), Color(0x661A1A1A)],
  );

  /// Compact detail hero (bottom-up).
  static const heroCompact = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xE61A1A1A), Color(0xB81A1A1A)],
  );

  /// Wide detail hero (leading edge).
  static const heroDetailWide = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xF21A1A1A), Color(0xAA1A1A1A), Color(0x441A1A1A)],
  );

  /// Category card overlay (top → bottom).
  static const categoryCard = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x661A1A1A), Color(0xCC1A1A1A)],
  );

  /// Solid-ish label plate on small posters.
  static Color labelPlate([double opacity = 0.65]) =>
      AppColors.theaterScrim.withValues(alpha: opacity.clamp(0.0, 1.0));
}

/// Line / task status colors used on both gallery and theater surfaces.
class AppStatusColors {
  const AppStatusColors._();

  static const available = AppColors.success;
  static const probing = AppColors.warning;
  static const failed = AppColors.danger;
  static const selected = AppColors.primary2;
}

/// Typography roles that pages may reference directly. The serif family is
/// bundled (Source Han Serif via NotoSerifSC) and reserved for display-sized
/// text; body text stays on the system sans stack.
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

  // The bundled NotoSansSC leads the fallback chain so the web and non-CJK
  // desktops never depend on a runtime font download; Windows still resolves
  // the primary YaHei UI family first.
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
  static const section = 32.0;
  static const hero = 40.0;
}

class AppRadius {
  const AppRadius._();

  static const xs = 6.0;
  static const sm = 8.0;
  static const md = 10.0;
  static const lg = 14.0;
  static const xl = 20.0;
  static const pill = 999.0;
}

class AppBreakpoints {
  const AppBreakpoints._();

  static const mobile = 600.0;
  static const compact = 760.0;
  static const desktop = 980.0;
  static const wide = 1180.0;
  static const extraWide = 1400.0;

  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < mobile;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktop;
}

class AppLayout {
  const AppLayout._();

  static const maxContentWidth = 1680.0;
  static const sideNavigationWidth = 148.0;
  static const topBarHeight = 72.0;
  static const mobileNavigationHeight = 64.0;

  static double mobileNavigationHeightFor(BuildContext context) =>
      mobileNavigationHeight +
      (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(0.0, 36.0);

  static EdgeInsets pagePaddingForWidth(double width) {
    if (width < AppBreakpoints.mobile) {
      return const EdgeInsets.fromLTRB(14, 16, 14, 22);
    }
    if (width < AppBreakpoints.desktop) {
      return const EdgeInsets.fromLTRB(20, 20, 20, 26);
    }
    if (width < AppBreakpoints.extraWide) {
      return const EdgeInsets.fromLTRB(26, 24, 26, 30);
    }
    return const EdgeInsets.fromLTRB(32, 28, 32, 36);
  }

  static EdgeInsets pagePadding(BuildContext context) =>
      pagePaddingForWidth(MediaQuery.sizeOf(context).width);
}

class AppMotion {
  const AppMotion._();

  static const quick = Duration(milliseconds: 120);
  static const standard = Duration(milliseconds: 220);
  static const relaxed = Duration(milliseconds: 360);
}

class AppShadows {
  const AppShadows._();

  // Neutral ink shadows: a tight contact layer plus a soft diffuse layer, kept
  // faint so cards read as paper resting on paper rather than floating.
  static const panel = <BoxShadow>[
    BoxShadow(color: Color(0x0A141414), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F141414), blurRadius: 16, offset: Offset(0, 4)),
  ];

  static const elevated = <BoxShadow>[
    BoxShadow(color: Color(0x0F141414), blurRadius: 4, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x1F141414), blurRadius: 32, offset: Offset(0, 12)),
  ];

  static const primaryGlow = <BoxShadow>[];
}

class AppGradients {
  const AppGradients._();

  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primary, AppColors.primary2, AppColors.cyan],
  );

  static const page = LinearGradient(colors: [AppColors.bg, AppColors.bg]);

  static const accent = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [AppColors.primary, Color(0xFF898989)],
  );

  static const coolAccent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primary2, AppColors.cyan],
  );

  static const mediaScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x08000000), Color(0x24141414), Color(0xE6161616)],
    stops: [0, 0.58, 1],
  );
}

extension AppContextDesign on BuildContext {
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  /// Theme-resolved ink shortcuts used when migrating legacy hardcoded
  /// white-on-black page code to the paper design.
  Color get ink => Theme.of(this).colorScheme.onSurface;
  Color get inkMuted => Theme.of(this).colorScheme.onSurfaceVariant;
  Color get inkFaint => Theme.of(this).colorScheme.outline;

  bool get isMobileLayout =>
      MediaQuery.sizeOf(this).width < AppBreakpoints.mobile;

  bool get isDesktopLayout =>
      MediaQuery.sizeOf(this).width >= AppBreakpoints.desktop;

  EdgeInsets get pagePadding => AppLayout.pagePadding(this);
}
