import 'dart:convert';

import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/chinese_metadata_repository.dart';
import 'package:anime/src/data/chinese_text.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('metadata placeholders', () {
    test('every placeholder is recognised regardless of punctuation', () {
      // The catalog used to gate blurbs on startsWith('暂无'), which let
      // "内容资料正在完善。" through and rendered it as a real synopsis on the
      // home hero, the detail hero, and the summary tab. Callers must use
      // isMetadataPlaceholder so the whole set is covered.
      for (final placeholder in const [
        '暂无简介',
        '暂无简介。',
        '暂无中文简介',
        '暂无资料',
        '暂无中文资料',
        '简介待补充',
        '内容资料正在完善',
        '内容资料正在完善。',
        '角色资料待bangumi返回',
        '  暂无简介  ',
        '',
      ]) {
        expect(isMetadataPlaceholder(placeholder), isTrue, reason: placeholder);
      }
    });

    test('real synopses are not treated as placeholders', () {
      for (final summary in const ['猫娘尼古快缴不起房租了。', '暂无门票的少年踏上旅程。']) {
        expect(isMetadataPlaceholder(summary), isFalse, reason: summary);
      }
    });
  });

  group('ChineseMetadataRepository Wikidata enrichment', () {
    test(
      'batches IMDb IDs, preserves Chinese text, and caches misses',
      () async {
        var requestCount = 0;
        var now = DateTime.utc(2026, 7, 13);
        final repository = ChineseMetadataRepository(
          now: () => now,
          client: MockClient((request) async {
            requestCount++;
            expect(request.url.host, 'query.wikidata.org');
            final query = request.url.queryParameters['query'] ?? '';
            expect(query, contains('"tt0903747"'));
            expect(query, contains('"tt0111161"'));
            expect(query, contains('"tt9999999"'));
            return _jsonResponse({
              'results': {
                'bindings': [
                  _wikidataBinding(
                    imdb: 'tt0903747',
                    title: '绝命毒师',
                    summary: '美国犯罪题材电视剧',
                  ),
                  _wikidataBinding(
                    imdb: 'tt0111161',
                    title: '肖申克的救赎',
                    summary: '1994年上映的美国剧情片',
                  ),
                ],
              },
            });
          }),
        );
        final subjects = [
          _subject(
            id: 1,
            title: 'Breaking Bad',
            originalTitle: 'Breaking Bad',
            summary: 'A chemistry teacher turns to crime.',
            source: 'cinemeta:series:tt0903747',
          ),
          _subject(
            id: 2,
            title: '已有中文片名',
            originalTitle: 'The Shawshank Redemption',
            summary: 'Two imprisoned men bond over a number of years.',
            source: 'cinemeta:movie:tt0111161',
          ),
          _subject(
            id: 3,
            title: 'Unknown Film',
            originalTitle: 'Unknown Film',
            summary: 'No verified Chinese metadata exists.',
            source: 'cinemeta:movie:tt9999999',
          ),
        ];

        final enriched = await repository.enrichSubjects(
          subjects,
          useBangumiForAnime: false,
        );

        expect(requestCount, 1);
        expect(enriched[0].title, '绝命毒师');
        expect(enriched[0].summary, '美国犯罪题材电视剧');
        expect(enriched[0].originalTitle, 'Breaking Bad');
        expect(enriched[0].source, subjects[0].source);
        expect(enriched[1].title, '已有中文片名');
        expect(enriched[1].summary, '1994年上映的美国剧情片');
        expect(enriched[2].title, subjects[2].title);
        expect(enriched[2].summary, subjects[2].summary);

        await repository.enrichSubjects(subjects, useBangumiForAnime: false);
        expect(
          requestCount,
          1,
          reason: 'hits and verified misses should be cached',
        );

        now = now.add(const Duration(days: 8));
        await repository.enrichSubjects(
          subjects.take(2),
          useBangumiForAnime: false,
        );
        expect(requestCount, 2, reason: 'expired metadata should refresh');
      },
    );

    test(
      'failed Wikidata requests leave data intact and remain retryable',
      () async {
        var requestCount = 0;
        final repository = ChineseMetadataRepository(
          client: MockClient((_) async {
            requestCount++;
            return http.Response('temporarily unavailable', 503);
          }),
        );
        final subject = _subject(
          id: 7,
          title: 'English Movie',
          originalTitle: 'English Movie',
          summary: 'English summary',
          source: 'cinemeta:movie:tt1234567',
        );

        final first = await repository.enrichSubject(
          subject,
          useBangumiForAnime: false,
        );
        final second = await repository.enrichSubject(
          subject,
          useBangumiForAnime: false,
        );

        expect(identical(first, subject), isTrue);
        expect(identical(second, subject), isTrue);
        expect(requestCount, 2);
      },
    );
  });

  group('ChineseMetadataRepository Bangumi enrichment', () {
    test('uses exact original-title matching and caches the result', () async {
      var requestCount = 0;
      final bangumi = BangumiMetadataRepository(
        client: MockClient((request) async {
          requestCount++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['keyword'], '進撃の巨人');
          return _jsonResponse({
            'data': [
              {
                'id': 55770,
                'name_cn': '进击的巨人',
                'name': '進撃の巨人',
                'summary': '人类为夺回墙外世界而战的故事。',
                'date': '2013-04-07',
                'platform': 'TV',
                'total_episodes': 25,
                'meta_tags': ['动画'],
                'tags': const [],
                'rating': const {},
              },
            ],
          });
        }),
      );
      final repository = ChineseMetadataRepository(
        client: MockClient((_) async => throw StateError('unexpected request')),
        bangumiRepository: bangumi,
      );
      final subject = _subject(
        id: 10,
        title: 'Attack on Titan',
        originalTitle: '進撃の巨人',
        summary: 'Humanity lives inside cities surrounded by enormous walls.',
        source: 'jikan',
        date: '2013-04-07',
      );

      final enriched = await repository.enrichSubject(subject);
      final cached = await repository.enrichSubject(subject);

      expect(enriched.title, '进击的巨人');
      expect(enriched.summary, '人类为夺回墙外世界而战的故事。');
      expect(enriched.originalTitle, '進撃の巨人');
      expect(cached.title, '进击的巨人');
      expect(requestCount, 1);
    });

    test('rejects fuzzy or unrelated Bangumi results', () async {
      final bangumi = BangumiMetadataRepository(
        client: MockClient(
          (_) async => _jsonResponse({
            'data': [
              {
                'id': 1,
                'name_cn': '完全不同的作品',
                'name': 'Different Work',
                'summary': '不应套用到当前条目。',
                'date': '2024-01-01',
                'platform': 'TV',
                'total_episodes': 12,
                'meta_tags': ['动画'],
                'tags': const [],
                'rating': const {},
              },
            ],
          }),
        ),
      );
      final repository = ChineseMetadataRepository(
        client: MockClient((_) async => throw StateError('unexpected request')),
        bangumiRepository: bangumi,
      );
      final subject = _subject(
        id: 11,
        title: 'Frieren: Beyond Journey\'s End',
        originalTitle: '葬送のフリーレン',
        summary: 'An elf mage reflects on her long life.',
        source: 'anilist',
        date: '2023-09-29',
      );

      final result = await repository.enrichSubject(subject);

      expect(identical(result, subject), isTrue);
    });

    test(
      'does not treat Japanese Kanji and kana as Chinese metadata',
      () async {
        final bangumi = BangumiMetadataRepository(
          client: MockClient(
            (_) async => _jsonResponse({
              'data': [
                {
                  'id': 400602,
                  'name_cn': '',
                  'name': '葬送のフリーレン',
                  'summary': '勇者一行と共に魔王を倒した魔法使いの旅が始まる。',
                  'date': '2023-09-29',
                  'platform': 'TV',
                  'total_episodes': 28,
                  'meta_tags': ['动画'],
                  'tags': const [],
                  'rating': const {},
                },
              ],
            }),
          ),
        );
        final repository = ChineseMetadataRepository(
          client: MockClient(
            (_) async => throw StateError('unexpected request'),
          ),
          bangumiRepository: bangumi,
        );
        final subject = _subject(
          id: 13,
          title: 'Frieren: Beyond Journey\'s End',
          originalTitle: '葬送のフリーレン',
          summary: 'An elf mage reflects on her long life.',
          source: 'anilist',
          date: '2023-09-29',
        );

        final result = await repository.enrichSubject(subject);

        expect(identical(result, subject), isTrue);
      },
    );

    test(
      'does not promote an untranslated pure-Kanji original title',
      () async {
        final bangumi = BangumiMetadataRepository(
          client: MockClient(
            (_) async => _jsonResponse({
              'data': [
                {
                  'id': 1671,
                  'name_cn': '',
                  'name': '東京喰種',
                  'summary': '人を喰らう怪人たちの物語。',
                  'date': '2014-07-04',
                  'platform': 'TV',
                  'total_episodes': 12,
                  'meta_tags': ['动画'],
                  'tags': const [],
                  'rating': const {},
                },
              ],
            }),
          ),
        );
        final repository = ChineseMetadataRepository(
          client: MockClient(
            (_) async => throw StateError('unexpected request'),
          ),
          bangumiRepository: bangumi,
        );
        final subject = _subject(
          id: 15,
          title: 'Tokyo Ghoul',
          originalTitle: '東京喰種',
          summary: 'A college student is transformed after a deadly encounter.',
          source: 'anilist',
          date: '2014-07-04',
        );

        final result = await repository.enrichSubject(subject);

        expect(identical(result, subject), isTrue);
      },
    );

    test(
      'replaces a Chinese placeholder with a real Chinese summary',
      () async {
        final bangumi = BangumiMetadataRepository(
          client: MockClient(
            (_) async => _jsonResponse({
              'data': [
                {
                  'id': 55770,
                  'name_cn': '进击的巨人',
                  'name': '進撃の巨人',
                  'summary': '人类为夺回墙外世界而战的故事。',
                  'date': '2013-04-07',
                  'platform': 'TV',
                  'total_episodes': 25,
                  'meta_tags': ['动画'],
                  'tags': const [],
                  'rating': const {},
                },
              ],
            }),
          ),
        );
        final repository = ChineseMetadataRepository(
          client: MockClient(
            (_) async => throw StateError('unexpected request'),
          ),
          bangumiRepository: bangumi,
        );
        final subject = _subject(
          id: 14,
          title: '进击的巨人',
          originalTitle: '進撃の巨人',
          summary: '暂无简介。',
          source: 'jikan',
          date: '2013-04-07',
        );

        final result = await repository.enrichSubject(subject);

        expect(result.title, '进击的巨人');
        expect(result.summary, '人类为夺回墙外世界而战的故事。');
      },
    );

    test(
      'skips network lookup when title and summary are already Chinese',
      () async {
        final repository = ChineseMetadataRepository(
          client: MockClient(
            (_) async => throw StateError('unexpected request'),
          ),
          bangumiRepository: BangumiMetadataRepository(
            client: MockClient(
              (_) async => throw StateError('unexpected request'),
            ),
          ),
        );
        final subject = _subject(
          id: 12,
          title: '葬送的芙莉莲',
          originalTitle: '葬送のフリーレン',
          summary: '勇者一行击败魔王后的旅程。',
          source: 'anilist',
        );

        final result = await repository.enrichSubject(subject);

        expect(identical(result, subject), isTrue);
      },
    );
  });
}

AnimeSubject _subject({
  required int id,
  required String title,
  required String originalTitle,
  required String summary,
  required String source,
  String? date,
}) {
  return AnimeSubject(
    id: id,
    title: title,
    originalTitle: originalTitle,
    summary: summary,
    coverUrl: 'https://example.com/$id.jpg',
    bannerUrl: null,
    date: date,
    platform: 'TV',
    language: '英语',
    region: '美国',
    status: '已完结',
    categories: const [AnimeCategory(name: '剧情')],
    tags: const [],
    totalEpisodes: 1,
    source: source,
  );
}

Map<String, Object?> _wikidataBinding({
  required String imdb,
  required String title,
  required String summary,
}) {
  return {
    'imdb': {'type': 'literal', 'value': imdb},
    'zhCnLabel': {'type': 'literal', 'xml:lang': 'zh-cn', 'value': title},
    'zhCnDescription': {
      'type': 'literal',
      'xml:lang': 'zh-cn',
      'value': summary,
    },
  };
}

http.Response _jsonResponse(Map<String, Object?> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
