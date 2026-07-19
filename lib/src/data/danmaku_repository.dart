import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../domain/anime_models.dart';
import 'danmaku_response_decoder.dart';

class DanmakuRepository {
  DanmakuRepository({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  static const _requestTimeout = Duration(seconds: 8);
  static const _successCacheDuration = Duration(minutes: 30);
  static const _emptyCacheDuration = Duration(minutes: 2);

  final http.Client _client;
  final bool _ownsClient;
  final Map<String, _TimedTimeline> _cache = {};
  final Map<String, Future<DanmakuTimeline>> _inFlight = {};
  String? _wbiMixinKey;
  DateTime? _wbiMixinKeyExpiresAt;
  Future<String?>? _wbiKeyInFlight;

  Future<DanmakuTimeline> timelineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
    ExternalServiceSettings settings,
  ) {
    final key = _cacheKey(subject, episode, settings);
    final cached = _cache[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return Future.value(cached.timeline);
    }
    final active = _inFlight[key];
    if (active != null) return active;

    late final Future<DanmakuTimeline> future;
    future = _loadTimeline(subject, episode, settings)
        .then((timeline) {
          _cache[key] = _TimedTimeline(
            timeline: timeline,
            expiresAt: DateTime.now().add(
              timeline.comments.isEmpty
                  ? _emptyCacheDuration
                  : _successCacheDuration,
            ),
          );
          return timeline;
        })
        .whenComplete(() {
          if (identical(_inFlight[key], future)) _inFlight.remove(key);
        });
    _inFlight[key] = future;
    return future;
  }

  void invalidate() {
    _cache.clear();
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<DanmakuTimeline> _loadTimeline(
    AnimeSubject subject,
    AnimeEpisode episode,
    ExternalServiceSettings settings,
  ) async {
    final sources = <DanmakuMatch>[];

    if (settings.bilibiliDanmakuEnabled) {
      final bilibili = await _loadBilibili(subject, episode);
      sources.add(bilibili.match);
      if (bilibili.comments.isNotEmpty) {
        return DanmakuTimeline(
          sources: List.unmodifiable(sources),
          comments: List.unmodifiable(bilibili.comments),
        );
      }
    }

    if (settings.dandanplayDanmakuEnabled) {
      final dandanplay = await _loadDandanplay(subject, episode, settings);
      sources.add(dandanplay.match);
      if (dandanplay.comments.isNotEmpty) {
        return DanmakuTimeline(
          sources: List.unmodifiable(sources),
          comments: List.unmodifiable(dandanplay.comments),
        );
      }
    }

    final customEndpoint = settings.customDanmakuEndpoint.trim();
    if (settings.customDanmakuEnabled && customEndpoint.isNotEmpty) {
      final custom = await _loadCustom(customEndpoint, subject, episode);
      sources.add(custom.match);
      if (custom.comments.isNotEmpty) {
        return DanmakuTimeline(
          sources: List.unmodifiable(sources),
          comments: List.unmodifiable(custom.comments),
        );
      }
    }

    return DanmakuTimeline(sources: List.unmodifiable(sources));
  }

  Future<_DanmakuSourceResult> _loadBilibili(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    try {
      final match = await _findBilibiliEpisode(subject, episode);
      if (match == null) {
        return _DanmakuSourceResult(
          match: _unavailableMatch(
            provider: 'Bilibili',
            title: subject.title,
            episodeTitle: episode.displayTitle,
            message: '没有匹配到当前番剧与集数',
          ),
        );
      }
      final response = await _get(
        Uri.parse(
          'https://api.bilibili.com/x/v1/dm/list.so',
        ).replace(queryParameters: {'oid': '${match.cid}'}),
        headers: const {'Accept': 'text/xml,application/xml,text/plain,*/*'},
        referer: 'https://www.bilibili.com/bangumi/play/',
      ).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        return _DanmakuSourceResult(
          match: _unavailableMatch(
            provider: 'Bilibili',
            title: match.seasonTitle,
            episodeTitle: match.episodeTitle,
            episodeId: '${match.cid}',
            message: '弹幕读取失败：HTTP ${response.statusCode}',
          ),
        );
      }
      final xmlSource = utf8.decode(
        decodeDanmakuResponse(
          response.bodyBytes,
          response.headers['content-encoding'],
        ),
        allowMalformed: true,
      );
      final comments = parseBilibiliDanmakuXml(xmlSource);
      return _DanmakuSourceResult(
        match: DanmakuMatch(
          provider: 'Bilibili',
          title: match.seasonTitle,
          episodeTitle: match.episodeTitle,
          episodeId: '${match.cid}',
          commentCount: comments.length,
          available: comments.isNotEmpty,
          message: comments.isEmpty ? '当前集没有返回公开弹幕' : null,
        ),
        comments: comments,
      );
    } on _BilibiliLookupException catch (error) {
      return _DanmakuSourceResult(
        match: _unavailableMatch(
          provider: 'Bilibili',
          title: subject.title,
          episodeTitle: episode.displayTitle,
          message: error.message,
        ),
      );
    } catch (_) {
      return _DanmakuSourceResult(
        match: _unavailableMatch(
          provider: 'Bilibili',
          title: subject.title,
          episodeTitle: episode.displayTitle,
          message: '弹幕源暂时无法访问',
        ),
      );
    }
  }

  Future<_BilibiliEpisode?> _findBilibiliEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    final keywords = <String>{
      subject.title.trim(),
      subject.originalTitle.trim(),
    }.where((value) => value.length >= 2).take(2).toList(growable: false);
    if (keywords.isEmpty) return null;

    final batches = await Future.wait(keywords.map(_searchBilibiliBangumi));
    if (batches.every((batch) => batch.items.isEmpty)) {
      String? rejection;
      for (final batch in batches) {
        if (batch.rejectionMessage != null) {
          rejection = batch.rejectionMessage;
          break;
        }
      }
      if (rejection != null) throw _BilibiliLookupException(rejection);
    }

    final candidates = <int, Map<dynamic, dynamic>>{};
    for (final item in batches.expand((batch) => batch.items)) {
      final seasonId = _intValue(item['season_id']);
      if (seasonId != null && seasonId > 0) candidates[seasonId] = item;
    }
    if (candidates.isEmpty) return null;

    Map<dynamic, dynamic>? selected;
    var bestScore = 0;
    for (final item in candidates.values) {
      final score = _bilibiliTitleScore(item, subject);
      if (score > bestScore) {
        bestScore = score;
        selected = item;
      }
    }
    if (selected == null || bestScore < 55) return null;
    final seasonId = _intValue(selected['season_id']);
    if (seasonId == null) return null;

    final response = await _get(
      Uri.parse(
        'https://api.bilibili.com/pgc/view/web/season',
      ).replace(queryParameters: {'season_id': '$seasonId'}),
      headers: const {'Accept': 'application/json'},
      referer: 'https://www.bilibili.com/bangumi/play/',
    ).timeout(_requestTimeout);
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || _intValue(decoded['code']) != 0) return null;
    final result = decoded['result'];
    if (result is! Map || result['episodes'] is! List) return null;
    final episodes = (result['episodes'] as List).whereType<Map>().toList();
    if (episodes.isEmpty) return null;
    final selectedEpisode = _pickBilibiliEpisode(episodes, subject, episode);
    if (selectedEpisode == null) return null;
    final cid = _intValue(selectedEpisode['cid']) ?? 0;
    if (cid <= 0) return null;
    final longTitle = _plainText(selectedEpisode['long_title']);
    return _BilibiliEpisode(
      seasonTitle: _plainText(result['title']).isEmpty
          ? subject.title
          : _plainText(result['title']),
      episodeTitle: longTitle.isEmpty ? episode.displayTitle : longTitle,
      cid: cid,
    );
  }

  Future<_BilibiliSearchResult> _searchBilibiliBangumi(String keyword) async {
    try {
      final uri = await _signedBilibiliSearchUri({
        'search_type': 'media_bangumi',
        'keyword': keyword,
      });
      final response = await _get(
        uri,
        headers: const {'Accept': 'application/json'},
        referer: 'https://www.bilibili.com/',
      ).timeout(_requestTimeout);
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode == 412 ||
          body.contains('错误号: 412') ||
          body.contains('error-container')) {
        return const _BilibiliSearchResult(
          rejectionMessage: '搜索请求被 B 站风控拦截，已自动尝试下一弹幕源',
        );
      }
      if (response.statusCode != 200) return const _BilibiliSearchResult();
      final decoded = jsonDecode(body);
      if (decoded is! Map || _intValue(decoded['code']) != 0) {
        final code = decoded is Map ? _intValue(decoded['code']) : null;
        if (code == -352 || code == -412) {
          return const _BilibiliSearchResult(
            rejectionMessage: '搜索请求被 B 站风控拦截，已自动尝试下一弹幕源',
          );
        }
        return const _BilibiliSearchResult();
      }
      final data = decoded['data'];
      final results = data is Map ? data['result'] : null;
      return _BilibiliSearchResult(
        items: results is List
            ? results.whereType<Map>().toList(growable: false)
            : const [],
      );
    } catch (_) {
      return const _BilibiliSearchResult();
    }
  }

  Future<Uri> _signedBilibiliSearchUri(Map<String, String> parameters) async {
    final values = <String, String>{
      ...parameters,
      'wts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    };
    final mixinKey = await _bilibiliWbiMixinKey();
    final keys = values.keys.toList()..sort();
    final query = keys
        .map((key) {
          final cleanValue = values[key]!.replaceAll(RegExp(r"[!'()*]"), '');
          return '${Uri.encodeQueryComponent(key)}='
              '${Uri.encodeQueryComponent(cleanValue)}';
        })
        .join('&');
    final signature = mixinKey == null
        ? null
        : md5.convert(utf8.encode('$query$mixinKey')).toString();
    return Uri.parse(
      'https://api.bilibili.com/x/web-interface/wbi/search/type?'
      '$query${signature == null ? '' : '&w_rid=$signature'}',
    );
  }

  Future<String?> _bilibiliWbiMixinKey() {
    final cached = _wbiMixinKey;
    if (cached != null &&
        (_wbiMixinKeyExpiresAt?.isAfter(DateTime.now()) ?? false)) {
      return Future.value(cached);
    }
    final active = _wbiKeyInFlight;
    if (active != null) return active;
    late final Future<String?> future;
    future = _fetchBilibiliWbiMixinKey().whenComplete(() {
      if (identical(_wbiKeyInFlight, future)) _wbiKeyInFlight = null;
    });
    _wbiKeyInFlight = future;
    return future;
  }

  Future<String?> _fetchBilibiliWbiMixinKey() async {
    try {
      final response = await _get(
        Uri.parse('https://api.bilibili.com/x/web-interface/nav'),
        headers: const {'Accept': 'application/json'},
        referer: 'https://www.bilibili.com/',
      ).timeout(_requestTimeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final data = decoded is Map ? decoded['data'] : null;
      final wbiImage = data is Map ? data['wbi_img'] : null;
      if (wbiImage is! Map) return null;
      final rawKey =
          '${_wbiFileKey(wbiImage['img_url'])}'
          '${_wbiFileKey(wbiImage['sub_url'])}';
      if (rawKey.length < 64) return null;
      const order = <int>[
        46,
        47,
        18,
        2,
        53,
        8,
        23,
        32,
        15,
        50,
        10,
        31,
        58,
        3,
        45,
        35,
        27,
        43,
        5,
        49,
        33,
        9,
        42,
        19,
        29,
        28,
        14,
        39,
        12,
        38,
        41,
        13,
        37,
        48,
        7,
        16,
        24,
        55,
        40,
        61,
        26,
        17,
        0,
        1,
        60,
        51,
        30,
        4,
        22,
        25,
        54,
        21,
        56,
        59,
        6,
        63,
        57,
        62,
        11,
        36,
        20,
        34,
        44,
        52,
      ];
      final mixinKey = order.map((index) => rawKey[index]).take(32).join();
      _wbiMixinKey = mixinKey;
      _wbiMixinKeyExpiresAt = DateTime.now().add(const Duration(hours: 6));
      return mixinKey;
    } catch (_) {
      return null;
    }
  }

  String _wbiFileKey(Object? value) {
    final url = Uri.tryParse(value?.toString() ?? '');
    if (url == null || url.pathSegments.isEmpty) return '';
    return url.pathSegments.last.split('.').first;
  }

  Map<dynamic, dynamic>? _pickBilibiliEpisode(
    List<Map<dynamic, dynamic>> episodes,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    if (subject.platform.toLowerCase() == 'movie') return episodes.first;
    for (final item in episodes) {
      if (_episodeNumber(item['title']) == episode.number ||
          _episodeNumber(item['short_title']) == episode.number) {
        return item;
      }
    }
    final index = episode.number - 1;
    if (index >= 0 && index < episodes.length) return episodes[index];
    return null;
  }

  Future<_DanmakuSourceResult> _loadDandanplay(
    AnimeSubject subject,
    AnimeEpisode episode,
    ExternalServiceSettings settings,
  ) async {
    final appId = settings.dandanplayAppId.trim();
    final appSecret = settings.dandanplayAppSecret.trim();
    if (appId.isEmpty || appSecret.isEmpty) {
      return _DanmakuSourceResult(
        match: _unavailableMatch(
          provider: '弹弹play',
          title: subject.title,
          episodeTitle: episode.displayTitle,
          message: '尚未配置开放平台凭证',
        ),
      );
    }
    try {
      const searchPath = '/api/v2/search/episodes';
      final searchResponse = await _get(
        Uri.parse('https://api.dandanplay.net$searchPath').replace(
          queryParameters: {
            'anime': _preferredKeyword(subject),
            'episode': subject.platform.toLowerCase() == 'movie'
                ? 'movie'
                : '${episode.number}',
          },
        ),
        headers: _dandanplayHeaders(appId, appSecret, searchPath),
      ).timeout(_requestTimeout);
      if (searchResponse.statusCode != 200) {
        return _DanmakuSourceResult(
          match: _unavailableMatch(
            provider: '弹弹play',
            title: subject.title,
            episodeTitle: episode.displayTitle,
            message:
                searchResponse.statusCode == 401 ||
                    searchResponse.statusCode == 403
                ? '开放平台凭证无效或权限不足'
                : '匹配失败：HTTP ${searchResponse.statusCode}',
          ),
        );
      }
      final decoded = jsonDecode(utf8.decode(searchResponse.bodyBytes));
      final matched = _pickDandanplayEpisode(decoded, subject, episode);
      if (matched == null) {
        return _DanmakuSourceResult(
          match: _unavailableMatch(
            provider: '弹弹play',
            title: subject.title,
            episodeTitle: episode.displayTitle,
            message: '没有匹配到当前番剧与集数',
          ),
        );
      }

      final commentPath = '/api/v2/comment/${matched.episodeId}';
      final commentResponse = await _get(
        Uri.parse('https://api.dandanplay.net$commentPath').replace(
          queryParameters: const {
            'from': '0',
            'withRelated': 'true',
            'chConvert': '1',
          },
        ),
        headers: _dandanplayHeaders(appId, appSecret, commentPath),
      ).timeout(_requestTimeout);
      if (commentResponse.statusCode != 200 &&
          commentResponse.statusCode != 302) {
        return _DanmakuSourceResult(
          match: _unavailableMatch(
            provider: '弹弹play',
            title: matched.title,
            episodeTitle: matched.episodeTitle,
            episodeId: '${matched.episodeId}',
            message: '弹幕读取失败：HTTP ${commentResponse.statusCode}',
          ),
        );
      }
      final comments = parseDandanplayDanmaku(
        jsonDecode(utf8.decode(commentResponse.bodyBytes)),
      );
      return _DanmakuSourceResult(
        match: DanmakuMatch(
          provider: '弹弹play',
          title: matched.title,
          episodeTitle: matched.episodeTitle,
          episodeId: '${matched.episodeId}',
          commentCount: comments.length,
          available: comments.isNotEmpty,
          message: comments.isEmpty ? '已匹配弹幕库，但没有返回弹幕内容' : null,
        ),
        comments: comments,
      );
    } catch (_) {
      return _DanmakuSourceResult(
        match: _unavailableMatch(
          provider: '弹弹play',
          title: subject.title,
          episodeTitle: episode.displayTitle,
          message: '弹幕源暂时无法访问',
        ),
      );
    }
  }

  Future<_DanmakuSourceResult> _loadCustom(
    String endpoint,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    try {
      final response = await _get(
        Uri.parse(endpoint).replace(
          queryParameters: {
            ...Uri.parse(endpoint).queryParameters,
            'title': subject.title,
            'episode': '${episode.number}',
          },
        ),
        headers: const {'Accept': 'application/json'},
      ).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        return _DanmakuSourceResult(
          match: _unavailableMatch(
            provider: '自建弹幕库',
            title: subject.title,
            episodeTitle: episode.displayTitle,
            message: '读取失败：HTTP ${response.statusCode}',
          ),
        );
      }
      final comments = parseCustomDanmaku(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
      return _DanmakuSourceResult(
        match: DanmakuMatch(
          provider: '自建弹幕库',
          title: subject.title,
          episodeTitle: episode.displayTitle,
          episodeId: '${subject.id}-${episode.number}',
          commentCount: comments.length,
          available: comments.isNotEmpty,
          message: comments.isEmpty ? '接口没有返回可解析的弹幕内容' : null,
        ),
        comments: comments,
      );
    } catch (_) {
      return _DanmakuSourceResult(
        match: _unavailableMatch(
          provider: '自建弹幕库',
          title: subject.title,
          episodeTitle: episode.displayTitle,
          message: '弹幕源暂时无法访问',
        ),
      );
    }
  }

  Future<http.Response> _get(
    Uri target, {
    Map<String, String> headers = const {},
    String? referer,
  }) {
    if (!kIsWeb) {
      return _client.get(
        target,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
          'Referer': ?referer,
          ...headers,
        },
      );
    }
    final proxyHeaders = <String, String>{
      if (headers['Accept'] != null) 'Accept': headers['Accept']!,
      'X-Upstream-Referer': ?referer,
      if (headers['X-AppId'] != null) 'X-Upstream-X-AppId': headers['X-AppId']!,
      if (headers['X-Timestamp'] != null)
        'X-Upstream-X-Timestamp': headers['X-Timestamp']!,
      if (headers['X-Signature'] != null)
        'X-Upstream-X-Signature': headers['X-Signature']!,
    };
    final proxy = Uri.base.resolve(
      '/media-proxy?url=${Uri.encodeQueryComponent(target.toString())}',
    );
    return _client.get(proxy, headers: proxyHeaders);
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
    return {
      'Accept': 'application/json',
      'X-AppId': appId,
      'X-Timestamp': '$timestamp',
      'X-Signature': base64Encode(digest.bytes),
    };
  }

  _DandanplayEpisode? _pickDandanplayEpisode(
    Object? decoded,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    final root = decoded is Map ? decoded : const {};
    final rawAnimes = root['animes'] ?? root['items'] ?? root['data'];
    if (rawAnimes is! List) return null;
    _DandanplayEpisode? selected;
    var bestScore = -1;
    for (final anime in rawAnimes.whereType<Map>()) {
      final animeTitle = _firstText([
        anime['animeTitle'],
        anime['title'],
        anime['name'],
      ]);
      final titleScore = _titleScore(animeTitle, subject);
      final rawEpisodes = anime['episodes'];
      if (rawEpisodes is! List) continue;
      for (final item in rawEpisodes.whereType<Map>()) {
        final episodeId = _intValue(item['episodeId'] ?? item['id']) ?? 0;
        if (episodeId <= 0) continue;
        final episodeTitle = _firstText([
          item['episodeTitle'],
          item['title'],
          item['name'],
        ]);
        final episodeMatched = _episodeMatches(episodeTitle, episode);
        final score = titleScore + (episodeMatched ? 60 : 0);
        if (score > bestScore) {
          bestScore = score;
          selected = _DandanplayEpisode(
            title: animeTitle.isEmpty ? subject.title : animeTitle,
            episodeTitle: episodeTitle.isEmpty
                ? episode.displayTitle
                : episodeTitle,
            episodeId: episodeId,
          );
        }
      }
    }
    return bestScore >= 60 ? selected : null;
  }

  int _bilibiliTitleScore(Map<dynamic, dynamic> item, AnimeSubject subject) {
    final title = _plainText(item['title']);
    final original = _plainText(item['org_title']);
    return [
      _titleScore(title, subject),
      _titleScore(original, subject),
    ].reduce((left, right) => left > right ? left : right);
  }

  int _titleScore(String value, AnimeSubject subject) {
    final candidate = _normalizeTitle(value);
    if (candidate.isEmpty) return 0;
    var score = 0;
    for (final rawTarget in [subject.title, subject.originalTitle]) {
      final target = _normalizeTitle(rawTarget);
      if (target.isEmpty) continue;
      if (candidate == target) {
        score = score < 120 ? 120 : score;
      } else if (candidate.contains(target) || target.contains(candidate)) {
        score = score < 75 ? 75 : score;
      }
    }
    return score;
  }

  String _cacheKey(
    AnimeSubject subject,
    AnimeEpisode episode,
    ExternalServiceSettings settings,
  ) {
    return '${subject.source}|${subject.id}|${subject.title}|${episode.number}|'
        '${settings.bilibiliDanmakuEnabled}|'
        '${settings.dandanplayDanmakuEnabled}|${settings.dandanplayAppId}|'
        '${settings.dandanplayAppSecret.hashCode}|'
        '${settings.customDanmakuEnabled}|${settings.customDanmakuEndpoint}';
  }
}

