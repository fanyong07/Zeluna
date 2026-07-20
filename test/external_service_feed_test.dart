import 'dart:convert';

import 'package:anime/src/data/external_service_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'AniList trending feed aggregates the requested GraphQL pages',
    () async {
      final requestedPages = <int>[];
      final requestedPageSizes = <int>[];
      final repository = ExternalServiceRepository(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['query']?.toString(), contains('format'));
          final variables = (body['variables'] as Map).cast<String, dynamic>();
          final page = variables['page'] as int;
          requestedPages.add(page);
          requestedPageSizes.add(variables['perPage'] as int);
          return http.Response(
            jsonEncode({
              'data': {
                'Page': {
                  'media': [
                    {
                      'id': page,
                      'format': page == 1 ? 'MOVIE' : 'TV',
                      'title': {
                        'romaji': 'Anime $page',
                        'english': 'Anime $page',
                        'native': 'Anime Native $page',
                      },
                      'description': 'Page $page',
                      'coverImage': {
                        'large': 'https://images.example/anilist-$page.jpg',
                      },
                      'startDate': {'year': 2026, 'month': 1, 'day': page},
                      'episodes': 12,
                      'averageScore': 80,
                      'genres': ['Drama'],
                      'tags': <Object>[],
                      'studios': {'nodes': <Object>[]},
                    },
                  ],
                },
              },
            }),
            200,
          );
        }),
      );

      final subjects = await repository.anilistTrendingFeed(
        pages: 3,
        perPage: 50,
      );

      expect(requestedPages..sort(), [1, 2, 3]);
      expect(requestedPageSizes, everyElement(50));
      expect(subjects, hasLength(3));
      expect(subjects.first.platform, 'MOVIE');
      expect(subjects.skip(1).map((item) => item.platform), everyElement('TV'));
    },
  );

  test('AniList search requests and preserves the release format', () async {
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query']?.toString(), contains('format'));
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {
                'Page': {
                  'media': [
                    {
                      'id': 99,
                      'format': 'MOVIE',
                      'title': {
                        'romaji': 'Anime Movie',
                        'english': 'Anime Movie',
                        'native': 'アニメ映画',
                      },
                      'startDate': {'year': 2026, 'month': 7, 'day': 19},
                      'genres': ['Drama'],
                      'tags': <Object>[],
                    },
                  ],
                },
              },
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final subjects = await repository.anilistSearch('Anime Movie');

    expect(subjects.single.platform, 'MOVIE');
  });

  test('Jikan discovery feed combines airing and popularity pages', () async {
    final requested = <String>[];
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        final filter = request.url.queryParameters['filter'] ?? '';
        final page = int.parse(request.url.queryParameters['page'] ?? '1');
        requested.add('$filter:$page');
        final id = filter == 'airing' ? 1 : page + 1;
        return http.Response(
          jsonEncode({
            'data': [
              {
                'mal_id': id,
                'title': 'Jikan $filter $page',
                'title_japanese': 'Jikan Native $id',
                'titles': [
                  {'type': 'Default', 'title': 'Jikan $filter $page'},
                ],
                'type': 'TV',
                'status': 'Finished Airing',
                'aired': {'from': '202$id-01-01'},
                'genres': <Object>[],
                'themes': <Object>[],
                'studios': <Object>[],
              },
            ],
          }),
          200,
        );
      }),
    );

    final subjects = await repository.jikanDiscoveryFeed(pages: 2);

    expect(requested.toSet(), {'airing:1', 'bypopularity:1', 'bypopularity:2'});
    expect(subjects, hasLength(3));
  });

  test('Kitsu trending feed advances offsets by page size', () async {
    final requestedOffsets = <int>[];
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        final offset = int.parse(
          request.url.queryParameters['page[offset]'] ?? '-1',
        );
        requestedOffsets.add(offset);
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': '${offset + 1}',
                'attributes': {
                  'canonicalTitle': 'Kitsu $offset',
                  'titles': {
                    'en_jp': 'Kitsu $offset',
                    'ja_jp': 'Kitsu Native $offset',
                  },
                  'startDate': '2026-01-01',
                  'subtype': 'TV',
                  'status': 'finished',
                  'episodeCount': 12,
                  'averageRating': '80',
                  'userCount': offset + 100,
                  'posterImage': {
                    'large': 'https://images.example/kitsu-$offset.jpg',
                  },
                },
              },
            ],
          }),
          200,
        );
      }),
    );

    final subjects = await repository.kitsuTrendingFeed(pages: 3);

    expect(requestedOffsets..sort(), [0, 20, 40]);
    expect(subjects, hasLength(3));
  });
}
