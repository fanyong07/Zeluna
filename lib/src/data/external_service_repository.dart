import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';

class ExternalServiceRepository {
  ExternalServiceRepository({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;
  static const _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
    'Accept': 'application/json, text/plain, */*',
  };

  Future<List<AnimeSubject>> anilistSearch(String keyword, {int perPage = 24}) {
    return _anilistSubjects(
      r'''
query ($perPage: Int, $search: String) {
  Page(page: 1, perPage: $perPage) {
    media(type: ANIME, search: $search, sort: SEARCH_MATCH) {
      id
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
    String season = '',
    int? seasonYear,
  }) async {
    return _anilistSubjects(
      r'''
query ($perPage: Int, $season: MediaSeason, $seasonYear: Int) {
  Page(page: 1, perPage: $perPage) {
    media(type: ANIME, sort: TRENDING_DESC, season: $season, seasonYear: $seasonYear) {
      id
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
        'perPage': perPage,
        if (season.isNotEmpty) 'season': season,
        'seasonYear': ?seasonYear,
      },
    );
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

  Future<List<AnimeSubject>> mediaSearch(String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    final groups = await Future.wait([
      tvMazeSearch(keyword).onError((_, _) => const <AnimeSubject>[]),
      wikidataMovieSearch(keyword).onError((_, _) => const <AnimeSubject>[]),
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

  Future<List<AnimeSubject>> tvMazeShows({int page = 0}) async {
    final response = await _client
        .get(
          Uri.parse(
            'https://api.tvmaze.com/shows',
          ).replace(queryParameters: {'page': '$page'}),
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
        .take(80)
        .toList();
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

  Future<List<AnimeSubject>> seriesMetadataFeed() async {
    final now = DateTime.now();
    final scheduleRequests = <Future<List<AnimeSubject>>>[];
    for (final country in const ['US', 'GB', 'KR', 'JP', 'CN']) {
      for (var days = 0; days < 4; days++) {
        scheduleRequests.add(
          tvMazeSchedule(
            country: country,
            date: now.subtract(Duration(days: days)),
          ).onError((_, _) => const <AnimeSubject>[]),
        );
      }
    }
    final groups =
        await Future.wait([
          ...scheduleRequests,
          tvMazeSearch('drama').onError((_, _) => const <AnimeSubject>[]),
          tvMazeSearch(
            'korean drama',
          ).onError((_, _) => const <AnimeSubject>[]),
          tvMazeSearch(
            'chinese drama',
          ).onError((_, _) => const <AnimeSubject>[]),
          tvMazeSearch('crime').onError((_, _) => const <AnimeSubject>[]),
        ]).timeout(
          const Duration(seconds: 24),
          onTimeout: () => const <List<AnimeSubject>>[],
        );
    final subjects = _uniqueSubjects(groups.expand((items) => items));
    subjects.sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
    return subjects.take(96).toList();
  }

  Future<List<AnimeSubject>> movieMetadataFeed({String keyword = ''}) {
    return _wikidataMovies(keyword: keyword, limit: keyword.isEmpty ? 72 : 36);
  }

  Future<List<AnimeSubject>> wikidataMovieSearch(String keyword) {
    if (keyword.trim().isEmpty) return Future.value(const []);
    return _wikidataMovies(keyword: keyword.trim(), limit: 24);
  }

  Future<AnimeDetailBundle> externalDetail(AnimeSubject subject) async {
    if (subject.source == 'tvmaze') {
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
      coverUrl: cover['extraLarge']?.toString() ?? cover['large']?.toString(),
      bannerUrl: json['bannerImage']?.toString(),
      date: date,
      platform: 'TV',
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
    final title = showJson['name']?.toString() ?? '';
    return AnimeSubject(
      id: _intValue(showJson['id']) ?? 0,
      title: title,
      originalTitle: title,
      summary: _cleanText(showJson['summary']?.toString()),
      coverUrl: images['original']?.toString() ?? images['medium']?.toString(),
      bannerUrl: images['original']?.toString() ?? images['medium']?.toString(),
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
      source: 'tvmaze',
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
      bannerUrl: image.isEmpty ? null : image,
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

  String _bindingValue(Object? value) {
    if (value is! Map) return '';
    return value['value']?.toString() ?? '';
  }

  List<AnimeSubject> _uniqueSubjects(Iterable<AnimeSubject> subjects) {
    final seen = <String>{};
    final unique = <AnimeSubject>[];
    for (final subject in subjects) {
      final key = '${subject.source}:${subject.id}:${subject.title}';
      if (subject.title.trim().isEmpty || !seen.add(key)) continue;
      unique.add(subject);
    }
    return unique;
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }
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
