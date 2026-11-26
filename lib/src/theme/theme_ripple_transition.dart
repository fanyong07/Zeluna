import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../domain/anime_models.dart';
import '../shared_ui/app_design.dart';
import 'zeluna_color_palette.dart';

/// Captures a synchronous GPU image snapshot from a [RenderRepaintBoundary].
typedef ThemeSnapshotCapturer =
    ui.Image? Function(RenderRepaintBoundary boundary, double pixelRatio);

/// Callback controller exposed by [ThemeRippleHost] to descendant theme toggles.
abstract interface class ThemeRippleController {
  /// Whether a circular ripple transition is currently animating.
  bool get isAnimating;

  /// Runs a bidirectional outward circular water-ripple transition from
  /// [origin] (global coordinates) while executing [applyChange].
  Future<void> runTransition({
    Offset? origin,
    Color? accentColor,
    required bool nextIsDark,
    required FutureOr<void> Function() applyChange,
  });
}

/// Hosts a root [RepaintBoundary] and plays a bidirectional outward circular
/// water-ripple reveal (with an optional translucent wavefront halo) when the
/// app switches light/dark mode or discrete theme accents.
///
/// Respects both app-level [reduceMotion] and platform accessibility
/// `disableAnimations`, safely falling back to an immediate switch if disabled
/// or if synchronous snapshot capture is unavailable.
class ThemeRippleHost extends StatefulWidget {
  const ThemeRippleHost({
    super.key,
    required this.child,
    this.reduceMotion = false,
    this.duration = defaultDuration,
    this.showHalo = true,
    this.captureSnapshot,
  });

  static const Duration defaultDuration = Duration(milliseconds: 520);
  static const Curve defaultCurve = Curves.easeInOutCubic;

  final Widget child;
  final bool reduceMotion;
  final Duration duration;
  final bool showHalo;
  final ThemeSnapshotCapturer? captureSnapshot;

  static ThemeRippleController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_ThemeRippleScope>()
        ?.controller;
  }

  /// Resolves the global center coordinate of [context]'s render box.
  static Offset? globalCenterOf(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(renderObject.size.center(Offset.zero));
  }

  /// Resolves the approximate center of a trailing [Switch] inside a
  /// horizontal settings row so the ripple originates from the toggle thumb.
  static Offset? switchCenterOf(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final size = renderObject.size;
    final dx = math.max(size.width / 2, size.width - 36.0);
    return renderObject.localToGlobal(Offset(dx, size.height / 2));
  }

  /// Computes the target theme's primary accent color for the wavefront halo.
  static Color accentColorFor(
    AppearanceSettings appearance, {
    required bool dark,
  }) {
    final monochrome = appearance.accentMode == ThemeAccentMode.monochrome;
    if (monochrome) {
      return dark ? AppColors.primary : AppColors.lightPrimary;
    }
    final seed = Color(appearance.accentColorValue | 0xFF000000);
    return ZelunaColorPalette.adaptiveAccent(seed, dark: dark);
  }

  /// Triggers a ripple transition if a [ThemeRippleHost] is mounted above
  /// [context]; otherwise runs [applyChange] directly.
  static Future<void> runIfAvailable(
    BuildContext context, {
    Offset? origin,
    Color? accentColor,
    required bool nextIsDark,
    required FutureOr<void> Function() applyChange,
  }) async {
    final controller = context
        .getInheritedWidgetOfExactType<_ThemeRippleScope>()
        ?.controller;
    if (controller == null) {
      await applyChange();
      return;
    }
    await controller.runTransition(
      origin: origin,
      accentColor: accentColor,
      nextIsDark: nextIsDark,
      applyChange: applyChange,
    );
  }

  @override
  State<ThemeRippleHost> createState() => ThemeRippleHostState();
}

