import 'dart:math' as math;

/// A watch becomes effective at 25% or ten minutes, whichever arrives first.
Duration recommendationEffectiveWatchThreshold(Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  return Duration(
    milliseconds: math.min(
      const Duration(minutes: 10).inMilliseconds,
      (duration.inMilliseconds * 0.25).round(),
    ),
  );
}

/// Completion is reached at 90%, or when no more than two minutes remain.
bool recommendationPlaybackReachedCompletion({
  required Duration position,
  required Duration duration,
}) {
  if (duration <= Duration.zero || position < Duration.zero) return false;
  final boundedPosition = position > duration ? duration : position;
  return boundedPosition.inMilliseconds / duration.inMilliseconds >= 0.90 ||
      duration - boundedPosition <= const Duration(minutes: 2);
}
