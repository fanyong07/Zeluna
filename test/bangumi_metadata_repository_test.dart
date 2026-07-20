import 'dart:convert';

import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('empty category and tag results stay empty', () async {
    final repository = BangumiMetadataRepository(
      client: MockClient((_) async => _jsonResponse({'data': const []})),
    );

    expect(await repository.subjectsByCategory('missing'), isEmpty);
    expect(await repository.subjectsByTag('missing'), isEmpty);
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