List<DanmakuComment> parseBilibiliDanmakuXml(String source) {
  try {
    return _parseBilibiliXmlDocument(XmlDocument.parse(source));
  } on XmlParserException {
    return _parseBilibiliXmlFallback(source);
  }
}

List<DanmakuComment> _parseBilibiliXmlDocument(XmlDocument document) {
  final comments = <DanmakuComment>[];
  var index = 0;
  for (final element in document.findAllElements('d')) {
    final packed = element.getAttribute('p');
    final text = element.innerText.trim();
    final comment = _parsePackedDanmaku(
      packed,
      text,
      provider: 'Bilibili',
      fallbackId: 'bilibili-${index++}',
    );
    if (comment != null) comments.add(comment);
  }
  comments.sort(_compareComments);
  return List.unmodifiable(comments);
}

List<DanmakuComment> _parseBilibiliXmlFallback(String source) {
  final comments = <DanmakuComment>[];
  final pattern = RegExp(
    r'<d\s+[^>]*\bp="([^"]*)"[^>]*>([\s\S]*?)</d>',
    caseSensitive: false,
  );
  var index = 0;
  for (final match in pattern.allMatches(source)) {
    final comment = _parsePackedDanmaku(
      match.group(1),
      _plainText(match.group(2)),
      provider: 'Bilibili',
      fallbackId: 'bilibili-${index++}',
    );
    if (comment != null) comments.add(comment);
  }
  comments.sort(_compareComments);
  return List.unmodifiable(comments);
}

