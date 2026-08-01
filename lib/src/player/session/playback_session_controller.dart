import 'package:flutter/foundation.dart';

import 'playback_session_event.dart';
import 'playback_session_state.dart';

final class PlaybackSessionController extends ChangeNotifier {
  PlaybackSessionController({required int episodeId})
    : _state = PlaybackSessionState.idle(episodeId: episodeId);

  PlaybackSessionState _state;
  bool _disposed = false;

  PlaybackSessionState get state => _state;

  bool dispatch(PlaybackSessionEvent event) {
    if (_disposed || _state.phase == PlaybackSessionPhase.disposed) {
      return false;
    }
    final next = reducePlaybackSession(_state, event);
    if (identical(next, _state)) return false;
    _state = next;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _state = reducePlaybackSession(_state, PlaybackSessionEvent.dispose());
    _disposed = true;
    super.dispose();
  }
}

PlaybackSessionState reducePlaybackSession(
  PlaybackSessionState current,
  PlaybackSessionEvent event,
) {
  if (current.phase == PlaybackSessionPhase.disposed) return current;

  var phase = current.phase;
  var episodeId = current.episodeId;
  var lineId = current.lineId;
  var position = current.position;
  var failureReason = current.failureReason;
  var phaseBeforePause = current.phaseBeforePause;
  var appInForeground = current.appInForeground;

  switch (event.type) {
    case PlaybackSessionEventType.lookupStarted:
      phase = PlaybackSessionPhase.discovering;
      failureReason = null;
    case PlaybackSessionEventType.lineDiscovered:
    case PlaybackSessionEventType.lineVerified:
      lineId = event.lineId ?? lineId;
      if (phase == PlaybackSessionPhase.idle ||
          phase == PlaybackSessionPhase.failed ||
          phase == PlaybackSessionPhase.ended) {
        phase = PlaybackSessionPhase.discovering;
      }
    case PlaybackSessionEventType.openRequested:
      phase = PlaybackSessionPhase.opening;
      lineId = event.lineId ?? lineId;
      position = event.position ?? position;
      failureReason = null;
    case PlaybackSessionEventType.firstFrame:
      phase = PlaybackSessionPhase.playing;
      lineId = event.lineId ?? lineId;
      failureReason = null;
    case PlaybackSessionEventType.bufferingStarted:
      if (phase != PlaybackSessionPhase.failed &&
          phase != PlaybackSessionPhase.ended) {
        phase = PlaybackSessionPhase.buffering;
      }
    case PlaybackSessionEventType.bufferingEnded:
      if (phase == PlaybackSessionPhase.buffering) {
        phase = PlaybackSessionPhase.playing;
      }
    case PlaybackSessionEventType.mediaError:
    case PlaybackSessionEventType.softTimeout:
    case PlaybackSessionEventType.hardTimeout:
    case PlaybackSessionEventType.lineFailed:
      phase = event.hasAlternative
          ? PlaybackSessionPhase.recovering
          : PlaybackSessionPhase.failed;
      lineId = event.lineId ?? lineId;
      failureReason = event.reason ?? event.type.name;
    case PlaybackSessionEventType.alternativeSelected:
      phase = PlaybackSessionPhase.opening;
      lineId = event.lineId ?? lineId;
      failureReason = null;
    case PlaybackSessionEventType.episodeChanged:
      phase = PlaybackSessionPhase.discovering;
      episodeId = event.episodeId ?? episodeId;
      lineId = null;
      position = Duration.zero;
      failureReason = null;
      phaseBeforePause = null;
    case PlaybackSessionEventType.userSeek:
      position = event.position ?? position;
    case PlaybackSessionEventType.applicationPaused:
      if (phase != PlaybackSessionPhase.paused) phaseBeforePause = phase;
      phase = PlaybackSessionPhase.paused;
      appInForeground = false;
    case PlaybackSessionEventType.applicationResumed:
      phase =
          phaseBeforePause == null ||
              phaseBeforePause == PlaybackSessionPhase.paused
          ? PlaybackSessionPhase.idle
          : phaseBeforePause;
      phaseBeforePause = null;
      appInForeground = true;
    case PlaybackSessionEventType.playbackPaused:
      if (phase != PlaybackSessionPhase.paused) phaseBeforePause = phase;
      phase = PlaybackSessionPhase.paused;
    case PlaybackSessionEventType.playbackResumed:
      phase = PlaybackSessionPhase.playing;
      phaseBeforePause = null;
    case PlaybackSessionEventType.playbackEnded:
      phase = PlaybackSessionPhase.ended;
    case PlaybackSessionEventType.dispose:
      phase = PlaybackSessionPhase.disposed;
  }

  return PlaybackSessionState(
    phase: phase,
    episodeId: episodeId,
    lineId: lineId,
    position: position,
    failureReason: failureReason,
    lastEvent: event.type,
    phaseBeforePause: phaseBeforePause,
    eventSequence: current.eventSequence + 1,
    appInForeground: appInForeground,
  );
}
