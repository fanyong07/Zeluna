import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/danmaku_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'six second partial response cannot restart an eight second budget',
    (tester) async {
      final start = tester.binding.clock.now();
      final pending = Completer<http.Response>();
      var attempts = 0;
      final repository = DanmakuRepository(
        stopwatchFactory: () =>
            _TestStopwatch(() => tester.binding.clock.now().difference(start)),
        officialClient: MockClient((_) async {
          attempts++;
          if (attempts > 1) return pending.future;
          await Future<void>.delayed(const Duration(seconds: 6));
          return _jsonResponse({
            'sources': [
              {'provider': 'Zeluna', 'available': true},
              {
                'provider': '弹弹play',
                'available': false,
                'error_code': 'timeout',
                'retryable': true,
              },
            ],
            'comments': [
              {
                'id': 'community',
                'provider': 'Zeluna',
                'text': 'still usable',
                'time_seconds': 1,
                'color': 16777215,
              },
            ],
          });
        }),
      );
      addTearDown(repository.close);
      DanmakuTimeline? result;
      final future = repository
          .timelineForEpisode(
            _subject,
            _episode,
            const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
          )
          .then((value) => result = value);
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 500));
      expect(attempts, 2);
      await tester.pump(const Duration(milliseconds: 1499));
      expect(result, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(result, isNotNull);
      await future;
      expect(result!.comments.single.text, 'still usable');
      expect(result!.sources.last, isA<TransientDanmakuFailure>());
      pending.complete(http.Response('', 503));
      await tester.pump(const Duration(seconds: 20));
      expect(attempts, 2);
    },
  );

  test('HTTP 200 permanent unknown and empty outcomes never retry', () async {
    for (final code in [
      'authorization',
      'rate_limited',
      'disabled',
      'no_match',
      'upstream_error',
      null,
    ]) {
      var attempts = 0;
      final repository = DanmakuRepository(
        officialClient: MockClient((_) async {
          attempts++;
          return _jsonResponse({
            'sources': [
              {
                'provider': '弹弹play',
                'available': false,
                'error_code': code,
                'retryable': true,
                'message': '弹弹play 暂时无法访问，Zeluna 社区弹幕仍可正常使用',
              },
            ],
            'comments': [],
          });
        }),
      );
      addTearDown(repository.close);
      final result = await repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
      );
      expect(attempts, 1, reason: '$code');
      expect(result.sources.single, isNot(isA<TransientDanmakuFailure>()));
    }
    for (final retryable in [false, null]) {
      final parsed = parseZelunaDanmakuSources({
        'sources': [
          {
            'provider': '弹弹play',
            'available': false,
            'error_code': 'timeout',
            'retryable': retryable,
          },
        ],
      });
      expect(parsed.single, isNot(isA<TransientDanmakuFailure>()));
    }
  });

  test(
    'HTTP 200 explicitly retryable partial failure recovers without a second load',
    () async {
      var attempts = 0;
      final repository = DanmakuRepository(
        officialClient: MockClient((_) async {
          attempts++;
          return _jsonResponse({
            'sources': [
              {'provider': 'Zeluna', 'available': true},
              {
                'provider': '弹弹play',
                'available': attempts > 1,
                'error_code': attempts == 1 ? 'timeout' : null,
                'retryable': attempts == 1,
              },
            ],
            'comments': [
              {
                'id': 'community',
                'provider': 'Zeluna',
                'text': 'community',
                'time_seconds': 2,
                'color': 16777215,
              },
              if (attempts > 1)
                {
                  'id': 'external',
                  'provider': '弹弹play',
                  'text': 'recovered',
                  'time_seconds': 1,
                  'color': 16777215,
                },
            ],
          });
        }),
      );
      addTearDown(repository.close);
      final result = await repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
      );
      expect(result.comments.map((c) => c.text), ['recovered', 'community']);
      expect(attempts, 2);
    },
  );

  testWidgets(
    'official retries and anonymous fallback share the eight second budget',
    (tester) async {
      final pending = Completer<http.Response>();
      final start = tester.binding.clock.now();
      var attempts = 0;
      final observed = <http.Request>[];
      final repository = DanmakuRepository(
        stopwatchFactory: () =>
            _TestStopwatch(() => tester.binding.clock.now().difference(start)),
        officialTokenProvider: () async => 'fixture-token',
        officialClient: MockClient((request) async {
          attempts++;
          observed.add(request);
          if (attempts == 1) {
            await Future<void>.delayed(const Duration(seconds: 3));
            return http.Response('', 401);
          }
          if (attempts == 2) {
            await Future<void>.delayed(const Duration(seconds: 3));
            return http.Response('', 503);
          }
          return pending.future;
        }),
      );
      addTearDown(repository.close);
      DanmakuTimeline? result;
      final future = repository
          .timelineForEpisode(
            _subject,
            _episode,
            const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
          )
          .then((value) => result = value);
      await tester.pump();
      expect(attempts, 1);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(attempts, 2, reason: '${observed.map((r) => r.url.path)}');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(attempts, 3);
      await tester.pump(const Duration(milliseconds: 1499));
      expect(result, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        result,
        isNotNull,
        reason: 'all requests must settle at eight seconds',
      );
      expect(
        result!.sources.every((s) => s is TransientDanmakuFailure),
        isTrue,
      );
      await future;
      pending.complete(http.Response('', 503));
      await tester.pump(const Duration(seconds: 20));
      expect(attempts, 3, reason: 'expiry must not schedule another retry');
      expect(observed.map((r) => r.url.path), [
        '/api/v3/danmaku/mine',
        '/api/v3/danmaku',
        '/api/v3/danmaku',
      ]);
      expect(observed.first.headers['authorization'], 'Bearer fixture-token');
      expect(
        observed.skip(1).every((r) => !r.headers.containsKey('authorization')),
        isTrue,
      );
    },
  );

  test('only transport failures carry transient source metadata', () async {
    for (final error in [
      TimeoutException('offline'),
      http.ClientException('connection reset'),
      const FormatException('malformed'),
      const NetworkSecurityException('blocked'),
    ]) {
      final repository = DanmakuRepository(
        officialClient: MockClient((_) async => throw error),
      );
      addTearDown(repository.close);
      final timeline = await repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
      );
      expect(timeline.sources, isNotEmpty);
      expect(
        timeline.sources.every((s) => s is TransientDanmakuFailure),
        error is TimeoutException || error is http.ClientException,
        reason: '${error.runtimeType}',
      );
    }
  });

  test(
    'transient official failure retries before returning an empty timeline',
    () async {
      var attempts = 0;
      final repository = DanmakuRepository(
        officialClient: MockClient((_) async {
          attempts++;
          if (attempts == 1) throw http.ClientException('network unavailable');
          if (attempts == 2) throw TimeoutException('request timed out');
          return _jsonResponse({
            'comments': [
              {
                'id': 'live-retry',
                'provider': '弹弹play',
                'text': '自动恢复',
                'time_seconds': 1,
                'color': 16777215,
                'mode': 'scroll',
              },
            ],
            'sources': [
              {'provider': '弹弹play', 'available': true, 'comment_count': 1},
            ],
          });
        }),
      );
      addTearDown(repository.close);
      final first = repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
      );
      final shared = repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
      );
      expect(identical(first, shared), isTrue);
      final timeline = await first;
      expect(timeline.comments.single.text, '自动恢复');
      expect(attempts, 3);
    },
  );

  test(
    'official transient retry is bounded and never retries denied requests',
    () async {
      for (final status in [503, 403, 429]) {
        var attempts = 0;
        final repository = DanmakuRepository(
          officialClient: MockClient((_) async {
            attempts++;
            return http.Response('', status);
          }),
        );
        addTearDown(repository.close);
        final timeline = await repository.timelineForEpisode(
          _subject,
          _episode,
          const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
        );
        expect(timeline.comments, isEmpty);
        expect(attempts, status == 503 ? 3 : 1);
      }
    },
  );

  test(
    'official failure remains visible and cannot poison a mixed timeline cache',
    () async {
      var now = DateTime(2026, 9, 8);
      var attempts = 0;
      final repository = DanmakuRepository(
        now: () => now,
        officialClient: MockClient((request) async {
          attempts++;
          expect(
            request.url.queryParameters['episode_key'],
            'v1|bangumi:1|episode:1',
          );
          if (attempts == 1) return http.Response('private error body', 422);
          return _jsonResponse({
            'comments': [],
            'sources': [
              {'provider': 'Zeluna', 'available': true},
              {'provider': '弹弹play', 'available': true, 'comment_count': 0},
            ],
          });
        }),
        client: MockClient(
          (_) async => _jsonResponse([
            {'time': 1, 'text': '其它来源的弹幕'},
          ]),
        ),
      );
      addTearDown(repository.close);
      const settings = ExternalServiceSettings(
        bilibiliDanmakuEnabled: false,
        customDanmakuEnabled: true,
        customDanmakuEndpoint: 'https://danmaku.example/comments',
      );
      final failed = await repository.timelineForEpisode(
        _subject,
        _episode,
        settings,
      );
      expect(failed.comments, isNotEmpty);
      expect(
        failed.sources.where((s) => s.provider == '弹弹play').single.available,
        isFalse,
      );
      expect(failed.sources.first.message, contains('422'));
      expect(failed.sources.first.message, isNot(contains('private')));
      await repository.timelineForEpisode(_subject, _episode, settings);
      expect(
        attempts,
        1,
        reason: 'brief failure cache prevents request storms',
      );
      now = now.add(const Duration(seconds: 31));
      final recovered = await repository.timelineForEpisode(
        _subject,
        _episode,
        settings,
      );
      expect(
        attempts,
        2,
        reason: 'partial failure must not be cached for 30 minutes',
      );
      expect(
        recovered.sources.where((s) => s.provider == '弹弹play').single.available,
        isTrue,
      );
      await repository.timelineForEpisode(
        _subject,
        _episode,
        settings,
        forceRefresh: true,
      );
      expect(attempts, 3, reason: 'user retry bypasses a cached result');
    },
  );

  test(
    'official network errors show enabled sources without leaking errors',
    () async {
      final repository = DanmakuRepository(
        officialClient: MockClient(
          (_) async => throw Exception('private-token'),
        ),
      );
      addTearDown(repository.close);
      final timeline = await repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(bilibiliDanmakuEnabled: false),
      );
      expect(timeline.sources.map((s) => s.provider), ['Zeluna', '弹弹play']);
      expect(timeline.sources.every((s) => !s.available), isTrue);
      expect(timeline.sources.first.message, isNot(contains('private-token')));
    },
  );
  test('Bilibili XML parses real time, mode, color and decoded text', () {
    final comments = parseBilibiliDanmakuXml('''
<i>
  <d p="1.25,1,25,16711680,0,0,user,9001">滚动 &amp; 文本</d>
  <d p="2.5,5,25,65280,0,0,user,9002">顶部弹幕</d>
  <d p="3,4,25,255,0,0,user,9003">底部弹幕</d>
</i>
''');

    expect(comments, hasLength(3));
    expect(comments[0].time, const Duration(milliseconds: 1250));
    expect(comments[0].mode, DanmakuMode.scroll);
    expect(comments[0].color, 0xFF0000);
    expect(comments[0].text, '滚动 & 文本');
    expect(comments[1].mode, DanmakuMode.top);
    expect(comments[1].color, 0x00FF00);
    expect(comments[2].mode, DanmakuMode.bottom);
    expect(comments[2].color, 0x0000FF);
  });

  test('Bilibili WBI matching loads episode XML and caches the timeline', () async {
    var requests = 0;
    final paths = <String>[];
    final repository = DanmakuRepository(
      officialClient: MockClient((_) async => _jsonResponse({'comments': []})),
      client: MockClient((request) async {
        requests++;
        paths.add(request.url.path);
        if (request.url.path == '/x/web-interface/nav') {
          return _jsonResponse({
            'code': -101,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz123456.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/654321zyxwvutsrqponmlkjihgfedcba.png',
              },
            },
          });
        }
        if (request.url.path == '/x/web-interface/wbi/search/type') {
          expect(request.url.queryParameters['search_type'], 'media_bangumi');
          expect(request.url.queryParameters['wts'], isNotEmpty);
          expect(
            request.url.queryParameters['w_rid'],
            matches(RegExp(r'^[0-9a-f]{32}$')),
          );
          return _jsonResponse({
            'code': 0,
            'data': {
              'result': [
                {
                  'season_id': 42,
                  'title': '<em>葬送的芙莉莲</em>',
                  'org_title': '葬送のフリーレン',
                },
              ],
            },
          });
        }
        if (request.url.path == '/pgc/view/web/season') {
          expect(request.url.queryParameters['season_id'], '42');
          return _jsonResponse({
            'code': 0,
            'result': {
              'title': '葬送的芙莉莲',
              'episodes': [
                {'title': '1', 'long_title': '冒险的结束', 'cid': 777},
              ],
            },
          });
        }
        if (request.url.path == '/x/v1/dm/list.so') {
          expect(request.url.queryParameters['oid'], '777');
          final compressed = ZLibCodec(raw: true).encode(
            utf8.encode('<i><d p="9.5,1,25,16777215,0,0,u,1">真实弹幕</d></i>'),
          );
          return http.Response.bytes(
            compressed,
            200,
            headers: const {
              'content-type': 'text/xml; charset=utf-8',
              'content-encoding': 'deflate',
            },
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final first = await repository.timelineForEpisode(
      _subject,
      _episode,
      const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
    );
    final afterFirstLoad = requests;
    final second = await repository.timelineForEpisode(
      _subject,
      _episode,
      const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
    );

    expect(paths, contains('/x/web-interface/wbi/search/type'));
    expect(
      first.sources.where((s) => s.provider == 'Bilibili').single.available,
      isTrue,
      reason:
          '${first.sources.where((s) => s.provider == 'Bilibili').single.message}; paths=$paths',
    );
    expect(
      first.sources.where((s) => s.provider == 'Bilibili').single.episodeId,
      '777',
    );
    expect(first.comments.single.provider, 'Bilibili');
    expect(first.comments.single.text, '真实弹幕');
    expect(second.comments.single.text, '真实弹幕');
    expect(requests, afterFirstLoad);
  });

  test('Bilibili 412 keeps server-provided dandanplay comments', () async {
    final paths = <String>[];
    late final MockClient client;
    client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.host == 'api.zeluna.test') {
        expect(request.url.path, '/api/v3/danmaku');
        expect(request.url.queryParameters['subject_key'], 'bangumi:1');
        expect(request.url.queryParameters['episode_key'], isNotEmpty);
        expect(request.url.queryParameters['title'], '葬送的芙莉莲');
        expect(request.url.queryParameters['original_title'], 'Frieren');
        expect(request.url.queryParameters['episode_number'], '1');
        expect(request.url.queryParameters['media_type'], 'anime');
        expect(request.url.queryParameters['include_dandanplay'], 'true');
        return _jsonResponse({
          'comments': [
            {
              'id': '41',
              'provider': 'Zeluna',
              'time_seconds': 20,
              'mode': 'scroll',
              'color': 0xFFFFFF,
              'text': 'Zeluna 用户弹幕',
              'author': {'display_name': '用户', 'is_mine': false},
            },
            {
              'id': 'dandanplay:12345:88',
              'provider': '弹弹play',
              'time_seconds': 12.5,
              'mode': 'top',
              'color': 0xFFFF00,
              'text': '备用真实弹幕',
              'author': {'display_name': '弹幕用户', 'is_mine': false},
            },
          ],
          'sources': [
            {
              'provider': 'Zeluna',
              'title': '葬送的芙莉莲',
              'episode_title': '第 1 集',
              'episode_id': 'episode:v2:first',
              'comment_count': 1,
              'available': true,
            },
            {
              'provider': '弹弹play',
              'title': '葬送的芙莉莲',
              'episode_title': '第1话 冒险的结束',
              'episode_id': '12345',
              'comment_count': 1,
              'available': true,
            },
          ],
          'next_cursor': null,
        });
      }
      if (request.url.path == '/x/web-interface/nav') {
        return _jsonResponse({
          'code': -101,
          'data': {
            'wbi_img': {
              'img_url':
                  'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz123456.png',
              'sub_url':
                  'https://i0.hdslb.com/bfs/wbi/654321zyxwvutsrqponmlkjihgfedcba.png',
            },
          },
        });
      }
      if (request.url.path == '/x/web-interface/wbi/search/type') {
        return http.Response('<div class="error-container">412</div>', 412);
      }
      return http.Response('not found', 404);
    });
    final repository = DanmakuRepository(
      client: client,
      officialClient: client,
      officialBaseUrl: 'https://api.zeluna.test',
    );

    final timeline = await repository.timelineForEpisode(
      _subject,
      _episode,
      const ExternalServiceSettings(),
    );

    expect(paths, contains('/api/v3/danmaku'));
    expect(paths, contains('/x/web-interface/wbi/search/type'));
    expect(timeline.sources.map((item) => item.provider), [
      'Zeluna',
      '弹弹play',
      'Bilibili',
    ]);
    expect(timeline.sources.last.message, contains('风控'));
    expect(timeline.comments.map((item) => item.provider), [
      '弹弹play',
      'Zeluna',
    ]);
    expect(timeline.comments.first.mode, DanmakuMode.top);
    expect(timeline.comments.first.color, 0xFFFF00);
    expect(timeline.comments.first.text, '备用真实弹幕');
  });

  test('official and public danmaku sources are merged', () async {
    final paths = <String>[];
    late final MockClient client;
    client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.host == 'api.zeluna.test') {
        expect(request.url.path, '/api/v3/danmaku');
        expect(request.url.queryParameters['subject_key'], 'bangumi:1');
        expect(request.url.queryParameters['episode_key'], isNotEmpty);
        return _jsonResponse({
          'comments': [
            {
              'id': '41',
              'subject_key': 'bangumi:1',
              'episode_key': 'episode:v2:first',
              'time_seconds': 9.5,
              'mode': 'scroll',
              'color': 0xFFFFFF,
              'text': 'B 站公开弹幕',
              'created_at': 1,
              'author': {'display_name': '同步用户', 'is_mine': false},
            },
            {
              'id': '42',
              'subject_key': 'bangumi:1',
              'episode_key': 'episode:v2:first',
              'time_seconds': 20,
              'mode': 'top',
              'color': 0xFFCC00,
              'text': 'Zeluna 用户弹幕',
              'created_at': 1,
              'author': {'display_name': '用户', 'is_mine': false},
            },
          ],
          'next_cursor': null,
        });
      }
      if (request.url.path == '/x/web-interface/nav') {
        return _jsonResponse({
          'code': -101,
          'data': {
            'wbi_img': {
              'img_url':
                  'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz123456.png',
              'sub_url':
                  'https://i0.hdslb.com/bfs/wbi/654321zyxwvutsrqponmlkjihgfedcba.png',
            },
          },
        });
      }
      if (request.url.path == '/x/web-interface/wbi/search/type') {
        return _jsonResponse({
          'code': 0,
          'data': {
            'result': [
              {'season_id': 42, 'title': '葬送的芙莉莲', 'org_title': ''},
            ],
          },
        });
      }
      if (request.url.path == '/pgc/view/web/season') {
        return _jsonResponse({
          'code': 0,
          'result': {
            'title': '葬送的芙莉莲',
            'episodes': [
              {'title': '1', 'long_title': '冒险的结束', 'cid': 777},
            ],
          },
        });
      }
      if (request.url.path == '/x/v1/dm/list.so') {
        return http.Response(
          '<i><d p="9.5,1,25,16777215,0,0,u,1">B 站公开弹幕</d></i>',
          200,
          headers: const {'content-type': 'text/xml; charset=utf-8'},
        );
      }
      return http.Response('not found', 404);
    });
    final repository = DanmakuRepository(
      client: client,
      officialClient: client,
      officialBaseUrl: 'https://api.zeluna.test',
    );

    final timeline = await repository.timelineForEpisode(
      _subject,
      _episode,
      const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
    );

    expect(paths, contains('/api/v3/danmaku'));
    expect(timeline.sources.map((item) => item.provider), [
      'Zeluna',
      'Bilibili',
    ]);
    expect(timeline.comments.map((item) => item.text), [
      'B 站公开弹幕',
      'Zeluna 用户弹幕',
    ]);
    expect(timeline.comments.first.provider, 'Zeluna');
  });

  test(
    'unrelated Bilibili result is rejected instead of attaching wrong comments',
    () async {
      var seasonRequested = false;
      final repository = DanmakuRepository(
        client: MockClient((request) async {
          if (request.url.path == '/x/web-interface/nav') {
            return _jsonResponse({
              'code': -101,
              'data': {
                'wbi_img': {
                  'img_url':
                      'https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz123456.png',
                  'sub_url':
                      'https://i0.hdslb.com/bfs/wbi/654321zyxwvutsrqponmlkjihgfedcba.png',
                },
              },
            });
          }
          if (request.url.path == '/x/web-interface/wbi/search/type') {
            return _jsonResponse({
              'code': 0,
              'data': {
                'result': [
                  {'season_id': 99, 'title': '完全无关的电视剧', 'org_title': ''},
                ],
              },
            });
          }
          if (request.url.path == '/pgc/view/web/season') {
            seasonRequested = true;
          }
          return http.Response('not found', 404);
        }),
      );

      final timeline = await repository.timelineForEpisode(
        _subject,
        _episode,
        const ExternalServiceSettings(dandanplayDanmakuEnabled: false),
      );

      expect(seasonRequested, isFalse);
      expect(timeline.comments, isEmpty);
      expect(
        timeline.sources
            .where((s) => s.provider == 'Bilibili')
            .single
            .available,
        isFalse,
      );
    },
  );

  test(
    'timeline window follows progress and respects mode and keyword filters',
    () {
      const comments = [
        DanmakuComment(
          id: '1',
          provider: 'Bilibili',
          time: Duration(seconds: 1),
          mode: DanmakuMode.scroll,
          color: 0xFFFFFF,
          text: '保留',
        ),
        DanmakuComment(
          id: '2',
          provider: 'Bilibili',
          time: Duration(milliseconds: 1200),
          mode: DanmakuMode.top,
          color: 0xFFFFFF,
          text: '顶部',
        ),
        DanmakuComment(
          id: '3',
          provider: 'Bilibili',
          time: Duration(milliseconds: 1400),
          mode: DanmakuMode.bottom,
          color: 0xFFFFFF,
          text: '剧透内容',
        ),
        DanmakuComment(
          id: '4',
          provider: 'Bilibili',
          time: Duration(seconds: 3),
          mode: DanmakuMode.scroll,
          color: 0xFFFFFF,
          text: '未来弹幕',
        ),
      ];

      final visible = visibleDanmakuComments(
        comments,
        position: const Duration(seconds: 2),
        settings: const DanmakuSettings(
          enabled: true,
          blockTop: true,
          blockKeywords: ['剧透'],
        ),
      );

      expect(visible.map((item) => item.text), ['保留']);
    },
  );
}

http.Response _jsonResponse(Object value) {
  return http.Response(
    jsonEncode(value),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
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

class _TestStopwatch extends Stopwatch {
  _TestStopwatch(this.readElapsed);
  final Duration Function() readElapsed;
  @override
  Duration get elapsed => readElapsed();
}
