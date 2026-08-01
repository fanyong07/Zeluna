import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/subtitles/subtitle_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('unavailable subtitles never reach the player', () async {
    var calls = 0;
    final controller = SubtitleController(applyTrack: (_) async => calls++);
    addTearDown(controller.dispose);

    final result = await controller.select(
      _candidate(available: false, message: 'missing'),
    );

    expect(result.status, SubtitleActionStatus.unavailable);
    expect(result.message, 'missing');
    expect(calls, 0);
    expect(controller.selected, isNull);
  });

  test('a newer subtitle selection rejects an older late result', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    var calls = 0;
    final controller = SubtitleController(
      applyTrack: (_) {
        calls++;
        return calls == 1 ? first.future : second.future;
      },
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final firstResult = controller.select(_candidate(title: 'first'));
    final secondResult = controller.select(_candidate(title: 'second'));
    second.complete();

    expect((await secondResult).status, SubtitleActionStatus.applied);
    expect(controller.selected?.title, 'second');
    first.complete();
    expect((await firstResult).status, SubtitleActionStatus.stale);
    expect(controller.selected?.title, 'second');
    expect(notifications, 1);
  });

  test('disable clears the selected subtitle through the same owner', () async {
    final tracks = <SubtitleTrack>[];
    final controller = SubtitleController(
      applyTrack: (track) async => tracks.add(track),
    );
    addTearDown(controller.dispose);

    await controller.select(_candidate());
    final result = await controller.disable();

    expect(result.status, SubtitleActionStatus.applied);
    expect(controller.selected, isNull);
    expect(tracks, hasLength(2));
  });

  test('episode invalidation and dispose reject late callbacks', () async {
    final episodePending = Completer<void>();
    final disposePending = Completer<void>();
    var calls = 0;
    final controller = SubtitleController(
      applyTrack: (_) {
        calls++;
        return calls == 1 ? episodePending.future : disposePending.future;
      },
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    final oldEpisode = controller.select(_candidate(title: 'old episode'));
    controller.invalidatePendingAction();
    episodePending.complete();
    expect((await oldEpisode).status, SubtitleActionStatus.stale);

    final disposed = controller.select(_candidate(title: 'disposed'));
    controller.dispose();
    disposePending.complete();
    expect((await disposed).status, SubtitleActionStatus.stale);
    expect(controller.selected, isNull);
    expect(notifications, 0);
  });
}

SubtitleCandidate _candidate({
  String title = 'subtitle',
  bool available = true,
  String? message,
}) {
  return SubtitleCandidate(
    provider: 'test',
    title: title,
    language: 'zh-CN',
    downloadUrl: 'https://example.invalid/subtitle.vtt',
    available: available,
    message: message,
  );
}
