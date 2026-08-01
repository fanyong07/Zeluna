import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku/danmaku_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('episode changes reject stale parallel danmaku results', () async {
    final controller = DanmakuController();
    addTearDown(controller.dispose);
    final first = Completer<DanmakuTimeline>();
    final second = Completer<DanmakuTimeline>();

    final firstLoad = controller.loadEpisode(
      episodeId: 1,
      load: () => first.future,
    );
    controller.changeEpisode();
    final secondLoad = controller.loadEpisode(
      episodeId: 2,
      load: () => second.future,
    );

    first.complete(DanmakuTimeline(comments: [_comment('old')]));
    await firstLoad;
    expect(controller.remoteComments, isEmpty);

    second.complete(DanmakuTimeline(comments: [_comment('current')]));
    await secondLoad;
    expect(controller.remoteComments.single.text, 'current');
    expect(controller.requestedEpisodeId, 2);
  });

  test('failed loads can retry the same episode', () async {
    final controller = DanmakuController();
    addTearDown(controller.dispose);
    var attempts = 0;

    await controller.loadEpisode(
      episodeId: 7,
      load: () async {
        attempts++;
        throw StateError('temporary');
      },
    );
    expect(controller.requestedEpisodeId, isNull);

    await controller.loadEpisode(
      episodeId: 7,
      load: () async {
        attempts++;
        return DanmakuTimeline(comments: [_comment('retried')]);
      },
    );
    expect(attempts, 2);
    expect(controller.remoteComments.single.text, 'retried');
  });

  test('local input validation and expiry are controller-owned', () async {
    final controller = DanmakuController(
      localCommentLifetime: const Duration(milliseconds: 10),
      now: () => DateTime.fromMicrosecondsSinceEpoch(42),
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    expect(
      controller.sendLocal('hello', settings: const DanmakuSettings()),
      LocalDanmakuSendResult.disabled,
    );
    expect(
      controller.sendLocal(
        'blocked text',
        settings: const DanmakuSettings(
          enabled: true,
          blockKeywords: ['blocked'],
        ),
      ),
      LocalDanmakuSendResult.blocked,
    );

    controller.input.text = 'hello';
    expect(
      controller.sendLocal(
        controller.input.text,
        settings: const DanmakuSettings(enabled: true),
      ),
      LocalDanmakuSendResult.accepted,
    );
    expect(controller.input.text, isEmpty);
    expect(controller.localComments.single.text, 'hello');

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.localComments, isEmpty);
    expect(notifications, 2);
  });

  test('dispose rejects late loads and local timer callbacks', () async {
    final controller = DanmakuController(
      localCommentLifetime: const Duration(milliseconds: 10),
    );
    final pending = Completer<DanmakuTimeline>();
    var notifications = 0;
    controller.addListener(() => notifications++);

    final load = controller.loadEpisode(
      episodeId: 3,
      load: () => pending.future,
    );
    controller.sendLocal(
      'visible',
      settings: const DanmakuSettings(enabled: true),
    );
    expect(notifications, 1);
    controller.dispose();

    pending.complete(DanmakuTimeline(comments: [_comment('late')]));
    await load;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.isDisposed, isTrue);
    expect(controller.remoteComments, isEmpty);
    expect(notifications, 1);
  });
}

DanmakuComment _comment(String text) {
  return DanmakuComment(
    id: text,
    provider: 'test',
    time: Duration.zero,
    mode: DanmakuMode.scroll,
    color: 0xFFFFFF,
    text: text,
  );
}
