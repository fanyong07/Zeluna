import 'package:anime/src/player/session/playback_session_controller.dart';
import 'package:anime/src/player/session/playback_session_event.dart';
import 'package:anime/src/player/session/playback_session_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'first-frame flow has one explicit ordered state transition per event',
    () {
      final controller = PlaybackSessionController(episodeId: 101);
      addTearDown(controller.dispose);
      final phases = <PlaybackSessionPhase>[];
      controller.addListener(() => phases.add(controller.state.phase));

      controller.dispatch(PlaybackSessionEvent.lookupStarted());
      controller.dispatch(PlaybackSessionEvent.lineDiscovered('line-a'));
      controller.dispatch(PlaybackSessionEvent.lineVerified('line-a'));
      controller.dispatch(PlaybackSessionEvent.openRequested('line-a'));
      controller.dispatch(PlaybackSessionEvent.bufferingStarted());
      controller.dispatch(PlaybackSessionEvent.firstFrame('line-a'));

      expect(phases, [
        PlaybackSessionPhase.discovering,
        PlaybackSessionPhase.discovering,
        PlaybackSessionPhase.discovering,
        PlaybackSessionPhase.opening,
        PlaybackSessionPhase.buffering,
        PlaybackSessionPhase.playing,
      ]);
      expect(controller.state.lineId, 'line-a');
      expect(controller.state.eventSequence, 6);
    },
  );

  test('line failure distinguishes recovery from final failure', () {
    final controller = PlaybackSessionController(episodeId: 101);
    addTearDown(controller.dispose);

    controller.dispatch(PlaybackSessionEvent.openRequested('line-a'));
    controller.dispatch(
      PlaybackSessionEvent.lineFailed(
        'line-a',
        reason: 'decoder',
        hasAlternative: true,
      ),
    );
    expect(controller.state.phase, PlaybackSessionPhase.recovering);
    expect(controller.state.failureReason, 'decoder');

    controller.dispatch(PlaybackSessionEvent.alternativeSelected('line-b'));
    controller.dispatch(
      PlaybackSessionEvent.hardTimeout(hasAlternative: false),
    );
    expect(controller.state.phase, PlaybackSessionPhase.failed);
    expect(controller.state.lineId, 'line-b');
  });

  test('episode, seek and foreground events preserve the resumable phase', () {
    final controller = PlaybackSessionController(episodeId: 101);
    addTearDown(controller.dispose);

    controller.dispatch(PlaybackSessionEvent.openRequested('line-a'));
    controller.dispatch(PlaybackSessionEvent.firstFrame('line-a'));
    controller.dispatch(
      PlaybackSessionEvent.userSeek(const Duration(minutes: 8)),
    );
    controller.dispatch(PlaybackSessionEvent.applicationPaused());
    expect(controller.state.phase, PlaybackSessionPhase.paused);
    expect(controller.state.appInForeground, isFalse);

    controller.dispatch(PlaybackSessionEvent.applicationResumed());
    expect(controller.state.phase, PlaybackSessionPhase.playing);
    expect(controller.state.position, const Duration(minutes: 8));

    controller.dispatch(PlaybackSessionEvent.episodeChanged(102));
    expect(controller.state.phase, PlaybackSessionPhase.discovering);
    expect(controller.state.episodeId, 102);
    expect(controller.state.lineId, isNull);
    expect(controller.state.position, Duration.zero);
  });

  test('a user pause survives lifecycle and late player state callbacks', () {
    final controller = PlaybackSessionController(episodeId: 101);
    addTearDown(controller.dispose);

    controller.dispatch(PlaybackSessionEvent.openRequested('line-a'));
    controller.dispatch(PlaybackSessionEvent.firstFrame('line-a'));
    controller.dispatch(PlaybackSessionEvent.playbackPaused());
    controller.dispatch(PlaybackSessionEvent.applicationPaused());
    controller.dispatch(PlaybackSessionEvent.playbackStateChanged(true));
    controller.dispatch(PlaybackSessionEvent.applicationResumed());

    expect(controller.state.userIntent, PlaybackIntent.paused);
    expect(controller.state.phase, PlaybackSessionPhase.paused);
    expect(controller.state.appInForeground, isTrue);
  });

  test('foreground recovery restores the phase that was active before pause', () {
    final playing = PlaybackSessionController(episodeId: 101);
    addTearDown(playing.dispose);
    playing.dispatch(PlaybackSessionEvent.openRequested('line-a'));
    playing.dispatch(PlaybackSessionEvent.firstFrame('line-a'));
    playing.dispatch(PlaybackSessionEvent.applicationPaused());
    expect(playing.state.phase, PlaybackSessionPhase.paused);
    playing.dispatch(PlaybackSessionEvent.applicationResumed());
    expect(playing.state.phase, PlaybackSessionPhase.playing);

    final buffering = PlaybackSessionController(episodeId: 102);
    addTearDown(buffering.dispose);
    buffering.dispatch(PlaybackSessionEvent.openRequested('line-b'));
    buffering.dispatch(PlaybackSessionEvent.bufferingStarted());
    buffering.dispatch(PlaybackSessionEvent.applicationPaused());
    buffering.dispatch(PlaybackSessionEvent.applicationResumed());
    expect(buffering.state.phase, PlaybackSessionPhase.buffering);
  });

  test('dispose owns the terminal state and rejects late callbacks', () {
    final controller = PlaybackSessionController(episodeId: 101);
    var callbacks = 0;
    controller.addListener(() => callbacks++);
    controller.dispatch(PlaybackSessionEvent.lookupStarted());
    expect(callbacks, 1);

    controller.dispose();
    expect(controller.state.phase, PlaybackSessionPhase.disposed);
    expect(controller.dispatch(PlaybackSessionEvent.firstFrame('late')), false);
    expect(callbacks, 1);
  });
}
