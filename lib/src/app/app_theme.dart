import 'package:flutter/material.dart';

import '../domain/anime_models.dart';
import '../shared_ui/app_design.dart';
import '../theme/zeluna_color_palette.dart';

/// Dynamic Zeluna v3.0 theme builder.
///
/// Defaults to pure monochrome black/white cinema surfaces so posters carry all
/// the color, while supporting Pure Black OLED, 7-color spectrum presets, and
/// any custom HSV palette color with automatic contrast protection.
class AnimeTheme {
  const AnimeTheme._();

  static ThemeData dark({
    bool compact = false,
    bool reduceMotion = false,
    AppearanceSettings? appearance,
  }) {
    final effective = (appearance ?? const AppearanceSettings()).copyWith(
      compactMode: compact || (appearance?.compactMode ?? false),
      reduceMotion: reduceMotion || (appearance?.reduceMotion ?? false),
    );
    return _theme(brightness: Brightness.dark, appearance: effective);
  }

  static ThemeData light({
    bool compact = false,
    bool reduceMotion = false,
    AppearanceSettings? appearance,
  }) {
    final effective = (appearance ?? const AppearanceSettings()).copyWith(
      compactMode: compact || (appearance?.compactMode ?? false),
      reduceMotion: reduceMotion || (appearance?.reduceMotion ?? false),
    );
    return _theme(brightness: Brightness.light, appearance: effective);
  }

  static ThemeData _theme({
    required Brightness brightness,
    required AppearanceSettings appearance,
  }) {
    final dark = brightness == Brightness.dark;
    final compact = appearance.compactMode;
    final reduceMotion = appearance.reduceMotion;
    final monochrome = appearance.accentMode == ThemeAccentMode.monochrome;
    final seed = Color(appearance.accentColorValue | 0xFF000000);

    final primary = monochrome
        ? (dark ? AppColors.primary : AppColors.lightPrimary)
        : ZelunaColorPalette.adaptiveAccent(seed, dark: dark);
    final onPrimary = monochrome
        ? (dark ? const Color(0xFF0B0B0D) : const Color(0xFFFFFFFF))
        : ZelunaColorPalette.contrastingForeground(primary);
    final secondary = monochrome
        ? (dark ? AppColors.primary2 : AppColors.lightSecondary)
        : ZelunaColorPalette.companionAccent(primary, dark: dark);
    final onSecondary = monochrome
        ? (dark ? const Color(0xFF0B0B0D) : const Color(0xFFFFFFFF))
        : ZelunaColorPalette.contrastingForeground(secondary);

    final colors = _ThemeSurfaces.resolve(
      dark: dark,
      oled: dark && appearance.pureBlackOled,
      tintAccent: !monochrome && appearance.tintedSurfaces ? primary : null,
    );

    final primaryContainer = monochrome
        ? (dark ? const Color(0xFF28282F) : const Color(0xFFEBEBF0))
        : Color.alphaBlend(
            primary.withValues(alpha: dark ? 0.22 : 0.14),
            colors.panel,
          );
    final onPrimaryContainer = monochrome
        ? colors.text
        : (dark
              ? Color.lerp(primary, Colors.white, 0.55)!
              : Color.lerp(primary, Colors.black, 0.45)!);

    final secondaryContainer = monochrome
        ? (dark ? const Color(0xFF222228) : const Color(0xFFF0F0F4))
        : Color.alphaBlend(
            secondary.withValues(alpha: dark ? 0.20 : 0.12),
            colors.panel,
          );
    final onSecondaryContainer = monochrome
        ? colors.text
        : (dark
              ? Color.lerp(secondary, Colors.white, 0.50)!
              : Color.lerp(secondary, Colors.black, 0.42)!);

    final tertiary = monochrome
        ? (dark ? const Color(0xFFB4B4BE) : const Color(0xFF52525B))
        : (dark ? AppColors.rose : AppColors.lightRose);
    final onTertiary = ZelunaColorPalette.contrastingForeground(tertiary);
    final tertiaryContainer = monochrome
        ? colors.panelHigh
        : Color.alphaBlend(
            tertiary.withValues(alpha: dark ? 0.22 : 0.14),
            colors.panel,
          );
    final onTertiaryContainer = monochrome
        ? colors.text
        : (dark
              ? Color.lerp(tertiary, Colors.white, 0.45)!
              : Color.lerp(tertiary, Colors.black, 0.40)!);

    final errorColor = dark ? AppColors.danger : const Color(0xFFDC2626);
    final onErrorColor = Colors.white;
    final errorContainerColor = dark
        ? const Color(0xFF3A161A)
        : const Color(0xFFFEE2E2);
    final onErrorContainerColor = dark
        ? const Color(0xFFFCA5A5)
        : const Color(0xFF991B1B);

    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: secondary,
      onSecondary: onSecondary,
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: tertiary,
      onTertiary: onTertiary,
      tertiaryContainer: tertiaryContainer,
      onTertiaryContainer: onTertiaryContainer,
      error: errorColor,
      onError: onErrorColor,
      errorContainer: errorContainerColor,
      onErrorContainer: onErrorContainerColor,
      surface: colors.surface,
      onSurface: colors.text,
      onSurfaceVariant: colors.muted,
      surfaceContainerLowest: colors.background,
      surfaceContainerLow: colors.surfaceLow,
      surfaceContainer: colors.panel,
      surfaceContainerHigh: colors.panelHigh,
      surfaceContainerHighest: colors.panelHighest,
      surfaceDim: colors.panelHigh,
      surfaceBright: colors.surface,
      outline: colors.borderBright,
      outlineVariant: colors.border,
      inverseSurface: colors.text,
      onInverseSurface: colors.background,
      inversePrimary: monochrome
          ? (dark ? AppColors.lightPrimary : AppColors.primary)
          : ZelunaColorPalette.adaptiveAccent(seed, dark: !dark),
      shadow: Colors.black,
      scrim: Colors.black,
      surfaceTint: Colors.transparent,
    );

