import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Application-wide scroll behavior that enables mouse, trackpad, touch, and
/// stylus drag gestures so horizontal strips and carousels work naturally on
/// Windows desktop as well as Android touch screens.
class ZelunaScrollBehavior extends MaterialScrollBehavior {
  const ZelunaScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.unknown,
  };
}

/// Triggers a light selection haptic only on touch-first mobile platforms.
void zelunaSelectionHaptic() {
  if (kIsWeb) return;
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return;
  }
  unawaited(HapticFeedback.selectionClick());
}

/// Coordinates active-tab reselect actions (such as smooth scroll-to-top)
/// across persistent shell branches without coupling chrome widgets to
/// individual page scroll controllers.
class TabReselectBus {
  TabReselectBus._();

  static final Map<String, List<VoidCallback>> _listeners = {};

  static void register(String route, VoidCallback callback) {
    final bucket = _listeners.putIfAbsent(route, () => <VoidCallback>[]);
    if (!bucket.contains(callback)) {
      bucket.add(callback);
    }
  }

  static void unregister(String route, VoidCallback callback) {
    final bucket = _listeners[route];
    if (bucket == null) return;
    bucket.remove(callback);
    if (bucket.isEmpty) {
      _listeners.remove(route);
    }
  }

  /// Invokes all active listeners for [route]. Returns true if at least one
  /// listener handled the reselect event.
  static bool notify(String route) {
    final bucket = _listeners[route];
    if (bucket == null || bucket.isEmpty) return false;
    for (final listener in List<VoidCallback>.of(bucket)) {
      listener();
    }
    return true;
  }
}

/// Smoothly scrolls [controller] back to offset 0 when attached and scrolled.
void scrollControllerToTop(
  ScrollController? controller, {
  bool reduceMotion = false,
}) {
  if (controller == null || !controller.hasClients) return;
  final position = controller.position;
  if (position.pixels <= 0.5) return;
  if (reduceMotion) {
    controller.jumpTo(0);
    return;
  }
  unawaited(
    controller.animateTo(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    ),
  );
}

/// Wraps a horizontally scrolling strip so desktop mouse users get hover
/// previous/next navigation arrows and Shift+wheel horizontal scrolling in
/// addition to touch/mouse drag, without hijacking normal vertical page wheel.
class HorizontalScrollStrip extends StatefulWidget {
  const HorizontalScrollStrip({
    super.key,
    required this.builder,
    this.controller,
  });

  final Widget Function(BuildContext context, ScrollController controller)
  builder;
  final ScrollController? controller;

  @override
  State<HorizontalScrollStrip> createState() => _HorizontalScrollStripState();
}

class _HorizontalScrollStripState extends State<HorizontalScrollStrip> {
  ScrollController? _ownController;
  bool _hovered = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  ScrollController get _controller =>
      widget.controller ?? (_ownController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncEdges());
  }

  @override
  void didUpdateWidget(covariant HorizontalScrollStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?.removeListener(_syncEdges);
      _controller.addListener(_syncEdges);
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncEdges());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_syncEdges);
    _ownController?.dispose();
    super.dispose();
  }

  void _syncEdges() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final left = pos.pixels > 2;
    final right = pos.maxScrollExtent - pos.pixels > 2;
    if (left != _canScrollLeft || right != _canScrollRight) {
      setState(() {
        _canScrollLeft = left;
        _canScrollRight = right;
      });
    }
  }

  void _scrollBy(double direction) {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final step = (pos.viewportDimension * 0.78).clamp(180.0, 560.0);
    final target = (pos.pixels + direction * step).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(target);
      return;
    }
    unawaited(
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final pos = _controller.position;
    if (pos.maxScrollExtent <= 0) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : HardwareKeyboard.instance.isShiftPressed
        ? event.scrollDelta.dy
        : 0.0;
    if (delta == 0) return;
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if ((target - pos.pixels).abs() > 0.1) {
      _controller.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final showArrows = !isMobile && _hovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _syncEdges();
            return false;
          },
          child: Stack(
            children: [
              widget.builder(context, _controller),
              if (showArrows && _canScrollLeft)
                Positioned(
                  left: 4,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _StripArrowButton(
                      icon: Icons.chevron_left_rounded,
                      tooltip: '向左滚动',
                      onTap: () => _scrollBy(-1),
                    ),
                  ),
                ),
              if (showArrows && _canScrollRight)
                Positioned(
                  right: 4,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _StripArrowButton(
                      icon: Icons.chevron_right_rounded,
                      tooltip: '向右滚动',
                      onTap: () => _scrollBy(1),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StripArrowButton extends StatelessWidget {
  const _StripArrowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
        shape: CircleBorder(
          side: BorderSide(color: scheme.outlineVariant, width: 0.8),
        ),
        elevation: 3,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: 34,
            child: Icon(icon, size: 22, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}
