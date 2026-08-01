import 'dart:async';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
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

  test('one runtime failure retries before the line is quarantined', () {
    final controller = PlaybackLineController();
    addTearDown(controller.dispose);
    final line = _line('line-a', 'provider-a');

    expect(controller.markFailure(line), isFalse);
    expect(controller.failedLineIds, isEmpty);
    expect(controller.markFailure(line), isTrue);
    expect(controller.failedLineIds, contains(line.id));

    controller.clearFailure(line.id);
    expect(controller.failureCounts, isEmpty);
    expect(controller.failedLineIds, isEmpty);
  });

  test(
    'source priority chooses a healthy preferred provider before latency',
    () {
      final controller = PlaybackLineController()
        ..preferredProviderId = 'provider-b';
      addTearDown(controller.dispose);
      final first = _line('line-a', 'provider-a', latencyMs: 10);
      final preferred = _line('line-b', 'provider-b', latencyMs: 500);
      final third = _line('line-c', 'provider-c', latencyMs: 20);

      expect(
        controller.preferredPlayableLine([first, preferred, third]),
        same(preferred),
      );
      controller.failedLineIds.add(preferred.id);
      expect(
        controller.nextPlayableLine(
          currentLine: first,
          lines: [first, preferred, third],
        ),
        same(third),
      );
    },
  );

  test('a failed background probe cannot replace loaded healthy media', () {
    final controller = PlaybackLineController();
    addTearDown(controller.dispose);
    final current = _line('line-a', 'provider-a');
    final rejected = _line(
      'line-a',
      'provider-a',
      available: false,
      serverVerified: false,
    );

    final preserved = controller.preserveLoadedLineIfProbeDisagrees(
      lines: [rejected],
      currentLine: current,
      loadedUrl: current.url,
      playbackFailed: false,
    );

    expect(preserved.single, same(current));
  });
}

PlaybackLine _line(
  String id,
  String providerId, {
  int latencyMs = 30,
  bool available = true,
  bool serverVerified = true,
}) {
  return PlaybackLine(
    id: id,
    episodeId: 1,
    providerId: providerId,
    providerName: providerId,
    title: id,
    quality: '1080p',
    url: 'https://example.invalid/$id.m3u8',
    format: 'HLS',
    available: available,
    serverVerified: serverVerified,
    latency: Duration(milliseconds: latencyMs),
  );
}
