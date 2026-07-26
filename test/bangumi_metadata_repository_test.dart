import 'dart:convert';

import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('public search and calendar never receive the personal token', () async {
    const token = 'public_endpoint_test_token_abcdefghijklmnopqrstuvwxyz';
    final requests = <http.Request>[];
    final repository = BangumiMetadataRepository(
      accessCredentialProvider: () async =>
          const BangumiAccessCredential(token: token),
      client: MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], isNull);
        if (request.url.path == '/calendar') {
          return _jsonListResponse(const []);
        }
        return _jsonResponse({'data': const []});
      }),
    );

    await repository.searchSubjects(keyword: '测试');
    await repository.weeklySchedule();

    expect(requests.map((item) => item.url.path), [
      '/v0/search/subjects',
      '/calendar',
    ]);
  });

  test('detail endpoints receive a bearer token when configured', () async {
    const token = 'detail_endpoint_test_token_abcdefghijklmnopqrstuvwxyz';
    final requests = <http.Request>[];
    final repository = BangumiMetadataRepository(
      accessCredentialProvider: () async =>
          const BangumiAccessCredential(token: token),
      client: MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer $token');
        return _detailResponse(request, subjectId: 321);
      }),
    );

    final detail = await repository.detail(321);

    expect(detail.subject.id, 321);
    expect(requests, hasLength(5));
  });

  test(
    'rejected bearer retries detail anonymously and marks it invalid',
    () async {
      const token = 'rejected_detail_test_token_abcdefghijklmnopqrstuvwxyz';
      var tokenRejected = false;
      var rejectionCount = 0;
      final requests = <http.Request>[];
      final repository = BangumiMetadataRepository(
        accessCredentialProvider: () async =>
            tokenRejected ? null : const BangumiAccessCredential(token: token),
        onAccessTokenRejected: (_) async {
          tokenRejected = true;
          rejectionCount++;
        },
        client: MockClient((request) async {
          requests.add(request);
          if (request.headers['authorization'] != null) {
            return http.Response('', 401);
          }
          return _detailResponse(request, subjectId: 654);
        }),
      );

      final detail = await repository.detail(654);

      expect(detail.subject.id, 654);
      expect(rejectionCount, 1);
      expect(
        requests.any((item) => item.headers['authorization'] != null),
        isTrue,
      );
      expect(
        requests.any((item) => item.headers['authorization'] == null),
        isTrue,
      );
    },
  );

  test(
    'forbidden detail falls back anonymously without disabling the token',
    () async {
      const token = 'forbidden_detail_test_token_abcdefghijklmnopqrstuvwxyz';
      var rejectionCount = 0;
      final requests = <http.Request>[];
      final repository = BangumiMetadataRepository(
        accessCredentialProvider: () async =>
            const BangumiAccessCredential(token: token),
        onAccessTokenRejected: (_) async => rejectionCount++,
        client: MockClient((request) async {
          requests.add(request);
          if (request.headers['authorization'] != null) {
            return http.Response('', 403);
          }
          final subjectId = request.url.pathSegments.length > 2
              ? int.parse(request.url.pathSegments[2])
              : int.parse(request.url.queryParameters['subject_id']!);
          return _detailResponse(request, subjectId: subjectId);
        }),
      );

      expect((await repository.detail(700)).subject.id, 700);
      expect((await repository.detail(701)).subject.id, 701);

      expect(rejectionCount, 0);
      expect(
        requests.where((item) => item.headers['authorization'] != null),
        hasLength(10),
      );
      expect(
        requests.where((item) => item.headers['authorization'] == null),
        hasLength(10),
      );
    },
  );

  test(
    'rate limit blocks follow-up requests until retry-after expires',
    () async {
      var now = DateTime.utc(2026, 7, 23, 12);
      var rateLimited = true;
      final requests = <http.Request>[];
      final repository = BangumiMetadataRepository(
        clock: () => now,
        client: MockClient((request) async {
          requests.add(request);
          if (rateLimited) {
            return http.Response('', 429, headers: {'retry-after': '60'});
          }
          return _jsonResponse({'data': const []});
        }),
      );

      await expectLater(
        repository.detail(702),
        throwsA(isA<BangumiRateLimitException>()),
      );
      final requestsAtLimit = requests.length;

      await expectLater(
        repository.searchSubjects(keyword: '测试'),
        throwsA(isA<BangumiRateLimitException>()),
      );
      expect(requests, hasLength(requestsAtLimit));

      rateLimited = false;
      now = now.add(const Duration(seconds: 61));
      expect(await repository.searchSubjects(keyword: '测试'), isEmpty);
      expect(requests, hasLength(requestsAtLimit + 1));
    },
  );

  test(
    'token validation uses v0 me and returns only account identity',
    () async {
      const token = 'validation_test_token_abcdefghijklmnopqrstuvwxyz';
      final repository = BangumiMetadataRepository(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v0/me');
          expect(request.headers['authorization'], 'Bearer $token');
          return _jsonResponse({
            'id': 99,
            'username': 'tester',
            'nickname': '令牌测试账号',
          });
        }),
      );

      final result = await repository.validateAccessToken(token);

      expect(result.isValid, isTrue);
      expect(result.userId, '99');
      expect(result.username, 'tester');
      expect(result.displayName, '令牌测试账号');
    },
  );

  test(
    'token validation maps unauthorized response to a safe message',
    () async {
      final repository = BangumiMetadataRepository(
        client: MockClient((_) async => http.Response('', 401)),
      );

      final result = await repository.validateAccessToken(
        'invalid_test_token_abcdefghijklmnopqrstuvwxyz',
      );

      expect(result.isValid, isFalse);
      expect(result.message, contains('无效'));
    },
  );

  test(
    'subject title uses an explicit mainland Chinese alias from infobox',
    () async {
      final repository = BangumiMetadataRepository(
        client: MockClient(
          (_) async => _jsonResponse({
            'data': [
              {
                'id': 428735,
                'name': "BanG Dream! It's MyGO!!!!!",
                'name_cn': 'BanG Dream! 少女乐团派对（旧译）',
                'summary': '「能一辈子和我搞乐队吗？」迷茫也无所谓，迷茫也要前进。',
                'date': '2023-06-29',
                'platform': 'TV',
                'total_episodes': 13,
                'meta_tags': ['动画'],
                'infobox': [
                  {
                    'key': '别名',
                    'value': [
                      {'k': '大陆版权译', 'v': '迷途之子!!!!!'},
                      {'v': 'BanG Dream! 迷途之子!!!!!'},
                    ],
                  },
                ],
                'tags': const [],
                'rating': const {},
              },
            ],
          }),
        ),
      );

      final subject = (await repository.searchSubjects(keyword: 'MyGO')).single;

      expect(subject.title, '迷途之子!!!!!');
      expect(subject.originalTitle, "BanG Dream! It's MyGO!!!!!");
    },
  );

  test('subject parsing extracts Chinese summary blocks and tags', () async {
    final repository = BangumiMetadataRepository(
      client: MockClient(
        (_) async => _jsonResponse({
          'data': [
            {
              'id': 1,
              'name': '魔法少女まどか☆マギカ',
              'name_cn': '魔法少女小圆',
              'summary':
                  '大好きな家族がいて、親友がいて、時には笑い、時には泣く。\n\n'
                  '[中文简介]\n普通的初中生鹿目圆，与一场改变命运的相遇。',
              'tags': [
                {'name': 'Fantasy', 'count': 20},
                {'name': '魔法少女', 'count': 18},
                {'name': 'まどか', 'count': 16},
                {'name': 'SHAFT', 'count': 14},
              ],
              'meta_tags': ['动画'],
              'rating': const {},
            },
            {
              'id': 2,
              'name': 'ダンジョン飯',
              'name_cn': '迷宫饭',
              'summary':
                  '为了救回妹妹，冒险者们一边深入迷宫，一边研究如何烹饪魔物。\n\n'
                  '[简介原文]\nダンジョンの奥深くで、妹が赤竜に喰われた。',
              'tags': const [],
              'meta_tags': ['动画'],
              'rating': const {},
            },
            {
              'id': 3,
              'name': '日本語だけ',
              'name_cn': '仅日文简介测试',
              'summary': '大好きな家族がいて、親友がいて、時には笑い、時には泣く。',
              'tags': const [],
              'meta_tags': ['动画'],
              'rating': const {},
            },
            {
              'id': 4,
              'name': '混合简介テスト',
              'name_cn': '无标记双语简介测试',
              'summary':
                  '少女为了找回失去的记忆，与伙伴们踏上跨越大陆的漫长旅程。'
                  '旅途中她逐渐理解勇气、友情与选择的意义。'
                  '物語はここから始まる。',
              'tags': const [],
              'meta_tags': ['动画'],
              'rating': const {},
            },
          ],
        }),
      ),
    );

    final subjects = await repository.searchSubjects(keyword: 'test');

    expect(subjects[0].summary, '普通的初中生鹿目圆，与一场改变命运的相遇。');
    expect(subjects[0].tags.map((item) => item.name), ['奇幻', '魔法少女']);
    expect(subjects[1].summary, '为了救回妹妹，冒险者们一边深入迷宫，一边研究如何烹饪魔物。');
    expect(subjects[2].summary, '暂无中文简介。');
    expect(
      subjects[3].summary,
      '少女为了找回失去的记忆，与伙伴们踏上跨越大陆的漫长旅程。 '
      '旅途中她逐渐理解勇气、友情与选择的意义。',
    );
  });

  test(
    'translated tag queries with its Bangumi alias and keeps Chinese keyword',
    () async {
      final requests = <http.Request>[];
      final repository = BangumiMetadataRepository(
        client: MockClient((request) async {
          requests.add(request);
          return _jsonResponse({'data': const []});
        }),
      );

      await repository.subjectsByTag('奇幻');

      expect(requests, hasLength(3));
      for (final request in requests) {
        expect(request.method, 'POST');
        expect(request.url.path, '/v0/search/subjects');
        expect(request.url.queryParameters, {'limit': '20', 'offset': '0'});
      }
      final payloads = requests
          .map((request) => jsonDecode(request.body) as Map<String, dynamic>)
          .toList();
      final filtered = payloads
          .where((payload) => payload['keyword'] == '')
          .map((payload) => (payload['filter'] as Map)['tag'])
          .toSet();
      expect(filtered, {
        ['奇幻'],
        ['Fantasy'],
      });
      final keyword = payloads.singleWhere(
        (payload) => payload['keyword'] == '奇幻',
      );
      expect(keyword['sort'], 'match');
      expect(keyword['filter'], {
        'type': [2],
      });
    },
  );

  test(
    'translated category queries tag and meta tag aliases with Chinese fallback',
    () async {
      final requests = <http.Request>[];
      final repository = BangumiMetadataRepository(
        client: MockClient((request) async {
          requests.add(request);
          return _jsonResponse({'data': const []});
        }),
      );

      await repository.subjectsByCategory('原创动画录像');

      expect(requests, hasLength(5));
      for (final request in requests) {
        expect(request.method, 'POST');
        expect(request.url.path, '/v0/search/subjects');
        expect(request.url.queryParameters, {'limit': '20', 'offset': '0'});
      }
      final payloads = requests
          .map((request) => jsonDecode(request.body) as Map<String, dynamic>)
          .toList();
      final tagFilters = payloads
          .where((payload) => (payload['filter'] as Map).containsKey('tag'))
          .map((payload) => (payload['filter'] as Map)['tag'])
          .toSet();
      expect(tagFilters, {
        ['原创动画录像'],
        ['OVA'],
      });
      final metaTagFilters = payloads
          .where(
            (payload) => (payload['filter'] as Map).containsKey('meta_tags'),
          )
          .map((payload) => (payload['filter'] as Map)['meta_tags'])
          .toSet();
      expect(metaTagFilters, {
        ['原创动画录像'],
        ['OVA'],
      });
      final keyword = payloads.singleWhere(
        (payload) => payload['keyword'] == '原创动画录像',
      );
      expect(keyword['sort'], 'match');
      expect(keyword['filter'], {
        'type': [2],
      });
    },
  );

  test('empty category and tag results stay empty', () async {
    final repository = BangumiMetadataRepository(
      client: MockClient((_) async => _jsonResponse({'data': const []})),
    );

    expect(await repository.subjectsByCategory('missing'), isEmpty);
    expect(await repository.subjectsByTag('missing'), isEmpty);
  });

  test('fallback covers use stable Bangumi subject image endpoints', () {
    final feed = BangumiMetadataRepository().fallbackHomeFeed();
    final subjects = <int, String?>{
      for (final subject in feed.index) subject.id: subject.coverUrl,
    };

    expect(subjects.keys, {328609, 400602, 395378});
    for (final entry in subjects.entries) {
      final uri = Uri.parse(entry.value!);
      expect(uri.scheme, 'https');
      expect(uri.host, 'api.bgm.tv');
      expect(uri.path, '/v0/subjects/${entry.key}/image');
      expect(uri.queryParameters, {'type': 'common'});
    }

    final subjectCovers = subjects.values.toSet();
    final artworkUrls = <String?>[
      ...feed.categories.map((item) => item.imageUrl),
      ...feed.tags.map((item) => item.imageUrl),
    ];
    expect(artworkUrls, everyElement(isIn(subjectCovers)));
  });

  test('subject covers prefer common size and fall back to large', () async {
    final repository = BangumiMetadataRepository(
      client: MockClient(
        (_) async => _jsonResponse({
          'data': [
            {
              'id': 1,
              'name': 'Common Cover',
              'name_cn': '常用尺寸封面',
              'images': {
                'common': 'https://images.example/common.jpg',
                'large': 'https://images.example/large.jpg',
              },
              'meta_tags': ['动画'],
              'tags': const [],
              'rating': const {},
            },
            {
              'id': 2,
              'name': 'Large Cover',
              'name_cn': '大尺寸封面兜底',
              'images': {'large': 'https://images.example/fallback.jpg'},
              'meta_tags': ['动画'],
              'tags': const [],
              'rating': const {},
            },
          ],
        }),
      ),
    );

    final subjects = await repository.searchSubjects(keyword: 'cover');

    expect(subjects.map((item) => item.coverUrl), [
      'https://images.example/common.jpg',
      'https://images.example/fallback.jpg',
    ]);
  });

  test(
    'weekly schedule uses the calendar endpoint and preserves Chinese fields',
    () async {
      var requestCount = 0;
      final repository = BangumiMetadataRepository(
        client: MockClient((request) async {
          requestCount++;
          expect(request.method, 'GET');
          expect(request.url.path, '/calendar');
          return _jsonListResponse([
            {
              'weekday': {'id': 7, 'cn': '星期日'},
              'items': [
                {
                  'id': 1001,
                  'name': 'Sunday Original',
                  'name_cn': '周日中文番剧',
                  'summary': '这是来自 Bangumi 的中文简介。',
                  'air_date': '2026-07-19',
                  'images': {'large': 'https://example.com/sunday.jpg'},
                  'rating': {'score': 8.7, 'total': 1234},
                  'rank': 88,
                },
              ],
            },
            {
              'weekday': {'id': 2, 'cn': '星期二'},
              'items': [
                {
                  'id': 1002,
                  'name': 'Tuesday Original',
                  'name_cn': '周二中文番剧',
                  'summary': '周二中文简介。',
                  'air_date': '2026-07-21',
                  'images': {'common': 'https://example.com/tuesday.jpg'},
                },
              ],
            },
          ]);
        }),
      );

      final schedule = await repository.weeklySchedule();

      expect(requestCount, 1);
      expect(schedule.keys, containsAll(List.generate(7, (index) => index)));
      expect(schedule[0], hasLength(1), reason: 'weekday 7 must map to Sunday');
      expect(schedule[2], hasLength(1));
      final sunday = schedule[0]!.single;
      expect(sunday.title, '周日中文番剧');
      expect(sunday.originalTitle, 'Sunday Original');
      expect(sunday.summary, '这是来自 Bangumi 的中文简介。');
      expect(sunday.date, '2026-07-19');
      expect(sunday.platform, 'TV');
      expect(sunday.source, 'bangumi');
      expect(sunday.ratingRank, 88);
    },
  );

  test('weekly schedule returns empty when calendar fails', () async {
    final repository = BangumiMetadataRepository(
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );

    expect(await repository.weeklySchedule(), isEmpty);
  });

  test(
    'home feed uses a rolling recent window and distinct quality picks',
    () async {
      String? recentFloor;
      final recentDate = _dateText(
        DateTime.now().subtract(const Duration(days: 8)),
      );
      final olderDate = _dateText(
        DateTime.now().subtract(const Duration(days: 90)),
      );
      final recent = [
        _subjectJson(
          1,
          'Recent Action A',
          recentDate,
          'Action',
          'Action Group',
          score: 9.1,
        ),
        _subjectJson(
          2,
          'Recent Comedy B',
          recentDate,
          'Comedy',
          'Comedy Group',
          score: 8.8,
        ),
        _subjectJson(
          3,
          'Recent Sci-Fi C',
          olderDate,
          'Sci-Fi',
          'Sci-Fi Group',
          score: 8.6,
        ),
      ];
      final scored = [
        recent.first,
        _subjectJson(
          4,
          'Scored Action D',
          olderDate,
          'Action',
          'Action Group',
          score: 9.0,
        ),
        _subjectJson(
          5,
          'Scored Comedy E',
          olderDate,
          'Comedy',
          'Comedy Group',
          score: 8.9,
        ),
        _subjectJson(
          6,
          'Scored Sci-Fi F',
          olderDate,
          'Sci-Fi',
          'Sci-Fi Group',
          score: 8.7,
        ),
      ];
      final ranked = [
        recent[1],
        _subjectJson(
          7,
          'Ranked Action G',
          olderDate,
          'Action',
          'Action Group',
          score: 8.5,
        ),
        _subjectJson(
          8,
          'Ranked Music H',
          olderDate,
          'Music',
          'Music Group',
          score: 8.4,
        ),
        _subjectJson(
          9,
          'Ranked Music I',
          olderDate,
          'Music',
          'Music Group',
          score: 8.3,
        ),
      ];
      final repository = BangumiMetadataRepository(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final sort = body['sort']?.toString();
          final filter = (body['filter'] as Map).cast<String, dynamic>();
          final airDates = filter['air_date'];
          if (airDates is List && airDates.isNotEmpty) {
            recentFloor = airDates.first.toString();
          }
          if (request.url.queryParameters['offset'] != '0') {
            return _jsonResponse({'data': const []});
          }
          return _jsonResponse({
            'data': switch (sort) {
              'heat' => recent,
              'score' => scored,
              'rank' => ranked,
              _ => const [],
            },
          });
        }),
      );

      final feed = await repository.homeFeed();
      final floor = DateTime.parse(recentFloor!.substring(2));
      final expectedFloor = DateTime.now().subtract(const Duration(days: 180));
      expect(
        floor.difference(expectedFloor).inDays.abs(),
        lessThanOrEqualTo(1),
      );

      final recentIds = feed.recent.take(18).map((item) => item.id).toSet();
      final recommendedIds = feed.recommended
          .take(18)
          .map((item) => item.id)
          .toSet();
      expect(recentIds.intersection(recommendedIds), isEmpty);
      expect(recentIds, isNot(contains(feed.hero.id)));
      expect(recommendedIds, isNot(contains(feed.hero.id)));

      final allSubjects = [
        feed.hero,
        ...feed.recent,
        ...feed.recommended,
        ...feed.index,
      ];
      expect(allSubjects.every((item) => item.bannerUrl == null), isTrue);
      expect(feed.hero.coverUrl, isNotNull);

      expect(feed.categories.first.count, 9);
      final categoryImages = feed.categories
          .map((category) => category.imageUrl)
          .whereType<String>()
          .toList();
      expect(categoryImages.toSet(), hasLength(categoryImages.length));

      final tagImages = feed.tags
          .map((tag) => tag.imageUrl)
          .whereType<String>()
          .toList();
      expect(tagImages.toSet(), hasLength(tagImages.length));
    },
  );

  test('discovery advances with the server 20-item page size', () async {
    final offsetsBySort = <String, List<int>>{};
    final requestedLimits = <int>[];
    final repository = BangumiMetadataRepository(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final sort = body['sort']!.toString();
        final offset = int.parse(request.url.queryParameters['offset']!);
        final limit = int.parse(request.url.queryParameters['limit']!);
        offsetsBySort.putIfAbsent(sort, () => []).add(offset);
        requestedLimits.add(limit);
        final sortSeed = switch (sort) {
          'heat' => 1000,
          'rank' => 2000,
          'score' => 3000,
          _ => 4000,
        };
        return _jsonResponse({
          'data': [
            _subjectJson(
              sortSeed + offset,
              '$sort $offset',
              '2026-01-01',
              'Animation',
              sort,
              score: 8,
            ),
          ],
          'limit': 20,
          'offset': offset,
          'total': 1000,
        });
      }),
    );

    final subjects = await repository.discoverySubjects();

    expect(subjects, hasLength(12));
    expect(requestedLimits, everyElement(20));
    for (final offsets in offsetsBySort.values) {
      expect(offsets..sort(), [0, 20, 40, 60]);
    }
  });

  test('detail loads every episode page reported by total', () async {
    const subjectId = 123;
    const totalEpisodes = 450;
    final episodeOffsets = <int>[];
    final repository = BangumiMetadataRepository(
      client: MockClient((request) async {
        if (request.url.path == '/v0/subjects/$subjectId') {
          return _jsonResponse(
            _subjectJson(
              subjectId,
              'Long Series',
              '2026-01-01',
              'Animation',
              'Long Running',
              score: 8.5,
            ),
          );
        }
        if (request.url.path == '/v0/episodes') {
          final offset = int.parse(request.url.queryParameters['offset']!);
          final limit = int.parse(request.url.queryParameters['limit']!);
          episodeOffsets.add(offset);
          final count = (totalEpisodes - offset).clamp(0, limit).toInt();
          return _jsonResponse({
            'data': [
              for (var index = 0; index < count; index++)
                _episodeJson(offset + index + 1, subjectId),
            ],
            'total': totalEpisodes,
            'limit': limit,
            'offset': offset,
          });
        }
        return _jsonListResponse(const []);
      }),
    );

    final detail = await repository.detail(subjectId);

    expect(episodeOffsets..sort(), [0, 100, 200, 300, 400]);
    expect(detail.episodes, hasLength(totalEpisodes));
    expect(detail.episodes.first.number, 1);
    expect(detail.episodes.last.number, totalEpisodes);
    expect(detail.subject.totalEpisodes, totalEpisodes);
  });

  test('detail keeps successful episode pages when one page fails', () async {
    const subjectId = 456;
    const totalEpisodes = 250;
    final repository = BangumiMetadataRepository(
      client: MockClient((request) async {
        if (request.url.path == '/v0/subjects/$subjectId') {
          return _jsonResponse(
            _subjectJson(
              subjectId,
              'Partial Pages',
              '2026-01-01',
              'Animation',
              'Tolerance',
              score: 8,
            ),
          );
        }
        if (request.url.path == '/v0/episodes') {
          final offset = int.parse(request.url.queryParameters['offset']!);
          final limit = int.parse(request.url.queryParameters['limit']!);
          if (offset == 100) return http.Response('failed', 503);
          final count = (totalEpisodes - offset).clamp(0, limit).toInt();
          return _jsonResponse({
            'data': [
              for (var index = 0; index < count; index++)
                _episodeJson(offset + index + 1, subjectId),
            ],
            'total': totalEpisodes,
            'limit': limit,
            'offset': offset,
          });
        }
        return _jsonListResponse(const []);
      }),
    );

    final detail = await repository.detail(subjectId);
    final episodeNumbers = detail.episodes.map((item) => item.number).toSet();

    expect(detail.episodes, hasLength(150));
    expect(episodeNumbers, containsAll([1, 100, 201, 250]));
    expect(episodeNumbers, isNot(contains(101)));
  });

  test(
    'detail hides episode titles and descriptions without Chinese',
    () async {
      const subjectId = 789;
      final repository = BangumiMetadataRepository(
        client: MockClient((request) async {
          if (request.url.path == '/v0/subjects/$subjectId') {
            return _jsonResponse({
              ..._subjectJson(
                subjectId,
                '中文番剧',
                '2026-01-01',
                '动画',
                '测试',
                score: 8,
              ),
              'summary': '这是中文简介。',
            });
          }
          if (request.url.path == '/v0/episodes') {
            return _jsonResponse({
              'data': [
                {
                  'id': 1,
                  'subject_id': subjectId,
                  'ep': 1,
                  'name': 'はじまりの日',
                  'name_cn': '',
                  'desc': '新しい物語が始まる。',
                },
                {
                  'id': 2,
                  'subject_id': subjectId,
                  'ep': 2,
                  'name': 'Second Episode',
                  'name_cn': '新的旅程',
                  'desc': '主角踏上了新的旅程。',
                },
                {
                  'id': 3,
                  'subject_id': subjectId,
                  'ep': 3,
                  'name': '再会',
                  'name_cn': '',
                  'desc': '',
                },
              ],
              'total': 3,
              'limit': 100,
            });
          }
          return _jsonListResponse(const []);
        }),
      );

      final detail = await repository.detail(subjectId);

      expect(detail.episodes[0].title, isEmpty);
      expect(detail.episodes[0].description, isEmpty);
      expect(detail.episodes[1].title, '新的旅程');
      expect(detail.episodes[1].description, '主角踏上了新的旅程。');
      expect(detail.episodes[2].title, isEmpty);
    },
  );
}

