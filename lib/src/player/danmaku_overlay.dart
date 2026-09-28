import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/anime_models.dart';

class RemoteDanmakuOverlay extends StatefulWidget {
  const RemoteDanmakuOverlay({
    super.key,
    required this.comments,
    required this.position,
    required this.settings,
    this.excludedArea,
    this.reservedInsets = EdgeInsets.zero,
  });

  final List<DanmakuComment> comments;
  final Duration position;
  final DanmakuSettings settings;
  final Rect? excludedArea;
  final EdgeInsets reservedInsets;

  @override
  State<RemoteDanmakuOverlay> createState() => _RemoteDanmakuOverlayState();
}

class _RemoteDanmakuOverlayState extends State<RemoteDanmakuOverlay> {
  Object? _layoutKey;
  _DanmakuLayout? _layout;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() {
    // Deferred NotoSansSC 600 changes metrics after the first frame.
    setState(() => _layoutKey = null);
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final settings = widget.settings;
          final bounds = danmakuDisplayBounds(
            constraints.biggest,
            settings.displayArea,
            excludedArea: widget.excludedArea,
            reservedInsets: widget.reservedInsets,
          );
          final scaler = MediaQuery.textScalerOf(context);
          final direction = Directionality.of(context);
          final key = (
            widget.comments,
            widget.comments.length,
            bounds,
            scaler,
            direction,
            settings.fontSize,
            settings.speed,
            settings.displayArea,
            settings.enabled,
            settings.blockTop,
            settings.blockBottom,
            settings.blockScroll,
            // An unambiguous value key; opacity does not affect admission.
            settings.blockKeywords.map((word) => '${word.length}:$word').join(),
          );
          if (_layoutKey != key) {
            _layoutKey = key;
            _layout = _DanmakuLayout(
              comments: widget.comments,
              settings: settings,
              bounds: bounds,
              scaler: scaler,
              direction: direction,
            );
          }
          final placements = _layout!.at(widget.position);
          return ClipRect(
            clipper: DanmakuAreaClipper(bounds),
            child: Stack(
              children: [
                for (final placement in placements)
                  Positioned(
                    key: ValueKey(placement.index),
                    left: placement.xAt(widget.position.inMicroseconds / 1000),
                    top: placement.top,
                    width: placement.size.width,
                    height: placement.size.height,
                    child: DanmakuText(
                      text: placement.comment.text,
                      color: Color(0xff000000 | placement.comment.color),
                      fontSize: settings.fontSize,
                      opacity: settings.opacity,
                      maxWidth: placement.maxWidth,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Shared by remote and local comments. Fill and outline use exactly the same
/// font metrics; group opacity fades both, without blurred duplicate shadows.
class DanmakuText extends StatefulWidget {
  const DanmakuText({
    super.key,
    required this.text,
    this.fontSize = 18,
    this.color = Colors.white,
    this.opacity = .86,
    this.maxWidth = double.infinity,
  });

  final String text;
  final double fontSize;
  final Color color;
  final double opacity;
  final double maxWidth;

  static const _padding = 2.0;

  static TextStyle _style(double fontSize, {Color? color, Paint? foreground}) =>
      TextStyle(
        inherit: false,
        fontSize: fontSize.clamp(12, 30).toDouble(),
        fontFamily: 'NotoSansSC',
        fontWeight: FontWeight.w600,
        height: 1.1,
        color: color,
        foreground: foreground,
        decoration: TextDecoration.none,
      );

  static TextPainter _painter({
    required String text,
    required double fontSize,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required double maxWidth,
    Paint? foreground,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: _style(fontSize, foreground: foreground),
    ),
    textScaler: textScaler,
    textDirection: textDirection,
    maxLines: 1,
    ellipsis: maxWidth.isFinite ? '\u2026' : null,
  )..layout(maxWidth: math.max(0, maxWidth - _padding * 2));

  /// Includes the outline's padding. Use this instead of character-count width
  /// estimates for local scrolling motion as well.
  static Size measure({
    required String text,
    double fontSize = 18,
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    double maxWidth = double.infinity,
  }) {
    final painter = _painter(
      text: text,
      fontSize: fontSize,
      textScaler: textScaler,
      textDirection: textDirection,
      maxWidth: maxWidth,
    );
    final size = Size(
      painter.width + _padding * 2,
      painter.height + _padding * 2,
    );
    painter.dispose();
    return size;
  }

  @override
  State<DanmakuText> createState() => _DanmakuTextState();
}

class _DanmakuTextState extends State<DanmakuText> {
  Object? _metricsKey;
  TextPainter? _outline;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() {
    setState(() => _metricsKey = null);
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    _outline?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = math.min(widget.maxWidth, constraints.maxWidth);
        // Choose the higher-contrast neutral outline without changing the
        // provider's fill color. Include it in the cache key for live updates.
        final outlineColor = widget.color.computeLuminance() < .179
            ? Colors.white
            : Colors.black;
        final key = (
          widget.text,
          widget.fontSize,
          maxWidth,
          scaler,
          direction,
          outlineColor,
        );
        if (key != _metricsKey) {
          _metricsKey = key;
          _outline?.dispose();
          _outline = DanmakuText._painter(
            text: widget.text,
            fontSize: widget.fontSize,
            textScaler: scaler,
            textDirection: direction,
            maxWidth: maxWidth,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4
              ..strokeJoin = StrokeJoin.round
              ..color = outlineColor,
          );
        }
        return Opacity(
          opacity: widget.opacity.clamp(.2, 1).toDouble(),
          child: SizedBox(
            width: _outline!.width + DanmakuText._padding * 2,
            height: _outline!.height + DanmakuText._padding * 2,
            child: CustomPaint(
              painter: _DanmakuOutlinePainter(_outline!),
              child: Padding(
                padding: const EdgeInsets.all(DanmakuText._padding),
                child: Text(
                  widget.text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: maxWidth.isFinite
                      ? TextOverflow.ellipsis
                      : TextOverflow.visible,
                  textScaler: scaler,
                  textDirection: direction,
                  style: DanmakuText._style(
                    widget.fontSize,
                    color: widget.color,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuOutlinePainter extends CustomPainter {
  const _DanmakuOutlinePainter(this.outline);
  final TextPainter outline;

  @override
  void paint(Canvas canvas, Size size) =>
      outline.paint(canvas, const Offset(2, 2));

  @override
  bool shouldRepaint(covariant _DanmakuOutlinePainter oldDelegate) =>
      outline != oldDelegate.outline;
}

/// Only admitted comments are retained (at most 24), with a bounded width
/// cache. New comments are considered once, in timeline order, not reassigned
/// on every frame. Recent visited intervals restore admission checkpoints; a
/// cold seek outside the retained history uses a bounded look-back, not a
/// whole-episode replay, and may select a different valid subset there.
class _DanmakuLayout {
  _DanmakuLayout({
    required this.comments,
    required this.settings,
    required this.bounds,
    required this.scaler,
    required this.direction,
  }) {
    laneHeight =
        DanmakuText.measure(
          text: '弹幕Ag',
          fontSize: settings.fontSize,
          textScaler: scaler,
          textDirection: direction,
        ).height +
        3;
    // The safe rectangle already reflects the selected display area. Let its
    // measured height decide the tracks instead of reducing capacity twice.
    lanes = (bounds.height / laneHeight).floor();
    // Bound burst work separately from on-screen density. Short comments may
    // share a track once a safe gap opens; wide canvases must not stop at one
    // comment per track or at a small area-scaled count.
    candidateBudget = (lanes * 4).clamp(32, _maxActiveDanmaku);
  }

  final List<DanmakuComment> comments;
  final DanmakuSettings settings;
  final Rect bounds;
  final TextScaler scaler;
  final TextDirection direction;
  late final double laneHeight;
  late final int lanes;
  late final int candidateBudget;
  final _active = <_DanmakuPlacement>[];
  final _sizes = <(String, bool), Size>{};
  int _cursor = 0;
  int? _admissionBucket;
  int _bucketAttempts = 0;
  int _bucketStart = 0;
  int _bucketEnd = 0;
  double? _lastPosition;
  // At most one snapshot per visited second, with a bounded active list.
  // This preserves rejected comments as well as admitted ones:
  // the cursor and partial-bucket budget must be restored together.
  final _checkpoints = <int, _DanmakuCheckpoint>{};

  bool _restoreCheckpoint(double now, double maxReplay) {
    _DanmakuCheckpoint? closest;
    for (final checkpoint in _checkpoints.values) {
      if (checkpoint.position <= now &&
          now - checkpoint.position <= maxReplay &&
          (closest == null || checkpoint.position > closest.position)) {
        closest = checkpoint;
      }
    }
    if (closest == null) return false;
    _active
      ..clear()
      ..addAll(closest.active);
    _cursor = closest.cursor;
    _admissionBucket = closest.bucket;
    _bucketAttempts = closest.attempts;
    _bucketStart = closest.bucketStart;
    _bucketEnd = closest.bucketEnd;
    return true;
  }

  void _rememberCheckpoint(double now) {
    final second = (now / 1000).floor();
    final existing = _checkpoints[second];
    if (existing != null && existing.position <= now) return;
    if (existing == null && _checkpoints.length >= 128) {
      _checkpoints.remove(_checkpoints.keys.first);
    }
    _checkpoints[second] = (
      position: now,
      active: List<_DanmakuPlacement>.of(_active),
      cursor: _cursor,
      bucket: _admissionBucket,
      attempts: _bucketAttempts,
      bucketStart: _bucketStart,
      bucketEnd: _bucketEnd,
    );
  }

  List<_DanmakuPlacement> at(Duration position) {
    final now = position.inMicroseconds / 1000;
    if (!settings.enabled || now < 0 || lanes <= 0 || bounds.width <= 4) {
      _active.clear();
      _lastPosition = null;
      return const [];
    }
    final maxLifetime = 10600 / settings.speed.clamp(.5, 2);
    if (_lastPosition == null ||
        now < _lastPosition! ||
        now - _lastPosition! > maxLifetime) {
      if (!_restoreCheckpoint(now, maxLifetime * 2)) {
        _active.clear();
        _cursor = _lowerBound(comments, now - maxLifetime * 2);
        _admissionBucket = null;
        _bucketAttempts = 0;
      }
    }
    final occupied = _DanmakuBands(laneHeight);
    for (final placement in _active) {
      occupied.add(placement);
    }
    while (_cursor < comments.length) {
      final comment = comments[_cursor];
      final start = comment.time.inMicroseconds / 1000;
      if (start > now) break;
      final index = _cursor;
      final bucket = (start / 250).floor();
      if (_admissionBucket != bucket) {
        _admissionBucket = bucket;
        _bucketAttempts = 0;
        _bucketStart = _cursor;
        // Sparse buckets stay O(1): only binary-search when a full budget's
        // worth of candidates actually fits in this same timestamp bucket.
        _bucketEnd = math.min(comments.length, _cursor + candidateBudget);
        if (_bucketEnd < comments.length &&
            comments[_bucketEnd].time.inMicroseconds / 1000 <
                (bucket + 1) * 250) {
          _bucketEnd = _lowerBound(comments, (bucket + 1) * 250.0);
        }
      }
      // Charge every inspected candidate BEFORE filters/full-lane checks.
      // Oversized bursts are sampled across the entire bucket (including its
      // endpoints), so a blocked prefix cannot consume every attempt. This
      // deliberately drops unsampled comments; finding every allowed comment
      // would require the unbounded scan we must avoid. Timeline-based samples
      // stay identical at 30/60 fps and do not reappear on later frames.
      final count = _bucketEnd - _bucketStart;
      final samples = math.min(candidateBudget, count);
      _bucketAttempts++;
      _cursor = _bucketAttempts >= samples
          ? _bucketEnd
          : _bucketStart + (_bucketAttempts * (count - 1) ~/ (samples - 1));
      _active.removeWhere((entry) => entry.end <= start);
      if (_active.length >= _maxActiveDanmaku ||
          comment.text.trim().isEmpty ||
          _isBlocked(comment, settings)) {
        continue;
      }
      final fixed = _isFixed(comment);
      final maxWidth = fixed
          ? math.max(4.0, bounds.width - 24)
          : double.infinity;
      final cacheKey = (comment.text, fixed);
      var size = _sizes[cacheKey];
      if (size == null) {
        size = DanmakuText.measure(
          text: comment.text,
          fontSize: settings.fontSize,
          textScaler: scaler,
          textDirection: direction,
          maxWidth: maxWidth,
        );
        if (_sizes.length >= 256) _sizes.remove(_sizes.keys.first);
        _sizes[cacheKey] = size;
      }
      if (size.height > bounds.height) continue;
      final step = lanes <= 1
          ? 0.0
          : (bounds.height - laneHeight) / (lanes - 1);
      for (var attempt = 0; attempt < lanes; attempt++) {
        final bottom = comment.mode == DanmakuMode.bottom;
        final top = bottom
            ? bounds.bottom - size.height - attempt * step
            : bounds.top + attempt * step;
        if (top < bounds.top || top + size.height > bounds.bottom) continue;
        final candidate = _DanmakuPlacement(
          index: index,
          comment: comment,
          size: size,
          top: top,
          bounds: bounds,
          maxWidth: maxWidth,
          duration: _displayDuration(
            comment,
            settings.speed,
          ).inMilliseconds.toDouble(),
        );
        if (occupied.canPlace(candidate)) {
          _active.add(candidate);
          occupied.add(candidate);
          break;
        }
      }
    }
    _active.removeWhere((entry) => entry.end <= now);
    _lastPosition = now;
    _rememberCheckpoint(now);
    return _active;
  }
}

/// Only vertically nearby comments can collide. Rebuilt from the bounded
/// active list (including restored checkpoints), so cold seeks at high density
/// do not compare every candidate track against the entire screen. The exact
/// lifetime collision test remains authoritative; bands are just an index.
class _DanmakuBands {
  _DanmakuBands(this.height);

  final double height;
  final _bands = <int, List<_DanmakuPlacement>>{};

  int _first(_DanmakuPlacement placement) => (placement.top / height).floor();
  int _last(_DanmakuPlacement placement) =>
      ((placement.top + placement.size.height + 2) / height).floor();

  void add(_DanmakuPlacement placement) {
    final last = _last(placement);
    for (var band = _first(placement); band <= last; band++) {
      (_bands[band] ??= []).add(placement);
    }
  }

  bool canPlace(_DanmakuPlacement candidate) {
    final last = _last(candidate);
    for (var band = _first(candidate); band <= last; band++) {
      final entries = _bands[band];
      if (entries == null) continue;
      entries.removeWhere((entry) => entry.end <= candidate.start);
      if (entries.any((other) => !candidate.canShareWith(other))) return false;
    }
    return true;
  }
}

typedef _DanmakuCheckpoint = ({
  double position,
  List<_DanmakuPlacement> active,
  int cursor,
  int? bucket,
  int attempts,
  int bucketStart,
  int bucketEnd,
});

class _DanmakuPlacement {
  const _DanmakuPlacement({
    required this.index,
    required this.comment,
    required this.size,
    required this.top,
    required this.bounds,
    required this.maxWidth,
    required this.duration,
  });

  final int index;
  final DanmakuComment comment;
  final Size size;
  final double top;
  final Rect bounds;
  final double maxWidth;
  final double duration;
  double get start => comment.time.inMicroseconds / 1000;
  double get end => start + duration;

  double xAt(double time) {
    if (_isFixed(comment)) return bounds.center.dx - size.width / 2;
    final progress = ((time - start) / duration).clamp(0.0, 1.0);
    final travel = bounds.width + size.width;
    return comment.mode == DanmakuMode.reverse
        ? bounds.left - size.width + travel * progress
        : bounds.right - travel * progress;
  }

  bool canShareWith(_DanmakuPlacement other) {
    if (top + size.height + 2 <= other.top ||
        other.top + other.size.height + 2 <= top) {
      return true;
    }
    final from = math.max(start, other.start);
    final until = math.min(end, other.end);
    if (until <= from) return true;
    // Relative motion is linear. Keeping the same left/right ordering at
    // BOTH ends proves separation for the entire shared lifetime, including
    // fast followers and reverse/fixed-mode crossings.
    const gap = 12.0;
    return (xAt(from) >= other.xAt(from) + other.size.width + gap &&
            xAt(until) >= other.xAt(until) + other.size.width + gap) ||
        (xAt(from) + size.width + gap <= other.xAt(from) &&
            xAt(until) + size.width + gap <= other.xAt(until));
  }
}

bool _isFixed(DanmakuComment comment) =>
    comment.mode == DanmakuMode.top ||
    comment.mode == DanmakuMode.bottom ||
    comment.mode == DanmakuMode.advanced;

// A rendering/memory circuit breaker for pathological traffic, not a display-
// area quota. Normal admission is determined by glyph geometry and collisions.
const _maxActiveDanmaku = 256;

int _lowerBound(List<DanmakuComment> comments, double milliseconds) {
  var low = 0;
  var high = comments.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (comments[middle].time.inMicroseconds / 1000 < milliseconds) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// Time/mode eligibility only. Without a viewport this helper cannot decide
/// spatial density; the overlay performs measured track admission separately.
List<DanmakuComment> visibleDanmakuComments(
  List<DanmakuComment> comments, {
  required Duration position,
  required DanmakuSettings settings,
  int limit = _maxActiveDanmaku,
}) {
  final budget = math.max(0, limit);
  if (!settings.enabled ||
      comments.isEmpty ||
      position.isNegative ||
      budget == 0) {
    return const [];
  }
  final earliest =
      position.inMicroseconds / 1000 - 12000 / settings.speed.clamp(.5, 2);
  final visible = <DanmakuComment>[];
  for (
    var index = _lowerBound(comments, earliest);
    index < comments.length;
    index++
  ) {
    final comment = comments[index];
    if (comment.time > position) break;
    if (_isBlocked(comment, settings)) continue;
    if (position - comment.time <= _displayDuration(comment, settings.speed)) {
      visible.add(comment);
    }
  }
  if (visible.length <= budget) return visible;
  return visible.sublist(visible.length - budget);
}

bool _isBlocked(DanmakuComment comment, DanmakuSettings settings) {
  if (settings.blockKeywords.any(comment.text.contains)) return true;
  if (settings.blockTop &&
      (comment.mode == DanmakuMode.top ||
          comment.mode == DanmakuMode.advanced)) {
    return true;
  }
  if (settings.blockBottom && comment.mode == DanmakuMode.bottom) return true;
  if (settings.blockScroll &&
      (comment.mode == DanmakuMode.scroll ||
          comment.mode == DanmakuMode.reverse)) {
    return true;
  }
  return false;
}

Duration _displayDuration(DanmakuComment comment, double speed) {
  final base = switch (comment.mode) {
    DanmakuMode.top || DanmakuMode.bottom => const Duration(seconds: 4),
    DanmakuMode.advanced => const Duration(seconds: 5),
    DanmakuMode.scroll || DanmakuMode.reverse => Duration(
      milliseconds: 7000 + comment.text.runes.length.clamp(0, 45).toInt() * 80,
    ),
  };
  return Duration(
    milliseconds: (base.inMilliseconds / speed.clamp(.5, 2)).round(),
  );
}

/// Reserve chrome insets and then avoid the subtitle rectangle. No lane is
/// forced into an empty safe region. Insets are relative to the full canvas,
/// so the footer does not unnecessarily shrink quarter-screen danmaku.
Rect danmakuDisplayBounds(
  Size size,
  double area, {
  Rect? excludedArea,
  EdgeInsets reservedInsets = EdgeInsets.zero,
}) {
  final bottom = math
      .min(
        size.height * area.clamp(.25, 1),
        size.height -
            math.max(math.min(48.0, size.height * .1), reservedInsets.bottom),
      )
      .clamp(0.0, size.height)
      .toDouble();
  final top = math
      .max(math.min(48.0, bottom * .2), reservedInsets.top)
      .clamp(0.0, size.height)
      .toDouble();
  final left = reservedInsets.left.clamp(0.0, size.width).toDouble();
  final right = (size.width - reservedInsets.right)
      .clamp(left, size.width)
      .toDouble();
  final bounds = Rect.fromLTRB(left, top, right, math.max(top, bottom));
  if (excludedArea == null || !bounds.overlaps(excludedArea)) return bounds;
  final above = math.max(0.0, excludedArea.top - bounds.top - 6);
  final below = math.max(0.0, bounds.bottom - excludedArea.bottom - 6);
  if (above >= below) {
    return Rect.fromLTWH(left, bounds.top, bounds.width, above);
  }
  return Rect.fromLTWH(
    left,
    math.min(bounds.bottom, excludedArea.bottom + 6),
    bounds.width,
    below,
  );
}

class DanmakuAreaClipper extends CustomClipper<Rect> {
  const DanmakuAreaClipper(this.bounds);
  final Rect bounds;

  @override
  Rect getClip(Size size) => bounds;

  @override
  bool shouldReclip(covariant DanmakuAreaClipper oldClipper) =>
      oldClipper.bounds != bounds;
}