    final textTheme = _textTheme(colors: colors);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.background,
      colorScheme: scheme,
      fontFamily: AppTypography.sansFamily,
      fontFamilyFallback: AppTypography.sansFallback,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.background,
        foregroundColor: colors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      iconTheme: IconThemeData(color: colors.text, size: 22),
      cardTheme: CardThemeData(
        color: colors.panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: colors.border, width: 0.75),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 0.75,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.muted,
        textColor: colors.text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          disabledBackgroundColor: colors.panelHigh,
          disabledForegroundColor: colors.faint,
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          elevation: 0,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.text,
          backgroundColor: Colors.transparent,
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          side: BorderSide(color: colors.borderBright, width: 0.9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: monochrome ? colors.text : primary,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return primary;
            return colors.panel;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return onPrimary;
            return colors.muted;
          }),
          side: WidgetStatePropertyAll(BorderSide(color: colors.border)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.panel,
        hintStyle: textTheme.bodyMedium?.copyWith(color: colors.faint),
        labelStyle: textTheme.bodyMedium?.copyWith(color: colors.muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: colors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: primary, width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.panel,
        selectedColor: primary,
        disabledColor: colors.panel,
        side: BorderSide(color: colors.border, width: 0.75),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        showCheckmark: false,
        labelStyle: textTheme.labelMedium?.copyWith(
          color: colors.text,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: onPrimary,
          fontWeight: FontWeight.w700,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return onPrimary;
          return colors.muted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return colors.panelHigh;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return colors.borderBright;
        }),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return onPrimary;
          return Colors.transparent;
        }),
        side: BorderSide(color: colors.borderBright, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return colors.muted;
        }),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: colors.borderBright,
        thumbColor: primary,
        overlayColor: primary.withValues(alpha: 0.16),
        trackHeight: 3,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: colors.panelHigh,
        circularTrackColor: colors.panelHigh,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: monochrome ? colors.text : primary,
        unselectedLabelColor: colors.muted,
        indicatorColor: primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: colors.border,
        labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: colors.border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: colors.borderBright,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: colors.border),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: dark ? colors.panelHighest : colors.text,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: dark ? colors.text : colors.background,
          fontWeight: FontWeight.w500,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? colors.panelHighest : colors.text,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        textStyle: textTheme.labelSmall?.copyWith(
          color: dark ? colors.text : colors.background,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        waitDuration: const Duration(milliseconds: 400),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: AppLayout.mobileNavigationHeight,
        elevation: 0,
        backgroundColor: colors.background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: primary.withValues(alpha: dark ? 0.16 : 0.10),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? primary
                : colors.muted,
            size: 22,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return textTheme.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected)
                ? primary
                : colors.muted,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          );
        }),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(5),
        radius: const Radius.circular(AppRadius.pill),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.hovered)
              ? colors.muted
              : colors.borderBright;
        }),
        trackColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      pageTransitionsTheme: reduceMotion
          ? const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: _NoAnimationPageTransitionsBuilder(),
                TargetPlatform.iOS: _NoAnimationPageTransitionsBuilder(),
                TargetPlatform.linux: _NoAnimationPageTransitionsBuilder(),
                TargetPlatform.macOS: _NoAnimationPageTransitionsBuilder(),
                TargetPlatform.windows: _NoAnimationPageTransitionsBuilder(),
              },
            )
          : const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: _GentlePageTransitionsBuilder(),
                TargetPlatform.iOS: _GentlePageTransitionsBuilder(),
                TargetPlatform.fuchsia: _GentlePageTransitionsBuilder(),
                TargetPlatform.linux: _GentlePageTransitionsBuilder(),
                TargetPlatform.macOS: _GentlePageTransitionsBuilder(),
                TargetPlatform.windows: _GentlePageTransitionsBuilder(),
              },
            ),
    );
  }

  static TextTheme _textTheme({required _ThemeSurfaces colors}) {
    TextStyle sans({
      required double size,
      required FontWeight weight,
      required double height,
      double spacing = 0,
      Color? color,
    }) {
      return TextStyle(
        color: color ?? colors.text,
        fontFamily: AppTypography.sansFamily,
        fontFamilyFallback: AppTypography.sansFallback,
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
      );
    }

    return TextTheme(
      displaySmall: sans(
        size: 30,
        weight: FontWeight.w800,
        height: 1.15,
        spacing: -0.5,
      ),
      headlineMedium: sans(
        size: 24,
        weight: FontWeight.w800,
        height: 1.2,
        spacing: -0.35,
      ),
      headlineSmall: sans(
        size: 20,
        weight: FontWeight.w700,
        height: 1.24,
        spacing: -0.2,
      ),
      titleLarge: sans(size: 18, weight: FontWeight.w700, height: 1.28),
      titleMedium: sans(size: 15, weight: FontWeight.w700, height: 1.32),
      titleSmall: sans(size: 13.5, weight: FontWeight.w700, height: 1.32),
      bodyLarge: sans(size: 14.5, weight: FontWeight.w500, height: 1.5),
      bodyMedium: sans(size: 13.5, weight: FontWeight.w400, height: 1.48),
      bodySmall: sans(
        size: 12,
        weight: FontWeight.w400,
        height: 1.4,
        color: colors.muted,
      ),
      labelLarge: sans(size: 13.5, weight: FontWeight.w600, height: 1.2),
      labelMedium: sans(size: 12, weight: FontWeight.w600, height: 1.2),
      labelSmall: sans(
        size: 11,
        weight: FontWeight.w600,
        height: 1.2,
        color: colors.muted,
      ),
    );
  }
}

