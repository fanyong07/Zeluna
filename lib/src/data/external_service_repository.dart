import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';

class TmdbTokenValidation {
  const TmdbTokenValidation._({required this.isValid, required this.message});

  const TmdbTokenValidation.valid(String message)
    : this._(isValid: true, message: message);

  const TmdbTokenValidation.invalid(String message)
    : this._(isValid: false, message: message);

  final bool isValid;
  final String message;
}

class ExternalServiceRepository {
  ExternalServiceRepository({
    http.Client? client,
    Future<String?> Function()? tmdbAccessTokenProvider,
    Future<void> Function(String rejectedToken)? onTmdbAccessTokenRejected,
  }) : _client = client ?? http.Client(),
       _tmdbAccessTokenProvider = tmdbAccessTokenProvider,
       _onTmdbAccessTokenRejected = onTmdbAccessTokenRejected;

  final http.Client _client;
  final Future<String?> Function()? _tmdbAccessTokenProvider;
  final Future<void> Function(String rejectedToken)? _onTmdbAccessTokenRejected;
  final Set<String> _rejectedTmdbAccessTokens = <String>{};
  bool _suppressTmdbAccessToken = false;
  int _tmdbAccessTokenGeneration = 0;
  DateTime? _tmdbRateLimitedUntil;
  static const _cinemetaBase = 'https://v3-cinemeta.strem.io';
  static const _tmdbBase = 'https://api.themoviedb.org/3';
  static const _tmdbImageBase = 'https://image.tmdb.org/t/p';
  static const _tmdbDefaultRateLimitCooldown = Duration(seconds: 15);
  static const _tmdbMaxRateLimitCooldown = Duration(minutes: 1);
  static const _tmdbGenreNames = <int, String>{
    12: '冒险',
    14: '奇幻',
    16: '动画',
    18: '剧情',
    27: '恐怖',
    28: '动作',
    35: '喜剧',
    36: '历史',
    37: '西部',
    53: '惊悚',
    80: '犯罪',
    99: '纪录片',
    878: '科幻',
    9648: '悬疑',
    10402: '音乐',
    10749: '爱情',
    10751: '家庭',
    10752: '战争',
    10759: '动作冒险',
    10762: '儿童',
    10763: '新闻',
    10764: '真人秀',
    10765: '科幻奇幻',
    10766: '肥皂剧',
    10767: '脱口秀',
    10768: '战争政治',
    10770: '电视电影',
  };
  static const _archiveCollections = <String>[
    'animationandcartoons',
    'feature_films',
    'classic_tv',
    'prelinger',
  ];
  static const _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
    'Accept': 'application/json, text/plain, */*',
  };

  void resetTmdbAccessTokenState() {
    _tmdbAccessTokenGeneration++;
    _suppressTmdbAccessToken = false;
    _rejectedTmdbAccessTokens.clear();
    _tmdbRateLimitedUntil = null;
  }

  Future<TmdbTokenValidation> validateTmdbAccessToken(String token) async {
    final normalized = token.trim();
    if (normalized.length < 32 ||
        normalized.length > 2048 ||
        RegExp(r'\s').hasMatch(normalized)) {
      return const TmdbTokenValidation.invalid('令牌格式不正确');
    }
    final uri = Uri.parse(
      '$_tmdbBase/authentication',
    ).replace(queryParameters: const {'language': 'zh-CN'});
    try {
      if (_tmdbRequestIsCoolingDown()) {
        return const TmdbTokenValidation.invalid('请求过于频繁，请稍后再试');
      }
      final response = await _client
          .get(uri, headers: _tmdbHeaders(normalized))
          .timeout(const Duration(seconds: 12));
      _acceptTmdbRateLimit(response);
      if (response.statusCode == 401) {
        return const TmdbTokenValidation.invalid('令牌无效或已过期');
      }
      if (response.statusCode == 403) {
        return const TmdbTokenValidation.invalid('TMDB 拒绝了本次验证，请检查令牌权限或稍后重试');
      }
      if (response.statusCode == 429) {
        return const TmdbTokenValidation.invalid('请求过于频繁，请稍后再试');
      }
      if (response.statusCode != 200) {
        return TmdbTokenValidation.invalid(
          'TMDB 暂时无法验证令牌（HTTP ${response.statusCode}）',
        );
      }
      final json = _decodeJsonMap(response);
      if (json['success'] != true) {
        return const TmdbTokenValidation.invalid('TMDB 未接受这个令牌');
      }
      return const TmdbTokenValidation.valid('TMDB 连接成功');
    } on TimeoutException {
      return const TmdbTokenValidation.invalid('连接 TMDB 超时，请检查网络后重试');
    } catch (_) {
      return const TmdbTokenValidation.invalid('无法连接 TMDB，请检查网络后重试');
    }
  }

  Future<List<AnimeSubject>> tmdbSearch(String keyword, {int page = 1}) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final safePage = page.clamp(1, 500).toInt();
    final groups = await Future.wait([
      _tmdbSubjects(
        path: '/search/movie',
        type: 'movie',
        queryParameters: {
          'query': query,
          'page': '$safePage',
          'language': 'zh-CN',
          'region': 'CN',
          'include_adult': 'false',
        },
      ),
      _tmdbSubjects(
        path: '/search/tv',
        type: 'tv',
        queryParameters: {
          'query': query,
          'page': '$safePage',
          'language': 'zh-CN',
          'include_adult': 'false',
        },
      ),
    ]);
    return _uniqueSubjects(_interleaveSubjectGroups(groups, limitPerRound: 6));
  }

  Future<List<AnimeSubject>> tmdbSeriesFeed({int pages = 3}) async {
    final safePages = pages.clamp(1, 10).toInt();
    final groups = await Future.wait([
      for (var page = 1; page <= safePages; page++)
        _tmdbSubjects(
          path: '/discover/tv',
          type: 'tv',
          queryParameters: {
            'page': '$page',
            'language': 'zh-CN',
            'include_adult': 'false',
            'include_null_first_air_dates': 'false',
            'sort_by': 'popularity.desc',
            'watch_region': 'CN',
          },
        ),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> tmdbMovieFeed({int pages = 3}) async {
    final safePages = pages.clamp(1, 10).toInt();
    final groups = await Future.wait([
      for (var page = 1; page <= safePages; page++)
        _tmdbSubjects(
          path: '/discover/movie',
          type: 'movie',
          queryParameters: {
            'page': '$page',
            'language': 'zh-CN',
            'region': 'CN',
            'include_adult': 'false',
            'sort_by': 'popularity.desc',
          },
        ),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<AnimeDetailBundle?> tmdbDetail(AnimeSubject subject) async {
    final identity = _tmdbIdentity(subject);
    if (identity == null) return null;
    final response = await _tmdbGet(
      Uri.parse('$_tmdbBase/${identity.$1}/${identity.$2}').replace(
        queryParameters: const {
          'language': 'zh-CN',
          'append_to_response': 'credits,recommendations',
        },
      ),
    );
    if (response == null || response.statusCode != 200) return null;
    final json = _decodeJsonMap(response);
    if (json.isEmpty) return null;
    final detailedSubject = _subjectFromTmdb(json, identity.$1);
    if (detailedSubject.id <= 0 || detailedSubject.title.trim().isEmpty) {
      return null;
    }
    final credits = json['credits'] is Map
        ? (json['credits'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final recommendations = json['recommendations'] is Map
        ? (json['recommendations'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final recommendationItems = recommendations['results'] is List
        ? recommendations['results'] as List
        : const [];
    return AnimeDetailBundle(
      subject: detailedSubject,
      episodes: identity.$1 == 'tv'
          ? _tmdbSeriesEpisodes(json, detailedSubject)
          : _tmdbMovieEpisodes(json, detailedSubject),
      characters: _tmdbCharacters(credits),
      staff: _tmdbStaff(credits),
      recommendations: recommendationItems
          .whereType<Map>()
          .map(
            (item) =>
                _subjectFromTmdb(item.cast<String, dynamic>(), identity.$1),
          )
          .where(
            (item) =>
                item.id > 0 &&
                item.source != detailedSubject.source &&
                item.title.trim().isNotEmpty,
          )
          .take(12)
          .map(
            (item) => AnimeRecommendation(
              subject: item,
              relation: identity.$1 == 'tv' ? '相关剧集' : '相关电影',
            ),
          )
          .toList(growable: false),
    );
  }

  Future<List<AnimeSubject>> anilistSearch(String keyword, {int perPage = 24}) {
    return _anilistSubjects(
      r'''
query ($perPage: Int, $search: String) {
  Page(page: 1, perPage: $perPage) {
    media(type: ANIME, search: $search, sort: SEARCH_MATCH) {
      id
      format
      title { romaji english native }
      description(asHtml: false)
      coverImage { large extraLarge color }
      bannerImage
      startDate { year month day }
      episodes
      averageScore
      genres
      tags { name rank }
      studios(isMain: true) { nodes { name } }
    }
  }
}
''',
      {'perPage': perPage, 'search': keyword.trim()},
      enabled: keyword.trim().isNotEmpty,
    );
  }

  Future<List<AnimeSubject>> anilistTrending({
    int perPage = 24,
    int page = 1,
    String season = '',
    int? seasonYear,
  }) async {
    return _anilistSubjects(
      r'''
query ($page: Int, $perPage: Int, $season: MediaSeason, $seasonYear: Int) {
  Page(page: $page, perPage: $perPage) {
    media(type: ANIME, sort: TRENDING_DESC, season: $season, seasonYear: $seasonYear) {
      id
      format
      title { romaji english native }
      description(asHtml: false)
      coverImage { large extraLarge color }
      bannerImage
      startDate { year month day }
      episodes
      averageScore
      genres
      tags { name rank }
      studios(isMain: true) { nodes { name } }
    }
  }

}
''',
      {
        'page': page.clamp(1, 10),
        'perPage': perPage,
        if (season.isNotEmpty) 'season': season,
        'seasonYear': ?seasonYear,
      },
    );
  }

  Future<List<AnimeSubject>> anilistTrendingFeed({
    int pages = 3,
    int perPage = 50,
  }) async {
    final safePages = pages.clamp(1, 5);
    final groups = await Future.wait([
      for (var page = 1; page <= safePages; page++)
        anilistTrending(
          page: page,
          perPage: perPage.clamp(1, 50),
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> jikanSearch(
    String keyword, {
    int limit = 24,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final response = await _client
        .get(
          Uri.parse('https://api.jikan.moe/v4/anime').replace(
            queryParameters: {
              'q': query,
              'limit': '${limit.clamp(1, 25)}',
              'sfw': 'true',
              'order_by': 'score',
              'sort': 'desc',
            },
          ),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 16));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) => _subjectFromJikan(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AnimeSubject>> jikanTop({
    int limit = 24,
    int page = 1,
    String filter = 'airing',
  }) async {
    final queryParameters = <String, String>{
      'page': '${page.clamp(1, 20)}',
      'limit': '${limit.clamp(1, 25)}',
      'sfw': 'true',
    };
    if (filter.trim().isNotEmpty) {
      queryParameters['filter'] = filter.trim();
    }
    final response = await _client
        .get(
          Uri.parse(
            'https://api.jikan.moe/v4/top/anime',
          ).replace(queryParameters: queryParameters),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 16));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) => _subjectFromJikan(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AnimeSubject>> jikanDiscoveryFeed({int pages = 2}) async {
    final safePages = pages.clamp(1, 4);
    final groups = await Future.wait([
      jikanTop(
        limit: 25,
        filter: 'airing',
      ).onError((_, _) => const <AnimeSubject>[]),
      for (var page = 1; page <= safePages; page++)
        jikanTop(
          limit: 25,
          page: page,
          filter: 'bypopularity',
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> kitsuSearch(
    String keyword, {
    int limit = 20,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    return _kitsuSubjects(
      queryParameters: {
        'filter[text]': query,
        'page[limit]': '${limit.clamp(1, 20)}',
      },
    );
  }

  Future<List<AnimeSubject>> kitsuTrending({int limit = 20, int offset = 0}) {
    return _kitsuSubjects(
      queryParameters: {
        'sort': '-userCount',
        'page[limit]': '${limit.clamp(1, 20)}',
        'page[offset]': '${offset < 0 ? 0 : offset}',
      },
    );
  }

  Future<List<AnimeSubject>> kitsuTrendingFeed({int pages = 4}) async {
    final safePages = pages.clamp(1, 6);
    final groups = await Future.wait([
      for (var page = 0; page < safePages; page++)
        kitsuTrending(
          limit: 20,
          offset: page * 20,
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> _kitsuSubjects({
    required Map<String, String> queryParameters,
  }) async {
    final response = await _client
        .get(
          Uri.parse(
            'https://kitsu.io/api/edge/anime',
          ).replace(queryParameters: queryParameters),
          headers: const {'Accept': 'application/vnd.api+json'},
        )
        .timeout(const Duration(seconds: 16));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) => _subjectFromKitsu(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AnimeSubject>> _anilistSubjects(
    String query,
    Map<String, Object?> variables, {
    bool enabled = true,
  }) async {
    if (!enabled) return const [];
    final response = await _client
        .post(
          Uri.parse('https://graphql.anilist.co'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query, 'variables': variables}),
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final media = decoded is Map
        ? (((decoded['data'] as Map?)?['Page'] as Map?)?['media'] as List?)
        : null;
    if (media == null) return const [];
    return media
        .whereType<Map>()
        .map((item) => _subjectFromAnilist(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }

  Future<List<AnimeSubject>> cinemetaCatalog({
    required String type,
    int skip = 0,
    String genre = '',
    String search = '',
  }) async {
    final mediaType = type == 'series' ? 'series' : 'movie';
    final extras = <String>[];
    if (genre.trim().isNotEmpty) {
      extras.add('genre=${Uri.encodeComponent(genre.trim())}');
    }
    if (search.trim().isNotEmpty) {
      extras.add('search=${Uri.encodeComponent(search.trim())}');
    }
    if (skip > 0) extras.add('skip=$skip');
    final extraPath = extras.isEmpty ? '' : '/${extras.join('&')}';
    final response = await _client
        .get(
          Uri.parse('$_cinemetaBase/catalog/$mediaType/top$extraPath.json'),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 16));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final metas = decoded is Map ? decoded['metas'] : null;
    if (metas is! List) return const [];
    return metas
        .whereType<Map>()
        .map(
          (item) =>
              _subjectFromCinemeta(item.cast<String, dynamic>(), mediaType),
        )
        .where((item) => item.title.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AnimeSubject>> cinemetaFeed({
    required String type,
    int pages = 6,
    String genre = '',
  }) async {
    final safePages = pages.clamp(1, 6);
    final requests = <Future<List<AnimeSubject>>>[];
    for (var page = 0; page < safePages; page++) {
      final skip = page * 50;
      requests.add(
        cinemetaCatalog(
          type: type,
          skip: skip,
          genre: genre,
        ).onError((_, _) => const <AnimeSubject>[]),
      );
    }
    final groups = await Future.wait(requests);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> cinemetaSearch(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final groups = await Future.wait([
      cinemetaCatalog(
        type: 'movie',
        search: query,
      ).onError((_, _) => const <AnimeSubject>[]),
      cinemetaCatalog(
        type: 'series',
        search: query,
      ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> mediaSearch(String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    final groups = await Future.wait([
      cinemetaSearch(keyword).onError((_, _) => const <AnimeSubject>[]),
      tvMazeSearch(keyword).onError((_, _) => const <AnimeSubject>[]),
      wikidataMovieSearch(keyword).onError((_, _) => const <AnimeSubject>[]),
      internetArchiveSearch(keyword).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> tvMazeSearch(String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    final response = await _client
        .get(
          Uri.parse(
            'https://api.tvmaze.com/search/shows',
          ).replace(queryParameters: {'q': keyword.trim()}),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final results = decoded is List ? decoded : null;
    if (results == null) return const [];
    return results
        .whereType<Map>()
        .map((item) => _subjectFromTvMaze(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }

  Future<List<AnimeSubject>> tvMazeShows({int page = 0, int limit = 80}) async {
    final safePage = page < 0 ? 0 : page;
    final safeLimit = limit.clamp(1, 250).toInt();
    final response = await _client
        .get(
          Uri.parse(
            'https://api.tvmaze.com/shows',
          ).replace(queryParameters: {'page': '$safePage'}),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 16));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final results = decoded is List ? decoded : null;
    if (results == null) return const [];
    return results
        .whereType<Map>()
        .map((item) => _subjectFromTvMaze(item.cast<String, dynamic>()))
        .where((item) => item.title.trim().isNotEmpty)
        .take(safeLimit)
        .toList();
  }

  Future<List<AnimeSubject>> tvMazeShowsFeed({
    int pages = 3,
    int startPage = 0,
    int limitPerPage = 220,
  }) async {
    final safePages = pages.clamp(1, 10).toInt();
    final safeStartPage = startPage < 0 ? 0 : startPage;
    final safeLimit = limitPerPage.clamp(1, 250).toInt();
    final groups = await Future.wait([
      for (var offset = 0; offset < safePages; offset++)
        tvMazeShows(
          page: safeStartPage + offset,
          limit: safeLimit,
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects(groups.expand((items) => items));
  }

  Future<List<AnimeSubject>> tvMazeSchedule({
    required String country,
    required DateTime date,
  }) async {
    final response = await _client
        .get(
          Uri.parse('https://api.tvmaze.com/schedule').replace(
            queryParameters: {'country': country, 'date': _dateString(date)},
          ),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final results = decoded is List ? decoded : null;
    if (results == null) return const [];
    return results
        .whereType<Map>()
        .map((item) {
          final show = item['show'] is Map ? item['show'] as Map : item;
          return _subjectFromTvMaze(show.cast<String, dynamic>());
        })
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }

  Future<List<AnimeSubject>> seriesMetadataFeed({
    bool includeCinemeta = true,
    int cinemetaPages = 6,
    int tvMazePages = 3,
  }) async {
    final now = DateTime.now();
    final scheduleRequests = <Future<List<AnimeSubject>>>[];
    for (final country in const ['US', 'GB', 'KR', 'JP', 'CN']) {
      for (var days = 0; days < 2; days++) {
        scheduleRequests.add(
          tvMazeSchedule(
            country: country,
            date: now.subtract(Duration(days: days)),
          ).onError((_, _) => const <AnimeSubject>[]),
        );
      }
    }
    final groups = await Future.wait([
      if (includeCinemeta)
        cinemetaFeed(
          type: 'series',
          pages: cinemetaPages,
        ).onError((_, _) => const <AnimeSubject>[])
      else
        Future.value(const <AnimeSubject>[]),
      tvMazeShowsFeed(
        pages: tvMazePages,
      ).onError((_, _) => const <AnimeSubject>[]),
      ...scheduleRequests,
      tvMazeSearch('drama').onError((_, _) => const <AnimeSubject>[]),
      tvMazeSearch('korean drama').onError((_, _) => const <AnimeSubject>[]),
      tvMazeSearch('chinese drama').onError((_, _) => const <AnimeSubject>[]),
      tvMazeSearch('crime').onError((_, _) => const <AnimeSubject>[]),
    ]);
    final cinemeta = groups.first;
    final recent = _uniqueSubjects(groups.skip(1).expand((items) => items))
      ..sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
    return _uniqueSubjects([
      ..._interleaveSubjectGroups([cinemeta, recent], limitPerRound: 8),
      ...cinemeta,
      ...recent,
    ]).take(900).toList(growable: false);
  }

  Future<List<AnimeSubject>> movieMetadataFeed({
    String keyword = '',
    bool includeCinemeta = true,
    bool includeArchive = true,
    int cinemetaPages = 6,
  }) async {
    final query = keyword.trim();
    final groups = await Future.wait([
      if (!includeCinemeta)
        Future.value(const <AnimeSubject>[])
      else if (query.isEmpty)
        cinemetaFeed(
          type: 'movie',
          pages: cinemetaPages,
        ).onError((_, _) => const <AnimeSubject>[])
      else
        cinemetaCatalog(
          type: 'movie',
          search: query,
        ).onError((_, _) => const <AnimeSubject>[]),
      _wikidataMovies(
        keyword: query,
        limit: query.isEmpty ? 60 : 30,
      ).onError((_, _) => const <AnimeSubject>[]),
      if (includeArchive && query.isEmpty)
        internetArchiveCatalog(
          limit: 96,
          page: 1,
        ).onError((_, _) => const <AnimeSubject>[])
      else if (includeArchive)
        internetArchiveSearch(
          query,
          limit: 28,
          page: 1,
        ).onError((_, _) => const <AnimeSubject>[])
      else
        Future.value(const <AnimeSubject>[]),
      if (query.isEmpty && includeArchive)
        internetArchiveCatalog(
          limit: 96,
          page: 2,
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    final cinemeta = groups.first;
    final metadata = groups.length > 1 ? groups[1] : const <AnimeSubject>[];
    final playable = groups.skip(2).expand((items) => items).toList();
    return _uniqueSubjects([
      ..._interleaveSubjectGroups([
        cinemeta,
        playable,
        metadata,
      ], limitPerRound: 10),
      ...cinemeta,
      ...playable,
      ...metadata,
    ]).take(1000).toList(growable: false);
  }

  Future<List<AnimeSubject>> wikidataMovieSearch(String keyword) {
    if (keyword.trim().isEmpty) return Future.value(const []);
    return _wikidataMovies(keyword: keyword.trim(), limit: 24);
  }

  Future<List<AnimeSubject>> internetArchiveSearch(
    String keyword, {
    int limit = 18,
    int page = 1,
    String? collection,
  }) async {
    final query = keyword.trim();
    final requestedCollection = collection?.trim() ?? '';
    final trustedCollections =
        requestedCollection.isNotEmpty &&
            _archiveCollections.contains(requestedCollection)
        ? 'collection:$requestedCollection'
        : '(${_archiveCollections.map((item) => 'collection:$item').join(' OR ')})';
    final search = query.isEmpty
        ? 'mediatype:movies AND $trustedCollections AND '
              '(format:"MPEG4" OR format:"h.264")'
        : 'mediatype:movies AND $trustedCollections AND '
              'title:(${_archiveQuery(query)}) AND '
              '(format:"MPEG4" OR format:"h.264")';
    final response = await _client
        .get(
          Uri.parse('https://archive.org/advancedsearch.php').replace(
            queryParameters: {
              'q': search,
              'fl[]':
                  'identifier,title,description,date,language,downloads,'
                  'collection,licenseurl,rights',
              'rows': '${(limit * 4).clamp(limit, 100)}',
              'page': '${page.clamp(1, 20)}',
              'sort[]': 'downloads desc',
              'output': 'json',
            },
          ),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final docs = decoded is Map && decoded['response'] is Map
        ? (decoded['response'] as Map)['docs']
        : null;
    if (docs is! List) return const [];
    return docs
        .whereType<Map>()
        .map(
          (item) => _subjectFromInternetArchive(item.cast<String, dynamic>()),
        )
        .whereType<AnimeSubject>()
        .where((item) => item.title.trim().isNotEmpty)
        .take(limit.clamp(1, 100))
        .toList(growable: false);
  }

  /// Builds a broader playable catalogue from separately paged, curated
  /// Internet Archive collections. Items still need an explicit Public
  /// Domain, CC0, CC BY or CC BY-SA marker before they are returned.
  Future<List<AnimeSubject>> internetArchiveCatalog({
    int page = 1,
    int limit = 96,
  }) async {
    final safeLimit = limit.clamp(1, 240).toInt();
    final perCollection = ((safeLimit / _archiveCollections.length).ceil() * 2)
        .clamp(24, 60)
        .toInt();
    final groups = await Future.wait([
      for (final collection in _archiveCollections)
        internetArchiveSearch(
          '',
          collection: collection,
          page: page,
          limit: perCollection,
        ).onError((_, _) => const <AnimeSubject>[]),
    ]);
    return _uniqueSubjects([
      ..._interleaveSubjectGroups(groups, limitPerRound: 6),
      ...groups.expand((items) => items),
    ]).take(safeLimit).toList(growable: false);
  }

  Future<AnimeDetailBundle> externalDetail(AnimeSubject subject) async {
    if (subject.source.startsWith('cinemeta:')) {
      final detail = await _cinemetaDetail(subject);
      if (detail != null) return detail;
    }
    if (subject.source.startsWith('tvmaze')) {
      final detail = await _tvMazeDetail(subject);
      if (detail != null) return detail;
    }
    if (subject.source == 'wikidata') {
      return AnimeDetailBundle(
        subject: subject,
        episodes: _externalEpisodes(subject),
        characters: const [],
        staff: const [],
        recommendations: await movieMetadataFeed(keyword: subject.title)
            .onError((_, _) => const <AnimeSubject>[])
            .then(
              (items) => items
                  .where((item) => item.id != subject.id)
                  .take(8)
                  .map(
                    (item) =>
                        AnimeRecommendation(subject: item, relation: '相关电影'),
                  )
                  .toList(),
            ),
      );
    }
    return AnimeDetailBundle(
      subject: subject,
      episodes: _externalEpisodes(subject),
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }

  Future<AnimeDetailBundle?> _cinemetaDetail(AnimeSubject subject) async {
    final identity = _cinemetaIdentity(subject);
    if (identity == null) return null;
    final response = await _client
        .get(
          Uri.parse('$_cinemetaBase/meta/${identity.$1}/${identity.$2}.json'),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 16));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final meta = decoded is Map ? decoded['meta'] : null;
    if (meta is! Map) return null;
    final json = meta.cast<String, dynamic>();
    final detailedSubject = _subjectFromCinemeta(json, identity.$1);
    final episodes = _cinemetaEpisodes(json, detailedSubject);
    final genres = _stringList(json['genres']);
    final related = genres.isEmpty
        ? const <AnimeSubject>[]
        : await cinemetaCatalog(
            type: identity.$1,
            genre: genres.first,
          ).onError((_, _) => const <AnimeSubject>[]);
    return AnimeDetailBundle(
      subject: detailedSubject,
      episodes: episodes,
      characters: _cinemetaCharacters(json),
      staff: _cinemetaStaff(json),
      recommendations: related
          .where((item) => item.source != detailedSubject.source)
          .take(12)
          .map(
            (item) =>
                AnimeRecommendation(subject: item, relation: genres.first),
          )
          .toList(growable: false),
    );
  }

  Future<List<SubtitleCandidate>> searchSubtitles(
    AnimeSubject subject,
    AnimeEpisode episode,
    ExternalServiceSettings settings,
  ) async {
    if (!settings.bilibiliSubtitleEnabled) return const [];
    final match = await _bilibiliEpisodeMatch(subject, episode);
    if (match == null) {
      return [
        const SubtitleCandidate(
          provider: 'Bilibili',
          title: '未匹配到 B 站番剧',
          language: 'zh-CN',
          available: false,
          message: 'B 站公开搜索没有匹配到当前集字幕',
        ),
      ];
    }
    final subtitles = await _bilibiliSubtitles(match, settings);
    if (subtitles.isNotEmpty) return subtitles;
    return [
      SubtitleCandidate(
        provider: 'Bilibili',
        title: '${match.seasonTitle} ${match.episodeTitle}',
        language: settings.subtitleLanguage,
        available: false,
        message: 'B 站当前集没有公开字幕，或字幕需要登录/版权权限',
      ),
    ];
  }

  Future<List<DanmakuMatch>> matchDanmaku(
    AnimeSubject subject,
    AnimeEpisode episode,
    ExternalServiceSettings settings,
  ) async {
    final customEndpoint = settings.customDanmakuEndpoint.trim();
    if (settings.customDanmakuEnabled && customEndpoint.isNotEmpty) {
      final custom = await _matchCustomDanmaku(
        customEndpoint,
        subject,
        episode,
      );
      if (custom.isNotEmpty) return custom;
    }
    final results = <DanmakuMatch>[];
    if (settings.dandanplayDanmakuEnabled) {
      results.addAll(await _matchDandanplayDanmaku(subject, episode, settings));
      if (results.any((item) => item.available)) return results;
    }
    if (!settings.bilibiliDanmakuEnabled) {
      return results;
    }
    final match = await _bilibiliEpisodeMatch(subject, episode);
    if (match == null) {
      return [
        ...results,
        const DanmakuMatch(
          provider: 'Bilibili',
          title: '未匹配到 B 站番剧',
          episodeTitle: '',
          episodeId: '',
          available: false,
          message: 'B 站公开搜索没有匹配到当前集弹幕',
        ),
      ];
    }
    final count = await _bilibiliDanmakuCount(match.cid);
    return [
      ...results,
      DanmakuMatch(
        provider: 'Bilibili',
        title: match.seasonTitle,
        episodeTitle: match.episodeTitle,
        episodeId: '${match.cid}',
        commentCount: count,
        available: count > 0,
        message: count > 0 ? null : 'B 站弹幕接口没有返回公开弹幕',
      ),
    ];
  }

  Future<bool> syncLocalHistory(
    AnimeSubject subject,
    AnimeEpisode? episode,
    ExternalServiceSettings settings,
  ) async {
    return settings.publicCollectionSyncEnabled;
  }

  Future<List<DanmakuMatch>> _matchDandanplayDanmaku(
    AnimeSubject subject,
    AnimeEpisode episode,
    ExternalServiceSettings settings,
  ) async {
    final appId = settings.dandanplayAppId.trim();
    final appSecret = settings.dandanplayAppSecret.trim();
    if (appId.isEmpty || appSecret.isEmpty) {
      return [
        const DanmakuMatch(
          provider: '弹弹play',
          title: '弹弹play 弹幕源',
          episodeTitle: '',
          episodeId: '',
          available: false,
          message: '需要在弹幕源设置里填写 AppId 和 AppSecret',
        ),
      ];
    }

    try {
      final response = await _client
          .get(
            _dandanplayUri(
              'https://api.dandanplay.net/api/v2/search/episodes',
              queryParameters: {
                'anime': _dandanplayKeyword(subject),
                'episode': subject.platform == 'Movie'
                    ? 'movie'
                    : '${episode.number}',
              },
            ),
            headers: _dandanplayHeaders(
              appId,
              appSecret,
              '/api/v2/search/episodes',
            ),
          )
          .timeout(const Duration(seconds: 14));
      if (response.statusCode == 401 || response.statusCode == 403) {
        return [_dandanplayUnavailable('弹弹play 凭证无效或权限不足')];
      }
      if (response.statusCode != 200) {
        return [
          _dandanplayUnavailable('弹弹play 搜索失败：HTTP ${response.statusCode}'),
        ];
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final selected = _pickDandanplayEpisode(decoded, subject, episode);
      if (selected == null) {
        return [
          DanmakuMatch(
            provider: '弹弹play',
            title: subject.title,
            episodeTitle: episode.displayTitle,
            episodeId: '',
            available: false,
            message: '弹弹play 没有匹配到当前集弹幕库',
          ),
        ];
      }
      final count = await _dandanplayCommentCount(
        selected.episodeId,
        appId,
        appSecret,
      );
      return [
        DanmakuMatch(
          provider: '弹弹play',
          title: selected.title,
          episodeTitle: selected.episodeTitle,
          episodeId: '${selected.episodeId}',
          commentCount: count,
          available: count > 0,
          message: count > 0 ? null : '已匹配弹幕库，但没有返回弹幕内容',
        ),
      ];
    } catch (_) {
      return [_dandanplayUnavailable('弹弹play 暂时无法访问')];
    }
  }

  DanmakuMatch _dandanplayUnavailable(String message) {
    return DanmakuMatch(
      provider: '弹弹play',
      title: '弹弹play 弹幕源',
      episodeTitle: '',
      episodeId: '',
      available: false,
      message: message,
    );
  }

  Future<int> _dandanplayCommentCount(
    int episodeId,
    String appId,
    String appSecret,
  ) async {
    if (episodeId <= 0) return 0;
    final response = await _client
        .get(
          _dandanplayUri(
            'https://api.dandanplay.net/api/v2/comment/$episodeId',
            queryParameters: const {
              'from': '0',
              'withRelated': 'true',
              'chConvert': '1',
            },
          ),
          headers: _dandanplayHeaders(
            appId,
            appSecret,
            '/api/v2/comment/$episodeId',
          ),
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200 && response.statusCode != 302) return 0;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return 0;
    return _intValue(decoded['count']) ??
        (decoded['comments'] is List
            ? (decoded['comments'] as List).length
            : 0);
  }

  Uri _dandanplayUri(String url, {Map<String, String>? queryParameters}) {
    return Uri.parse(url).replace(queryParameters: queryParameters);
  }

  Map<String, String> _dandanplayHeaders(
    String appId,
    String appSecret,
    String path,
  ) {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = sha256.convert(
      utf8.encode('$appId$timestamp$path$appSecret'),
    );
    final signature = base64Encode(digest.bytes);
    return {
      'Accept': 'application/json',
      'User-Agent': 'anime-app/1.0',
      'X-AppId': appId,
      'X-Timestamp': '$timestamp',
      'X-Signature': signature,
    };
  }

  _DandanplayEpisode? _pickDandanplayEpisode(
    Object? decoded,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    final root = decoded is Map ? decoded : const {};
    final animes = _mapList(root['animes'] ?? root['items'] ?? root['data']);
    if (animes.isEmpty) return null;

    _DandanplayEpisode? fallback;
    var bestScore = -1;
    for (final anime in animes) {
      final title = _bestText(
        anime['animeTitle'],
        anime['title'],
        anime['name'],
      );
      final titleScore = _titleScore(title, subject);
      final episodes = _mapList(anime['episodes']);
      for (final item in episodes) {
        final episodeId = _intValue(item['episodeId'] ?? item['id']) ?? 0;
        if (episodeId <= 0) continue;
        final episodeTitle = _bestText(
          item['episodeTitle'],
          item['title'],
          item['name'],
        );
        final score =
            titleScore + (_episodeMatches(episodeTitle, episode) ? 40 : 0);
        final candidate = _DandanplayEpisode(
          title: title.isEmpty ? subject.title : title,
          episodeTitle: episodeTitle.isEmpty
              ? episode.displayTitle
              : episodeTitle,
          episodeId: episodeId,
        );
        fallback ??= candidate;
        if (score > bestScore) {
          bestScore = score;
          fallback = candidate;
        }
      }
    }
    return fallback;
  }

  String _dandanplayKeyword(AnimeSubject subject) {
    final title = subject.title.trim();
    if (title.length >= 2) return title;
    final original = subject.originalTitle.trim();
    return original.length >= 2 ? original : title;
  }

  bool _episodeMatches(String title, AnimeEpisode episode) {
    final normalized = title.toLowerCase();
    final number = episode.number.toString();
    return normalized == number ||
        normalized.contains('第$number') ||
        normalized.contains('ep$number') ||
        normalized.contains('episode $number');
  }

  int _titleScore(String value, AnimeSubject subject) {
    final candidate = _normalizeTitle(value);
    if (candidate.isEmpty) return 0;
    final targets = [
      _normalizeTitle(subject.title),
      _normalizeTitle(subject.originalTitle),
    ].where((item) => item.isNotEmpty);
    var score = 0;
    for (final target in targets) {
      if (candidate == target) {
        score = score < 100 ? 100 : score;
      } else if (candidate.contains(target) || target.contains(candidate)) {
        score = score < 70 ? 70 : score;
      }
    }
    return score;
  }

  String _normalizeTitle(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_·・:：,，.。!！?？\[\]【】()]'), '')
        .trim();
  }

  List<Map<dynamic, dynamic>> _mapList(Object? value) {
    if (value is! List) return const [];
    return value.whereType<Map>().toList(growable: false);
  }

  Future<List<DanmakuMatch>> _matchCustomDanmaku(
    String endpoint,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    try {
      final response = await _client
          .get(
            Uri.parse(endpoint).replace(
              queryParameters: {
                'title': subject.title,
                'episode': '${episode.number}',
              },
            ),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final data = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['data'] as List?
          : null;
      if (data == null) return const [];
      return [
        ...data.whereType<Map>().map(
          (item) => DanmakuMatch(
            provider: '自建弹幕库',
            title: item['title']?.toString() ?? subject.title,
            episodeTitle:
                item['episodeTitle']?.toString() ?? episode.displayTitle,
            episodeId: item['episodeId']?.toString() ?? '',
            commentCount: _intValue(item['commentCount']) ?? 0,
            available: true,
          ),
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<_BilibiliEpisodeMatch?> _bilibiliEpisodeMatch(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final seasonId = await _bilibiliSeasonId(subject);
    if (seasonId == null) return null;
    final response = await _client
        .get(
          Uri.parse(
            'https://api.bilibili.com/pgc/view/web/season',
          ).replace(queryParameters: {'season_id': '$seasonId'}),
          headers: _browserHeaders,
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final result = decoded is Map ? decoded['result'] as Map? : null;
    final episodes = result?['episodes'] is List
        ? result!['episodes'] as List
        : const [];
    if (episodes.isEmpty) return null;
    final selected = episodes
        .whereType<Map>()
        .cast<Map<dynamic, dynamic>>()
        .firstWhere(
          (item) => _intValue(item['title']) == episode.number,
          orElse: () => episodes
              .whereType<Map>()
              .cast<Map<dynamic, dynamic>>()
              .elementAt((episode.number - 1).clamp(0, episodes.length - 1)),
        );
    final longTitle = _stripHtml(selected['long_title']?.toString() ?? '');
    return _BilibiliEpisodeMatch(
      seasonTitle: _stripHtml(result?['title']?.toString() ?? subject.title),
      episodeTitle: longTitle.isEmpty ? '第${episode.number}集' : longTitle,
      aid: _intValue(selected['aid']) ?? 0,
      cid: _intValue(selected['cid']) ?? 0,
    );
  }

  Future<int?> _bilibiliSeasonId(AnimeSubject subject) async {
    final response = await _client
        .get(
          Uri.parse(
            'https://api.bilibili.com/x/web-interface/search/type',
          ).replace(
            queryParameters: {
              'search_type': 'media_bangumi',
              'keyword': subject.title,
            },
          ),
          headers: _browserHeaders,
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded is Map ? decoded['data'] as Map? : null;
    final result = data?['result'] is List ? data!['result'] as List : null;
    if (result == null || result.isEmpty) return null;
    final candidates = result.whereType<Map>().toList();
    final exact = candidates.cast<Map<dynamic, dynamic>?>().firstWhere((item) {
      final title = _stripHtml(item?['title']?.toString() ?? '');
      final origin = _stripHtml(item?['org_title']?.toString() ?? '');
      return title == subject.title || origin == subject.originalTitle;
    }, orElse: () => null);
    final selected = exact ?? candidates.first;
    return _intValue(selected['season_id']);
  }

  Future<List<SubtitleCandidate>> _bilibiliSubtitles(
    _BilibiliEpisodeMatch match,
    ExternalServiceSettings settings,
  ) async {
    if (match.aid <= 0 || match.cid <= 0) return const [];
    final response = await _client
        .get(
          Uri.parse('https://api.bilibili.com/x/player/v2').replace(
            queryParameters: {'aid': '${match.aid}', 'cid': '${match.cid}'},
          ),
          headers: {
            ..._browserHeaders,
            'Referer': 'https://www.bilibili.com/bangumi/play/',
          },
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded is Map ? decoded['data'] as Map? : null;
    final subtitle = data?['subtitle'] is Map ? data!['subtitle'] as Map : null;
    final list = subtitle?['subtitles'] is List
        ? subtitle!['subtitles'] as List
        : const [];
    return list.whereType<Map>().map((item) {
      final lan = item['lan']?.toString() ?? settings.subtitleLanguage;
      final url = item['subtitle_url']?.toString() ?? '';
      return SubtitleCandidate(
        provider: 'Bilibili',
        title: item['lan_doc']?.toString() ?? '$lan 字幕',
        language: lan,
        fileName: url.split('/').last,
        downloadUrl: url.startsWith('//') ? 'https:$url' : url,
        available: url.isNotEmpty,
        message: url.isEmpty ? '字幕地址未公开' : null,
      );
    }).toList();
  }

  Future<int> _bilibiliDanmakuCount(int cid) async {
    if (cid <= 0) return 0;
    final response = await _client
        .get(
          Uri.parse(
            'https://api.bilibili.com/x/v1/dm/list.so',
          ).replace(queryParameters: {'oid': '$cid'}),
          headers: {
            ..._browserHeaders,
            'Accept': 'text/xml,application/xml,text/plain,*/*',
          },
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return 0;
    return RegExp(r'<d\s').allMatches(utf8.decode(response.bodyBytes)).length;
  }

  Future<List<AnimeSubject>> _tmdbSubjects({
    required String path,
    required String type,
    required Map<String, String> queryParameters,
  }) async {
    final response = await _tmdbGet(
      Uri.parse('$_tmdbBase$path').replace(queryParameters: queryParameters),
    );
    if (response == null || response.statusCode != 200) return const [];
    final json = _decodeJsonMap(response);
    final results = json['results'];
    if (results is! List) return const [];
    return results
        .whereType<Map>()
        .map((item) => _subjectFromTmdb(item.cast<String, dynamic>(), type))
        .where((item) => item.id > 0 && item.title.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<http.Response?> _tmdbGet(Uri uri) async {
    if (_tmdbRequestIsCoolingDown()) return null;
    final generation = _tmdbAccessTokenGeneration;
    final token = await _readTmdbAccessToken();
    if (token == null || generation != _tmdbAccessTokenGeneration) return null;
    try {
      final response = await _client
          .get(uri, headers: _tmdbHeaders(token))
          .timeout(const Duration(seconds: 8));
      if (generation != _tmdbAccessTokenGeneration) return null;
      _acceptTmdbRateLimit(response);
      if (response.statusCode == 403) {
        _startTmdbCooldown(_tmdbDefaultRateLimitCooldown);
      }
      if (response.statusCode == 401) {
        await _rejectTmdbAccessToken(token, generation);
      }
      return response;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readTmdbAccessToken() async {
    if (_suppressTmdbAccessToken) return null;
    try {
      final token = (await _tmdbAccessTokenProvider?.call())?.trim() ?? '';
      if (token.length < 32 ||
          token.length > 2048 ||
          RegExp(r'[\r\n\s]').hasMatch(token)) {
        return null;
      }
      return token;
    } catch (_) {
      return null;
    }
  }

  Future<void> _rejectTmdbAccessToken(String token, int generation) async {
    if (generation != _tmdbAccessTokenGeneration ||
        _rejectedTmdbAccessTokens.contains(token)) {
      return;
    }
    String currentToken;
    try {
      currentToken = (await _tmdbAccessTokenProvider?.call())?.trim() ?? '';
    } catch (_) {
      return;
    }
    if (generation != _tmdbAccessTokenGeneration || currentToken != token) {
      return;
    }
    if (!_rejectedTmdbAccessTokens.add(token)) return;
    _suppressTmdbAccessToken = true;
    _tmdbAccessTokenGeneration++;
    try {
      await _onTmdbAccessTokenRejected?.call(token);
    } catch (_) {
      // Persisting the rejected state must not make metadata calls fail.
    }
  }

  Map<String, String> _tmdbHeaders(String token) => {
    'Accept': 'application/json',
    'Authorization': 'Bearer $token',
  };

  void _acceptTmdbRateLimit(http.Response response) {
    if (response.statusCode != 429) return;
    final retryAfter = int.tryParse(
      response.headers['retry-after']?.trim() ?? '',
    );
    final seconds = retryAfter == null
        ? _tmdbDefaultRateLimitCooldown.inSeconds
        : retryAfter.clamp(1, _tmdbMaxRateLimitCooldown.inSeconds).toInt();
    _startTmdbCooldown(Duration(seconds: seconds));
  }

  void _startTmdbCooldown(Duration duration) {
    final candidate = DateTime.now().toUtc().add(duration);
    final current = _tmdbRateLimitedUntil;
    if (current == null || candidate.isAfter(current)) {
      _tmdbRateLimitedUntil = candidate;
    }
  }

  bool _tmdbRequestIsCoolingDown() {
    final until = _tmdbRateLimitedUntil;
    if (until == null) return false;
    if (until.isAfter(DateTime.now().toUtc())) return true;
    _tmdbRateLimitedUntil = null;
    return false;
  }

  Map<String, dynamic> _decodeJsonMap(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  (String, int)? _tmdbIdentity(AnimeSubject subject) {
    final parts = subject.source.split(':');
    if (parts.length != 3 || parts.first != 'tmdb') return null;
    final type = switch (parts[1]) {
      'movie' => 'movie',
      'series' => 'tv',
      _ => null,
    };
    final id = int.tryParse(parts[2]);
    if (type == null || id == null || id <= 0) return null;
    return (type, id);
  }

  AnimeSubject _subjectFromTmdb(Map<String, dynamic> json, String type) {
    final isSeries = type == 'tv';
    final id = _intValue(json['id']) ?? 0;
    final title = _bestText(
      isSeries ? json['name'] : json['title'],
      isSeries ? json['original_name'] : json['original_title'],
      '',
    );
    final originalTitle = _bestText(
      isSeries ? json['original_name'] : json['original_title'],
      title,
      '',
    );
    final totalEpisodes = isSeries
        ? _intValue(json['number_of_episodes']) ?? 0
        : 1;
    final categories = _tmdbCategories(json);
    final region = _tmdbRegion(json);
    final companies = json['production_companies'] is List
        ? json['production_companies'] as List
        : const [];
    return AnimeSubject(
      id: id,
      title: title,
      originalTitle: originalTitle,
      summary: _cleanText(json['overview']?.toString()),
      coverUrl: _tmdbImageUrl(json['poster_path'], 'w500'),
      bannerUrl: _tmdbImageUrl(json['backdrop_path'], 'w1280'),
      date: _dateOnly(
        (isSeries ? json['first_air_date'] : json['release_date'])?.toString(),
      ),
      platform: isSeries ? 'Series' : 'Movie',
      language: _tmdbLanguageName(json['original_language']?.toString()),
      region: region,
      status: _tmdbStatus(json['status']?.toString(), isSeries, totalEpisodes),
      categories: categories,
      tags: [
        const AnimeTag(name: 'TMDB'),
        ...companies
            .whereType<Map>()
            .map((item) => item['name']?.toString().trim() ?? '')
            .where((name) => name.isNotEmpty)
            .take(5)
            .map((name) => AnimeTag(name: name)),
      ],
      totalEpisodes: totalEpisodes,
      ratingScore: (json['vote_average'] as num?)?.toDouble(),
      ratingTotal: _intValue(json['vote_count']),
      source: 'tmdb:${isSeries ? 'series' : 'movie'}:$id',
    );
  }

  List<AnimeCategory> _tmdbCategories(Map<String, dynamic> json) {
    final genres = json['genres'];
    if (genres is List) {
      return genres
          .whereType<Map>()
          .map((item) => item['name']?.toString().trim() ?? '')
          .where((name) => name.isNotEmpty)
          .take(6)
          .map((name) => AnimeCategory(name: name))
          .toList(growable: false);
    }
    final genreIds = json['genre_ids'];
    if (genreIds is! List) return const [];
    return genreIds
        .map(_intValue)
        .whereType<int>()
        .map((id) => _tmdbGenreNames[id])
        .whereType<String>()
        .take(6)
        .map((name) => AnimeCategory(name: name))
        .toList(growable: false);
  }

  String _tmdbRegion(Map<String, dynamic> json) {
    final countries = json['production_countries'];
    if (countries is List) {
      final names = countries
          .whereType<Map>()
          .map((item) {
            final code = item['iso_3166_1']?.toString();
            return _tmdbCountryName(code, item['name']?.toString());
          })
          .where((name) => name.isNotEmpty)
          .take(3)
          .toList(growable: false);
      if (names.isNotEmpty) return names.join('/');
    }
    final origins = json['origin_country'];
    if (origins is List) {
      final names = origins
          .map((item) => _tmdbCountryName(item?.toString(), null))
          .where((name) => name.isNotEmpty)
          .take(3)
          .toList(growable: false);
      if (names.isNotEmpty) return names.join('/');
    }
    return 'TMDB';
  }

  List<AnimeEpisode> _tmdbSeriesEpisodes(
    Map<String, dynamic> json,
    AnimeSubject subject,
  ) {
    final rawSeasons = json['seasons'] is List
        ? (json['seasons'] as List).whereType<Map>().toList(growable: false)
        : const <Map>[];
    final seasons =
        rawSeasons
            .where((season) {
              final number = _intValue(season['season_number']) ?? 0;
              return number > 0 &&
                  (_intValue(season['episode_count']) ?? 0) > 0;
            })
            .toList(growable: false)
          ..sort(
            (a, b) => (_intValue(a['season_number']) ?? 0).compareTo(
              _intValue(b['season_number']) ?? 0,
            ),
          );
    final reportedTotal = _intValue(json['number_of_episodes']) ?? 0;
    final seasonTotal = seasons.fold<int>(
      0,
      (total, season) => total + (_intValue(season['episode_count']) ?? 0),
    );
    final targetTotal = reportedTotal > 0 ? reportedTotal : seasonTotal;
    if (targetTotal <= 0) return const [];
    final runtime = _tmdbRuntime(json);
    final episodes = <AnimeEpisode>[];
    for (final season in seasons) {
      final seasonNumber = _intValue(season['season_number']) ?? 0;
      final episodeCount = _intValue(season['episode_count']) ?? 0;
      final seasonSummary = season['overview']?.toString().trim() ?? '';
      final seasonDate = _dateOnly(season['air_date']?.toString());
      final seasonImage =
          _tmdbImageUrl(season['poster_path'], 'w500') ??
          subject.bannerUrl ??
          subject.coverUrl;
      for (
        var episodeNumber = 1;
        episodeNumber <= episodeCount && episodes.length < targetTotal;
        episodeNumber++
      ) {
        final globalNumber = episodes.length + 1;
        episodes.add(
          AnimeEpisode(
            id: _stableInt('${subject.source}:$seasonNumber:$episodeNumber'),
            subjectId: subject.id,
            number: globalNumber,
            title: '第$seasonNumber季 第$episodeNumber集',
            airdate: episodeNumber == 1 ? seasonDate : null,
            duration: runtime,
            description: seasonSummary.isEmpty
                ? subject.summary
                : seasonSummary,
            thumbnailUrl: seasonImage,
          ),
        );
      }
    }
    while (episodes.length < targetTotal) {
      final globalNumber = episodes.length + 1;
      episodes.add(
        AnimeEpisode(
          id: _stableInt('${subject.source}:episode:$globalNumber'),
          subjectId: subject.id,
          number: globalNumber,
          title: '',
          airdate: globalNumber == 1 ? subject.date : null,
          duration: runtime,
          description: subject.summary,
          thumbnailUrl: subject.bannerUrl ?? subject.coverUrl,
        ),
      );
    }
    return episodes;
  }

  List<AnimeEpisode> _tmdbMovieEpisodes(
    Map<String, dynamic> json,
    AnimeSubject subject,
  ) {
    return [
      AnimeEpisode(
        id: _stableInt('${subject.source}:feature'),
        subjectId: subject.id,
        number: 1,
        title: '正片',
        airdate: subject.date,
        duration: _tmdbRuntime(json),
        description: subject.summary,
        thumbnailUrl: subject.bannerUrl ?? subject.coverUrl,
      ),
    ];
  }

  List<AnimeCharacter> _tmdbCharacters(Map<String, dynamic> credits) {
    final cast = credits['cast'];
    if (cast is! List) return const [];
    return cast
        .whereType<Map>()
        .map((item) {
          final actor = item['name']?.toString().trim() ?? '';
          final character = item['character']?.toString().trim() ?? '';
          final creditId = item['credit_id']?.toString() ?? '';
          return AnimeCharacter(
            id:
                _intValue(item['cast_id']) ??
                _intValue(item['id']) ??
                _stableInt('tmdb-cast:$creditId:$actor:$character'),
            name: character.isEmpty ? actor : character,
            relation: '角色',
            cv: actor,
            summary: '',
            imageUrl: _tmdbImageUrl(item['profile_path'], 'w500'),
          );
        })
        .where((item) => item.name.isNotEmpty)
        .take(24)
        .toList(growable: false);
  }

  List<AnimeStaff> _tmdbStaff(Map<String, dynamic> credits) {
    final crew = credits['crew'];
    if (crew is! List) return const [];
    final items = crew.whereType<Map>().toList(growable: false)
      ..sort(
        (a, b) => _tmdbCrewPriority(
          a['department']?.toString(),
        ).compareTo(_tmdbCrewPriority(b['department']?.toString())),
      );
    final seen = <String>{};
    final result = <AnimeStaff>[];
    for (final item in items) {
      final name = item['name']?.toString().trim() ?? '';
      final job = item['job']?.toString().trim() ?? '';
      if (name.isEmpty || !seen.add('$name\u0000$job')) continue;
      result.add(
        AnimeStaff(
          id: _intValue(item['id']) ?? _stableInt('$name:$job'),
          name: name,
          role: _tmdbCrewRole(job, item['department']?.toString()),
          career: item['department']?.toString() ?? '',
          imageUrl: _tmdbImageUrl(item['profile_path'], 'w500'),
        ),
      );
      if (result.length >= 24) break;
    }
    return result;
  }

  String _tmdbRuntime(Map<String, dynamic> json) {
    final runtime = _intValue(json['runtime']);
    if (runtime != null && runtime > 0) return _formatMinutes(runtime);
    final episodeRuntimes = json['episode_run_time'];
    if (episodeRuntimes is List) {
      final first = episodeRuntimes.map(_intValue).whereType<int>().firstOrNull;
      if (first != null && first > 0) return _formatMinutes(first);
    }
    return '待补';
  }

  String _tmdbStatus(String? status, bool isSeries, int totalEpisodes) {
    final translated = switch (status?.trim()) {
      'Returning Series' => '连载中',
      'In Production' => '制作中',
      'Planned' => '已计划',
      'Pilot' => '试播',
      'Ended' => '已完结',
      'Canceled' => '已取消',
      'Released' => '已上映',
      'Post Production' => '后期制作',
      'Rumored' => '传闻',
      _ => status?.trim() ?? '',
    };
    if (isSeries && totalEpisodes > 0) {
      return translated.isEmpty
          ? '全$totalEpisodes集'
          : '$translated · 全$totalEpisodes集';
    }
    return translated.isEmpty ? (isSeries ? '剧集' : '电影') : translated;
  }

  String _tmdbCrewRole(String job, String? department) {
    return switch (job) {
      'Director' => '导演',
      'Writer' || 'Screenplay' => '编剧',
      'Producer' => '制片人',
      'Executive Producer' => '执行制片人',
      'Director of Photography' => '摄影指导',
      'Original Music Composer' => '作曲',
      'Editor' => '剪辑',
      'Casting' => '选角',
      _ => job.isNotEmpty ? job : department?.trim() ?? '制作人员',
    };
  }

  int _tmdbCrewPriority(String? department) {
    return switch (department?.trim()) {
      'Directing' => 0,
      'Writing' => 1,
      'Production' => 2,
      'Camera' => 3,
      'Sound' => 4,
      'Editing' => 5,
      _ => 10,
    };
  }

  String _tmdbLanguageName(String? code) {
    return switch (code?.toLowerCase()) {
      'zh' => '中文',
      'ja' => '日语',
      'ko' => '韩语',
      'en' => '英语',
      'fr' => '法语',
      'de' => '德语',
      'es' => '西班牙语',
      'it' => '意大利语',
      'ru' => '俄语',
      null || '' => '未知',
      final code => code,
    };
  }

  String _tmdbCountryName(String? code, String? fallback) {
    final normalized = code?.toUpperCase().trim() ?? '';
    return switch (normalized) {
      'CN' => '中国大陆',
      'HK' => '中国香港',
      'TW' => '中国台湾',
      'JP' => '日本',
      'KR' => '韩国',
      'US' => '美国',
      'GB' => '英国',
      'FR' => '法国',
      'DE' => '德国',
      'IN' => '印度',
      _ => fallback?.trim().isNotEmpty == true ? fallback!.trim() : normalized,
    };
  }

  String? _tmdbImageUrl(Object? path, String size) {
    final value = path?.toString().trim() ?? '';
    if (value.isEmpty || !value.startsWith('/')) return null;
    return '$_tmdbImageBase/$size$value';
  }

  AnimeSubject _subjectFromAnilist(Map<String, dynamic> json) {
    final title = json['title'] is Map ? json['title'] as Map : const {};
    final cover = json['coverImage'] is Map
        ? json['coverImage'] as Map
        : const {};
    final startDate = json['startDate'] is Map
        ? json['startDate'] as Map
        : const {};
    final tags = json['tags'] is List ? json['tags'] as List : const [];
    final genres = json['genres'] is List ? json['genres'] as List : const [];
    final date = _dateFromParts(
      startDate['year'],
      startDate['month'],
      startDate['day'],
    );
    return AnimeSubject(
      id: _intValue(json['id']) ?? 0,
      title: _bestText(title['english'], title['romaji'], title['native']),
      originalTitle: title['native']?.toString() ?? '',
      summary: _cleanText(json['description']?.toString()),
      coverUrl: cover['large']?.toString() ?? cover['extraLarge']?.toString(),
      bannerUrl: json['bannerImage']?.toString(),
      date: date,
      platform: json['format']?.toString() ?? 'TV',
      language: '日语',
      region: '日本',
      status: json['episodes'] == null ? '未确定' : '全${json['episodes']}集',
      categories: genres
          .map((item) => AnimeCategory(name: item.toString()))
          .take(4)
          .toList(),
      tags: tags
          .whereType<Map>()
          .map(
            (item) => AnimeTag(
              name: item['name']?.toString() ?? '',
              count: _intValue(item['rank']) ?? 0,
            ),
          )
          .where((item) => item.name.isNotEmpty)
          .take(20)
          .toList(),
      totalEpisodes: _intValue(json['episodes']) ?? 0,
      ratingScore: (json['averageScore'] as num?) == null
          ? null
          : (json['averageScore'] as num).toDouble() / 10,
      source: 'anilist',
    );
  }

  AnimeSubject _subjectFromJikan(Map<String, dynamic> json) {
    final titles = json['titles'] is List ? json['titles'] as List : const [];
    final images = json['images'] is Map ? json['images'] as Map : const {};
    final jpg = images['jpg'] is Map ? images['jpg'] as Map : const {};
    final trailer = json['trailer'] is Map ? json['trailer'] as Map : const {};
    final title = titles
        .whereType<Map>()
        .map((item) => item['title']?.toString() ?? '')
        .firstWhere(
          (item) => item.trim().isNotEmpty,
          orElse: () => json['title']?.toString() ?? '',
        );
    final genres = <Object?>[
      if (json['genres'] is List) ...(json['genres'] as List),
      if (json['themes'] is List) ...(json['themes'] as List),
    ];
    final studios = json['studios'] is List
        ? json['studios'] as List
        : const [];
    return AnimeSubject(
      id: _intValue(json['mal_id']) ?? 0,
      title: title,
      originalTitle: json['title_japanese']?.toString() ?? title,
      summary: _cleanText(json['synopsis']?.toString()),
      coverUrl:
          jpg['image_url']?.toString() ?? jpg['large_image_url']?.toString(),
      bannerUrl: trailer['images'] is Map
          ? ((trailer['images'] as Map)['maximum_image_url']?.toString() ??
                jpg['large_image_url']?.toString())
          : jpg['large_image_url']?.toString(),
      date: json['aired'] is Map
          ? ((json['aired'] as Map)['from']?.toString())
          : null,
      platform: json['type']?.toString() ?? 'TV',
      language: '日语',
      region: '日本',
      status: json['status']?.toString() ?? '动画',
      categories: genres
          .whereType<Map>()
          .map((item) => AnimeCategory(name: item['name']?.toString() ?? ''))
          .where((item) => item.name.isNotEmpty)
          .take(6)
          .toList(),
      tags: studios
          .whereType<Map>()
          .map((item) => AnimeTag(name: item['name']?.toString() ?? ''))
          .where((item) => item.name.isNotEmpty)
          .take(6)
          .toList(),
      totalEpisodes: _intValue(json['episodes']) ?? 0,
      ratingScore: (json['score'] as num?)?.toDouble(),
      ratingRank: _intValue(json['rank']),
      ratingTotal: _intValue(json['scored_by']),
      source: 'jikan',
    );
  }

  AnimeSubject _subjectFromKitsu(Map<String, dynamic> json) {
    final attributes = json['attributes'] is Map
        ? json['attributes'] as Map
        : const {};
    final titles = attributes['titles'] is Map
        ? attributes['titles'] as Map
        : const {};
    final poster = attributes['posterImage'] is Map
        ? attributes['posterImage'] as Map
        : const {};
    final cover = attributes['coverImage'] is Map
        ? attributes['coverImage'] as Map
        : const {};
    final title = _bestText(
      titles['zh_cn'],
      attributes['canonicalTitle'],
      titles['en_jp'],
    );
    final subtype = attributes['subtype']?.toString() ?? 'TV';
    final averageRating = double.tryParse(
      attributes['averageRating']?.toString() ?? '',
    );
    return AnimeSubject(
      id: int.tryParse(json['id']?.toString() ?? '') ?? title.hashCode.abs(),
      title: title,
      originalTitle: titles['ja_jp']?.toString() ?? title,
      summary: _cleanText(attributes['synopsis']?.toString()),
      coverUrl: poster['large']?.toString() ?? poster['original']?.toString(),
      bannerUrl: cover['original']?.toString() ?? cover['large']?.toString(),
      date: attributes['startDate']?.toString(),
      platform: subtype,
      language: '日语',
      region: '日本',
      status: attributes['status']?.toString() ?? '动画',
      categories: [AnimeCategory(name: subtype)],
      tags: const [AnimeTag(name: 'Kitsu')],
      totalEpisodes: _intValue(attributes['episodeCount']) ?? 0,
      ratingScore: averageRating == null ? null : averageRating / 10,
      ratingTotal: _intValue(attributes['userCount']),
      source: 'kitsu',
    );
  }

  AnimeSubject _subjectFromCinemeta(
    Map<String, dynamic> json,
    String fallbackType,
  ) {
    final type = json['type']?.toString() == 'series' ? 'series' : fallbackType;
    final imdbId = json['id']?.toString().trim() ?? '';
    final title = _bestText(json['name'], json['title'], imdbId);
    final genres = _stringList(json['genres']);
    final cast = _stringList(json['cast']);
    final directors = _stringList(json['director']);
    final releaseInfo = json['releaseInfo']?.toString().trim() ?? '';
    final released = json['released']?.toString().trim() ?? '';
    final yearMatch = RegExp(r'(19|20)\d{2}').firstMatch(releaseInfo);
    final date = released.length >= 10
        ? released.substring(0, 10)
        : yearMatch?.group(0);
    final poster = json['poster']?.toString().trim();
    final background = json['background']?.toString().trim();
    final videos = json['videos'] is List ? json['videos'] as List : const [];
    final rating = double.tryParse(json['imdbRating']?.toString() ?? '');
    final categories = <AnimeCategory>[
      AnimeCategory(name: type == 'series' ? '剧集' : '电影'),
      ...genres.take(5).map((item) => AnimeCategory(name: item)),
    ];
    final tags = <AnimeTag>[
      const AnimeTag(name: 'Cinemeta'),
      if (imdbId.startsWith('tt')) const AnimeTag(name: 'IMDb'),
      ...cast.take(3).map((item) => AnimeTag(name: item)),
      ...directors.take(2).map((item) => AnimeTag(name: item)),
    ];
    return AnimeSubject(
      id: _stableInt('$type:$imdbId:$title'),
      title: title,
      originalTitle: title,
      summary: _cleanText(json['description']?.toString()),
      coverUrl: poster == null || poster.isEmpty ? null : poster,
      bannerUrl: background == null || background.isEmpty ? null : background,
      date: date,
      platform: type == 'series' ? 'Series' : 'Movie',
      language: _bestText(json['language'], '', ''),
      region: _bestText(json['country'], 'Cinemeta', ''),
      status: type == 'series'
          ? (videos.isEmpty ? '剧集' : '共${videos.length}集')
          : _bestText(json['runtime'], '电影', ''),
      categories: categories,
      tags: tags,
      totalEpisodes: type == 'series' ? videos.length : 1,
      ratingScore: rating,
      source: 'cinemeta:$type:$imdbId',
    );
  }

  List<AnimeEpisode> _cinemetaEpisodes(
    Map<String, dynamic> json,
    AnimeSubject subject,
  ) {
    final rawVideos = json['videos'];
    if (rawVideos is! List || rawVideos.isEmpty) {
      return _externalEpisodes(subject);
    }
    final videos = rawVideos.whereType<Map>().toList()
      ..sort((a, b) {
        final aSeason = _intValue(a['season']) ?? 0;
        final bSeason = _intValue(b['season']) ?? 0;
        final seasonOrder = aSeason.compareTo(bSeason);
        if (seasonOrder != 0) return seasonOrder;
        return (_intValue(a['episode']) ?? 0).compareTo(
          _intValue(b['episode']) ?? 0,
        );
      });
    return videos.indexed
        .map((entry) {
          final index = entry.$1;
          final video = entry.$2;
          final season = _intValue(video['season']) ?? 0;
          final episode = _intValue(video['episode']) ?? index + 1;
          final videoId =
              video['id']?.toString() ?? '${subject.source}:$season:$episode';
          final name = video['title']?.toString().trim() ?? '';
          final prefix = season > 0 ? '第$season季 第$episode集' : '第$episode集';
          return AnimeEpisode(
            id: _stableInt(videoId),
            subjectId: subject.id,
            number: index + 1,
            title: name.isEmpty ? prefix : '$prefix $name',
            airdate: _dateOnly(video['released']?.toString()),
            duration: _bestText(video['runtime'], json['runtime'], '待补'),
            description: subject.summary,
            thumbnailUrl:
                video['thumbnail']?.toString() ??
                subject.bannerUrl ??
                subject.coverUrl,
          );
        })
        .toList(growable: false);
  }

  List<AnimeCharacter> _cinemetaCharacters(Map<String, dynamic> json) {
    return _stringList(json['cast'])
        .take(24)
        .map((name) {
          return AnimeCharacter(
            id: _stableInt('cast:$name'),
            name: name,
            relation: '演员',
            cv: '',
            summary: '',
          );
        })
        .toList(growable: false);
  }

  List<AnimeStaff> _cinemetaStaff(Map<String, dynamic> json) {
    final items = <(String, String)>[
      ..._stringList(json['director']).map((name) => (name, '导演')),
      ..._stringList(json['writer']).map((name) => (name, '编剧')),
    ];
    return items
        .take(16)
        .map((item) {
          return AnimeStaff(
            id: _stableInt('${item.$2}:${item.$1}'),
            name: item.$1,
            role: item.$2,
            career: '',
          );
        })
        .toList(growable: false);
  }

  AnimeSubject _subjectFromTvMaze(Map<String, dynamic> json) {
    final showJson = json['show'] is Map ? json['show'] as Map : json;
    final images = showJson['image'] is Map
        ? showJson['image'] as Map
        : const {};
    final rating = showJson['rating'] is Map
        ? showJson['rating'] as Map
        : const {};
    final genres = showJson['genres'] is List
        ? showJson['genres'] as List
        : const [];
    final externals = showJson['externals'] is Map
        ? showJson['externals'] as Map
        : const {};
    final imdbId = externals['imdb']?.toString().trim() ?? '';
    final title = showJson['name']?.toString() ?? '';
    return AnimeSubject(
      id: _intValue(showJson['id']) ?? 0,
      title: title,
      originalTitle: title,
      summary: _cleanText(showJson['summary']?.toString()),
      coverUrl: images['medium']?.toString() ?? images['original']?.toString(),
      bannerUrl: null,
      date: showJson['premiered']?.toString(),
      platform: showJson['type']?.toString() ?? 'TV',
      language: showJson['language']?.toString() ?? '',
      region: showJson['network'] is Map
          ? ((showJson['network'] as Map)['country'] is Map
                ? (((showJson['network'] as Map)['country'] as Map)['name']
                          ?.toString() ??
                      'TVMaze')
                : 'TVMaze')
          : 'TVMaze',
      status: showJson['status']?.toString() ?? '剧集',
      categories: genres
          .map((item) => AnimeCategory(name: item.toString()))
          .take(4)
          .toList(),
      tags: const [AnimeTag(name: 'TVMaze')],
      totalEpisodes: 0,
      ratingScore: (rating['average'] as num?)?.toDouble(),
      source: imdbId.isEmpty ? 'tvmaze' : 'tvmaze:$imdbId',
    );
  }

  AnimeSubject? _subjectFromInternetArchive(Map<String, dynamic> json) {
    final license = _internetArchiveLicense(json);
    if (license == null) return null;
    final identifier = json['identifier']?.toString() ?? '';
    if (identifier.trim().isEmpty) return null;
    final title = json['title'] is List
        ? (json['title'] as List).firstOrNull?.toString() ?? ''
        : json['title']?.toString() ?? '';
    final rawDescription = json['description'] is List
        ? (json['description'] as List).firstOrNull?.toString()
        : json['description']?.toString();
    final language = json['language'] is List
        ? (json['language'] as List).firstOrNull?.toString() ?? ''
        : json['language']?.toString() ?? '';
    final description = _cleanText(rawDescription);
    final chineseDescription = RegExp(r'[\u3400-\u9fff]').hasMatch(description);
    final summary = chineseDescription
        ? description
        : [
            '来自 Internet Archive 的公开授权影视，可直接解析可播放文件。',
            '许可：${license.label}。',
            if (json['date']?.toString().trim().isNotEmpty == true)
              '公开日期：${json['date']}。',
            '作品原名：$title。',
          ].join();
    return AnimeSubject(
      id: identifier.hashCode.abs(),
      title: title,
      originalTitle: title,
      summary: summary,
      coverUrl: identifier.isEmpty
          ? null
          : 'https://archive.org/services/img/$identifier',
      bannerUrl: null,
      date: json['date']?.toString(),
      platform: 'Movie',
      language: language,
      region: 'Internet Archive',
      status: '公开授权 · ${license.label}',
      categories: const [AnimeCategory(name: '公共领域/公开授权')],
      tags: [
        const AnimeTag(name: 'Internet Archive'),
        AnimeTag(name: license.label),
      ],
      totalEpisodes: 1,
      source: 'archive:$identifier',
    );
  }

  Future<List<AnimeSubject>> _wikidataMovies({
    required String keyword,
    required int limit,
  }) async {
    final escapedKeyword = _sparqlString(keyword.trim());
    final query = keyword.trim().isEmpty
        ? '''
SELECT ?item ?itemLabel ?description ?date ?imdb ?image ?genreLabel ?languageLabel ?countryLabel WHERE {
  ?item wdt:P31/wdt:P279* wd:Q11424.
  OPTIONAL { ?item wdt:P577 ?date. }
  OPTIONAL { ?item wdt:P345 ?imdb. }
  OPTIONAL { ?item wdt:P18 ?image. }
  OPTIONAL { ?item wdt:P136 ?genre. }
  OPTIONAL { ?item wdt:P364 ?language. }
  OPTIONAL { ?item wdt:P495 ?country. }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "zh,en". }
}
ORDER BY DESC(?date)
LIMIT $limit
'''
        : '''
SELECT ?item ?itemLabel ?description ?date ?imdb ?image ?genreLabel ?languageLabel ?countryLabel WHERE {
  SERVICE wikibase:mwapi {
    bd:serviceParam wikibase:endpoint "www.wikidata.org";
                    wikibase:api "EntitySearch";
                    mwapi:search "$escapedKeyword";
                    mwapi:language "zh";
                    mwapi:limit "$limit".
    ?item wikibase:apiOutputItem mwapi:item.
  }
  ?item wdt:P31/wdt:P279* wd:Q11424.
  OPTIONAL { ?item wdt:P577 ?date. }
  OPTIONAL { ?item wdt:P345 ?imdb. }
  OPTIONAL { ?item wdt:P18 ?image. }
  OPTIONAL { ?item wdt:P136 ?genre. }
  OPTIONAL { ?item wdt:P364 ?language. }
  OPTIONAL { ?item wdt:P495 ?country. }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "zh,en". }
}
LIMIT $limit
''';
    final response = await _client
        .get(
          Uri.parse(
            'https://query.wikidata.org/sparql',
          ).replace(queryParameters: {'format': 'json', 'query': query}),
          headers: const {
            'Accept': 'application/sparql-results+json',
            'User-Agent': 'anime-app/1.0 (public metadata client)',
          },
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final bindings = decoded is Map
        ? (((decoded['results'] as Map?)?['bindings']) as List?)
        : null;
    if (bindings == null) return const [];
    return _uniqueSubjects(
      bindings
          .whereType<Map>()
          .map(
            (item) => _subjectFromWikidataMovie(item.cast<String, dynamic>()),
          )
          .where((item) => item.title.trim().isNotEmpty),
    );
  }

  AnimeSubject _subjectFromWikidataMovie(Map<String, dynamic> json) {
    final itemUrl = _bindingValue(json['item']);
    final idText = itemUrl.split('/').last.replaceFirst('Q', '');
    final title = _bindingValue(json['itemLabel']);
    final genre = _bindingValue(json['genreLabel']);
    final description = _bindingValue(json['description']);
    final date = _bindingValue(json['date']);
    final image = _bindingValue(json['image']);
    final imdb = _bindingValue(json['imdb']);
    final language = _bindingValue(json['languageLabel']);
    final country = _bindingValue(json['countryLabel']);
    final categories = [
      const AnimeCategory(name: '电影'),
      if (genre.isNotEmpty) AnimeCategory(name: genre),
    ];
    final tags = [
      const AnimeTag(name: 'Wikidata'),
      if (imdb.isNotEmpty) const AnimeTag(name: 'IMDb'),
      if (genre.isNotEmpty) AnimeTag(name: genre),
    ];
    return AnimeSubject(
      id: _intValue(idText) ?? title.hashCode.abs(),
      title: title,
      originalTitle: title,
      summary: description.isEmpty ? '暂无简介。' : description,
      coverUrl: image.isEmpty ? null : image,
      bannerUrl: null,
      date: date.length >= 10 ? date.substring(0, 10) : null,
      platform: 'Movie',
      language: language,
      region: country.isEmpty ? 'Wikidata' : country,
      status: '电影',
      categories: categories,
      tags: tags,
      totalEpisodes: 1,
      source: 'wikidata',
    );
  }

  Future<AnimeDetailBundle?> _tvMazeDetail(AnimeSubject subject) async {
    final response = await _client
        .get(
          Uri.parse(
            'https://api.tvmaze.com/shows/${subject.id}',
          ).replace(queryParameters: {'embed[]': 'episodes'}),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return null;
    final show = _subjectFromTvMaze(decoded.cast<String, dynamic>());
    final cast = await _tvMazeCast(subject.id);
    final embedded = decoded['_embedded'] is Map
        ? decoded['_embedded'] as Map
        : const {};
    final episodes = embedded['episodes'] is List
        ? (embedded['episodes'] as List)
              .whereType<Map>()
              .map((item) => _tvMazeEpisode(item.cast<String, dynamic>(), show))
              .where((item) => item.number > 0)
              .toList()
        : _externalEpisodes(show);
    return AnimeDetailBundle(
      subject: show.copyWith(
        totalEpisodes: episodes.length,
        status: episodes.isEmpty ? show.status : '全${episodes.length}集',
      ),
      episodes: episodes.isEmpty ? _externalEpisodes(show) : episodes,
      characters: cast,
      staff: const [],
      recommendations: const [],
    );
  }

  Future<List<AnimeCharacter>> _tvMazeCast(int showId) async {
    final response = await _client
        .get(
          Uri.parse('https://api.tvmaze.com/shows/$showId/cast'),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 14));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((item) => _tvMazeCharacter(item.cast<String, dynamic>()))
        .where((item) => item.name.isNotEmpty)
        .toList();
  }

  AnimeEpisode _tvMazeEpisode(Map<String, dynamic> json, AnimeSubject subject) {
    final images = json['image'] is Map ? json['image'] as Map : const {};
    final number = _intValue(json['number']) ?? _intValue(json['id']) ?? 0;
    return AnimeEpisode(
      id: _intValue(json['id']) ?? subject.id * 10000 + number,
      subjectId: subject.id,
      number: number,
      title: json['name']?.toString() ?? '',
      airdate: json['airdate']?.toString(),
      duration: _formatMinutes(_intValue(json['runtime']) ?? 0),
      description: _cleanText(json['summary']?.toString()),
      thumbnailUrl:
          images['original']?.toString() ?? images['medium']?.toString(),
    );
  }

  AnimeCharacter _tvMazeCharacter(Map<String, dynamic> json) {
    final person = json['person'] is Map ? json['person'] as Map : const {};
    final character = json['character'] is Map
        ? json['character'] as Map
        : const {};
    return AnimeCharacter(
      id: _intValue(character['id']) ?? _intValue(person['id']) ?? 0,
      name: character['name']?.toString() ?? '',
      relation: '角色',
      cv: person['name']?.toString() ?? '未知',
      summary: '',
      imageUrl:
          _tvMazeImage(character['image']) ?? _tvMazeImage(person['image']),
    );
  }

  List<AnimeEpisode> _externalEpisodes(AnimeSubject subject) {
    final total = subject.platform == 'Movie'
        ? 1
        : subject.totalEpisodes.clamp(1, 200);
    return List.generate(total, (index) {
      final number = index + 1;
      return AnimeEpisode(
        id: subject.id * 10000 + number,
        subjectId: subject.id,
        number: number,
        title: subject.platform == 'Movie' ? '正片' : '',
        airdate: number == 1 ? subject.date : null,
        duration: subject.platform == 'Movie' ? '待补' : '24:00',
        description: subject.summary,
        thumbnailUrl: subject.coverUrl,
      );
    });
  }

  String _dateFromParts(Object? year, Object? month, Object? day) {
    final y = _intValue(year);
    if (y == null || y <= 0) return '';
    final m = (_intValue(month) ?? 1).toString().padLeft(2, '0');
    final d = (_intValue(day) ?? 1).toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _bestText(Object? first, Object? second, Object? third) {
    for (final item in [first, second, third]) {
      final text = item?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _cleanText(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return '暂无简介。';
    return text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  String _stripHtml(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _formatMinutes(int minutes) {
    if (minutes <= 0) return '待补';
    return '$minutes 分钟';
  }

  String _dateString(DateTime date) {
    final month = '${date.month}'.padLeft(2, '0');
    final day = '${date.day}'.padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _sparqlString(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  String? _tvMazeImage(Object? value) {
    if (value is! Map) return null;
    return value['original']?.toString() ?? value['medium']?.toString();
  }

  (String, String)? _cinemetaIdentity(AnimeSubject subject) {
    final parts = subject.source.split(':');
    if (parts.length < 3 || parts.first != 'cinemeta') return null;
    final type = parts[1] == 'series' ? 'series' : 'movie';
    final id = parts.sublist(2).join(':').trim();
    if (id.isEmpty) return null;
    return (type, id);
  }

  String? _dateOnly(String? value) {
    final text = value?.trim() ?? '';
    if (text.length >= 10) return text.substring(0, 10);
    final year = RegExp(r'(19|20)\d{2}').firstMatch(text)?.group(0);
    return year;
  }

  List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return const [];
    return text
        .split(RegExp(r'\s*,\s*'))
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  int _stableInt(String value) {
    final bytes = sha256.convert(utf8.encode(value)).bytes;
    final result =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    return result & 0x7fffffff;
  }

  List<AnimeSubject> _interleaveSubjectGroups(
    List<List<AnimeSubject>> groups, {
    int limitPerRound = 6,
  }) {
    final result = <AnimeSubject>[];
    final offsets = List<int>.filled(groups.length, 0);
    var added = true;
    while (added) {
      added = false;
      for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
        final group = groups[groupIndex];
        final start = offsets[groupIndex];
        if (start >= group.length) continue;
        final end = (start + limitPerRound).clamp(0, group.length);
        result.addAll(group.sublist(start, end));
        offsets[groupIndex] = end;
        added = true;
      }
    }
    return result;
  }

  String _bindingValue(Object? value) {
    if (value is! Map) return '';
    return value['value']?.toString() ?? '';
  }

  _InternetArchiveLicense? _internetArchiveLicense(Map<String, dynamic> json) {
    final rawUrl = json['licenseurl'] is List
        ? (json['licenseurl'] as List).firstOrNull?.toString() ?? ''
        : json['licenseurl']?.toString() ?? '';
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri != null &&
        (uri.host == 'creativecommons.org' ||
            uri.host == 'www.creativecommons.org')) {
      final path = uri.path.toLowerCase();
      if (path.contains('/publicdomain/mark/') ||
          path.contains('/publicdomain/zero/')) {
        return const _InternetArchiveLicense('公共领域 / CC0');
      }
      if (path.contains('/licenses/by-sa/')) {
        return const _InternetArchiveLicense('CC BY-SA');
      }
      if (RegExp(r'/licenses/by/').hasMatch(path)) {
        return const _InternetArchiveLicense('CC BY');
      }
      return null;
    }

    final rights = json['rights'] is List
        ? (json['rights'] as List).join(' ')
        : json['rights']?.toString() ?? '';
    final normalized = rights.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.contains('public domain') || normalized.contains('cc0')) {
      return const _InternetArchiveLicense('公共领域 / CC0');
    }
    if (normalized.contains('noncommercial') ||
        normalized.contains('no derivatives') ||
        normalized.contains('cc by-nc') ||
        normalized.contains('cc by-nd')) {
      return null;
    }
    if (normalized.contains('attribution-sharealike') ||
        normalized.contains('cc by-sa')) {
      return const _InternetArchiveLicense('CC BY-SA');
    }
    if (normalized.contains('creative commons attribution') ||
        normalized.contains('cc by')) {
      return const _InternetArchiveLicense('CC BY');
    }
    return null;
  }

  List<AnimeSubject> _uniqueSubjects(Iterable<AnimeSubject> subjects) {
    final keyToIndex = <String, int>{};
    final unique = <AnimeSubject>[];
    for (final subject in subjects) {
      if (subject.title.trim().isEmpty) continue;
      final keys = _subjectKeys(subject);
      int? existingIndex;
      for (final key in keys) {
        final index = keyToIndex[key];
        if (index != null) {
          existingIndex = index;
          break;
        }
      }
      if (existingIndex == null) {
        final index = unique.length;
        unique.add(subject);
        for (final key in keys) {
          keyToIndex[key] = index;
        }
        continue;
      }
      final existing = unique[existingIndex];
      if (_subjectQuality(subject) <= _subjectQuality(existing)) continue;
      unique[existingIndex] = subject;
      for (final key in keys) {
        keyToIndex[key] = existingIndex;
      }
    }
    return unique;
  }

  Set<String> _subjectKeys(AnimeSubject subject) {
    final kind = subject.source.startsWith('archive:')
        ? 'movie-direct'
        : subject.platform.toLowerCase().contains('movie')
        ? 'movie'
        : subject.platform.toLowerCase().contains('series') ||
              subject.source.startsWith('tvmaze')
        ? 'series'
        : 'anime';
    final year = subject.year == '未知' ? '' : subject.year;
    final titles = <String>{subject.title, subject.originalTitle}
        .map(
          (item) => item.toLowerCase().replaceAll(
            RegExp(r'[^\p{L}\p{N}]', unicode: true),
            '',
          ),
        )
        .where((item) => item.isNotEmpty);
    final keys = titles.map((title) => '$kind:$year:$title').toSet();
    if (keys.isEmpty) keys.add('$kind:$year:${subject.id}');
    return keys;
  }

  int _subjectQuality(AnimeSubject subject) {
    var score = 0;
    if ((subject.bannerUrl ?? '').isNotEmpty) score += 16;
    if ((subject.coverUrl ?? '').isNotEmpty) score += 8;
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(subject.title)) score += 4;
    if (subject.summary.length >= 80) score += 3;
    if (subject.ratingScore != null) score += 3;
    if (subject.totalEpisodes > 0) score += 2;
    if (subject.source.startsWith('cinemeta:')) score += 2;
    return score;
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }
}

class _InternetArchiveLicense {
  const _InternetArchiveLicense(this.label);

  final String label;
}

String _archiveQuery(String value) {
  return value
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s-]', unicode: true), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((item) => item.isNotEmpty)
      .map((item) => '"$item"')
      .join(' AND ');
}

class _BilibiliEpisodeMatch {
  const _BilibiliEpisodeMatch({
    required this.seasonTitle,
    required this.episodeTitle,
    required this.aid,
    required this.cid,
  });

  final String seasonTitle;
  final String episodeTitle;
  final int aid;
  final int cid;
}

class _DandanplayEpisode {
  const _DandanplayEpisode({
    required this.title,
    required this.episodeTitle,
    required this.episodeId,
  });

  final String title;
  final String episodeTitle;
  final int episodeId;
}
