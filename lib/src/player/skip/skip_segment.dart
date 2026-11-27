enum SkipSegmentType {
  op('片头'),
  ed('片尾'),
  recap('前情');

  const SkipSegmentType(this.label);
  final String label;
}

enum SkipSegmentSource {
  manual('手动设置'),
  chapter('视频章节'),
  aniskip('AniSkip'),
  danmaku('弹幕分析');

  const SkipSegmentSource(this.label);
  final String label;
}

final class SkipSegment {
  const SkipSegment({
    required this.type,
    required this.start,
    required this.end,
    required this.source,
    this.title,
  });
  final SkipSegmentType type;
  final Duration start, end;
  final SkipSegmentSource source;
  final String? title;

  bool get isValid =>
      start >= Duration.zero && end > start + const Duration(seconds: 5);
  bool contains(Duration position) => position >= start && position < end;
  bool isTerminalEnding(Duration duration) =>
      type == SkipSegmentType.ed &&
      duration > Duration.zero &&
      duration - end < const Duration(seconds: 15);
  String get shortLabel => type.label;
  String get actionLabel => '跳过$shortLabel';

  @override
  bool operator ==(Object other) =>
      other is SkipSegment &&
      other.type == type &&
      other.start == start &&
      other.end == end &&
      other.source == source &&
      other.title == title;
  @override
  int get hashCode => Object.hash(type, start, end, source, title);
}

String skipTimeLabel(Duration time) =>
    '${time.inMinutes.toString().padLeft(2, '0')}:${time.inSeconds.remainder(60).toString().padLeft(2, '0')}';

List<SkipSegment> mergeSkipSegments(
  Iterable<SkipSegment> candidates, {
  Duration? episodeDuration,
}) {
  final best = <SkipSegmentType, SkipSegment>{};
  for (var segment in candidates) {
    if (episodeDuration != null &&
        episodeDuration > Duration.zero &&
        segment.end > episodeDuration) {
      segment = SkipSegment(
        type: segment.type,
        start: segment.start,
        end: episodeDuration,
        source: segment.source,
        title: segment.title,
      );
    }
    final previous = best[segment.type];
    if (segment.isValid &&
        (previous == null || segment.source.index < previous.source.index)) {
      best[segment.type] = segment;
    }
  }
  return List.unmodifiable(
    best.values.toList()..sort((a, b) => a.start.compareTo(b.start)),
  );
}