class _ThemeSurfaces {
  const _ThemeSurfaces({
    required this.background,
    required this.surface,
    required this.surfaceLow,
    required this.panel,
    required this.panelHigh,
    required this.panelHighest,
    required this.border,
    required this.borderBright,
    required this.text,
    required this.muted,
    required this.faint,
  });

  final Color background;
  final Color surface;
  final Color surfaceLow;
  final Color panel;
  final Color panelHigh;
  final Color panelHighest;
  final Color border;
  final Color borderBright;
  final Color text;
  final Color muted;
  final Color faint;

  factory _ThemeSurfaces.resolve({
    required bool dark,
    required bool oled,
    required Color? tintAccent,
  }) {
    Color maybeTint(Color base, double alpha) {
      if (tintAccent == null) return base;
      return Color.alphaBlend(tintAccent.withValues(alpha: alpha), base);
    }

    if (dark) {
      final bg = oled ? const Color(0xFF000000) : maybeTint(AppColors.bg, 0.03);
      return _ThemeSurfaces(
        background: bg,
        surface: oled
            ? const Color(0xFF0A0A0C)
            : maybeTint(const Color(0xFF151518), 0.04),
        surfaceLow: oled
            ? const Color(0xFF0C0C0E)
            : maybeTint(const Color(0xFF141417), 0.035),
        panel: oled
            ? const Color(0xFF121215)
            : maybeTint(AppColors.panel, 0.045),
        panelHigh: oled
            ? const Color(0xFF1B1B20)
            : maybeTint(AppColors.panelHigh, 0.055),
        panelHighest: oled
            ? const Color(0xFF26262C)
            : maybeTint(AppColors.panelHover, 0.06),
        border: maybeTint(AppColors.border, 0.08),
        borderBright: maybeTint(AppColors.borderBright, 0.12),
        text: AppColors.text,
        muted: AppColors.muted,
        faint: AppColors.faint,
      );
    }

    return _ThemeSurfaces(
      background: maybeTint(AppColors.lightBg, 0.025),
      surface: AppColors.lightCard,
      surfaceLow: maybeTint(const Color(0xFFF7F7F9), 0.03),
      panel: maybeTint(AppColors.lightPanel, 0.04),
      panelHigh: maybeTint(AppColors.lightPanelHigh, 0.055),
      panelHighest: maybeTint(const Color(0xFFE0E0E6), 0.06),
      border: maybeTint(AppColors.lightBorder, 0.08),
      borderBright: maybeTint(const Color(0xFFCBCBD4), 0.12),
      text: AppColors.lightText,
      muted: AppColors.lightMuted,
      faint: AppColors.lightFaint,
    );
  }
}

class _GentlePageTransitionsBuilder extends PageTransitionsBuilder {
  const _GentlePageTransitionsBuilder();

  static final Animatable<Offset> _slideTween = Tween<Offset>(
    begin: const Offset(0.045, 0),
    end: Offset.zero,
  );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: _slideTween.animate(curved),
        child: child,
      ),
    );
  }
}

class _NoAnimationPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoAnimationPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
