import 'dart:convert';

import 'package:anime/src/data/external_service_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Cinemeta catalog maps high quality movie metadata', () async {
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        expect(request.url.path, '/catalog/movie/top.json');
        return http.Response(
          jsonEncode({
            'metas': [
              {
                'id': 'tt1375666',
                'type': 'movie',
                'name': 'Inception',
                'poster': 'https://images.example/poster.jpg',
                'background': 'https://images.example/backdrop.jpg',
                'description': 'A dream within a dream.',
                'releaseInfo': '2010',
                'imdbRating': '8.8',
                'genres': ['Action', 'Science Fiction'],
              },
            ],
          }),
          200,
        );
      }),
    );

    final subjects = await repository.cinemetaCatalog(type: 'movie');

    expect(subjects, hasLength(1));
    expect(subjects.single.source, 'cinemeta:movie:tt1375666');
    expect(subjects.single.bannerUrl, contains('backdrop.jpg'));
    expect(subjects.single.coverUrl, contains('poster.jpg'));
    expect(subjects.single.ratingScore, 8.8);
  });

  test('Cinemeta feeds request six skip pages for series and movies', () async {
    final requestedPaths = <String>[];
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        final type = request.url.path.contains('/series/') ? 'series' : 'movie';
        final skipMatch = RegExp(r'skip=(\d+)').firstMatch(request.url.path);
        final skip = int.tryParse(skipMatch?.group(1) ?? '') ?? 0;
        return http.Response(
          jsonEncode({
            'metas': [
              {
                'id': 'tt$type$skip',
                'type': type,
                'name': '$type $skip',
                'releaseInfo': '${2026 - skip ~/ 50}',
              },
            ],
          }),
          200,
        );
      }),
    );

    final series = await repository.cinemetaFeed(type: 'series');
    final movies = await repository.cinemetaFeed(type: 'movie');

    expect(series, hasLength(6));
    expect(movies, hasLength(6));
    for (final type in const ['series', 'movie']) {
      expect(requestedPaths.where((path) => path.contains('/$type/')).toSet(), {
        '/catalog/$type/top.json',
        for (var skip = 50; skip <= 250; skip += 50)
          '/catalog/$type/top/skip=$skip.json',
      });
    }
  });

  test('TVMaze show feed aggregates pages zero through two', () async {
    final requestedPages = <int>[];
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        final page = int.parse(request.url.queryParameters['page'] ?? '-1');
        requestedPages.add(page);
        return http.Response(
          jsonEncode([
            for (var index = 0; index < 240; index++)
              {
                'id': page * 1000 + index,
                'name': 'Show $page-$index',
                'premiered': '202$page-01-01',
                'type': 'Scripted',
                'genres': ['Drama'],
                'image': {
                  'medium': 'https://images.example/show-$page-$index.jpg',
                  'original':
                      'https://images.example/show-$page-$index-original.jpg',
                },
              },
          ]),
          200,
        );
      }),
    );

    final subjects = await repository.tvMazeShowsFeed();

    expect(requestedPages..sort(), [0, 1, 2]);
    expect(subjects, hasLength(660));
    expect(subjects.map((item) => item.title), contains('Show 0-219'));
    expect(subjects.map((item) => item.title), isNot(contains('Show 0-220')));
    expect(subjects.first.coverUrl, 'https://images.example/show-0-0.jpg');
  });

  test(
    'series metadata feed includes the configured TVMaze show pages',
    () async {
      final requestedPages = <int>[];
      final repository = ExternalServiceRepository(
        client: MockClient((request) async {
          if (request.url.path == '/shows') {
            final page = int.parse(request.url.queryParameters['page'] ?? '-1');
            requestedPages.add(page);
            return http.Response(
              jsonEncode([
                {
                  'id': 100 + page,
                  'name': 'Catalog Show $page',
                  'premiered': '202$page-01-01',
                  'type': 'Scripted',
                  'genres': ['Drama'],
                },
              ]),
              200,
            );
          }
          return http.Response(jsonEncode([]), 200);
        }),
      );

      final subjects = await repository.seriesMetadataFeed(
        includeCinemeta: false,
        tvMazePages: 3,
      );

      expect(requestedPages..sort(), [0, 1, 2]);
      expect(
        subjects.where((item) => item.title.startsWith('Catalog Show')),
        hasLength(3),
      );
    },
  );

  test(
    'series metadata feed keeps up to nine hundred aggregated items',
    () async {
      final repository = ExternalServiceRepository(
        client: MockClient((request) async {
          if (request.url.host == 'v3-cinemeta.strem.io') {
            final skipMatch = RegExp(
              r'skip=(\d+)',
            ).firstMatch(request.url.path);
            final skip = int.tryParse(skipMatch?.group(1) ?? '') ?? 0;
            return http.Response(
              jsonEncode({
                'metas': [
                  for (var index = 0; index < 100; index++)
                    {
                      'id': 'ttseries$skip$index',
                      'type': 'series',
                      'name': 'Series $skip-$index',
                      'releaseInfo': '2026',
                    },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/shows') {
            final page = int.parse(request.url.queryParameters['page'] ?? '0');
            return http.Response(
              jsonEncode([
                for (var index = 0; index < 240; index++)
                  {
                    'id': page * 1000 + index,
                    'name': 'TV $page-$index',
                    'premiered': '2026-01-01',
                    'type': 'Scripted',
                    'genres': ['Drama'],
                  },
              ]),
              200,
            );
          }
          return http.Response(jsonEncode([]), 200);
        }),
      );

      final subjects = await repository.seriesMetadataFeed();

      expect(subjects, hasLength(900));
    },
  );

  test('movie metadata feed keeps up to one thousand Cinemeta items', () async {
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        if (request.url.host == 'v3-cinemeta.strem.io') {
          final skipMatch = RegExp(r'skip=(\d+)').firstMatch(request.url.path);
          final skip = int.tryParse(skipMatch?.group(1) ?? '') ?? 0;
          return http.Response(
            jsonEncode({
              'metas': [
                for (var index = 0; index < 200; index++)
                  {
                    'id': 'ttmovie$skip$index',
                    'type': 'movie',
                    'name': 'Movie $skip-$index',
                    'releaseInfo': '2026',
                  },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'results': {'bindings': <Object>[]},
          }),
          200,
        );
      }),
    );

    final subjects = await repository.movieMetadataFeed(includeArchive: false);

    expect(subjects, hasLength(1000));
  });

  test('Cinemeta detail never requests retired platform links', () async {
    final requestedPaths = <String>[];
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path == '/meta/movie/tt1375666.json') {
          return http.Response(
            jsonEncode({
              'meta': {
                'id': 'tt1375666',
                'type': 'movie',
                'name': 'Inception',
                'poster': 'https://images.example/poster.jpg',
                'background': 'https://images.example/backdrop.jpg',
                'description': 'A dream within a dream.',
                'releaseInfo': '2010',
                'imdbRating': '8.8',
                'genres': ['Drama'],
                'director': ['Christopher Nolan'],
                'cast': ['Leonardo DiCaprio'],
              },
            }),
            200,
          );
        }
        if (request.url.path == '/catalog/movie/top/genre=Drama.json') {
          return http.Response(jsonEncode({'metas': []}), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    const subject = AnimeSubject(
      id: 1,
      title: 'Inception',
      originalTitle: 'Inception',
      summary: '',
      coverUrl: null,
      bannerUrl: null,
      date: '2010',
      platform: 'Movie',
      language: 'English',
      region: 'US',
      status: 'Movie',
      categories: [],
      tags: [],
      totalEpisodes: 1,
      source: 'cinemeta:movie:tt1375666',
    );

    final detail = await repository.externalDetail(subject);

    expect(detail.episodes, hasLength(1));
    expect(detail.watchLinks, isEmpty);
    expect(requestedPaths, isNot(contains('/stream/movie/tt1375666.json')));
  });

  test(
    'movie feed keeps playable Archive results when metadata fails',
    () async {
      final repository = ExternalServiceRepository(
        client: MockClient((request) async {
          if (request.url.host == 'archive.org') {
            return http.Response(
              jsonEncode({
                'response': {
                  'docs': [
                    {
                      'identifier': 'open_movie',
                      'title': 'Open Movie',
                      'description': 'Public media item',
                      'date': '2024-01-01',
                      'language': 'en',
                      'licenseurl':
                          'https://creativecommons.org/publicdomain/mark/1.0/',
                    },
                  ],
                },
              }),
              200,
            );
          }
          return http.Response('upstream failed', 503);
        }),
      );

      final subjects = await repository.movieMetadataFeed(
        includeCinemeta: false,
        includeArchive: true,
      );

      expect(subjects, isNotEmpty);
      expect(
        subjects.any((item) => item.source == 'archive:open_movie'),
        isTrue,
      );
    },
  );
}
