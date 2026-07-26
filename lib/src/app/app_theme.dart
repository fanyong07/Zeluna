import 'package:flutter/material.dart';

import '../shared_ui/app_design.dart';

class AnimeTheme {
  const AnimeTheme._();

  static ThemeData dark({bool compact = false, bool reduceMotion = false}) {
    return _theme(
      brightness: Brightness.dark,
      compact: compact,
      reduceMotion: reduceMotion,
    );
  }

  static ThemeData light({bool compact = false, bool reduceMotion = false}) {
    return _theme(
      brightness: Brightness.light,
      compact: compact,
      reduceMotion: reduceMotion,
    );
  }

  static ThemeData _theme({
    required Brightness brightness,
    required bool compact,
    required bool reduceMotion,
  }) {
    final dark = brightness == Brightness.dark;
    final colors = _ThemeColors(dark: dark);
    // The accent fill stays mist blue in both themes; only the readable
    // text-accent shifts (deep on paper, lightened on charcoal).
    const primary = AppColors.primary;
    const onPrimary = Colors.white;
    final textAccent = dark ? AppColors.primary2 : AppColors.accentDeep;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: brightness,
          surface: colors.surface,
        ).copyWith(
          primary: primary,
          onPrimary: onPrimary,
          secondary: AppColors.cyan,
          onSecondary: Colors.white,
          tertiary: AppColors.rose,
          onTertiary: Colors.white,
          primaryContainer: dark
              ? AppColors.primarySurface
              : const Color(0xFFDFE9F3),
          onPrimaryContainer: dark
              ? const Color(0xFFC3D8EC)
              : const Color(0xFF2C4A66),
          secondaryContainer: dark
              ? AppColors.secondarySurface
              : AppColors.lightPanel,
          onSecondaryContainer: dark
              ? const Color(0xFFD6D3C8)
              : const Color(0xFF3C3A33),
          surface: colors.surface,
          surfaceContainerLowest: colors.background,
          surfaceContainerLow: colors.surfaceLow,
          surfaceContainer: colors.panel,
          surfaceContainerHigh: colors.panelHigh,
          surfaceContainerHighest: colors.panelHighest,
          onSurface: colors.text,
          onSurfaceVariant: colors.muted,
          outline: colors.borderBright,
          outlineVariant: colors.border,
          error: AppColors.danger,
          onError: Colors.white,
          shadow: const Color(0xFF141413),
          scrim: Colors.black,
        );

