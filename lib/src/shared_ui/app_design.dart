import 'package:flutter/material.dart';

/// Shared visual tokens for the media experience.
///
/// Design language: "gallery + theater". Browsing surfaces use a warm paper
/// palette (light) or warm charcoal (dark); the player always runs on the
/// dedicated theater tokens. Mist blue is the single global accent, with
/// celadon and wisteria reserved for content-type coding. Keep these values
/// small and intentional. Business pages can import `app_chrome.dart`, which
/// re-exports this file for backwards compatibility.
class AppColors {
  const AppColors._();

  // Warm charcoal surfaces for the dark theme. Never pure black: the dark
  // theme shares the paper temperature of the light theme.
  static const bg = Color(0xFF1F1E1C);
  static const bg2 = Color(0xFF242220);
  static const panel = Color(0xFF282624);
  static const panelHigh = Color(0xFF302D2A);
  static const panelHover = Color(0xFF373431);
  static const overlay = Color(0xE61B1A18);

  static const border = Color(0xFF3B3833);
  static const borderBright = Color(0xFF4E4A44);

  // Mist blue accent family. `primary2` doubles as the readable accent for
  // text on dark surfaces; `accentDeep` is the readable accent on paper.
  static const primary = Color(0xFF6A9BCC);
  static const primary2 = Color(0xFF8FB3D9);
  static const accentDeep = Color(0xFF46759F);

  // Content-type coding colors. The legacy `cyan`/`rose` aliases now resolve
  // to celadon (series) and wisteria (movies); anime uses the accent itself.
  static const cyan = Color(0xFF6FA39B);
  static const rose = Color(0xFF9C90C4);
  static const celadonDeep = Color(0xFF4E7F77);
  static const wisteriaDeep = Color(0xFF746699);

  static const primarySurface = Color(0xFF333A41);
  static const secondarySurface = Color(0xFF35322E);

  static const text = Color(0xFFF0EFE9);
  static const muted = Color(0xFFB8B5AA);
  static const faint = Color(0xFF8A877C);

  // Semantic colors sit apart from the accent family and are tuned to stay
  // legible on both paper and charcoal.
  static const success = Color(0xFF7C9159);
  static const warning = Color(0xFFC9963F);
  static const danger = Color(0xFFC05B50);

  // Warm paper surfaces for the light theme.
  static const lightBg = Color(0xFFFAF9F5);
  static const lightCard = Color(0xFFFFFEFB);
  static const lightPanel = Color(0xFFF0EEE6);
  static const lightPanelHigh = Color(0xFFE9E6DA);
  static const lightBorder = Color(0xFFE4E1D5);
  static const lightText = Color(0xFF141413);
  static const lightMuted = Color(0xFF57564F);
  static const lightFaint = Color(0xFF8F8C80);

  // Theater tokens are theme-independent: playback always happens in the
  // same warm dark room regardless of the browsing theme.
  static const theaterBg = Color(0xFF171614);
  static const theaterPanel = Color(0xFF211F1D);
  static const theaterInk = Color(0xFFEFEDE6);
  static const theaterMuted = Color(0xB3EFEDE6);
  static const theaterFaint = Color(0x66EFEDE6);
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
  static const mobileNavigationHeight = 72.0;

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

  // Warm ink shadows: a tight contact layer plus a soft diffuse layer, kept
  // faint so cards read as paper resting on paper rather than floating.
  static const panel = <BoxShadow>[
    BoxShadow(color: Color(0x0A141413), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F141413), blurRadius: 16, offset: Offset(0, 4)),
  ];

  static const elevated = <BoxShadow>[
    BoxShadow(color: Color(0x0F141413), blurRadius: 4, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x1F141413), blurRadius: 32, offset: Offset(0, 12)),
  ];

  static const primaryGlow = <BoxShadow>[
    BoxShadow(color: Color(0x2E6A9BCC), blurRadius: 24, offset: Offset(0, 8)),
  ];
}

class AppGradients {
  const AppGradients._();

  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primary, AppColors.primary2, AppColors.cyan],
  );

  static const page = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF232120), AppColors.bg, Color(0xFF1A1918)],
    stops: [0, 0.52, 1],
  );

  static const accent = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [AppColors.primary, Color(0xFF5B88B8)],
  );

  static const coolAccent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primary2, AppColors.cyan],
  );

  static const mediaScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x08000000), Color(0x24151412), Color(0xE6171614)],
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
