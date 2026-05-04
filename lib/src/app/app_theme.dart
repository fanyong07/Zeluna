import 'package:flutter/material.dart';

class AnimeTheme {
  const AnimeTheme._();

  static ThemeData dark() {
    const seed = Color(0xFF7567FF);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: Color(0xFF080B14),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(
        primary: const Color(0xFF7567FF),
        onPrimary: const Color(0xFFF6F3FF),
        secondary: const Color(0xFF57B8FF),
        onSecondary: const Color(0xFFEAF7FF),
        primaryContainer: const Color(0xFF24255C),
        onPrimaryContainer: const Color(0xFFE7E7FF),
        surface: const Color(0xFF080B14),
        surfaceContainer: const Color(0xFF101522),
        surfaceContainerHigh: const Color(0xFF151C2C),
        surfaceContainerHighest: const Color(0xFF1A2235),
        outline: const Color(0xFF303A55),
        outlineVariant: const Color(0xFF20283C),
        onSurface: const Color(0xFFE9ECF8),
        onSurfaceVariant: const Color(0xFF9DA7C2),
      ),
      scaffoldBackgroundColor: const Color(0xFF060912),
      fontFamily: 'Microsoft YaHei UI',
      textTheme: const TextTheme(
        displaySmall: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0),
        headlineMedium: TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        titleLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0),
        titleMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0),
        labelLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: const Color(0xFF101522),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF20283C)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF111827),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFF20283C)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFF7567FF)),
        ),
        hintStyle: const TextStyle(color: Color(0xFF7F89A6)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF20283C),
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(Color(0xFF6758F2)),
          foregroundColor: const WidgetStatePropertyAll(Color(0xFFFFFFFF)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(Color(0xFFE9ECF8)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }
}
