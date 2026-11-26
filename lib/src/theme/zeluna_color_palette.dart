import 'package:flutter/material.dart';

/// Curated accent presets: monochrome default plus the 7-color spectrum
/// (red, orange, yellow, green, cyan, blue, violet) and classic ACG sakura.
class ZelunaAccentPreset {
  const ZelunaAccentPreset({
    required this.id,
    required this.label,
    required this.color,
    required this.subtitle,
  });

  final String id;
  final String label;
  final Color color;
  final String subtitle;
}

class ZelunaColorPalette {
  const ZelunaColorPalette._();

  /// Classic 7-color spectrum presets + sakura pink swatch.
  static const spectrumPresets = <ZelunaAccentPreset>[
    ZelunaAccentPreset(
      id: 'red',
      label: '赤红',
      color: Color(0xFFEF4444),
      subtitle: '热血明快',
    ),
    ZelunaAccentPreset(
      id: 'orange',
      label: '橙阳',
      color: Color(0xFFF97316),
      subtitle: '温暖活力',
    ),
    ZelunaAccentPreset(
      id: 'yellow',
      label: '金黄',
      color: Color(0xFFEAB308),
      subtitle: '影院典金',
    ),
    ZelunaAccentPreset(
      id: 'green',
      label: '翠绿',
      color: Color(0xFF10B981),
      subtitle: '清新护眼',
    ),
    ZelunaAccentPreset(
      id: 'cyan',
      label: '青空',
      color: Color(0xFF06B6D4),
      subtitle: '透亮冰青',
    ),
    ZelunaAccentPreset(
      id: 'blue',
      label: '星蓝',
      color: Color(0xFF3B82F6),
      subtitle: '经典耐看',
    ),
    ZelunaAccentPreset(
      id: 'violet',
      label: '紫罗兰',
      color: Color(0xFF8B5CF6),
      subtitle: '轻次元夜空',
    ),
    ZelunaAccentPreset(
      id: 'sakura',
      label: '樱花粉',
      color: Color(0xFFFB7299),
      subtitle: '次元经典粉',
    ),
  ];

  static ZelunaAccentPreset? matchPreset(int colorValue) {
    final normalized = colorValue | 0xFF000000;
    for (final preset in spectrumPresets) {
      if (preset.color.toARGB32() == normalized) return preset;
    }
    return null;
  }

  /// Picks crisp white or deep ink foreground text based on WCAG luminance.
  static Color contrastingForeground(Color background) {
    return background.computeLuminance() > 0.36
        ? const Color(0xFF0B0B0E)
        : const Color(0xFFFFFFFF);
  }

  /// Ensures any user-picked HSV color stays vibrant and legible on dark or
  /// light neutral surfaces without turning washed-out or invisible.
  static Color adaptiveAccent(Color seed, {required bool dark}) {
    final hsl = HSLColor.fromColor(seed);
    final sat = hsl.saturation.clamp(0.28, 1.0);
    final lightness = dark
        ? hsl.lightness.clamp(0.54, 0.72)
        : hsl.lightness.clamp(0.34, 0.50);
    return hsl.withSaturation(sat).withLightness(lightness).toColor();
  }

  /// Derives a calm companion accent (+26 deg hue shift) for secondary chips.
  static Color companionAccent(Color primary, {required bool dark}) {
    final hsl = HSLColor.fromColor(primary);
    final shiftedHue = (hsl.hue + 26) % 360;
    final lightness = dark
        ? hsl.lightness.clamp(0.58, 0.74)
        : hsl.lightness.clamp(0.36, 0.52);
    return hsl
        .withHue(shiftedHue)
        .withSaturation((hsl.saturation * 0.85).clamp(0.22, 0.85))
        .withLightness(lightness)
        .toColor();
  }

  /// Formats an opaque color as uppercase `#RRGGBB`.
  static String toHex(Color color) {
    final argb = color.toARGB32() & 0x00FFFFFF;
    return '#${argb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// Parses `#RRGGBB` or `RRGGBB` into an opaque [Color]. Returns null if invalid.
  static Color? tryParseHex(String raw) {
    final cleaned = raw.trim().replaceFirst('#', '');
    if (cleaned.length != 6) return null;
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return null;
    return Color(0xFF000000 | parsed);
  }
}
