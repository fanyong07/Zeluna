import 'dart:async';
import 'dart:convert';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/skip/episode_skip_controller.dart';
import 'package:anime/src/player/skip/episode_skip_resolver.dart';
import 'package:anime/src/player/skip/skip_segment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Duration sec(num n) => Duration(milliseconds: (1000 * n).round());
DanmakuComment comment(int t, String text, [String? id]) => DanmakuComment(
  id: id ?? '$t:$text',
  provider: 'test',
  time: sec(t),
  mode: DanmakuMode.scroll,
  color: 0,
  text: text,
);
SkipSegment mark(
  SkipSegmentType type,
  num start,
  num end,
  SkipSegmentSource source,
) => SkipSegment(type: type, start: sec(start), end: sec(end), source: source);
http.Response json(Object data) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), 200);

void main() {
  const op = SkipSegmentType.op,
      ed = SkipSegmentType.ed,
      recap = SkipSegmentType.recap;
  const manual = SkipSegmentSource.manual,
      chapter = SkipSegmentSource.chapter,
      online = SkipSegmentSource.aniskip,
      dm = SkipSegmentSource.danmaku;
  final duration = sec(1500);
  final subject = AnimeSubject.fromJson({
    'id': 42,
    'title': '星',
    'originalTitle': 'Hoshi',
    'totalEpisodes': 12,
    'date': '2020-01-01',
  });
  const services = ExternalServiceSettings(
    playbackBackendEnabled: true,
    playbackBackendEndpoint: 'https://api.zeluna.top',
  );
  test(
    'mpv chapters use next boundary, not zero or EOF, and prefer OP over generic Intro',
    () {
      final parsed = parseMpvChapterSkipSegments(
        jsonEncode([
          for (final (name, time) in [
            ('Intro', 0),
            ('OP', 153.35),
            ('Part A', 243.35),
            ('ED', 1370),
            ('Next Preview', 1460),
          ])
            {'title': name, 'time': time},
        ]),
        duration: duration,
      );
      expect(parsed.map((s) => (s.type, s.start, s.end, s.source)), [
        (op, sec(153.35), sec(243.35), chapter),
        (ed, sec(1370), sec(1460), chapter),
      ]);
      expect(parseMpvChapterSkipSegments('bad'), isEmpty);
      expect(
        parseMpvChapterSkipSegments(
          '[{"title":"ED","time":1475}]',
          duration: duration,
        ).single.end,
        duration,
      );
      expect(
        parseMpvChapterSkipSegments(
          '[{"title":"OP","time":0},{"title":"ED","time":10}]',
          duration: duration,
        ),
        isEmpty,
      );
    },
  );
  test(
    'airdrop coordinates and landing bursts require independent votes and a credible cold-open start',
    () {
      for (final votes in [
        [comment(98, '空降 03:12'), comment(101, '跳过op 03：12')],
        [comment(192, '空降成功'), comment(194, '感谢空降')],
        [comment(107, '正片 03:12'), comment(193, '精准空降')],
      ]) {
        final result = analyzeDanmakuSkipSegments([
          comment(97, 'OP来了'),
          comment(99, '片头曲'),
          ...votes,
        ], duration: duration);
        expect(result, [mark(op, 97, 192, dm)]);
      }
      expect(
        analyzeDanmakuSkipSegments([
          comment(1, '空降 03:12'),
          comment(192, '空降成功'),
        ], duration: duration),
        isEmpty,
      );
      expect(
        analyzeDanmakuSkipSegments([
          comment(90, '空降成功'),
          comment(91, '感谢空降'),
        ], duration: duration),
        [mark(op, 0, 90, dm)],
      );
      final duplicate = comment(6, '空降 01:30');
      expect(
        analyzeDanmakuSkipSegments([
          duplicate,
          duplicate,
          comment(920, '片尾'),
          comment(1410, 'ed来了'),
        ], duration: duration),
        isEmpty,
      );
    },
  );
  test(
    'landing confirmation across a bucket boundary retains the explicit coordinate',
    () {
      final result = analyzeDanmakuSkipSegments([
        comment(103, '片头曲'),
        comment(106, '空降 03:15'),
        comment(194, '空降成功'),
      ], duration: duration);
      expect(result, [mark(op, 103, 195, dm)]);
    },
  );
  test(
    'disabled or unrecognized backend goes directly to AniList; network failure stays a miss',
    () async {
      for (final config in [
        services.copyWith(playbackBackendEnabled: false),
        services.copyWith(playbackBackendEndpoint: 'https://example.invalid'),
      ]) {
        final hosts = <String>[];
        final repo = EpisodeSkipRepository(
          client: MockClient((r) async {
            hosts.add(r.url.host);
            throw http.ClientException('offline');
          }),
        );
        addTearDown(repo.dispose);
        expect(
          await repo.load(
            subject: subject,
            episodeNumber: 3,
            duration: duration,
            services: config,
          ),
          isEmpty,
        );
        expect(hosts, ['graphql.anilist.co']);
      }
    },
  );
  test(
    'ending cluster preserves post-credits scene and ignores short episodes',
    () {
      final cues = [
        comment(1370, 'ed来了'),
        comment(1373, '片尾曲'),
        comment(1382, '卡点'),
      ];
      expect(analyzeDanmakuSkipSegments(cues, duration: duration), [
        mark(ed, 1370, 1460, dm),
      ]);
      expect(
        analyzeDanmakuSkipSegments(
          [...cues, comment(1447, 'C part')].reversed.toList(),
          duration: duration,
        ),
        [mark(ed, 1370, 1447, dm)],
      );
      expect(
        analyzeDanmakuSkipSegments([
          comment(410, 'ED'),
          comment(412, '卡点'),
          comment(414, '片尾'),
        ], duration: sec(490)),
        isEmpty,
      );
    },
  );
  test(
    'merge resolves each type independently after clipping and validation',
    () {
      final candidates = [
        mark(op, 1, 91, dm),
        mark(op, 2, 92, online),
        mark(op, 3, 93, chapter),
        mark(op, 4, 94, manual),
      ];
      for (var i = 0; i < candidates.length; i++) {
        expect(mergeSkipSegments(candidates.take(i + 1)).single, candidates[i]);
      }
      final result = mergeSkipSegments([
        ...candidates,
        mark(ed, 1380, 1580, online),
        mark(ed, 1499, 1550, manual),
        mark(recap, 1500, 1580, manual),
      ], episodeDuration: duration);
      expect(result, [candidates.last, mark(ed, 1380, 1500, online)]);
      expect(() => result.clear(), throwsUnsupportedError);
      expect(result[0].contains(sec(4)), isTrue);
      expect(result[0].contains(sec(94)), isFalse);
    },
  );
  test(
    'official aggregate receives episode identity and fractional times; no direct queries on hit',
    () async {
      var calls = 0;
      final repo = EpisodeSkipRepository(
        client: MockClient((r) async {
          calls++;
          expect(r.url.host, 'api.zeluna.top');
          expect(r.url.path, '/api/v3/skip-times');
          expect(r.url.queryParameters, {
            'bangumi_id': '42',
            'title': '星',
            'original_title': 'Hoshi',
            'year': '2020',
            'total_episodes': '12',
            'episode_number': '3',
            'episode_length': '1500',
          });
          return json({
            'found': true,
            'segments': [
              {
                'type': 'op',
                'start': 153.35,
                'end': 243.35,
                'source': 'aniskip',
              },
            ],
          });
        }),
      );
      addTearDown(repo.dispose);
      Future<List<SkipSegment>> load() => repo.load(
        subject: subject,
        episodeNumber: 3,
        duration: duration,
        services: services,
      );
      final results = await Future.wait([load(), load()]);
      expect(results.first, [mark(op, 153.35, 243.35, online)]);
      expect(calls, 1);
    },
  );
  test(
    'fallback matches title and year, shares MAL lookup across episodes, caches each episode',
    () async {
      final calls = <String>[];
      final repo = EpisodeSkipRepository(
        client: MockClient((r) async {
          calls.add(r.url.host);
          switch (r.url.host) {
            case 'api.zeluna.top':
              return http.Response('', 503);
            case 'graphql.anilist.co':
              expect(r.method, 'POST');
              expect(jsonDecode(r.body)['variables'], {'search': 'Hoshi'});
              return json({
                'data': {
                  'Page': {
                    'media': [
                      for (final (id, y, title) in [
                        (10, 2010, 'Hoshi'),
                        (20, 2020, 'Hoshi 2'),
                        (30, 2020, 'Hoshi'),
                      ])
                        {
                          'idMal': id,
                          'title': {'romaji': title},
                          'startDate': {'year': y},
                          'episodes': 12,
                        },
                    ],
                  },
                },
              });
            case 'api.aniskip.com':
              expect(
                r.url.path,
                anyOf('/v2/skip-times/30/3', '/v2/skip-times/30/4'),
              );
              expect(r.url.queryParametersAll['types'], [
                'op',
                'ed',
                'mixed-op',
                'mixed-ed',
                'recap',
              ]);
              expect(r.url.queryParameters['episodeLength'], '1500');
              return json({
                'found': true,
                'results': [
                  for (final (type, start, end) in [
                    ('mixed-op', 153, 243),
                    ('mixed-ed', 1370, 1460),
                    ('recap', 0, 60),
                  ])
                    {
                      'skipType': type,
                      'interval': {'startTime': start, 'endTime': end},
                    },
                ],
              });
            default:
              fail('unexpected host ${r.url.host}');
          }
        }),
      );
      addTearDown(repo.dispose);
      Future<List<SkipSegment>> load(int ep) => repo.load(
        subject: subject,
        episodeNumber: ep,
        duration: duration,
        services: services,
      );
      for (final result in await Future.wait([load(3), load(3), load(4)])) {
        expect(result, [
          mark(recap, 0, 60, online),
          mark(op, 153, 243, online),
          mark(ed, 1370, 1460, online),
        ]);
      }
      expect(calls.where((h) => h == 'graphql.anilist.co'), hasLength(1));
      expect(calls, hasLength(5));
    },
  );
  test(
    'episode change rejects late metadata and recomputes duration-dependent last chapter',
    () async {
      final response = Completer<http.Response>();
      final repo = EpisodeSkipRepository(
        client: MockClient((_) => response.future),
      );
      addTearDown(repo.dispose);
      final controller = EpisodeSkipController()..updateDuration(duration);
      addTearDown(controller.dispose);
      final pending = controller.loadOnline(repo, subject, 3, services);
      controller.resetForEpisode();
      controller.updateChapters('[{"title":"ED","time":1370}]');
      expect(controller.segments, isEmpty);
      controller.updateDuration(sec(1460));
      response.complete(
        json({
          'found': true,
          'segments': [
            {'type': 'op', 'start': 5, 'end': 95},
          ],
        }),
      );
      await pending;
      expect(controller.segments.single.type, ed);
      expect(controller.activeSegmentAt(sec(1460)), isNull);
    },
  );
}