List<DanmakuComment> parseDandanplayDanmaku(Object? source) {
  final root = source is Map ? source : const {};
  final rawComments = root['comments'] ?? root['data'];
  if (rawComments is! List) return const [];
  final comments = <DanmakuComment>[];
  var index = 0;
  for (final item in rawComments.whereType<Map>()) {
    final text = _firstText([item['m'], item['text'], item['content']]);
    final comment = _parsePackedDanmaku(
      item['p']?.toString(),
      text,
      provider: '弹弹play',
      fallbackId: item['cid']?.toString() ?? 'dandanplay-${index++}',
    );
    if (comment != null) comments.add(comment);
  }
  comments.sort(_compareComments);
  return List.unmodifiable(comments);
}

List<DanmakuComment> parseCustomDanmaku(Object? source) {
  final rawComments = source is List
      ? source
      : source is Map
      ? source['comments'] ?? source['data']
      : null;
  if (rawComments is! List) return const [];
  final comments = <DanmakuComment>[];
  var index = 0;
  for (final item in rawComments.whereType<Map>()) {
    final packed = item['p']?.toString();
    final text = _firstText([item['m'], item['text'], item['content']]);
    DanmakuComment? comment;
    if (packed != null && packed.isNotEmpty) {
      comment = _parsePackedDanmaku(
        packed,
        text,
        provider: '自建弹幕库',
        fallbackId: item['id']?.toString() ?? 'custom-${index++}',
      );
    } else {
      final seconds = _doubleValue(item['time'] ?? item['timeSeconds']);
      final progress = _doubleValue(item['progress']);
      final time = seconds ?? (progress == null ? null : progress / 1000);
      if (time != null && time >= 0 && text.isNotEmpty) {
        comment = DanmakuComment(
          id: item['id']?.toString() ?? 'custom-${index++}',
          provider: '自建弹幕库',
          time: Duration(milliseconds: (time * 1000).round()),
          mode: _danmakuMode(_intValue(item['mode']) ?? 1),
          color: _colorValue(item['color']) ?? 0xFFFFFF,
          text: text,
        );
      }
    }
    if (comment != null) comments.add(comment);
  }
  comments.sort(_compareComments);
  return List.unmodifiable(comments);
}

