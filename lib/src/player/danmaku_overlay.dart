import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/anime_models.dart';

class RemoteDanmakuOverlay extends StatelessWidget {
  const RemoteDanmakuOverlay({
    super.key,
    required this.comments,
    required this.position,
    required this.settings,
  });

  final List<DanmakuComment> comments;
  final Duration position;
  final DanmakuSettings settings;

  @override
  Widget build(BuildContext context) {
    final visible = visibleDanmakuComments(
      comments,
      position: position,
      settings: settings,
    );
    if (visible.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = settings.fontSize.clamp(12, 30).toDouble();
          final laneHeight =
              MediaQuery.textScalerOf(context).scale(fontSize) * 1.4 + 4;
          final bounds = danmakuDisplayBounds(
            constraints.biggest,
            settings.displayArea,
          );
          final lanes = (bounds.height / laneHeight).floor().clamp(1, 12);
          return ClipRect(
            clipper: DanmakuAreaClipper(bounds),
            child: Stack(
              children: [
                for (final comment in visible)
                  _DanmakuItem(
                    key: ValueKey('${comment.provider}-${comment.id}'),
                    comment: comment,
                    position: position,
                    width: constraints.maxWidth,
                    bounds: bounds,
                    lane: _laneFor(comment, lanes),
                    laneHeight: laneHeight,
                    settings: settings,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

List<DanmakuComment> visibleDanmakuComments(
  List<DanmakuComment> comments, {
  required Duration position,
  required DanmakuSettings settings,
  int limit = 48,
}) {
  if (!settings.enabled || comments.isEmpty || position.isNegative) {
    return const [];
  }
  final earliest =
      position -
      Duration(milliseconds: (12000 / settings.speed.clamp(.5, 2)).ceil());
  var low = 0;
  var high = comments.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (comments[middle].time < earliest) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }

  final visible = <DanmakuComment>[];
  for (var index = low; index < comments.length; index++) {
    final comment = comments[index];
    if (comment.time > position) break;
    if (_isBlocked(comment, settings)) continue;
    final elapsed = position - comment.time;
    if (elapsed <= _displayDuration(comment, settings.speed)) {
      visible.add(comment);
    }
  }
  if (visible.length <= limit) return visible;
  return visible.sublist(visible.length - limit);
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

int _laneFor(DanmakuComment comment, int lanes) {
  return (comment.id.hashCode & 0x7fffffff) % lanes;
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

/// Keep all modes inside the chosen upper area, with room for controls.
Rect danmakuDisplayBounds(Size size, double area) {
  final bottom = math.min(
    size.height * area.clamp(.25, 1),
    size.height - math.min(48.0, size.height * .1),
  );
  final top = math.min(48.0, bottom * .2);
  return Rect.fromLTRB(0, top, size.width, math.max(top, bottom));
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

class _DanmakuItem extends StatelessWidget {
  const _DanmakuItem({
    super.key,
    required this.comment,
    required this.position,
    required this.width,
    required this.bounds,
    required this.lane,
    required this.laneHeight,
    required this.settings,
  });

  final DanmakuComment comment;
  final Duration position;
  final double width;
  final Rect bounds;
  final int lane;
  final double laneHeight;
  final DanmakuSettings settings;

  @override
  Widget build(BuildContext context) {
    final fontSize = settings.fontSize.clamp(12, 30).toDouble();
    final text = Opacity(
      opacity: settings.opacity.clamp(.2, 1).toDouble(),
      child: Text(
        comment.text,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xFF000000 | comment.color),
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          shadows: const [
            Shadow(color: Colors.black, blurRadius: 2, offset: Offset(1, 1)),
            Shadow(color: Colors.black, blurRadius: 2, offset: Offset(-1, -1)),
          ],
        ),
      ),
    );

    if (comment.mode == DanmakuMode.top ||
        comment.mode == DanmakuMode.advanced) {
      return Positioned(
        left: 12,
        right: 12,
        top: bounds.top + lane * laneHeight,
        child: Center(child: text),
      );
    }
    if (comment.mode == DanmakuMode.bottom) {
      return Positioned(
        left: 12,
        right: 12,
        top: math.max(bounds.top, bounds.bottom - (lane + 1) * laneHeight),
        child: Center(child: text),
      );
    }

    final duration = _displayDuration(comment, settings.speed);
    final elapsed = position - comment.time;
    final progress = (elapsed.inMilliseconds / duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
    final estimatedWidth = math.max(
      120.0,
      comment.text.runes.length * fontSize * 0.72,
    );
    final travel = width + estimatedWidth;
    final x = comment.mode == DanmakuMode.reverse
        ? -estimatedWidth + travel * progress
        : width - travel * progress;
    return Positioned(
      left: x,
      top: bounds.top + lane * laneHeight,
      child: text,
    );
  }
}
