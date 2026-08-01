import 'playback_session_event.dart';

enum PlaybackSessionPhase {
  idle,
  discovering,
  opening,
  buffering,
  playing,
  paused,
  recovering,
  failed,
  ended,
  disposed,
}

final class PlaybackSessionState {
  const PlaybackSessionState({
    required this.phase,
    required this.episodeId,
    this.lineId,
    this.position = Duration.zero,
    this.failureReason,
    this.lastEvent,
    this.phaseBeforePause,
    this.eventSequence = 0,
    this.appInForeground = true,
  });

  factory PlaybackSessionState.idle({required int episodeId}) =>
      PlaybackSessionState(
        phase: PlaybackSessionPhase.idle,
        episodeId: episodeId,
      );

  final PlaybackSessionPhase phase;
  final int episodeId;
  final String? lineId;
  final Duration position;
  final String? failureReason;
  final PlaybackSessionEventType? lastEvent;
  final PlaybackSessionPhase? phaseBeforePause;
  final int eventSequence;
  final bool appInForeground;

  bool get isTerminal =>
      phase == PlaybackSessionPhase.failed ||
      phase == PlaybackSessionPhase.ended ||
      phase == PlaybackSessionPhase.disposed;
}
