import 'dart:async';
import 'dart:convert';

import 'package:anime/src/data/external_service_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _testToken = 'tmdb_test_read_access_token_not_a_real_secret_1234567890';

void main() {
  test('validates a TMDB v4 read token with bearer authentication', () async {
    final repository = ExternalServiceRepository(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/3/authentication');
        expect(request.url.queryParameters['language'], 'zh-CN');
        expect(request.headers['authorization'], 'Bearer $_testToken');
        expect(request.headers['accept'], 'application/json');
        return _jsonResponse({'success': true, 'status_message': 'Success.'});
      }),
    );

    final validation = await repository.validateTmdbAccessToken(_testToken);

    expect(validation.isValid, isTrue);
    expect(validation.message, contains('成功'));
  });

  test('maps an unauthorized validation response to a safe message', () async {
    final repository = ExternalServiceRepository(
      client: MockClient((_) async => http.Response('', 401)),
    );

    final validation = await repository.validateTmdbAccessToken(_testToken);

    expect(validation.isValid, isFalse);
    expect(validation.message, contains('无效'));
  });

  test('does not accept a malformed HTTP 200 validation response', () async {
    final repository = ExternalServiceRepository(
      client: MockClient(
        (_) async => http.Response('<html>blocked</html>', 200),
      ),
    );

    final validation = await repository.validateTmdbAccessToken(_testToken);

    expect(validation.isValid, isFalse);
    expect(validation.message, contains('未接受'));
  });

  test(
    'search sends Chinese movie and series requests with bearer auth',
    () async {
      final requests = <http.Request>[];
      final repository = ExternalServiceRepository(
        tmdbAccessTokenProvider: () async => _testToken,
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer $_testToken');
          expect(request.headers['accept'], 'application/json');
          expect(request.url.queryParameters['language'], 'zh-CN');
          expect(request.url.queryParameters['include_adult'], 'false');
          if (request.url.path == '/3/search/movie') {
            expect(request.url.queryParameters['region'], 'CN');
            return _resultsResponse([
              {
                'id': 101,
                'title': '流浪地球',
                'original_title': '流浪地球',
                'overview': '人类为拯救家园，带着地球开启漫长旅程。',
                'poster_path': '/movie-poster.jpg',
                'backdrop_path': '/movie-backdrop.jpg',
                'release_date': '2019-02-05',
                'original_language': 'zh',
                'genre_ids': [878, 18],
                'vote_average': 8.1,
                'vote_count': 8000,
              },
            ]);
          }
          expect(request.url.path, '/3/search/tv');
          expect(request.url.queryParameters.containsKey('region'), isFalse);
          return _resultsResponse([
            {
              'id': 202,
              'name': '漫长的季节',
              'original_name': '漫长的季节',
              'overview': '一座小城里，几个人跨越多年追寻真相。',
              'poster_path': '/series-poster.jpg',
              'backdrop_path': '/series-backdrop.jpg',
              'first_air_date': '2023-04-22',
              'original_language': 'zh',
              'origin_country': ['CN'],
              'genre_ids': [18, 80],
              'vote_average': 9.0,
              'vote_count': 5000,
            },
          ]);
        }),
      );

      final results = await repository.tmdbSearch('中文片名');

      expect(requests, hasLength(2));
      expect(results, hasLength(2));
      final movie = results.firstWhere(
        (item) => item.source == 'tmdb:movie:101',
      );
      expect(movie.title, '流浪地球');
      expect(movie.summary, contains('拯救家园'));
      expect(
        movie.coverUrl,
        'https://image.tmdb.org/t/p/w500/movie-poster.jpg',
      );
      expect(
        movie.bannerUrl,
        'https://image.tmdb.org/t/p/w1280/movie-backdrop.jpg',
      );
      expect(
        movie.categories.map((item) => item.name),
        containsAll(['科幻', '剧情']),
      );
      final series = results.firstWhere(
        (item) => item.source == 'tmdb:series:202',
      );
      expect(series.title, '漫长的季节');
      expect(series.region, '中国大陆');
      expect(series.platform, 'Series');
    },
  );

  test('does not make TMDB requests when no token is configured', () async {
    var requestCount = 0;
    final repository = ExternalServiceRepository(
      tmdbAccessTokenProvider: () async => null,
      client: MockClient((_) async {
        requestCount++;
        return _resultsResponse(const []);
      }),
    );
    const subject = AnimeSubject(
      id: 42,
      title: '测试剧集',
      originalTitle: 'Test Series',
      summary: '',
      coverUrl: null,
      bannerUrl: null,
      date: null,
      platform: 'Series',
      language: '中文',
      region: '中国大陆',
      status: '',
      categories: [],
      tags: [],
      totalEpisodes: 0,
      source: 'tmdb:series:42',
    );

    expect(await repository.tmdbSearch('测试'), isEmpty);
    expect(await repository.tmdbSeriesFeed(), isEmpty);
    expect(await repository.tmdbMovieFeed(), isEmpty);
    expect(await repository.tmdbDetail(subject), isNull);
    expect(requestCount, 0);
  });

  test('concurrent 401 responses reject the exact token only once', () async {
    var rejectionCount = 0;
    var requestCount = 0;
    final responseGate = Completer<void>();
    final repository = ExternalServiceRepository(
      tmdbAccessTokenProvider: () async => _testToken,
      onTmdbAccessTokenRejected: (rejectedToken) async {
        expect(rejectedToken, _testToken);
        rejectionCount++;
      },
      client: MockClient((_) async {
        requestCount++;
        await responseGate.future;
        return http.Response('', 401);
      }),
    );

    final search = repository.tmdbSearch('并发鉴权');
    await Future<void>.delayed(Duration.zero);
    responseGate.complete();

    expect(await search, isEmpty);
    expect(requestCount, 2);
    expect(rejectionCount, 1);
    expect(await repository.tmdbMovieFeed(pages: 1), isEmpty);
    expect(requestCount, 2);
  });

  test('a late old-token 401 cannot reject a replacement token', () async {
    const replacementToken =
        'tmdb_replacement_read_token_not_a_real_secret_0987654321';
    var activeToken = _testToken;
    var rejectionCount = 0;
    final oldResponse = Completer<http.Response>();
    final requests = <http.Request>[];
    final repository = ExternalServiceRepository(
      tmdbAccessTokenProvider: () async => activeToken,
      onTmdbAccessTokenRejected: (_) async => rejectionCount++,
      client: MockClient((request) async {
        requests.add(request);
        if (request.headers['authorization'] == 'Bearer $_testToken') {
          return oldResponse.future;
        }
        return _resultsResponse(const []);
      }),
    );

    final oldRequest = repository.tmdbMovieFeed(pages: 1);
    await Future<void>.delayed(Duration.zero);
    activeToken = replacementToken;
    repository.resetTmdbAccessTokenState();
    oldResponse.complete(http.Response('', 401));

    expect(await oldRequest, isEmpty);
    expect(rejectionCount, 0);
    expect(await repository.tmdbMovieFeed(pages: 1), isEmpty);
    expect(requests.last.headers['authorization'], 'Bearer $replacementToken');
  });

  test('403 starts a short cooldown without rejecting the token', () async {
    var requestCount = 0;
    var rejectionCount = 0;
    final repository = ExternalServiceRepository(
      tmdbAccessTokenProvider: () async => _testToken,
      onTmdbAccessTokenRejected: (_) async => rejectionCount++,
      client: MockClient((request) async {
        requestCount++;
        expect(request.headers['authorization'], 'Bearer $_testToken');
        if (requestCount == 1) return http.Response('', 403);
        return _resultsResponse(const []);
      }),
    );

    expect(await repository.tmdbMovieFeed(pages: 1), isEmpty);
    expect(await repository.tmdbMovieFeed(pages: 1), isEmpty);
    expect(requestCount, 1);
    expect(rejectionCount, 0);

    repository.resetTmdbAccessTokenState();
    expect(await repository.tmdbMovieFeed(pages: 1), isEmpty);
    expect(requestCount, 2);
    expect(rejectionCount, 0);
  });

  test('429 starts a short cooldown that prevents request storms', () async {
    var requestCount = 0;
    final repository = ExternalServiceRepository(
      tmdbAccessTokenProvider: () async => _testToken,
      client: MockClient((_) async {
        requestCount++;
        return http.Response('', 429, headers: {'retry-after': '60'});
      }),
    );

    expect(await repository.tmdbMovieFeed(pages: 1), isEmpty);
    expect(await repository.tmdbSeriesFeed(pages: 3), isEmpty);
    expect(requestCount, 1);
  });

  test(
    'series detail uses one request and synthesizes seasons locally',
    () async {
      final requests = <http.Request>[];
      final repository = ExternalServiceRepository(
        tmdbAccessTokenProvider: () async => _testToken,
        client: MockClient((request) async {
          requests.add(request);
          expect(request.url.path, '/3/tv/42');
          expect(request.url.queryParameters['language'], 'zh-CN');
          expect(
            request.url.queryParameters['append_to_response'],
            'credits,recommendations',
          );
          return _jsonResponse({
            'id': 42,
            'name': '三体',
            'original_name': '三体',
            'overview': '人类文明第一次接触来自宇宙深处的未知文明。',
            'poster_path': '/three-body-poster.jpg',
            'backdrop_path': '/three-body-backdrop.jpg',
            'first_air_date': '2023-01-15',
            'original_language': 'zh',
            'origin_country': ['CN'],
            'status': 'Ended',
            'number_of_episodes': 3,
            'episode_run_time': [45],
            'vote_average': 8.4,
            'vote_count': 1200,
            'genres': [
              {'id': 18, 'name': '剧情'},
              {'id': 10765, 'name': '科幻奇幻'},
            ],
            'production_companies': [
              {'id': 1, 'name': '测试制作公司'},
            ],
            'seasons': [
              {'season_number': 0, 'episode_count': 2, 'name': '特别篇'},
              {
                'season_number': 1,
                'episode_count': 2,
                'air_date': '2023-01-15',
                'overview': '第一季简介',
                'poster_path': '/season-one.jpg',
              },
              {
                'season_number': 2,
                'episode_count': 1,
                'air_date': '2024-01-01',
                'overview': '第二季简介',
                'poster_path': '/season-two.jpg',
              },
            ],
            'credits': {
              'cast': [
                {
                  'id': 11,
                  'cast_id': 111,
                  'name': '张演员',
                  'character': '汪淼',
                  'profile_path': '/actor.jpg',
                },
              ],
              'crew': [
                {
                  'id': 22,
                  'name': '李导演',
                  'job': 'Director',
                  'department': 'Directing',
                  'profile_path': '/director.jpg',
                },
              ],
            },
            'recommendations': {
              'results': [
                {
                  'id': 43,
                  'name': '流浪地球剧集',
                  'original_name': '流浪地球剧集',
                  'overview': '相关科幻剧集。',
                  'poster_path': '/recommendation.jpg',
                  'first_air_date': '2025-01-01',
                  'original_language': 'zh',
                  'origin_country': ['CN'],
                  'genre_ids': [10765],
                },
              ],
            },
          });
        }),
      );
      const subject = AnimeSubject(
        id: 42,
        title: '三体',
        originalTitle: '三体',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: null,
        platform: 'Series',
        language: '中文',
        region: '中国大陆',
        status: '',
        categories: [],
        tags: [],
        totalEpisodes: 0,
        source: 'tmdb:series:42',
      );

      final detail = await repository.tmdbDetail(subject);

      expect(requests, hasLength(1));
      expect(requests.single.url.pathSegments, isNot(contains('season')));
      expect(detail, isNotNull);
      expect(detail!.subject.title, '三体');
      expect(detail.subject.status, '已完结 · 全3集');
      expect(detail.subject.coverUrl, contains('/w500/three-body-poster.jpg'));
      expect(
        detail.subject.bannerUrl,
        contains('/w1280/three-body-backdrop.jpg'),
      );
      expect(detail.episodes, hasLength(3));
      expect(detail.episodes.map((item) => item.title), [
        '第1季 第1集',
        '第1季 第2集',
        '第2季 第1集',
      ]);
      expect(detail.episodes.first.duration, '45 分钟');
      expect(detail.characters.single.name, '汪淼');
      expect(detail.characters.single.cv, '张演员');
      expect(detail.staff.single.role, '导演');
      expect(detail.recommendations.single.subject.source, 'tmdb:series:43');
    },
  );
}

http.Response _jsonResponse(Map<String, dynamic> body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _resultsResponse(List<Map<String, dynamic>> results) {
  return _jsonResponse({'page': 1, 'results': results, 'total_pages': 1});
}
