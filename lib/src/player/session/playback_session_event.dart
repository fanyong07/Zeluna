enum PlaybackSessionEventType {
  lookupStarted,
  lineDiscovered,
  lineVerified,
  openRequested,
  firstFrame,
  bufferingStarted,
  bufferingEnded,
  mediaError,
  softTimeout,
  hardTimeout,
  lineFailed,
  alternativeSelected,
  episodeChanged,
  userSeek,
  applicationPaused,
  applicationResumed,
  playbackPaused,
  playbackResumed,
  playbackStateChanged,
  playbackEnded,
  dispose,
}

final class PlaybackSessionEvent {
  const PlaybackSessionEvent._(
    this.type, {
    this.episodeId,
    this.lineId,
    this.position,
    this.playing,
    this.reason,
    this.hasAlternative = false,
  });

  factory PlaybackSessionEvent.lookupStarted() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.lookupStarted);

  factory PlaybackSessionEvent.lineDiscovered(String lineId) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.lineDiscovered,
        lineId: lineId,
      );

  factory PlaybackSessionEvent.lineVerified(String lineId) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.lineVerified,
        lineId: lineId,
      );

  factory PlaybackSessionEvent.openRequested(
    String lineId, {
    Duration position = Duration.zero,
  }) => PlaybackSessionEvent._(
    PlaybackSessionEventType.openRequested,
    lineId: lineId,
    position: position,
  );

  factory PlaybackSessionEvent.firstFrame(String lineId) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.firstFrame,
        lineId: lineId,
      );

  factory PlaybackSessionEvent.bufferingStarted() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.bufferingStarted);

  factory PlaybackSessionEvent.bufferingEnded() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.bufferingEnded);

  factory PlaybackSessionEvent.mediaError(
    String reason, {
    required bool hasAlternative,
  }) => PlaybackSessionEvent._(
    PlaybackSessionEventType.mediaError,
    reason: reason,
    hasAlternative: hasAlternative,
  );

  factory PlaybackSessionEvent.softTimeout({required bool hasAlternative}) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.softTimeout,
        hasAlternative: hasAlternative,
      );

  factory PlaybackSessionEvent.hardTimeout({required bool hasAlternative}) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.hardTimeout,
        hasAlternative: hasAlternative,
      );

  factory PlaybackSessionEvent.lineFailed(
    String lineId, {
    String? reason,
    required bool hasAlternative,
  }) => PlaybackSessionEvent._(
    PlaybackSessionEventType.lineFailed,
    lineId: lineId,
    reason: reason,
    hasAlternative: hasAlternative,
  );

  factory PlaybackSessionEvent.alternativeSelected(String lineId) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.alternativeSelected,
        lineId: lineId,
      );

  factory PlaybackSessionEvent.episodeChanged(int episodeId) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.episodeChanged,
        episodeId: episodeId,
      );

  factory PlaybackSessionEvent.userSeek(Duration position) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.userSeek,
        position: position,
      );

  factory PlaybackSessionEvent.applicationPaused() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.applicationPaused);

  factory PlaybackSessionEvent.applicationResumed() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.applicationResumed);

  factory PlaybackSessionEvent.playbackPaused() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.playbackPaused);

  factory PlaybackSessionEvent.playbackResumed() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.playbackResumed);

  factory PlaybackSessionEvent.playbackStateChanged(bool playing) =>
      PlaybackSessionEvent._(
        PlaybackSessionEventType.playbackStateChanged,
        playing: playing,
      );

  factory PlaybackSessionEvent.playbackEnded() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.playbackEnded);

  factory PlaybackSessionEvent.dispose() =>
      const PlaybackSessionEvent._(PlaybackSessionEventType.dispose);

  final PlaybackSessionEventType type;
  final int? episodeId;
  final String? lineId;
  final Duration? position;
  final bool? playing;
  final String? reason;
  final bool hasAlternative;
}