class ThemeRippleHostState extends State<ThemeRippleHost>
    with SingleTickerProviderStateMixin
    implements ThemeRippleController {
  final GlobalKey _boundaryKey = GlobalKey();
  late final AnimationController _controller;

  ui.Image? _snapshot;
  Offset _origin = Offset.zero;
  double _maxRadius = 0;
  Color _haloAccent = AppColors.primary;
  bool _nextIsDark = true;
  int _generation = 0;

  @override
  bool get isAnimating => _snapshot != null && _controller.isAnimating;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleStatusChanged);
  }

  @override
  void didUpdateWidget(covariant ThemeRippleHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.reduceMotion && _snapshot != null) {
      _controller.stop();
      _disposeSnapshot();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatusChanged);
    _controller.dispose();
    _disposeSnapshot();
    super.dispose();
  }

  void _handleStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      if (!mounted) {
        _disposeSnapshot();
        return;
      }
      if (_snapshot != null) {
        setState(_disposeSnapshot);
      }
    }
  }

  void _disposeSnapshot() {
    final old = _snapshot;
    _snapshot = null;
    old?.dispose();
  }

  static ui.Image? _captureBoundarySync(
    RenderRepaintBoundary boundary,
    double pixelRatio,
  ) {
    try {
      return boundary.toImageSync(pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> runTransition({
    Offset? origin,
    Color? accentColor,
    required bool nextIsDark,
    required FutureOr<void> Function() applyChange,
  }) async {
    final disableAnimations =
        widget.reduceMotion ||
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
    if (!mounted || disableAnimations || widget.duration <= Duration.zero) {
      if (_snapshot != null && mounted) {
        _controller.stop();
        setState(_disposeSnapshot);
      }
      await applyChange();
      return;
    }

    final renderObject = _boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      await applyChange();
      return;
    }

    // `debugNeedsPaint` only initializes its return value inside `assert` and
    // throws LateInitializationError in release builds if read directly. In
    // debug/test builds, wait one frame for any pending InkWell/focus paint so
    // `toImageSync` never skips the ripple or trips its debug assertion.
    var needsPaint = false;
    assert(() {
      needsPaint = renderObject.debugNeedsPaint;
      return true;
    }());
    if (needsPaint) {
      SchedulerBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        await applyChange();
        return;
      }
    }

    final size = renderObject.size;
    final rawDpr = View.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final pixelRatio = rawDpr.clamp(1.0, 2.5);
    final capturer = widget.captureSnapshot ?? _captureBoundarySync;
    final captured = capturer(renderObject, pixelRatio);
    if (captured == null) {
      await applyChange();
      return;
    }

    final localOrigin = origin == null
        ? size.center(Offset.zero)
        : renderObject.globalToLocal(origin);
    final clamped = Offset(
      localOrigin.dx.clamp(0.0, size.width),
      localOrigin.dy.clamp(0.0, size.height),
    );
    final maxX = math.max(clamped.dx, size.width - clamped.dx);
    final maxY = math.max(clamped.dy, size.height - clamped.dy);
    final maxRadius = math.sqrt(maxX * maxX + maxY * maxY) + 8.0;

    final gen = ++_generation;
    _controller.reset();
    final previous = _snapshot;
    setState(() {
      _snapshot = captured;
      _origin = clamped;
      _maxRadius = maxRadius;
      _haloAccent =
          accentColor ??
          (nextIsDark ? AppColors.primary : AppColors.lightPrimary);
      _nextIsDark = nextIsDark;
    });
    previous?.dispose();

    // Invoke applyChange immediately so synchronous Riverpod state updates
    // rebuild the underlying live tree on the very same frame, then start
    // the 520ms ripple without waiting on background disk/network persistence.
    final pending = applyChange();
    if (mounted && gen == _generation && _snapshot != null) {
      unawaited(_controller.forward(from: 0.0));
    }
    if (pending is Future<void>) {
      await pending;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return _ThemeRippleScope(
      controller: this,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(key: _boundaryKey, child: widget.child),
            if (snapshot != null)
              Positioned.fill(
                child: IgnorePointer(
                  key: const ValueKey<String>('theme-ripple-overlay'),
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final raw = _controller.value;
                      final curved = ThemeRippleHost.defaultCurve.transform(
                        raw,
                      );
                      final radius = _maxRadius * curved;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipPath(
                            clipBehavior: Clip.antiAlias,
                            clipper: _InvertedCircleHoleClipper(
                              origin: _origin,
                              radius: radius,
                            ),
                            child: RawImage(
                              image: snapshot,
                              fit: BoxFit.fill,
                              filterQuality: FilterQuality.low,
                            ),
                          ),
                          if (widget.showHalo)
                            CustomPaint(
                              key: const ValueKey<String>('theme-ripple-halo'),
                              painter: _ThemeRippleHaloPainter(
                                origin: _origin,
                                radius: radius,
                                rawProgress: raw,
                                accentColor: _haloAccent,
                                nextIsDark: _nextIsDark,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ThemeRippleScope extends InheritedWidget {
  const _ThemeRippleScope({required this.controller, required super.child});

  final ThemeRippleController controller;

  @override
  bool updateShouldNotify(covariant _ThemeRippleScope oldWidget) =>
      controller != oldWidget.controller;
}

class _InvertedCircleHoleClipper extends CustomClipper<Path> {
  const _InvertedCircleHoleClipper({
    required this.origin,
    required this.radius,
  });

  final Offset origin;
  final double radius;

  @override
  Path getClip(Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (radius > 0) {
      path.addOval(Rect.fromCircle(center: origin, radius: radius));
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _InvertedCircleHoleClipper oldClipper) {
    return origin != oldClipper.origin || radius != oldClipper.radius;
  }
}

class _ThemeRippleHaloPainter extends CustomPainter {
  const _ThemeRippleHaloPainter({
    required this.origin,
    required this.radius,
    required this.rawProgress,
    required this.accentColor,
    required this.nextIsDark,
  });

  final Offset origin;
  final double radius;
  final double rawProgress;
  final Color accentColor;
  final bool nextIsDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (rawProgress <= 0 || rawProgress >= 1 || radius <= 2) return;
    final alpha = math.sin(rawProgress * math.pi) * 0.55;
    if (alpha <= 0.01) return;

    final outerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 + (1.0 - rawProgress) * 4.0
      ..color = accentColor.withValues(alpha: alpha);
    canvas.drawCircle(origin, radius, outerPaint);

    final innerRadius = radius - 6.0;
    if (innerRadius > 0) {
      final trailColor = nextIsDark
          ? Colors.white.withValues(alpha: 0.34 * 0.65 * alpha)
          : const Color(0xFF0F172A).withValues(alpha: 0.22 * 0.65 * alpha);
      final innerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8.0
        ..color = trailColor;
      canvas.drawCircle(origin, innerRadius, innerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ThemeRippleHaloPainter oldDelegate) {
    return origin != oldDelegate.origin ||
        radius != oldDelegate.radius ||
        rawProgress != oldDelegate.rawProgress ||
        accentColor != oldDelegate.accentColor ||
        nextIsDark != oldDelegate.nextIsDark;
  }
}
