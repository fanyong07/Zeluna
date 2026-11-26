import 'dart:convert';

import 'package:anime/src/catalog/catalog_query.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _response(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object?> _raw(
  int id, {
  String date = '2026-10-01',
  String platform = 'TV',
  String region = '日本',
}) => {
  'id': id,
  'name': 'テスト$id',
  'name_cn': '测试番剧$id',
  'date': date,
  'platform': platform,
  'tags': [
    {'name': region},
    {'name': '科幻'},
  ],
};

void main() {
  test(
    'year and genre query the catalogue instead of the recommendation pool',
    () async {
      final seenOffsets = <String>[];
      final repo = BangumiMetadataRepository(
        client: MockClient((request) async {
          expect(request.url.path, '/v0/search/subjects');
          expect(request.headers.containsKey('authorization'), isFalse);
          final body = jsonDecode(request.body) as Map;
          expect(body['filter']['air_date'], ['>=2026-01-01', '<2027-01-01']);
          expect(body['filter']['tag'], ['科幻']);
          expect(body['sort'], 'heat');
          seenOffsets.add(request.url.queryParameters['offset']!);
          final offset = int.parse(seenOffsets.last);
          return _response({
            'total': 45,
            'data': List.generate(
              offset == 40 ? 5 : 20,
              (i) => _raw(offset + i + 1),
            ),
          });
        }),
      );
      addTearDown(repo.close);
      const query = CatalogQuery(
        contentType: SubjectContentType.anime,
        year: 2026,
        genre: '科幻',
      );
      final first = await repo.queryCatalog(query);
      final second = await repo.queryCatalog(query, cursor: first.nextCursor);
      final third = await repo.queryCatalog(query, cursor: second.nextCursor);
      expect(first.subjects, hasLength(20));
      expect(second.subjects.first.id, 21);
      expect(third.subjects, hasLength(5));
      expect(third.hasMore, isFalse);
      expect(seenOffsets, ['0', '20', '40']);
    },
  );

  test(
    'latest uses date ordering and excludes unreleased dates and movies',
    () async {
      final repo = BangumiMetadataRepository(
        clock: () => DateTime(2026, 10, 6),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v0/subjects');
          expect(request.url.queryParameters['sort'], 'date');
          expect(request.url.queryParameters['year'], '2026');
          return _response({
            'total': 4,
            'data': [
              _raw(1, date: '2026-12-01'),
              _raw(2, date: '2026-10-06'),
              _raw(3, date: '2026-10-05'),
              _raw(4, platform: '剧场版'),
            ],
          });
        }),
      );
      addTearDown(repo.close);
      final result = await repo.queryCatalog(
        const CatalogQuery(
          contentType: SubjectContentType.anime,
          sort: CatalogSortMode.latest,
          year: 2026,
        ),
      );
      expect(result.subjects.map((s) => s.id), [2, 3]);
      expect(result.nextCursor, isNull);
    },
  );

  test(
    'filtered-out pages preserve cursor so later languages remain reachable',
    () async {
      final repo = BangumiMetadataRepository(
        client: MockClient((request) async {
          final offset = int.parse(request.url.queryParameters['offset']!);
          return _response({
            'total': 100,
            'data': List.generate(
              20,
              (i) => _raw(offset + i + 1, region: offset < 80 ? '日本' : '法国'),
            ),
          });
        }),
      );
      addTearDown(repo.close);
      const query = CatalogQuery(
        contentType: SubjectContentType.anime,
        year: 2026,
        language: '其他',
      );
      final first = await repo.queryCatalog(query);
      expect(first.subjects, isEmpty);
      expect(first.hasMore, isTrue);
      final second = await repo.queryCatalog(query, cursor: first.nextCursor);
      expect(second.subjects, hasLength(20));
      expect(second.subjects.every((s) => s.language == '法语'), isTrue);
      expect(second.hasMore, isFalse);
    },
  );

  test('language index hints still fall back to untagged pages', () async {
    final tagged = <String>[];
    final repo = BangumiMetadataRepository(
      client: MockClient((request) async {
        final filter = (jsonDecode(request.body) as Map)['filter'] as Map;
        final tag = (filter['tag'] as List?)?.last as String?;
        if (tag != null) tagged.add(tag);
        return _response({
          'total': 1,
          'data': [
            if (tag != null)
              _raw(1, region: '中国')
            else
              {
                ..._raw(2, region: '国漫'),
                'tags': [],
                'meta_tags': ['国漫'],
              },
          ],
        });
      }),
    );
    addTearDown(repo.close);
    const query = CatalogQuery(
      contentType: SubjectContentType.anime,
      year: 2026,
      language: '国语',
    );
    final first = await repo.queryCatalog(query);
    expect(tagged, containsAll(['中国', '国产', '国创']));
    expect(first.subjects.single.id, 1);
    expect(first.nextCursor, 'search:2026:0');
    final second = await repo.queryCatalog(query, cursor: first.nextCursor);
    expect(second.subjects.single.id, 2);
    expect(second.hasMore, isFalse);
  });

  test(
    'latest walks backwards into the prior year after the current year',
    () async {
      final years = <String>[];
      final repo = BangumiMetadataRepository(
        clock: () => DateTime(2026, 10, 6),
        client: MockClient((request) async {
          final year = request.url.queryParameters['year']!;
          years.add(year);
          return _response({
            'total': 20,
            'data': List.generate(
              20,
              (i) => _raw(int.parse(year) * 100 + i, date: '$year-01-01'),
            ),
          });
        }),
      );
      addTearDown(repo.close);
      const query = CatalogQuery(
        contentType: SubjectContentType.anime,
        sort: CatalogSortMode.latest,
      );
      final first = await repo.queryCatalog(query);
      final second = await repo.queryCatalog(query, cursor: first.nextCursor);
      expect(years, ['2026', '2025']);
      expect(first.subjects.first.year, '2026');
      expect(second.subjects.first.year, '2025');
    },
  );

  test(
    'query and strict calendar failures are not reported as no works',
    () async {
      final repo = BangumiMetadataRepository(
        client: MockClient((_) async => http.Response('unavailable', 503)),
      );
      addTearDown(repo.close);
      await expectLater(
        repo.queryCatalog(
          const CatalogQuery(contentType: SubjectContentType.anime, year: 2026),
        ),
        throwsStateError,
      );
      await expectLater(repo.weeklySchedule(strict: true), throwsStateError);
    },
  );

  test(
    'calendar preserves current long-running works and provider weekdays',
    () async {
      final repo = BangumiMetadataRepository(
        client: MockClient(
          (_) async => _response([
            {
              'weekday': {'id': 2},
              'items': [
                {
                  'id': 10,
                  'name_cn': '仍在放送',
                  'air_date': '2011-01-01',
                  'eps': 100,
                },
              ],
            },
            {
              'weekday': {'id': 8},
              'items': [
                {'id': 20, 'name_cn': '无效星期'},
              ],
            },
          ]),
        ),
      );
      addTearDown(repo.close);
      final result = await repo.weeklySchedule(strict: true);
      expect(result[2]!.single.id, 10);
      expect(result[2]!.single.status, '连载中');
      expect(result.values.expand((items) => items), hasLength(1));
    },
  );

  test(
    'backend catalogue sends all query parameters and preserves cursor',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v3/catalog/discover/tv');
        expect(request.url.queryParameters, {
          'sort': 'latest',
          'genre': '日剧',
          'year': '2026',
          'language': '日语',
          'page': '4',
        });
        return _response({
          'subjects': [
            {
              'stable_id': 'tmdb:tv:1',
              'title': '真人剧集',
              'genres': ['剧情'],
            },
            {
              'stable_id': 'tmdb:tv:2',
              'title': '混入动画',
              'genres': ['动画', '剧情'],
            },
          ],
          'next_cursor': '5',
        });
      });
      addTearDown(client.close);
      final repository = ZelunaBackendCatalogRepository(
        baseUrl: 'https://catalog.example',
        client: client,
      );
      final result = await repository.queryCatalog(
        const CatalogQuery(
          contentType: SubjectContentType.series,
          sort: CatalogSortMode.latest,
          genre: '日剧',
          language: '日语',
          year: 2026,
        ),
        cursor: '4',
      );
      expect(result.subjects.single.id, 1);
      expect(result.nextCursor, '5');
    },
  );

  test('backend missing discovery endpoint is not an empty result', () async {
    final client = MockClient((_) async => http.Response('not found', 404));
    addTearDown(client.close);
    final repository = ZelunaBackendCatalogRepository(
      baseUrl: 'https://catalog.example',
      client: client,
    );
    await expectLater(
      repository.queryCatalog(
        const CatalogQuery(contentType: SubjectContentType.series),
      ),
      throwsStateError,
    );
  });

  test('language filters recognize ISO codes without guessing from title', () {
    for (final pair in [
      ('ja', '日语'),
      ('en', '英语'),
      ('ko', '韩语'),
      ('zh-CN', '国语'),
      ('cn', '国语'),
    ]) {
      final subject = AnimeSubject.fromJson({
        ..._subject.toJson(),
        'language': pair.$1,
      });
      expect(matchesCatalogLanguage(subject, pair.$2), isTrue);
      expect(matchesCatalogLanguage(subject, '其他'), isFalse);
    }
    expect(
      matchesCatalogLanguage(
        AnimeSubject.fromJson({..._subject.toJson(), 'language': 'fr'}),
        '其他',
      ),
      isTrue,
    );
    expect(
      matchesCatalogLanguage(
        AnimeSubject.fromJson({..._subject.toJson(), 'language': '未知'}),
        '其他',
      ),
      isFalse,
    );
  });
}

const _subject = AnimeSubject(
  id: 1,
  title: 'Test',
  originalTitle: 'Test',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-10-01',
  platform: 'TV',
  language: '',
  region: '',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);
