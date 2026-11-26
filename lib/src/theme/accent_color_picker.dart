import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/anime_models.dart';
import '../shared_ui/app_interactions.dart';
import 'theme_ripple_transition.dart';
import 'zeluna_color_palette.dart';

/// Pure-Flutter HSV palette + 7-color spectrum + Monochrome selector widget
/// with real-time contrast-safe mini preview card.
class ZelunaAccentColorPicker extends StatefulWidget {
  const ZelunaAccentColorPicker({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final AppearanceSettings settings;
  final ValueChanged<AppearanceSettings> onChanged;

  @override
  State<ZelunaAccentColorPicker> createState() =>
      _ZelunaAccentColorPickerState();
}

class _ZelunaAccentColorPickerState extends State<ZelunaAccentColorPicker> {
  late HSVColor _hsv;
  late TextEditingController _hexController;
  var _paletteExpanded = false;
  var _hexInvalid = false;

  @override
  void initState() {
    super.initState();
    final initial = Color(widget.settings.accentColorValue | 0xFF000000);
    _hsv = HSVColor.fromColor(initial);
    _hexController = TextEditingController(
      text: ZelunaColorPalette.toHex(initial),
    );
    _paletteExpanded = widget.settings.accentMode == ThemeAccentMode.custom;
  }

  @override
  void didUpdateWidget(covariant ZelunaAccentColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.accentColorValue !=
        widget.settings.accentColorValue) {
      final next = Color(widget.settings.accentColorValue | 0xFF000000);
      if (next.toARGB32() != _hsv.toColor().toARGB32()) {
        _hsv = HSVColor.fromColor(next);
        final hex = ZelunaColorPalette.toHex(next);
        if (_hexController.text.toUpperCase() != hex) {
          _hexController.text = hex;
          _hexInvalid = false;
        }
      }
    }
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _selectMonochrome(BuildContext swatchContext) {
    final next = widget.settings.copyWith(
      accentMode: ThemeAccentMode.monochrome,
    );
    final changed = widget.settings.accentMode != ThemeAccentMode.monochrome;
    setState(() => _paletteExpanded = false);
    if (!changed) {
      widget.onChanged(next);
      return;
    }
    final dark = Theme.of(swatchContext).brightness == Brightness.dark;
    ThemeRippleHost.runIfAvailable(
      swatchContext,
      origin: ThemeRippleHost.globalCenterOf(swatchContext),
      accentColor: ThemeRippleHost.accentColorFor(next, dark: dark),
      nextIsDark: dark,
      applyChange: () => widget.onChanged(next),
    );
  }

  void _selectPreset(BuildContext swatchContext, ZelunaAccentPreset preset) {
    final nextHsv = HSVColor.fromColor(preset.color);
    final next = widget.settings.copyWith(
      accentMode: ThemeAccentMode.preset,
      accentColorValue: preset.color.toARGB32(),
    );
    final changed =
        widget.settings.accentMode != ThemeAccentMode.preset ||
        (widget.settings.accentColorValue | 0xFF000000) !=
            preset.color.toARGB32();
    setState(() {
      _hsv = nextHsv;
      _hexController.text = ZelunaColorPalette.toHex(preset.color);
      _hexInvalid = false;
    });
    if (!changed) {
      widget.onChanged(next);
      return;
    }
    final dark = Theme.of(swatchContext).brightness == Brightness.dark;
    ThemeRippleHost.runIfAvailable(
      swatchContext,
      origin: ThemeRippleHost.globalCenterOf(swatchContext),
      accentColor: ThemeRippleHost.accentColorFor(next, dark: dark),
      nextIsDark: dark,
      applyChange: () => widget.onChanged(next),
    );
  }

  void _updateCustomHsv(HSVColor next) {
    final color = next.toColor();
    setState(() {
      _hsv = next;
      _hexController.text = ZelunaColorPalette.toHex(color);
      _hexInvalid = false;
    });
    widget.onChanged(
      widget.settings.copyWith(
        accentMode: ThemeAccentMode.custom,
        accentColorValue: color.toARGB32(),
      ),
    );
  }

  void _onHexSubmitted(String raw) {
    final parsed = ZelunaColorPalette.tryParseHex(raw);
    if (parsed == null) {
      setState(() => _hexInvalid = true);
      return;
    }
    setState(() {
      _hsv = HSVColor.fromColor(parsed);
      _hexInvalid = false;
    });
    widget.onChanged(
      widget.settings.copyWith(
        accentMode: ThemeAccentMode.custom,
        accentColorValue: parsed.toARGB32(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = widget.settings;
    final monochromeSelected =
        settings.accentMode == ThemeAccentMode.monochrome;
    final customSelected = settings.accentMode == ThemeAccentMode.custom;
    final currentHex = ZelunaColorPalette.toHex(_hsv.toColor());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Live theme preview card (WYSIWYG)
        ZelunaThemePreviewCard(settings: settings),
        const SizedBox(height: 20),

        // 2. Monochrome default + 7-color spectrum swatches
        Row(
          children: [
            Expanded(
              child: Text(
                '主题强调色',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              monochromeSelected
                  ? '默认黑白'
                  : (ZelunaColorPalette.matchPreset(
                          settings.accentColorValue,
                        )?.label ??
                        '自定义 $currentHex'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 12,
          children: [
            Builder(
              builder: (swatchContext) => _MonochromeSwatch(
                selected: monochromeSelected,
                onTap: () => _selectMonochrome(swatchContext),
              ),
            ),
            for (final preset in ZelunaColorPalette.spectrumPresets)
              Builder(
                builder: (swatchContext) => _ColorSwatchButton(
                  label: preset.label,
                  color: preset.color,
                  selected:
                      settings.accentMode == ThemeAccentMode.preset &&
                      (settings.accentColorValue | 0xFF000000) ==
                          preset.color.toARGB32(),
                  onTap: () => _selectPreset(swatchContext, preset),
                ),
              ),
            _CustomPaletteTrigger(
              selected: customSelected || _paletteExpanded,
              color: _hsv.toColor(),
              onTap: () {
                setState(() => _paletteExpanded = !_paletteExpanded);
              },
            ),
          ],
        ),

        // 3. Expandable HSV Palette + Hue Bar + Hex Input
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: _paletteExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          secondChild: const SizedBox.shrink(),
          firstChild: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.palette_outlined,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '自由调色板',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Builder(
                        builder: (btnContext) => TextButton(
                          onPressed: () => _selectMonochrome(btnContext),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('恢复黑白'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _SvColorBoard(hsv: _hsv, onChanged: _updateCustomHsv),
                  const SizedBox(height: 14),
                  _HueSliderBar(
                    hue: _hsv.hue,
                    onChanged: (hue) => _updateCustomHsv(_hsv.withHue(hue)),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _hsv.toColor(),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: scheme.outline.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _hexController,
                          maxLength: 7,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[#0-9a-fA-F]'),
                            ),
                          ],
                          decoration: InputDecoration(
                            counterText: '',
                            isDense: true,
                            labelText: 'Hex 色值',
                            hintText: '#3B82F6',
                            errorText: _hexInvalid ? '请输入 6 位色值' : null,
                          ),
                          onChanged: (value) {
                            final parsed = ZelunaColorPalette.tryParseHex(
                              value,
                            );
                            if (parsed != null) {
                              _onHexSubmitted(value);
                            }
                          },
                          onSubmitted: _onHexSubmitted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Real-time miniature preview of how the chosen monochrome / spectrum /
/// custom palette looks across Zeluna surfaces, buttons, chips, and dock.
class ZelunaThemePreviewCard extends StatelessWidget {
  const ZelunaThemePreviewCard({super.key, required this.settings});

  final AppearanceSettings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentLabel = settings.isMonochrome
        ? '极致黑白'
        : (ZelunaColorPalette.matchPreset(settings.accentColorValue)?.label ??
              ZelunaColorPalette.toHex(
                Color(settings.accentColorValue | 0xFF000000),
              ));

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '立即播放',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '第 08 集',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '当前：$accentLabel',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: 0.68,
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MiniNavIcon(
                icon: Icons.home_rounded,
                label: '首页',
                active: true,
                scheme: scheme,
              ),
              _MiniNavIcon(
                icon: Icons.explore_outlined,
                label: '番剧',
                active: false,
                scheme: scheme,
              ),
              _MiniNavIcon(
                icon: Icons.live_tv_outlined,
                label: '剧集',
                active: false,
                scheme: scheme,
              ),
              _MiniNavIcon(
                icon: Icons.movie_outlined,
                label: '电影',
                active: false,
                scheme: scheme,
              ),
              _MiniNavIcon(
                icon: Icons.person_outline_rounded,
                label: '我的',
                active: false,
                scheme: scheme,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniNavIcon extends StatelessWidget {
  const _MiniNavIcon({
    required this.icon,
    required this.label,
    required this.active,
    required this.scheme,
  });

  final IconData icon;
  final String label;
  final bool active;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 10,
            color: color,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _InteractiveSwatchFrame extends StatefulWidget {
  const _InteractiveSwatchFrame({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.swatch,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget swatch;

  @override
  State<_InteractiveSwatchFrame> createState() =>
      _InteractiveSwatchFrameState();
}

class _InteractiveSwatchFrameState extends State<_InteractiveSwatchFrame> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '主题色 ${widget.label}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Listener(
          onPointerDown: (_) => _setPressed(true),
          onPointerUp: (_) => _setPressed(false),
          onPointerCancel: (_) => _setPressed(false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              zelunaSelectionHaptic();
              widget.onTap();
            },
            child: SizedBox(
              width: 56,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedScale(
                    scale: _pressed
                        ? 0.92
                        : _hovered
                        ? 1.08
                        : 1.0,
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    child: widget.swatch,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: widget.selected || _hovered
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: widget.selected || _hovered
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MonochromeSwatch extends StatelessWidget {
  const _MonochromeSwatch({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InteractiveSwatchFrame(
      label: '黑白',
      selected: selected,
      onTap: onTap,
      swatch: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: [0.49, 0.51],
            colors: [Color(0xFF141418), Color(0xFFF5F5F7)],
          ),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check_rounded,
                size: 18,
                color: scheme.brightness == Brightness.dark
                    ? const Color(0xFF141418)
                    : const Color(0xFFFFFFFF),
              )
            : null,
      ),
    );
  }
}

class _ColorSwatchButton extends StatelessWidget {
  const _ColorSwatchButton({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = ZelunaColorPalette.contrastingForeground(color);
    return _InteractiveSwatchFrame(
      label: label,
      selected: selected,
      onTap: onTap,
      swatch: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? scheme.onSurface
                : Colors.white.withValues(alpha: 0.16),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected ? Icon(Icons.check_rounded, size: 18, color: fg) : null,
      ),
    );
  }
}

class _CustomPaletteTrigger extends StatelessWidget {
  const _CustomPaletteTrigger({
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InteractiveSwatchFrame(
      label: '调色板',
      selected: selected,
      onTap: onTap,
      swatch: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(
            colors: [
              Color(0xFFEF4444),
              Color(0xFFF97316),
              Color(0xFFEAB308),
              Color(0xFF10B981),
              Color(0xFF06B6D4),
              Color(0xFF3B82F6),
              Color(0xFF8B5CF6),
              Color(0xFFEF4444),
            ],
          ),
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outline,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: selected ? color : scheme.surface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.tune_rounded,
              size: 12,
              color: selected
                  ? ZelunaColorPalette.contrastingForeground(color)
                  : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _SvColorBoard extends StatelessWidget {
  const _SvColorBoard({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _handle(Offset local, Size size) {
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 148);
        return GestureDetector(
          onPanDown: (d) => _handle(d.localPosition, size),
          onPanUpdate: (d) => _handle(d.localPosition, size),
          onTapDown: (d) => _handle(d.localPosition, size),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CustomPaint(
              size: size,
              painter: _SvBoardPainter(hsv: hsv),
            ),
          ),
        );
      },
    );
  }
}

class _SvBoardPainter extends CustomPainter {
  const _SvBoardPainter({required this.hsv});

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hueColor = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );

    final pos = Offset(
      hsv.saturation * size.width,
      (1.0 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      pos,
      8.5,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      pos,
      8.5,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _SvBoardPainter oldDelegate) =>
      oldDelegate.hsv != hsv;
}

class _HueSliderBar extends StatelessWidget {
  const _HueSliderBar({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  void _handle(Offset local, double width) {
    final h = ((local.dx / width).clamp(0.0, 1.0)) * 360.0;
    onChanged(h >= 360.0 ? 359.5 : h);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          onPanDown: (d) => _handle(d.localPosition, width),
          onPanUpdate: (d) => _handle(d.localPosition, width),
          onTapDown: (d) => _handle(d.localPosition, width),
          child: SizedBox(
            height: 24,
            width: width,
            child: CustomPaint(painter: _HueBarPainter(hue: hue)),
          ),
        );
      },
    );
  }
}

class _HueBarPainter extends CustomPainter {
  const _HueBarPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, (size.height - 12) / 2, size.width, 12),
      const Radius.circular(999),
    );
    const colors = [
      Color(0xFFFF0000),
      Color(0xFFFFFF00),
      Color(0xFF00FF00),
      Color(0xFF00FFFF),
      Color(0xFF0000FF),
      Color(0xFFFF00FF),
      Color(0xFFFF0000),
    ];
    canvas.drawRRect(
      trackRect,
      Paint()
        ..shader = const LinearGradient(
          colors: colors,
        ).createShader(trackRect.outerRect),
    );
    final x = (hue / 360.0).clamp(0.0, 1.0) * size.width;
    final center = Offset(x.clamp(9, size.width - 9), size.height / 2);
    final thumbColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    canvas.drawCircle(center, 9.5, Paint()..color = Colors.white);
    canvas.drawCircle(center, 7, Paint()..color = thumbColor);
  }

  @override
  bool shouldRepaint(covariant _HueBarPainter oldDelegate) =>
      oldDelegate.hue != hue;
}