DanmakuComment? _parsePackedDanmaku(
  String? packed,
  String text, {
  required String provider,
  required String fallbackId,
}) {
  if (packed == null || text.isEmpty) return null;
  final fields = packed.split(',');
  if (fields.length < 3) return null;
  final seconds = double.tryParse(fields[0].trim());
  if (seconds == null || !seconds.isFinite || seconds < 0) return null;
  final mode = int.tryParse(fields[1].trim()) ?? 1;
  final color = _colorValue(fields.length >= 8 ? fields[3] : fields[2]);
  final rowId = fields.length > 7 ? fields[7].trim() : '';
  return DanmakuComment(
    id: rowId.isEmpty ? fallbackId : '$provider-$rowId',
    provider: provider,
    time: Duration(milliseconds: (seconds * 1000).round()),
    mode: _danmakuMode(mode),
    color: color ?? 0xFFFFFF,
    text: text,
  );
}

DanmakuMode _danmakuMode(int mode) {
  return switch (mode) {
    4 => DanmakuMode.bottom,
    5 => DanmakuMode.top,
    6 => DanmakuMode.reverse,
    7 || 8 => DanmakuMode.advanced,
    _ => DanmakuMode.scroll,
  };
}

int _compareComments(DanmakuComment left, DanmakuComment right) {
  final byTime = left.time.compareTo(right.time);
  return byTime != 0 ? byTime : left.id.compareTo(right.id);
}

