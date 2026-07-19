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
    final primary = dark ? const Color(0xFFF2F2F2) : const Color(0xFF171717);
    final onPrimary = dark ? const Color(0xFF111111) : Colors.white;
    final secondary = dark ? const Color(0xFFC4C4C4) : const Color(0xFF4F4F4F);
    final onSecondary = dark ? const Color(0xFF141414) : Colors.white;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF777777),
          brightness: brightness,
          surface: colors.surface,
        ).copyWith(
          primary: primary,
          onPrimary: onPrimary,
          secondary: secondary,
          onSecondary: onSecondary,
          tertiary: dark ? const Color(0xFF9A9A9A) : const Color(0xFF666666),
          onTertiary: dark ? const Color(0xFF111111) : Colors.white,
          primaryContainer: dark
              ? const Color(0xFF2A2A2A)
              : const Color(0xFFE4E4E4),
          onPrimaryContainer: dark
              ? const Color(0xFFF1F1F1)
              : const Color(0xFF1C1C1C),
          secondaryContainer: dark
              ? const Color(0xFF242424)
              : const Color(0xFFE9E9E9),
          onSecondaryContainer: dark
              ? const Color(0xFFDADADA)
              : const Color(0xFF303030),
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
          shadow: Colors.black,
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
      focusColor: scheme.primary.withValues(alpha: 0.16),
      hoverColor: scheme.primary.withValues(alpha: 0.07),
      highlightColor: scheme.primary.withValues(alpha: 0.09),
      splashColor: scheme.primary.withValues(alpha: 0.11),
      fontFamily: 'Microsoft YaHei UI',
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: colors.muted, size: 21),
      primaryIconTheme: IconThemeData(color: scheme.onPrimary, size: 21),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: 0.34),
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
          color: scheme.primary,
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
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
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
              return scheme.primary.withValues(alpha: 0.30);
            }
            if (states.contains(WidgetState.hovered)) return AppColors.rose;
            return scheme.primary;
          }),
          foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
          overlayColor: WidgetStatePropertyAll(
            scheme.onPrimary.withValues(alpha: 0.10),
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
            return colors.panelHigh;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            final color = states.contains(WidgetState.focused)
                ? scheme.primary
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
          foregroundColor: WidgetStatePropertyAll(scheme.primary),
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
                ? scheme.onPrimary
                : colors.muted;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? scheme.primary
                : colors.panelHigh;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            return BorderSide(
              color: states.contains(WidgetState.selected)
                  ? scheme.primary
                  : colors.border,
            );
          }),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.panelHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.16),
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
            return scheme.primary.withValues(alpha: 0.78);
          }
          return colors.panelHighest;
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : colors.muted;
        }),
        trackOutlineColor: WidgetStatePropertyAll(colors.border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? scheme.primary
              : Colors.transparent;
        }),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: BorderSide(color: colors.borderBright),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: colors.border,
        circularTrackColor: colors.border,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? AppColors.panelHigh : AppColors.lightText,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
        actionTextColor: dark ? Colors.white : const Color(0xFFD8D8D8),
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
        shadowColor: Colors.black.withValues(alpha: 0.45),
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
        textStyle: textTheme.labelMedium?.copyWith(color: Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        waitDuration: const Duration(milliseconds: 450),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: AppLayout.mobileNavigationHeight,
        elevation: 0,
        backgroundColor: colors.panel,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : colors.muted,
            size: 23,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return textTheme.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected)
                ? colors.text
                : colors.muted,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
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
          : const PageTransitionsTheme(),
    );
  }

  static TextTheme _textTheme({required bool dark}) {
    final text = dark ? AppColors.text : AppColors.lightText;
    final muted = dark ? AppColors.muted : AppColors.lightMuted;
    const fallback = <String>[
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC',
    ];

    TextStyle style({
      required double size,
      required FontWeight weight,
      required double height,
      double spacing = 0,
      Color? color,
    }) {
      return TextStyle(
        color: color ?? text,
        fontFamily: 'Microsoft YaHei UI',
        fontFamilyFallback: fallback,
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
      );
    }

    return TextTheme(
      displayLarge: style(size: 48, weight: FontWeight.w900, height: 1.08),
      displayMedium: style(size: 40, weight: FontWeight.w900, height: 1.10),
      displaySmall: style(size: 34, weight: FontWeight.w900, height: 1.12),
      headlineLarge: style(size: 30, weight: FontWeight.w800, height: 1.16),
      headlineMedium: style(size: 26, weight: FontWeight.w800, height: 1.20),
      headlineSmall: style(size: 22, weight: FontWeight.w800, height: 1.22),
      titleLarge: style(size: 20, weight: FontWeight.w800, height: 1.28),
      titleMedium: style(size: 16, weight: FontWeight.w700, height: 1.35),
      titleSmall: style(size: 14, weight: FontWeight.w700, height: 1.35),
      bodyLarge: style(size: 16, weight: FontWeight.w400, height: 1.55),
      bodyMedium: style(size: 14, weight: FontWeight.w400, height: 1.52),
      bodySmall: style(
        size: 12,
        weight: FontWeight.w400,
        height: 1.45,
        color: muted,
      ),
      labelLarge: style(size: 14, weight: FontWeight.w700, height: 1.20),
      labelMedium: style(size: 12, weight: FontWeight.w700, height: 1.20),
      labelSmall: style(size: 11, weight: FontWeight.w700, height: 1.20),
    );
  }
}

class _ThemeColors {
  const _ThemeColors({required this.dark});

  final bool dark;

  Color get background => dark ? AppColors.bg : AppColors.lightBg;
  Color get surface => dark ? AppColors.bg2 : AppColors.lightBg;
  Color get surfaceLow =>
      dark ? const Color(0xFF0F131D) : const Color(0xFFF9FAFD);
  Color get panel => dark ? AppColors.panel : AppColors.lightPanel;
  Color get panelHigh => dark ? AppColors.panelHigh : AppColors.lightPanelHigh;
  Color get panelHighest =>
      dark ? AppColors.panelHover : const Color(0xFFE8EBF3);
  Color get panelHover => dark ? AppColors.panelHover : const Color(0xFFEAEDF5);
  Color get border => dark ? AppColors.border : AppColors.lightBorder;
  Color get borderBright =>
      dark ? AppColors.borderBright : const Color(0xFFC4CAD8);
  Color get text => dark ? AppColors.text : AppColors.lightText;
  Color get muted => dark ? AppColors.muted : AppColors.lightMuted;
  Color get faint => dark ? AppColors.faint : const Color(0xFF8B93A5);
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
