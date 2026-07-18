import 'package:flutter/material.dart';

/// Shared visual tokens for the media experience.
///
/// Keep these values small and intentional. Business pages can import
/// `app_chrome.dart`, which re-exports this file for backwards compatibility.
class AppColors {
  const AppColors._();

  // Neutral grayscale tokens keep the light theme truly white and the dark
  // theme free of colored tint. Legacy aliases stay available for older page
  // code, but should resolve to neutral surfaces only.
  static const bg = Color(0xFF050505);
  static const bg2 = Color(0xFF0A0A0A);
  static const panel = Color(0xFF121212);
  static const panelHigh = Color(0xFF1A1A1A);
  static const panelHover = Color(0xFF232323);
  static const overlay = Color(0xE6080808);

  static const border = Color(0xFF2B2B2B);
  static const borderBright = Color(0xFF484848);

  static const primary = Color(0xFF707070);
  static const primary2 = Color(0xFF9A9A9A);
  static const cyan = Color(0xFFB8B8B8);
  static const rose = Color(0xFF888888);
  static const primarySurface = Color(0xFF242424);
  static const secondarySurface = Color(0xFF2A2A2A);

  static const text = Color(0xFFF5F5F5);
  static const muted = Color(0xFFB2B2B2);
  static const faint = Color(0xFF777777);

  static const success = Color(0xFF4ED6A0);
  static const warning = Color(0xFFFFB45E);
  static const danger = Color(0xFFFF7087);

  static const lightBg = Color(0xFFFFFFFF);
  static const lightPanel = Color(0xFFF5F5F5);
  static const lightPanelHigh = Color(0xFFEDEDED);
  static const lightBorder = Color(0xFFD8D8D8);
  static const lightText = Color(0xFF111111);
  static const lightMuted = Color(0xFF5E5E5E);
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
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 22.0;
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

  static const panel = <BoxShadow>[
    BoxShadow(color: Color(0x26000000), blurRadius: 26, offset: Offset(0, 12)),
  ];

  static const elevated = <BoxShadow>[
    BoxShadow(color: Color(0x52000000), blurRadius: 34, offset: Offset(0, 18)),
  ];

  static const primaryGlow = <BoxShadow>[
    BoxShadow(color: Color(0x38000000), blurRadius: 28, offset: Offset(0, 10)),
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
    colors: [Color(0xFF111111), AppColors.bg, Color(0xFF090909)],
    stops: [0, 0.52, 1],
  );

  static const accent = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [AppColors.primary, AppColors.primary2],
  );

  static const coolAccent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primary2, AppColors.cyan],
  );

  static const mediaScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x08000000), Color(0x24050505), Color(0xE6050505)],
    stops: [0, 0.58, 1],
  );
}

extension AppContextDesign on BuildContext {
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  bool get isMobileLayout =>
      MediaQuery.sizeOf(this).width < AppBreakpoints.mobile;

  bool get isDesktopLayout =>
      MediaQuery.sizeOf(this).width >= AppBreakpoints.desktop;

  EdgeInsets get pagePadding => AppLayout.pagePadding(this);
}