Map<String, Object?> _subjectJson(
  int id,
  String title,
  String date,
  String category,
  String group, {
  required double score,
}) {
  return {
    'id': id,
    'name_cn': title,
    'name': 'Original $id',
    'summary': 'Summary $id',
    'date': date,
    'platform': 'TV',
    'total_episodes': 12,
    'images': {'large': 'https://example.com/$id.jpg'},
    'meta_tags': ['Animation', category],
    'tags': [
      {'name': 'Popular', 'count': 100},
      {'name': group, 'count': 80 - id},
    ],
    'rating': {'score': score, 'rank': id * 10, 'total': 10000 - id},
  };
}

Map<String, Object?> _episodeJson(int number, int subjectId) {
  return {
    'id': number,
    'subject_id': subjectId,
    'ep': number,
    'sort': number,
    'name_cn': 'Episode $number',
    'name': 'Episode $number',
    'duration': '24:00',
  };
}

http.Response _detailResponse(http.Request request, {required int subjectId}) {
  if (request.url.path == '/v0/subjects/$subjectId') {
    return _jsonResponse(
      _subjectJson(subjectId, '鉴权详情测试', '2026-07-23', '动画', '测试', score: 8),
    );
  }
  if (request.url.path == '/v0/episodes') {
    return _jsonResponse({'data': const [], 'total': 0, 'limit': 100});
  }
  return _jsonListResponse(const []);
}

http.Response _jsonResponse(Map<String, Object?> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _jsonListResponse(List<Object?> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

String _dateText(DateTime date) {
  final month = '${date.month}'.padLeft(2, '0');
  final day = '${date.day}'.padLeft(2, '0');
  return '${date.year}-$month-$day';
}