DanmakuMatch _unavailableMatch({
  required String provider,
  required String title,
  required String episodeTitle,
  required String message,
  String episodeId = '',
}) {
  return DanmakuMatch(
    provider: provider,
    title: title,
    episodeTitle: episodeTitle,
    episodeId: episodeId,
    available: false,
    message: message,
  );
}

String _preferredKeyword(AnimeSubject subject) {
  final title = subject.title.trim();
  if (title.length >= 2) return title;
  return subject.originalTitle.trim();
}

bool _episodeMatches(String title, AnimeEpisode episode) {
  final normalized = title.toLowerCase().replaceAll(' ', '');
  final number = episode.number;
  return _episodeNumber(normalized) == number ||
      normalized.contains('第$number') ||
      normalized.contains('ep$number') ||
      normalized.contains('episode$number');
}

int? _episodeNumber(Object? value) {
  final text = _plainText(value).trim();
  final direct = double.tryParse(text);
  if (direct != null && direct == direct.roundToDouble()) {
    return direct.toInt();
  }
  final match = RegExp(
    r'(?:第\s*|ep(?:isode)?\s*)?(\d+)(?:\s*[集话話]|\b)',
    caseSensitive: false,
  ).firstMatch(text);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String _normalizeTitle(String value) {
  return _plainText(value)
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_·・:：,，.。!！?？\[\]【】()（）]'), '')
      .trim();
}

