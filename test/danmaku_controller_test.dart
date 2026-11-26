import 'dart:async';
import 'dart:convert';

import 'package:anime/src/data/danmaku_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku/danmaku_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'HTTP 200 partial failure retains dandanplay and updates community',
    () async {
      var phase = 0;
      var attempts = 0;
      final repository = DanmakuRepository(
        officialClient: MockClient((_) async {
          attempts++;
          return http.Response(
            jsonEncode({
              'sources': [
                {'provider': 'Zeluna', 'available': true},
                {
                  'provider': '弹弹play',
                  'available': phase != 1,
                  'error_code': phase == 1 ? 'timeout' : null,
                  'retryable': phase == 1,
                  'message': 'wording must not control recovery',
                },
              ],
              'comments': [
                {
                  'id': 'community',
                  'provider': 'Zeluna',
                  'text': 'community-$phase',
                  'time_seconds': 2,
                  'color': 16777215,
                },
                if (phase != 1)
                  {
                    'id': 'external',
                    'provider': '弹弹play',
                    'text': 'external-$phase',
                    'time_seconds': 1,
                    'color': 16777215,
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(repository.close);
      final controller = DanmakuController();
      addTearDown(controller.dispose);
      Future<void> load({bool refresh = false}) => controller.loadEpisode(
        episodeId: 7,
        forceRefresh: refresh,
        load: () => repository.timelineForEpisode(
          _subject,
          _episode,
          const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
          forceRefresh: refresh,
        ),
      );
      await load();
      expect(controller.remoteComments.map((c) => c.text), [
        'external-0',
        'community-0',
      ]);
      phase = 1;
      await load(refresh: true);
      expect(controller.remoteComments.map((c) => c.text), [
        'external-0',
        'community-1',
      ]);
      expect(controller.requestedEpisodeId, isNull);
      phase = 2;
      repository.invalidate();
      await load();
      expect(controller.remoteComments.map((c) => c.text), [
        'external-2',
        'community-2',
      ]);
      expect(controller.requestedEpisodeId, 7);
      expect(attempts, greaterThanOrEqualTo(3));
    },
  );

  test(
    'non-transient errors and empty source outcomes remove old comments',
    () async {
      final controller = DanmakuController();
      addTearDown(controller.dispose);
      for (final message in [
        'no_match',
        'disabled',
        'empty',
        'HTTP 403',
        'HTTP 429',
        '弹幕源暂时无法访问',
        '弹弹play 暂时无法访问，Zeluna 社区弹幕仍可正常使用',
        null,
      ]) {
        await controller.loadEpisode(
          episodeId: 7,
          forceRefresh: true,
          load: () async => DanmakuTimeline(comments: [_comment('old')]),
        );
        await controller.loadEpisode(
          episodeId: 7,
          forceRefresh: true,
          load: () async => DanmakuTimeline(
            sources: [
              DanmakuMatch(
                provider: 'test',
                title: '',
                episodeTitle: '',
                episodeId: '7',
                message: message,
              ),
            ],
          ),
        );
        expect(
          controller.remoteComments,
          isEmpty,
          reason: 'empty outcome: $message',
        );
        expect(controller.requestedEpisodeId, 7);
      }
      await controller.loadEpisode(
        episodeId: 7,
        forceRefresh: true,
        load: () async => DanmakuTimeline(comments: [_comment('old')]),
      );
      await controller.loadEpisode(
        episodeId: 7,
        forceRefresh: true,
        load: () async => throw const FormatException('malformed data'),
      );
      expect(controller.remoteComments, isEmpty);
    },
  );

  test(
    'partial transient refresh preserves only failed sources and can retry',
    () async {
      var failing = false;
      final repository = DanmakuRepository(
        officialClient: MockClient(
          (_) async => failing
              ? http.Response('', 503)
              : http.Response(
                  jsonEncode({
                    'comments': [
                      {
                        'id': 'official',
                        'provider': 'Zeluna',
                        'text': 'kept',
                        'time_seconds': 1,
                        'color': 16777215,
                      },
                    ],
                    'sources': [
                      {'provider': 'Zeluna', 'available': true},
                    ],
                  }),
                  200,
                ),
        ),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {'time': 2, 'text': failing ? 'fresh-custom' : 'old-custom'},
            ]),
            200,
          ),
        ),
      );
      addTearDown(repository.close);
      final controller = DanmakuController();
      addTearDown(controller.dispose);
      Future<void> load({bool refresh = false}) => controller.loadEpisode(
        episodeId: 7,
        forceRefresh: refresh,
        load: () => repository.timelineForEpisode(
          _subject,
          _episode,
          const ExternalServiceSettings(
            bilibiliDanmakuEnabled: false,
            dandanplayDanmakuEnabled: false,
            customDanmakuEnabled: true,
            customDanmakuEndpoint: 'https://danmaku.example/comments',
          ),
          forceRefresh: refresh,
        ),
      );
      await load();
      failing = true;
      await load(refresh: true);
      expect(controller.remoteComments.map((c) => c.text), [
        'kept',
        'fresh-custom',
      ]);
      expect(controller.requestedEpisodeId, isNull);
      failing = false;
      repository.invalidate();
      await load();
      expect(controller.remoteComments.map((c) => c.text), [
        'kept',
        'old-custom',
      ]);
      expect(controller.requestedEpisodeId, 7);
    },
  );

  test(
    'failed refresh preserves comments and permits a later same-episode retry',
    () async {
      final controller = DanmakuController();
      addTearDown(controller.dispose);
      await controller.loadEpisode(
        episodeId: 7,
        load: () async => DanmakuTimeline(comments: [_comment('last-good')]),
      );
      await controller.loadEpisode(
        episodeId: 7,
        forceRefresh: true,
        load: () async => const DanmakuTimeline(
          sources: [
            TransientDanmakuFailure(
              provider: 'test',
              title: '',
              episodeTitle: '',
              episodeId: '7',
            ),
          ],
        ),
      );
      expect(controller.remoteComments.single.text, 'last-good');
      expect(controller.requestedEpisodeId, isNull);
      await controller.loadEpisode(
        episodeId: 7,
        load: () async => throw TimeoutException('offline'),
      );
      expect(controller.remoteComments.single.text, 'last-good');
      controller.changeEpisode();
      expect(controller.remoteComments, isEmpty);
    },
  );

  test('new settings show danmaku but preserve an explicit saved opt-out', () {
    expect(const DanmakuSettings().enabled, isTrue);
    expect(DanmakuSettings.fromJson({}).enabled, isTrue);
    expect(DanmakuSettings.fromJson({'enabled': false}).enabled, isFalse);
  });

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

  test(
    'explicit refresh replaces a cached empty timeline for the same episode',
    () async {
      final controller = DanmakuController();
      addTearDown(controller.dispose);
      await controller.loadEpisode(
        episodeId: 7,
        load: () async => const DanmakuTimeline(),
      );
      await controller.loadEpisode(
        episodeId: 7,
        forceRefresh: true,
        load: () async => DanmakuTimeline(comments: [_comment('recovered')]),
      );
      expect(controller.remoteComments.single.text, 'recovered');
    },
  );

  test(
    'explicit refresh rejects older in-flight results for the same episode',
    () async {
      final controller = DanmakuController();
      addTearDown(controller.dispose);
      final stale = Completer<DanmakuTimeline>();
      final first = controller.loadEpisode(
        episodeId: 7,
        load: () => stale.future,
      );
      await controller.loadEpisode(
        episodeId: 7,
        forceRefresh: true,
        load: () async => DanmakuTimeline(comments: [_comment('fresh')]),
      );
      stale.complete(DanmakuTimeline(comments: [_comment('stale')]));
      await first;
      expect(controller.remoteComments.single.text, 'fresh');
    },
  );

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
      controller.sendLocal(
        'hello',
        settings: const DanmakuSettings(enabled: false),
      ),
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

  test('published danmaku is inserted and an owned comment can be removed', () {
    final controller = DanmakuController();
    addTearDown(controller.dispose);

    controller.addRemoteComment(
      _comment('later').copyWithForTest(
        id: 'zeluna-42',
        time: const Duration(seconds: 20),
        isMine: true,
      ),
    );
    controller.addRemoteComment(
      _comment('earlier').copyWithForTest(time: const Duration(seconds: 10)),
    );

    expect(controller.remoteComments.map((item) => item.text), [
      'earlier',
      'later',
    ]);
    controller.removeRemoteComment('zeluna-42');
    expect(controller.remoteComments.map((item) => item.text), ['earlier']);
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

extension on DanmakuComment {
  DanmakuComment copyWithForTest({String? id, Duration? time, bool? isMine}) =>
      DanmakuComment(
        id: id ?? this.id,
        provider: provider,
        time: time ?? this.time,
        mode: mode,
        color: color,
        text: text,
        authorName: authorName,
        isMine: isMine ?? this.isMine,
      );
}

const _subject = AnimeSubject(
  id: 1,
  title: '葬送的芙莉莲',
  originalTitle: 'Frieren',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-09-29',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '全28集',
  categories: [AnimeCategory(name: '动画')],
  tags: [AnimeTag(name: 'TV')],
  totalEpisodes: 28,
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '',
  airdate: '2023-09-29',
  duration: '24:00',
  description: '第一集',
);