    final textTheme = _textTheme(dark: dark);
    final controlHeight = compact ? 40.0 : 44.0;
    final controlPadding = EdgeInsets.symmetric(
      horizontal: compact ? 14 : 18,
      vertical: compact ? 9 : 11,
    );
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.background,
      cardColor: colors.panel,
      disabledColor: colors.muted.withValues(alpha: 0.42),
      dividerColor: colors.border,
      focusColor: primary.withValues(alpha: 0.18),
      hoverColor: primary.withValues(alpha: 0.06),
      highlightColor: primary.withValues(alpha: 0.08),
      splashColor: primary.withValues(alpha: 0.10),
      fontFamily: AppTypography.sansFamily,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: colors.muted, size: 21),
      primaryIconTheme: const IconThemeData(color: onPrimary, size: 21),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: const Color(0xFF141413).withValues(alpha: 0.18),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: colors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.panelHigh,
        isDense: compact,
        contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? 13 : 15,
          vertical: compact ? 11 : 13,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: colors.faint),
        labelStyle: textTheme.bodyMedium?.copyWith(color: colors.muted),
        floatingLabelStyle: textTheme.bodyMedium?.copyWith(
          color: textAccent,
          fontWeight: FontWeight.w700,
        ),
        prefixIconColor: colors.muted,
        suffixIconColor: colors.muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: colors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.4),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, controlHeight)),
          padding: WidgetStatePropertyAll(controlPadding),
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return primary.withValues(alpha: 0.30);
            }
            if (states.contains(WidgetState.hovered)) {
              return const Color(0xFF5B88B8);
            }
            return primary;
          }),
          foregroundColor: const WidgetStatePropertyAll(onPrimary),
          overlayColor: WidgetStatePropertyAll(
            Colors.white.withValues(alpha: 0.10),
          ),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, controlHeight)),
          padding: WidgetStatePropertyAll(controlPadding),
          elevation: const WidgetStatePropertyAll(0),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return colors.faint;
            return colors.text;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered)) return colors.panelHover;
            return colors.surfaceLow;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            final color = states.contains(WidgetState.focused)
                ? primary
                : colors.border;
            return BorderSide(color: color);
          }),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, controlHeight)),
          padding: WidgetStatePropertyAll(controlPadding),
          foregroundColor: WidgetStatePropertyAll(textAccent),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size.square(controlHeight)),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return colors.faint;
            if (states.contains(WidgetState.hovered)) return colors.text;
            return colors.muted;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered)) return colors.panelHover;
            return Colors.transparent;
          }),
          shape: WidgetStatePropertyAll(controlShape),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, controlHeight)),
          padding: WidgetStatePropertyAll(controlPadding),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? colors.selectedInk
                : colors.muted;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? colors.selectedFill
                : colors.surfaceLow;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            return BorderSide(
              color: states.contains(WidgetState.selected)
                  ? colors.selectedFill
                  : colors.border,
            );
          }),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surfaceLow,
        selectedColor: primary.withValues(alpha: dark ? 0.24 : 0.14),
        disabledColor: colors.panelHigh.withValues(alpha: 0.5),
        side: BorderSide(color: colors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        labelStyle: textTheme.labelMedium?.copyWith(color: colors.muted),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: colors.text,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary;
          }
          return colors.panelHighest;
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? Colors.white
              : colors.muted;
        }),
        trackOutlineColor: WidgetStatePropertyAll(colors.border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? primary
              : Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(color: colors.borderBright),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: colors.border,
        circularTrackColor: colors.border,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? AppColors.panelHigh : AppColors.lightText,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: AppColors.lightBg,
        ),
        actionTextColor: AppColors.primary2,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(
            color: dark ? AppColors.borderBright : Colors.transparent,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: colors.panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: const Color(0xFF141413).withValues(alpha: 0.30),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          side: BorderSide(color: colors.border),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: colors.muted),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        elevation: 0,
        backgroundColor: colors.panel,
        modalBackgroundColor: colors.panel,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        elevation: 0,
        color: colors.panelHigh,
        surfaceTintColor: Colors.transparent,
        textStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: colors.border),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.muted,
        textColor: colors.text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? AppColors.panelHigh : AppColors.lightText,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: dark ? AppColors.borderBright : Colors.transparent,
          ),
          boxShadow: AppShadows.panel,
        ),
        textStyle: textTheme.labelMedium?.copyWith(color: AppColors.lightBg),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        waitDuration: const Duration(milliseconds: 450),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: AppLayout.mobileNavigationHeight,
        elevation: 0,
        backgroundColor: colors.surfaceLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: primary.withValues(alpha: dark ? 0.22 : 0.13),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? textAccent
                : colors.muted,
            size: 23,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return textTheme.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected)
                ? textAccent
                : colors.muted,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w600,
          );
        }),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(7),
        radius: const Radius.circular(AppRadius.pill),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.hovered)
              ? colors.borderBright
              : colors.border;
        }),
        trackColor: WidgetStatePropertyAll(colors.background),
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

  static TextTheme _textTheme({required bool dark}) {
    final text = dark ? AppColors.text : AppColors.lightText;
    final muted = dark ? AppColors.muted : AppColors.lightMuted;

    TextStyle sans({
      required double size,
      required FontWeight weight,
      required double height,
      double spacing = 0,
      Color? color,
    }) {
      return TextStyle(
        color: color ?? text,
        fontFamily: AppTypography.sansFamily,
        fontFamilyFallback: AppTypography.sansFallback,
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
      );
    }

    // Display roles carry the bundled serif; it ships in SemiBold only, so
    // every serif style pins w600 to avoid faux-bolding.
    TextStyle serif({
      required double size,
      required double height,
      double spacing = 0.2,
      Color? color,
    }) {
      return TextStyle(
        color: color ?? text,
        fontFamily: AppTypography.serifFamily,
        fontFamilyFallback: AppTypography.serifFallback,
        fontSize: size,
        fontWeight: FontWeight.w600,
        height: height,
        letterSpacing: spacing,
      );
    }

    return TextTheme(
      displayLarge: serif(size: 44, height: 1.18),
      displayMedium: serif(size: 36, height: 1.20),
      displaySmall: serif(size: 32, height: 1.22),
      headlineLarge: serif(size: 28, height: 1.25),
      headlineMedium: serif(size: 24, height: 1.28),
      headlineSmall: serif(size: 21, height: 1.30),
      titleLarge: serif(size: 19, height: 1.35),
      titleMedium: sans(size: 16, weight: FontWeight.w600, height: 1.35),
      titleSmall: sans(size: 14, weight: FontWeight.w600, height: 1.35),
      bodyLarge: sans(size: 16, weight: FontWeight.w400, height: 1.6),
      bodyMedium: sans(size: 14, weight: FontWeight.w400, height: 1.55),
      bodySmall: sans(
        size: 12,
        weight: FontWeight.w400,
        height: 1.45,
        color: muted,
      ),
      labelLarge: sans(size: 14, weight: FontWeight.w600, height: 1.20),
      labelMedium: sans(size: 12, weight: FontWeight.w600, height: 1.20),
      labelSmall: sans(
        size: 11,
        weight: FontWeight.w600,
        height: 1.20,
        spacing: 0.6,
      ),
    );
  }
}

class _ThemeColors {
  const _ThemeColors({required this.dark});

  final bool dark;

  Color get background => dark ? AppColors.bg : AppColors.lightBg;
  Color get surface => dark ? AppColors.bg2 : AppColors.lightBg;
  Color get surfaceLow => dark ? AppColors.panel : AppColors.lightCard;
  Color get panel => dark ? AppColors.panel : AppColors.lightCard;
  Color get panelHigh => dark ? AppColors.panelHigh : AppColors.lightPanel;
  Color get panelHighest =>
      dark ? AppColors.panelHover : AppColors.lightPanelHigh;
  Color get panelHover => dark ? AppColors.panelHover : AppColors.lightPanel;
  Color get border => dark ? AppColors.border : AppColors.lightBorder;
  Color get borderBright =>
      dark ? AppColors.borderBright : const Color(0xFFCFCBBD);
  Color get text => dark ? AppColors.text : AppColors.lightText;
  Color get muted => dark ? AppColors.muted : AppColors.lightMuted;
  Color get faint => dark ? AppColors.faint : AppColors.lightFaint;

  // Selected segmented controls read as ink-on-paper: the fill flips to the
  // opposite ink and the label flips to the page color.
  Color get selectedFill => dark ? AppColors.text : AppColors.lightText;
  Color get selectedInk => dark ? AppColors.bg : AppColors.lightBg;
}

/// The calm paper transition: the incoming page fades in and settles with a
/// barely-there upward drift. No scaling — the Material 3 zoom default reads
/// as aggressive against static paper surfaces.
class _GentlePageTransitionsBuilder extends PageTransitionsBuilder {
  const _GentlePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.015),
          end: Offset.zero,
        ).animate(curved),
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