String _plainText(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return '';
  return html_parser.parseFragment(raw).text?.trim() ?? '';
}

String _firstText(Iterable<Object?> values) {
  for (final value in values) {
    final text = _plainText(value);
    if (text.isNotEmpty) return text;
  }
  return '';
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _doubleValue(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

int? _colorValue(Object? value) {
  if (value is int) return value.clamp(0, 0xFFFFFF).toInt();
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty) return null;
  if (raw.startsWith('#')) return int.tryParse(raw.substring(1), radix: 16);
  if (raw.startsWith('0x')) return int.tryParse(raw.substring(2), radix: 16);
  return int.tryParse(raw)?.clamp(0, 0xFFFFFF).toInt();
}

class _DanmakuSourceResult {
  const _DanmakuSourceResult({required this.match, this.comments = const []});

  final DanmakuMatch match;
  final List<DanmakuComment> comments;
}

class _BilibiliEpisode {
  const _BilibiliEpisode({
    required this.seasonTitle,
    required this.episodeTitle,
    required this.cid,
  });

  final String seasonTitle;
  final String episodeTitle;
  final int cid;
}

class _BilibiliSearchResult {
  const _BilibiliSearchResult({this.items = const [], this.rejectionMessage});

  final List<Map<dynamic, dynamic>> items;
  final String? rejectionMessage;
}

class _BilibiliLookupException implements Exception {
  const _BilibiliLookupException(this.message);

  final String message;
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

class _TimedTimeline {
  const _TimedTimeline({required this.timeline, required this.expiresAt});

  final DanmakuTimeline timeline;
  final DateTime expiresAt;
}
