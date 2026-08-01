import 'dart:async';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/player/lines/playback_line_controller.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispose cancels line lookup subscription and both tokens', () async {
    final controller = PlaybackLineController();
    final updates = StreamController<PlaybackLineLookupUpdate>();
    var callbacks = 0;
    controller.lookupSubscription = updates.stream.listen((_) => callbacks++);
    final lookupToken = RulePlaybackCancellationToken();
    final backupToken = RulePlaybackCancellationToken();
    controller.lookupCancellationToken = lookupToken;
    controller.backupLookupCancellationToken = backupToken;
    controller.failedLineIds.add('failed');
    controller.failureCounts['failed'] = 2;

    await controller.dispose();
    updates.add(
      const PlaybackLineLookupUpdate(
        phase: PlaybackLineLookupPhase.complete,
        lines: [],
        completedRules: 0,
        totalRules: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(lookupToken.isCancelled, isTrue);
    expect(backupToken.isCancelled, isTrue);
    expect(controller.lookupSubscription, isNull);
    expect(controller.failedLineIds, isEmpty);
    expect(callbacks, 0);
    await updates.close();
  });
}
