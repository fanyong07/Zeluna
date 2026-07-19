import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../domain/anime_models.dart';
import 'rule_models.dart';

const _playableProbeTimeout = Duration(seconds: 6);
const _responseCacheTtl = Duration(minutes: 5);
const _availableProbeCacheTtl = Duration(minutes: 2);
const _failedProbeCacheTtl = Duration(seconds: 20);
const _maxResponseCacheEntries = 128;
const _maxProbeCacheEntries = 256;

class RulePlaybackResolver {
  RulePlaybackResolver({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client;

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  final http.Client? _client;
  final Duration timeout;
  final Map<String, _TimedCacheEntry<String>> _responseCache = {};
  final Map<String, Future<String>> _responseRequests = {};
  final Map<String, _TimedCacheEntry<_PlayableProbeResult>> _probeCache = {};
  final Map<String, Future<_PlayableProbeResult>> _probeRequests = {};

  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
  }) async {
    if (rule.requiresCaptcha || rule.unsupportedReason != null) {
      return [
        _unavailableLine(
          rule,
          subject,
          episode,
          rule.unsupportedReason ?? '该规则需要验证码或 WebView 手动处理，解析器不会绕过验证。',
        ),
      ];
    }

    final ownedClient = _client == null;
    final client = _client ?? http.Client();
    final started = Stopwatch()..start();
    try {
      return switch (rule.engine.toLowerCase()) {
        'native' => await _resolveKazumi(
          client,
          rule,
          subject,
          episode,
          started,
          verifyPlayable: verifyPlayable,
        ),
        'xbpq' => await _resolveXbpq(
          client,
          rule,
          subject,
          episode,
          started,
          verifyPlayable: verifyPlayable,
        ),
        'tvbox-json-api' => await _resolveTvBoxJsonApi(
          client,
          rule,
          subject,
          episode,
          started,
          verifyPlayable: verifyPlayable,
        ),
        'animeko-web-selector' => await _resolveAnimekoWebSelector(
          client,
          rule,
          subject,
          episode,
          started,
          verifyPlayable: verifyPlayable,
        ),
        _ => [
          _unavailableLine(
            rule,
            subject,
            episode,
            '该规则属于 ${rule.engine}，需要接入对应规则执行器后才能解析。',
          ),
        ],
      };
    } catch (error) {
      return [_unavailableLine(rule, subject, episode, _friendlyError(error))];
    } finally {
      started.stop();
      if (ownedClient) client.close();
    }
  }

  Future<List<PlaybackLine>> _resolveAnimekoWebSelector(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final config = rule.animeko;
    if (config == null) {
      return [
        _unavailableLine(rule, subject, episode, '该 Animeko 源缺少 CSS 解析配置。'),
      ];
    }

    final detailUrl = await _findAnimekoDetailUrl(
      client,
      rule,
      config,
      subject,
    );
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目的详情页。')];
    }

    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    final detailRoot = _documentRoot(detailHtml);
    final episodeLinks = _animekoEpisodeLinks(
      detailRoot,
      detailUrl.toString(),
      config,
      episode,
    );
    if (episodeLinks.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '详情页没有解析到当前集的播放入口。')];
    }

    final lines = (await Future.wait([
      for (var index = 0; index < episodeLinks.length; index++)
        _resolveAnimekoLine(
          client,
          rule,
          config,
          episode,
          detailUrl,
          episodeLinks[index],
          index,
          started,
          verifyPlayable: verifyPlayable,
        ),
    ])).whereType<PlaybackLine>().toList(growable: false);

    if (lines.isEmpty) {
      return [
        _unavailableLine(rule, subject, episode, '找到了播放页，但没有解析到 mp4/m3u8 直链。'),
      ];
    }
    return lines;
  }

  Future<PlaybackLine?> _resolveAnimekoLine(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    AnimeEpisode episode,
    Uri detailUrl,
    _AnimekoEpisodeLink link,
    int index,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    try {
      final playHtml = await _get(
        client,
        Uri.parse(link.url),
        _headers(rule: rule, referer: detailUrl.toString()),
      );
      final playableUrl = await _extractAnimekoPlayableUrl(
        client,
        rule,
        config,
        playHtml,
        link.url,
        get: (url, headers) => _get(client, url, headers),
      );
      if (playableUrl == null || !_looksPlayable(playableUrl)) return null;

      final referer = _animekoVideoReferer(config, link.url);
      final headers = _animekoVideoHeaders(rule, config, referer);
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
      );
      final title =
          '${link.title.isEmpty ? episode.displayTitle : link.title} · 线路${index + 1}';
      return probe.available
          ? _availableLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: started.elapsed,
              referer: referer,
              quality: config.defaultResolution.trim().isEmpty
                  ? null
                  : config.defaultResolution.trim(),
              headers: headers,
            )
          : _deadLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: started.elapsed,
              message: probe.message,
              headers: headers,
            );
    } catch (_) {
      return null;
    }
  }

  Future<Uri?> _findAnimekoDetailUrl(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    AnimeSubject subject,
  ) async {
    final keywords = _animekoSearchKeywords(subject, config);
    final best = await _firstConfidentResult([
      for (var index = 0; index < keywords.length; index++)
        _searchAnimekoKeyword(
          client,
          rule,
          config,
          subject,
          keywords[index],
          index,
        ),
    ]);
    return best == null ? null : Uri.tryParse(best.url);
  }

  Future<_RankedResult<_SearchHit>?> _searchAnimekoKeyword(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    AnimeSubject subject,
    String keyword,
    int preference,
  ) async {
    final searchUri = Uri.parse(_animekoSearchUrl(config.searchUrl, keyword));
    final searchHtml = await _get(
      client,
      searchUri,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    final root = _documentRoot(searchHtml);
    final hits = _animekoSearchHits(root, searchUri.toString(), config);
    return _rankBestHit(hits, subject, preference);
  }

  Future<List<PlaybackLine>> _resolveKazumi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final config = rule.kazumi;
    if (config == null) {
      return [
        _unavailableLine(rule, subject, episode, '该 Kazumi 规则缺少 XPath 解析配置。'),
      ];
    }

    final detailUrl = await _findKazumiDetailUrl(client, rule, config, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目的详情页。')];
    }

    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl, userAgent: config.userAgent),
    );
    final detailRoot = _documentRoot(detailHtml);
    final roadNodes = _xpathNodes(detailRoot, config.chapterRoads);
    if (roadNodes.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '详情页没有解析到播放线路。')];
    }

    final lines = (await Future.wait([
      for (var roadIndex = 0; roadIndex < roadNodes.length; roadIndex++)
        _resolveKazumiLine(
          client,
          rule,
          config,
          episode,
          detailUrl,
          roadNodes[roadIndex],
          roadIndex,
          started,
          verifyPlayable: verifyPlayable,
        ),
    ])).whereType<PlaybackLine>().toList(growable: false);

    if (lines.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '找到详情页，但当前集没有解析到直链。')];
    }
    return lines;
  }

  Future<PlaybackLine?> _resolveKazumiLine(
    http.Client client,
    RulePlugin rule,
    KazumiParserConfig config,
    AnimeEpisode episode,
    Uri detailUrl,
    dom.Node road,
    int roadIndex,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    try {
      final episodeNodes = _xpathNodes(road, config.chapterResult);
      final episodeNode = _pickEpisodeNode(episodeNodes, episode);
      if (episodeNode == null) return null;

      final playHref = _nodeHref(episodeNode);
      if (playHref.isEmpty) return null;

      final playPageUrl = _absoluteUrl(playHref, detailUrl.toString());
      final playHtml = await _get(
        client,
        Uri.parse(playPageUrl),
        _headers(rule: rule, referer: detailUrl.toString()),
      );
      final playableUrl = _extractPlayableUrl(playHtml, playPageUrl);
      if (playableUrl == null || !_looksPlayable(playableUrl)) return null;
      final headers = _headers(rule: rule, referer: playPageUrl);
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
      );
      final title = '${episode.displayTitle} · 线路${roadIndex + 1}';
      return probe.available
          ? _availableLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: started.elapsed,
              referer: playPageUrl,
              headers: headers,
            )
          : _deadLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: started.elapsed,
              message: probe.message,
              headers: headers,
            );
    } catch (_) {
      return null;
    }
  }

  Future<Uri?> _findKazumiDetailUrl(
    http.Client client,
    RulePlugin rule,
    KazumiParserConfig config,
    AnimeSubject subject,
  ) async {
    final keywords = _searchKeywords(subject);
    final best = await _firstConfidentResult([
      for (var index = 0; index < keywords.length; index++)
        _searchKazumiKeyword(
          client,
          rule,
          config,
          subject,
          keywords[index],
          index,
        ),
    ]);
    return best == null ? null : Uri.tryParse(best.url);
  }

  Future<_RankedResult<_SearchHit>?> _searchKazumiKeyword(
    http.Client client,
    RulePlugin rule,
    KazumiParserConfig config,
    AnimeSubject subject,
    String keyword,
    int preference,
  ) async {
    final searchUrl = _searchUrl(rule.searchUrl, keyword);
    final searchHtml = await _get(
      client,
      Uri.parse(searchUrl),
      _headers(rule: rule, referer: rule.baseUrl, userAgent: config.userAgent),
    );
    final root = _documentRoot(searchHtml);
    final hits = [
      for (final item in _xpathNodes(root, config.searchList))
        _SearchHit(
          title: _xpathText(item, config.searchName),
          url: _absoluteUrl(
            _xpathHref(item, config.searchResult),
            rule.baseUrl,
          ),
        ),
    ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
    return _rankBestHit(hits, subject, preference);
  }

  Future<List<PlaybackLine>> _resolveXbpq(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final config = rule.xbpq;
    if (config == null) {
      return [_unavailableLine(rule, subject, episode, '该 XBPQ 规则缺少解析配置。')];
    }

    final detailUrl = await _findXbpqDetailUrl(client, rule, config, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目的详情页。')];
    }

    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    var playGroups = _segmentsByRule(detailHtml, config.playArray);
    if (playGroups.isEmpty) playGroups = [detailHtml];

    final lines = (await Future.wait([
      for (var groupIndex = 0; groupIndex < playGroups.length; groupIndex++)
        _resolveXbpqLine(
          client,
          rule,
          config,
          episode,
          detailUrl,
          playGroups[groupIndex],
          groupIndex,
          started,
          verifyPlayable: verifyPlayable,
        ),
    ])).whereType<PlaybackLine>().toList(growable: false);

    if (lines.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '找到详情页，但当前集没有解析到直链。')];
    }
    return lines;
  }

  Future<PlaybackLine?> _resolveXbpqLine(
    http.Client client,
    RulePlugin rule,
    XbpqParserConfig config,
    AnimeEpisode episode,
    Uri detailUrl,
    String playGroup,
    int groupIndex,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    try {
      var episodeSegments = _segmentsByRule(playGroup, config.playList);
      if (config.reverseEpisodes) {
        episodeSegments = episodeSegments.reversed.toList(growable: false);
      }
      final episodeSegment = _pickEpisodeSegment(episodeSegments, episode);
      if (episodeSegment == null) return null;

      final playHref = _cutByRule(episodeSegment, config.playLink);
      if (playHref.isEmpty) return null;

      final playPageUrl = _absoluteUrl(playHref, detailUrl.toString());
      final playHtml = await _get(
        client,
        Uri.parse(playPageUrl),
        _headers(rule: rule, referer: detailUrl.toString()),
      );
      final playableUrl =
          _extractByWildcardRule(playHtml, config.jumpPlayLink) ??
          _extractPlayableUrl(playHtml, playPageUrl);
      if (playableUrl == null || !_looksPlayable(playableUrl)) return null;

      final lineTitle = _cleanText(
        _cutByRule(episodeSegment, config.playTitle),
      );
      final normalizedPlayableUrl = _normalizePlayableUrl(
        playableUrl,
        playPageUrl,
      );
      final headers = _headers(rule: rule, referer: playPageUrl);
      final probe = await _playableCandidateStatus(
        client,
        normalizedPlayableUrl,
        headers,
        verifyPlayable: verifyPlayable,
      );
      final title =
          '${lineTitle.isEmpty ? episode.displayTitle : lineTitle} · 线路${groupIndex + 1}';
      return probe.available
          ? _availableLine(
              rule,
              episode,
              url: normalizedPlayableUrl,
              title: title,
              latency: started.elapsed,
              referer: playPageUrl,
              headers: headers,
            )
          : _deadLine(
              rule,
              episode,
              url: normalizedPlayableUrl,
              title: title,
              latency: started.elapsed,
              message: probe.message,
              headers: headers,
            );
    } catch (_) {
      return null;
    }
  }

  Future<Uri?> _findXbpqDetailUrl(
    http.Client client,
    RulePlugin rule,
    XbpqParserConfig config,
    AnimeSubject subject,
  ) async {
    final keywords = _searchKeywords(subject);
    final best = await _firstConfidentResult([
      for (var index = 0; index < keywords.length; index++)
        _searchXbpqKeyword(
          client,
          rule,
          config,
          subject,
          keywords[index],
          index,
        ),
    ]);
    return best == null ? null : Uri.tryParse(best.url);
  }

  Future<_RankedResult<_SearchHit>?> _searchXbpqKeyword(
    http.Client client,
    RulePlugin rule,
    XbpqParserConfig config,
    AnimeSubject subject,
    String keyword,
    int preference,
  ) async {
    final searchUri = Uri.parse(_searchUrl(rule.searchUrl, keyword));
    final searchHtml = config.searchPostBody.trim().isEmpty
        ? await _get(
            client,
            searchUri,
            _headers(rule: rule, referer: rule.baseUrl),
          )
        : await _post(
            client,
            searchUri,
            _searchBody(config.searchPostBody, keyword),
            _headers(rule: rule, referer: rule.baseUrl),
          );
    final hits = [
      for (final segment in _segmentsByRule(searchHtml, config.searchArray))
        _SearchHit(
          title: _cleanText(_cutByRule(segment, config.searchTitle)),
          url: _absoluteUrl(
            _cutByRule(segment, config.searchLink),
            rule.baseUrl,
          ),
        ),
    ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
    return _rankBestHit(hits, subject, preference);
  }

  Future<List<PlaybackLine>> _resolveTvBoxJsonApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final endpoint = Uri.tryParse(rule.baseUrl.trim());
    if (endpoint == null || !endpoint.hasScheme || endpoint.host.isEmpty) {
      return [
        _unavailableLine(rule, subject, episode, '该 TVBox JSON 源缺少有效接口地址。'),
      ];
    }

    final searches = <Future<_RankedResult<Map<String, dynamic>>?>>[];
    var preference = 0;
    for (final keyword in _searchKeywords(subject)) {
      for (final searchUri in _tvBoxSearchUris(endpoint, keyword)) {
        searches.add(
          _searchTvBoxItem(
            client,
            rule,
            subject,
            endpoint,
            searchUri,
            preference++,
          ),
        );
      }
    }
    var item = await _firstConfidentResult(searches);
    if (item == null) {
      return [_unavailableLine(rule, subject, episode, '接口没有匹配到当前条目。')];
    }

    if (_tvBoxPlayUrl(item).isEmpty) {
      final vodId = item['vod_id']?.toString().trim() ?? '';
      if (vodId.isNotEmpty) {
        try {
          final decoded = jsonDecode(
            await _get(
              client,
              _tvBoxDetailUri(endpoint, vodId),
              _headers(rule: rule, referer: endpoint.toString()),
            ),
          );
          final details = _tvBoxItems(decoded);
          if (details.isNotEmpty) item = details.first;
        } catch (_) {
          // 搜索响应本身可能已经包含播放地址，详情补查失败时继续使用原数据。
        }
      }
    }

    final groups = _tvBoxPlayGroups(item);
    final lines = (await Future.wait([
      for (var index = 0; index < groups.length && index < 8; index++)
        _resolveTvBoxLine(
          client,
          rule,
          episode,
          endpoint,
          groups[index],
          started,
          verifyPlayable: verifyPlayable,
        ),
    ])).whereType<PlaybackLine>().toList(growable: false);
    if (lines.isEmpty) {
      return [
        _unavailableLine(rule, subject, episode, '已找到条目，但当前集没有可直接播放的地址。'),
      ];
    }
    return lines;
  }

  Future<_RankedResult<Map<String, dynamic>>?> _searchTvBoxItem(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    Uri endpoint,
    Uri searchUri,
    int preference,
  ) async {
    try {
      final decoded = jsonDecode(
        await _get(
          client,
          searchUri,
          _headers(rule: rule, referer: endpoint.toString()),
        ),
      );
      return _rankBestTvBoxItem(_tvBoxItems(decoded), subject, preference);
    } catch (_) {
      // TVBox 聚合接口格式并不完全一致，单个查询失败时让其他查询继续。
      return null;
    }
  }

  Future<PlaybackLine?> _resolveTvBoxLine(
    http.Client client,
    RulePlugin rule,
    AnimeEpisode episode,
    Uri endpoint,
    _TvBoxPlayGroup group,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    final selected = _pickTvBoxEpisode(group.episodes, episode);
    if (selected == null) return null;
    final playableUrl = _normalizePlayableUrl(
      selected.url,
      endpoint.toString(),
    );
    if (!_looksPlayable(playableUrl)) return null;
    final headers = _headers(rule: rule, referer: endpoint.toString());
    final probe = await _playableCandidateStatus(
      client,
      playableUrl,
      headers,
      verifyPlayable: verifyPlayable,
    );
    final title = group.name.trim().isEmpty
        ? selected.title
        : '${selected.title} · ${group.name}';
    return probe.available
        ? _availableLine(
            rule,
            episode,
            url: playableUrl,
            title: title,
            latency: started.elapsed,
            referer: endpoint.toString(),
            headers: headers,
          )
        : _deadLine(
            rule,
            episode,
            url: playableUrl,
            title: title,
            latency: started.elapsed,
            message: probe.message,
            headers: headers,
          );
  }

  Future<String> _get(
    http.Client client,
    Uri url,
    Map<String, String> headers,
  ) async {
    final requestUri = _ruleRequestUri(url);
    final requestHeaders = _ruleRequestHeaders(url, headers);
    final key = _requestCacheKey('GET', requestUri, requestHeaders);
    final cached = _freshCacheValue(_responseCache, key);
    if (cached != null) return cached;

    final existing = _responseRequests[key];
    if (existing != null) return existing;

    final request = client
        .get(requestUri, headers: requestHeaders)
        .timeout(timeout)
        .then(_responseText);
    _responseRequests[key] = request;
    try {
      final result = await request;
      _storeCacheValue(
        _responseCache,
        key,
        result,
        _responseCacheTtl,
        _maxResponseCacheEntries,
      );
      return result;
    } finally {
      if (identical(_responseRequests[key], request)) {
        _responseRequests.remove(key);
      }
    }
  }

  Future<String> _post(
    http.Client client,
    Uri url,
    String body,
    Map<String, String> headers,
  ) async {
    final requestUri = _ruleRequestUri(url);
    final requestHeaders = _ruleRequestHeaders(url, headers);
    final key = _requestCacheKey(
      'POST',
      requestUri,
      requestHeaders,
      body: body,
    );
    final cached = _freshCacheValue(_responseCache, key);
    if (cached != null) return cached;

    final existing = _responseRequests[key];
    if (existing != null) return existing;

    final request = client
        .post(requestUri, headers: requestHeaders, body: body)
        .timeout(timeout)
        .then(_responseText);
    _responseRequests[key] = request;
    try {
      final result = await request;
      _storeCacheValue(
        _responseCache,
        key,
        result,
        _responseCacheTtl,
        _maxResponseCacheEntries,
      );
      return result;
    } finally {
      if (identical(_responseRequests[key], request)) {
        _responseRequests.remove(key);
      }
    }
  }

  String _responseText(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return response.body;
  }

  PlaybackLine _availableLine(
    RulePlugin rule,
    AnimeEpisode episode, {
    required String url,
    required String title,
    required Duration latency,
    required String referer,
    String? quality,
    Map<String, String>? headers,
  }) {
    final normalizedUrl = _normalizePlayableUrl(url, referer);
    return PlaybackLine(
      id: 'rule:${rule.id}:${episode.id}:${normalizedUrl.hashCode}',
      episodeId: episode.id,
      providerId: rule.id,
      providerName: rule.name,
      title: title,
      quality: quality ?? (rule.tags.contains('4K') ? '4K/HD' : 'HD'),
      format: _formatForUrl(normalizedUrl, rule.engine),
      url: normalizedUrl,
      headers: headers ?? _headers(rule: rule, referer: referer),
      latency: latency,
      sizeLabel: _sizeLabelForUrl(normalizedUrl),
      available: true,
      message: '已解析到当前集的播放地址。',
    );
  }

  PlaybackLine _deadLine(
    RulePlugin rule,
    AnimeEpisode episode, {
    required String url,
    required String title,
    required Duration latency,
    required String message,
    required Map<String, String> headers,
  }) {
    final normalizedUrl = _normalizePlayableUrl(url, headers['Referer'] ?? '');
    return PlaybackLine(
      id: 'rule:${rule.id}:${episode.id}:dead:${normalizedUrl.hashCode}',
      episodeId: episode.id,
      providerId: rule.id,
      providerName: rule.name,
      title: title,
      quality: rule.tags.contains('4K') ? '4K/HD' : 'HD',
      format: _formatForUrl(normalizedUrl, rule.engine),
      url: normalizedUrl,
      headers: headers,
      latency: latency,
      sizeLabel: _sizeLabelForUrl(normalizedUrl),
      available: false,
      message: message,
    );
  }

  PlaybackLine _unavailableLine(
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    String message,
  ) {
    return PlaybackLine(
      id: 'rule:${rule.id}:${episode.id}:unavailable',
      episodeId: episode.id,
      providerId: rule.id,
      providerName: rule.name,
      title: rule.contentType == RuleContentType.movie
          ? '${subject.title} · 正片'
          : '${subject.title} · 第${episode.number}集',
      quality: rule.tags.contains('4K') ? '4K/HD' : 'HD',
      format: rule.engine,
      available: false,
      message: message,
    );
  }

  Map<String, String> _headers({
    required RulePlugin rule,
    String? referer,
    String userAgent = '',
  }) {
    final headers = <String, String>{
      'User-Agent': _desktopUserAgent,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
    for (final entry in rule.requestHeaders.entries) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isNotEmpty && value.isNotEmpty) headers[name] = value;
    }
    if (userAgent.trim().isNotEmpty) headers['User-Agent'] = userAgent.trim();
    final refererValue = referer?.trim();
    if (refererValue != null && refererValue.isNotEmpty) {
      headers['Referer'] = refererValue;
    } else if (!headers.containsKey('Referer') &&
        rule.baseUrl.trim().isNotEmpty) {
      headers['Referer'] = rule.baseUrl;
    }
    return headers;
  }

  Map<String, String> _animekoVideoHeaders(
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    String referer,
  ) {
    final headers = _headers(
      rule: rule,
      referer: referer,
      userAgent: config.videoUserAgent,
    );
    final cookie = config.cookies.trim();
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    return headers;
  }

  Future<_PlayableProbeResult> _probePlayableUrl(
    http.Client client,
    String url,
    Map<String, String> headers,
  ) async {
    final target = Uri.tryParse(url);
    if (target == null || !target.hasScheme) {
      return const _PlayableProbeResult(false, '视频地址格式不正确。');
    }
    final requestUri = _ruleRequestUri(target);
    final requestHeaders = _ruleRequestHeaders(
      target,
      _videoProbeHeaders(headers),
    );
    final key = _requestCacheKey('PROBE', requestUri, requestHeaders);
    final cached = _freshCacheValue(_probeCache, key);
    if (cached != null) return cached;

    final existing = _probeRequests[key];
    if (existing != null) return existing;

    final request = _performPlayableProbe(client, requestUri, requestHeaders);
    _probeRequests[key] = request;
    try {
      final result = await request;
      _storeCacheValue(
        _probeCache,
        key,
        result,
        result.available ? _availableProbeCacheTtl : _failedProbeCacheTtl,
        _maxProbeCacheEntries,
      );
      return result;
    } finally {
      if (identical(_probeRequests[key], request)) {
        _probeRequests.remove(key);
      }
    }
  }

  Future<_PlayableProbeResult> _playableCandidateStatus(
    http.Client client,
    String url,
    Map<String, String> headers, {
    required bool verifyPlayable,
  }) {
    if (!verifyPlayable && _isExplicitPlayableUrl(url)) {
      return Future.value(const _PlayableProbeResult(true, ''));
    }
    return _probePlayableUrl(client, url, headers);
  }

  Future<_PlayableProbeResult> _performPlayableProbe(
    http.Client client,
    Uri requestUri,
    Map<String, String> headers,
  ) async {
    try {
      final response = await _sendPlayableProbe(
        client,
        requestUri,
        headers,
      ).timeout(_playableProbeTimeout);
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return const _PlayableProbeResult(true, '');
      }
      if (response.statusCode == 403) {
        return const _PlayableProbeResult(false, '视频 CDN 拒绝访问，可能有防盗链或地区限制。');
      }
      if (response.statusCode == 404) {
        return const _PlayableProbeResult(false, '视频 CDN 返回 404，这条播放地址已经失效。');
      }
      return _PlayableProbeResult(
        false,
        '视频 CDN 返回 HTTP ${response.statusCode}。',
      );
    } on TimeoutException {
      return const _PlayableProbeResult(false, '视频 CDN 连接超时。');
    } catch (error) {
      return _PlayableProbeResult(false, '视频 CDN 无法访问：${_shortError(error)}');
    }
  }

  Future<http.StreamedResponse> _sendPlayableProbe(
    http.Client client,
    Uri requestUri,
    Map<String, String> headers,
  ) async {
    final request = http.Request('GET', requestUri)..headers.addAll(headers);
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 400) {
      final subscription = response.stream.listen(null);
      await subscription.cancel();
      return response;
    }
    final stream = StreamIterator<List<int>>(response.stream);
    try {
      // 只确认首个响应块可读；Range 被忽略时也不会把整段视频缓冲进内存。
      await stream.moveNext();
    } finally {
      await stream.cancel();
    }
    return response;
  }
}

class _TimedCacheEntry<T> {
  const _TimedCacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;
}

T? _freshCacheValue<T>(Map<String, _TimedCacheEntry<T>> cache, String key) {
  final entry = cache[key];
  if (entry == null) return null;
  if (DateTime.now().isBefore(entry.expiresAt)) return entry.value;
  cache.remove(key);
  return null;
}

void _storeCacheValue<T>(
  Map<String, _TimedCacheEntry<T>> cache,
  String key,
  T value,
  Duration ttl,
  int maxEntries,
) {
  cache.remove(key);
  cache[key] = _TimedCacheEntry(value, DateTime.now().add(ttl));
  while (cache.length > maxEntries) {
    cache.remove(cache.keys.first);
  }
}

String _requestCacheKey(
  String method,
  Uri uri,
  Map<String, String> headers, {
  String body = '',
}) {
  final normalizedHeaders = headers.entries.toList(growable: false)
    ..sort(
      (left, right) =>
          left.key.toLowerCase().compareTo(right.key.toLowerCase()),
    );
  final headerKey = normalizedHeaders
      .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
      .join('\n');
  return '$method\n$uri\n$headerKey\n$body';
}

Uri _ruleRequestUri(Uri target) {
  if (!kIsWeb) return target;
  final base = Uri.base;
  if (!const {'http', 'https'}.contains(base.scheme.toLowerCase())) {
    return target;
  }
  final host = target.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return target;
  }
  return base.resolve(
    '/media-proxy?url=${Uri.encodeQueryComponent(target.toString())}',
  );
}

Map<String, String> _ruleRequestHeaders(
  Uri target,
  Map<String, String> headers,
) {
  if (!kIsWeb || identical(_ruleRequestUri(target), target)) return headers;
  final result = <String, String>{...headers};
  for (final entry in const {
    'User-Agent': 'X-Upstream-User-Agent',
    'Referer': 'X-Upstream-Referer',
    'Authorization': 'X-Upstream-Authorization',
    'Cookie': 'X-Upstream-Cookie',
  }.entries) {
    final value = result.remove(entry.key);
    if (value != null && value.trim().isNotEmpty) {
      result[entry.value] = value;
    }
  }
  return result;
}

class _PlayableProbeResult {
  const _PlayableProbeResult(this.available, this.message);

  final bool available;
  final String message;
}

class HttpException implements Exception {
  const HttpException(this.message);

  final String message;

  @override
  String toString() => message;
}

List<Uri> _tvBoxSearchUris(Uri endpoint, String keyword) {
  final result = <String, Uri>{};
  for (final action in const ['detail', 'videolist']) {
    final query = <String, String>{...endpoint.queryParameters}
      ..remove('ids')
      ..['ac'] = action
      ..['wd'] = keyword;
    final uri = endpoint.replace(queryParameters: query);
    result[uri.toString()] = uri;
  }
  return result.values.toList(growable: false);
}

Uri _tvBoxDetailUri(Uri endpoint, String vodId) {
  final query = <String, String>{...endpoint.queryParameters}
    ..remove('wd')
    ..['ac'] = 'detail'
    ..['ids'] = vodId;
  return endpoint.replace(queryParameters: query);
}

List<Map<String, dynamic>> _tvBoxItems(Object? decoded) {
  Object? value = decoded;
  if (value is Map) {
    value = value['list'] ?? value['data'] ?? value['items'];
    if (value is Map) value = value['list'] ?? value['items'];
  }
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

_RankedResult<Map<String, dynamic>>? _rankBestTvBoxItem(
  List<Map<String, dynamic>> items,
  AnimeSubject subject,
  int preference,
) {
  if (items.isEmpty) return null;
  var best = items.first;
  var bestScore = -1;
  for (final item in items) {
    final title =
        item['vod_name']?.toString() ??
        item['name']?.toString() ??
        item['title']?.toString() ??
        '';
    final score = _matchScore(title, subject);
    if (score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  return bestScore <= 0
      ? null
      : _RankedResult(value: best, score: bestScore, preference: preference);
}

String _tvBoxPlayUrl(Map<String, dynamic>? item) {
  if (item == null) return '';
  return item['vod_play_url']?.toString() ??
      item['play_url']?.toString() ??
      item['url']?.toString() ??
      '';
}

List<_TvBoxPlayGroup> _tvBoxPlayGroups(Map<String, dynamic>? item) {
  final playText = _tvBoxPlayUrl(item).trim();
  if (playText.isEmpty) return const [];
  final sourceNames = (item?['vod_play_from']?.toString() ?? '').split(r'$$$');
  final groups = playText.split(r'$$$');
  final result = <_TvBoxPlayGroup>[];
  for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    final episodes = <_TvBoxEpisode>[];
    final rawEpisodes = groups[groupIndex].split('#');
    for (
      var episodeIndex = 0;
      episodeIndex < rawEpisodes.length;
      episodeIndex++
    ) {
      final raw = rawEpisodes[episodeIndex].trim();
      if (raw.isEmpty) continue;
      final separator = raw.indexOf(r'$');
      final title = separator < 0
          ? '第${episodeIndex + 1}集'
          : raw.substring(0, separator).trim();
      final url = separator < 0 ? raw : raw.substring(separator + 1).trim();
      if (url.isEmpty) continue;
      episodes.add(
        _TvBoxEpisode(
          title: title.isEmpty ? '第${episodeIndex + 1}集' : title,
          url: url,
        ),
      );
    }
    if (episodes.isEmpty) continue;
    result.add(
      _TvBoxPlayGroup(
        name: groupIndex < sourceNames.length
            ? sourceNames[groupIndex].trim()
            : '线路${groupIndex + 1}',
        episodes: episodes,
      ),
    );
  }
  return result;
}

_TvBoxEpisode? _pickTvBoxEpisode(
  List<_TvBoxEpisode> candidates,
  AnimeEpisode episode,
) {
  if (candidates.isEmpty) return null;
  final number = episode.number.toString();
  for (final candidate in candidates) {
    final title = _cleanText(candidate.title).toLowerCase();
    if (title == number ||
        title.contains('第$number') ||
        title.contains('ep$number') ||
        title.contains('e$number')) {
      return candidate;
    }
  }
  final index = episode.number - 1;
  if (index >= 0 && index < candidates.length) return candidates[index];
  return candidates.first;
}

class _TvBoxPlayGroup {
  const _TvBoxPlayGroup({required this.name, required this.episodes});

  final String name;
  final List<_TvBoxEpisode> episodes;
}

class _TvBoxEpisode {
  const _TvBoxEpisode({required this.title, required this.url});

  final String title;
  final String url;
}

class _SearchHit {
  const _SearchHit({required this.title, required this.url});

  final String title;
  final String url;
}

class _RankedResult<T> {
  const _RankedResult({
    required this.value,
    required this.score,
    required this.preference,
  });

  final T value;
  final int score;
  final int preference;
}

Future<T?> _firstConfidentResult<T>(List<Future<_RankedResult<T>?>> requests) {
  if (requests.isEmpty) return Future<T?>.value();

  final completer = Completer<T?>();
  _RankedResult<T>? best;
  Object? firstError;
  StackTrace? firstStackTrace;
  var remaining = requests.length;

  for (final request in requests) {
    unawaited(() async {
      try {
        final result = await request;
        if (result != null) {
          final current = best;
          if (current == null ||
              result.score > current.score ||
              (result.score == current.score &&
                  result.preference < current.preference)) {
            best = result;
          }
          if (result.score >= 80 && !completer.isCompleted) {
            completer.complete(result.value);
          }
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      } finally {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          final result = best;
          if (result != null) {
            completer.complete(result.value);
          } else if (firstError != null) {
            completer.completeError(firstError!, firstStackTrace);
          } else {
            completer.complete(null);
          }
        }
      }
    }());
  }
  return completer.future;
}

class _AnimekoEpisodeLink {
  const _AnimekoEpisodeLink({required this.title, required this.url});

  final String title;
  final String url;
}

dom.Element _documentRoot(String html) {
  final root = html_parser.parse(html).documentElement;
  if (root == null) throw const FormatException('空 HTML');
  return root;
}

List<dom.Node> _xpathNodes(dom.Node root, String xpath) {
  if (xpath.trim().isEmpty) return const [];
  try {
    return HtmlXPath.node(
      root,
    ).query(xpath).nodes.map((item) => item.node).toList();
  } catch (_) {
    return const [];
  }
}

List<_SearchHit> _animekoSearchHits(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
) {
  final format = config.subjectFormatId.trim().toLowerCase();
  if (format == 'indexed') {
    final names = _querySelectorAll(root, config.subjectIndexed.selectNames);
    final links = _querySelectorAll(root, config.subjectIndexed.selectLinks);
    final length = names.length < links.length ? names.length : links.length;
    return [
      for (var i = 0; i < length; i++)
        _SearchHit(
          title: _cleanText(names[i].text),
          url: _absoluteUrl(_elementHref(links[i]), baseUrl),
        ),
    ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
  }

  return [
    for (final item in _querySelectorAll(root, config.subjectA.selectLists))
      _SearchHit(
        title: _cleanText(
          _attrFromElement(item, 'title') ??
              _attrFromElement(item, 'alt') ??
              item.text,
        ),
        url: _absoluteUrl(_elementHref(item), baseUrl),
      ),
  ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
}

List<_AnimekoEpisodeLink> _animekoEpisodeLinks(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
  AnimeEpisode episode,
) {
  final links = config.channelFormatId.trim().toLowerCase() == 'no-channel'
      ? _animekoNoChannelEpisodeLinks(root, baseUrl, config, episode)
      : _animekoGroupedEpisodeLinks(root, baseUrl, config, episode);
  if (links.isNotEmpty) return links;

  final fallback = [
    for (final anchor in root.querySelectorAll('a'))
      _AnimekoEpisodeLink(
        title: _cleanText(anchor.text),
        url: _absoluteUrl(_elementHref(anchor), baseUrl),
      ),
  ].where((item) => item.url.isNotEmpty).toList();
  return _pickAnimekoEpisodes(
    fallback,
    episode,
    config.channelFlattened.matchEpisodeSortFromName,
  );
}

List<_AnimekoEpisodeLink> _animekoGroupedEpisodeLinks(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
  AnimeEpisode episode,
) {
  final channelConfig = config.channelFlattened;
  final episodeLists = _querySelectorAll(
    root,
    channelConfig.selectEpisodeLists,
  );
  if (episodeLists.isEmpty) return const [];

  final channelNames = _querySelectorAll(
    root,
    channelConfig.selectChannelNames,
  );
  final result = <_AnimekoEpisodeLink>[];
  for (var i = 0; i < episodeLists.length; i++) {
    if (i < channelNames.length &&
        !_matchesOptionalPattern(
          _cleanText(channelNames[i].text),
          channelConfig.matchChannelName,
        )) {
      continue;
    }
    final episodeNodes = _querySelectorAll(
      episodeLists[i],
      channelConfig.selectEpisodesFromList,
    );
    final candidates = [
      for (final item in episodeNodes)
        _AnimekoEpisodeLink(
          title: _cleanText(item.text),
          url: _absoluteUrl(
            _animekoEpisodeHref(item, channelConfig.selectEpisodeLinksFromList),
            baseUrl,
          ),
        ),
    ].where((item) => item.url.isNotEmpty).toList();
    result.addAll(
      _pickAnimekoEpisodes(
        candidates,
        episode,
        channelConfig.matchEpisodeSortFromName,
      ),
    );
  }
  return _uniqueEpisodeLinks(result);
}

List<_AnimekoEpisodeLink> _animekoNoChannelEpisodeLinks(
  dom.Element root,
  String baseUrl,
  AnimekoWebSelectorConfig config,
  AnimeEpisode episode,
) {
  final channelConfig = config.channelNoChannel;
  final candidates = [
    for (final item in _querySelectorAll(root, channelConfig.selectEpisodes))
      _AnimekoEpisodeLink(
        title: _cleanText(item.text),
        url: _absoluteUrl(
          _animekoEpisodeHref(item, channelConfig.selectEpisodeLinks),
          baseUrl,
        ),
      ),
  ].where((item) => item.url.isNotEmpty).toList();
  return _pickAnimekoEpisodes(
    candidates,
    episode,
    channelConfig.matchEpisodeSortFromName,
  );
}

List<_AnimekoEpisodeLink> _pickAnimekoEpisodes(
  List<_AnimekoEpisodeLink> candidates,
  AnimeEpisode episode,
  String sortPattern,
) {
  if (candidates.isEmpty) return const [];

  final bySort = candidates.where((item) {
    final sort = _animekoEpisodeSort(item.title, sortPattern);
    return sort != null && sort == episode.number;
  }).toList();
  if (bySort.isNotEmpty) return bySort;

  final numberText = episode.number.toString();
  final byText = candidates.where((item) {
    final title = _cleanText(item.title).toLowerCase();
    return title == numberText ||
        title.contains('第$numberText') ||
        title.contains('ep$numberText') ||
        title.contains('e$numberText');
  }).toList();
  if (byText.isNotEmpty) return byText;

  final index = episode.number - 1;
  if (index >= 0 && index < candidates.length) return [candidates[index]];
  return [candidates.first];
}

List<_AnimekoEpisodeLink> _uniqueEpisodeLinks(List<_AnimekoEpisodeLink> links) {
  final seen = <String>{};
  final result = <_AnimekoEpisodeLink>[];
  for (final link in links) {
    if (seen.add(link.url)) result.add(link);
  }
  return result;
}

Future<String?> _extractAnimekoPlayableUrl(
  http.Client client,
  RulePlugin rule,
  AnimekoWebSelectorConfig config,
  String html,
  String playPageUrl, {
  Future<String> Function(Uri url, Map<String, String> headers)? get,
}) async {
  final direct = _extractByRegex(
    html,
    config.matchVideoUrl,
    baseUrl: playPageUrl,
  );
  if (direct != null && _looksPlayable(direct)) return direct;

  final fallbackDirect = _extractPlayableUrl(html, playPageUrl);
  if (fallbackDirect != null && _looksPlayable(fallbackDirect)) {
    return fallbackDirect;
  }

  if (!config.enableNestedUrl || config.matchNestedUrl.trim().isEmpty) {
    return null;
  }
  final nestedUrl = _extractByRegex(
    html,
    config.matchNestedUrl,
    baseUrl: playPageUrl,
    requirePlayable: false,
  );
  if (nestedUrl == null) return null;

  final nestedUri = Uri.parse(nestedUrl);
  final nestedHeaders = _animekoNestedHeaders(rule, config, playPageUrl);
  final nestedHtml = get != null
      ? await get(nestedUri, nestedHeaders)
      : await client
            .get(nestedUri, headers: nestedHeaders)
            .timeout(const Duration(seconds: 10))
            .then((response) {
              if (response.statusCode < 200 || response.statusCode >= 400) {
                throw HttpException('HTTP ${response.statusCode}');
              }
              return response.body;
            });
  return _extractByRegex(
        nestedHtml,
        config.matchVideoUrl,
        baseUrl: nestedUrl,
      ) ??
      _extractPlayableUrl(nestedHtml, nestedUrl);
}

Map<String, String> _animekoNestedHeaders(
  RulePlugin rule,
  AnimekoWebSelectorConfig config,
  String referer,
) {
  final headers = <String, String>{
    'User-Agent': config.videoUserAgent.trim().isEmpty
        ? RulePlaybackResolver._desktopUserAgent
        : config.videoUserAgent.trim(),
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Referer': referer,
  };
  final cookie = config.cookies.trim();
  if (cookie.isNotEmpty) headers['Cookie'] = cookie;
  if (rule.baseUrl.trim().isNotEmpty && referer.trim().isEmpty) {
    headers['Referer'] = rule.baseUrl;
  }
  return headers;
}

String? _extractByRegex(
  String source,
  String pattern, {
  required String baseUrl,
  bool requirePlayable = true,
}) {
  if (pattern.trim().isEmpty) return null;
  RegExp regex;
  try {
    regex = RegExp(pattern, caseSensitive: false, dotAll: true);
  } catch (_) {
    return null;
  }

  for (final match in regex.allMatches(source)) {
    for (final value in _regexMatchCandidates(match)) {
      final normalized = _normalizePlayableUrl(value, baseUrl);
      if (normalized.isEmpty) continue;
      if (!requirePlayable || _looksPlayable(normalized)) return normalized;
    }
  }
  return null;
}

List<String> _regexMatchCandidates(RegExpMatch match) {
  final values = <String>[];
  for (final name in const ['v', 'url']) {
    try {
      final value = match.namedGroup(name);
      if (value != null && value.trim().isNotEmpty) values.add(value);
    } catch (_) {
      // Older or source-specific regexes may not declare named groups.
    }
  }
  for (var i = 1; i <= match.groupCount; i++) {
    final value = match.group(i);
    if (value != null && value.trim().isNotEmpty) values.add(value);
  }
  final whole = match.group(0);
  if (whole != null && whole.trim().isNotEmpty) values.add(whole);

  return values
      .map(_decodePlayerUrl)
      .map(_stripVideoUrlPrefix)
      .where((item) => item.trim().isNotEmpty)
      .toList(growable: false);
}

String _stripVideoUrlPrefix(String value) {
  final text = value.trim();
  final urlIndex = text.indexOf(RegExp(r'https?://', caseSensitive: false));
  if (urlIndex > 0) return text.substring(urlIndex);
  return text;
}

List<dom.Element> _querySelectorAll(dom.Element root, String selector) {
  final text = selector.trim();
  if (text.isEmpty) return const [];
  try {
    return root.querySelectorAll(text);
  } catch (_) {
    final patched = _quoteUnquotedAttributeValues(text);
    if (patched == text) return const [];
    try {
      return root.querySelectorAll(patched);
    } catch (_) {
      return const [];
    }
  }
}

String _quoteUnquotedAttributeValues(String selector) {
  final buffer = StringBuffer();
  var cursor = 0;
  final pattern = RegExp(r'''=\s*([^\]\"'\s]+)''');
  for (final match in pattern.allMatches(selector)) {
    buffer.write(selector.substring(cursor, match.start));
    buffer.write('="');
    buffer.write(match.group(1));
    buffer.write('"');
    cursor = match.end;
  }
  buffer.write(selector.substring(cursor));
  return buffer.toString();
}

String? _attrFromElement(dom.Element element, String name) {
  final value = element.attributes[name]?.trim();
  if (value == null || value.isEmpty) return null;
  return value;
}

String _elementHref(dom.Element element) {
  final direct = _nodeHref(element);
  if (direct.isNotEmpty) return direct;
  return element.querySelector('a') == null
      ? ''
      : _nodeHref(element.querySelector('a')!);
}

String _animekoEpisodeHref(dom.Element element, String linkSelector) {
  final selector = linkSelector.trim();
  if (selector.isNotEmpty) {
    final selected = _querySelectorAll(element, selector);
    if (selected.isNotEmpty) {
      final selectedHref = _elementHref(selected.first);
      if (selectedHref.isNotEmpty) return selectedHref;
    }
  }
  return _elementHref(element);
}

bool _matchesOptionalPattern(String value, String pattern) {
  if (pattern.trim().isEmpty) return true;
  try {
    return RegExp(pattern, caseSensitive: false).hasMatch(value);
  } catch (_) {
    return true;
  }
}

int? _animekoEpisodeSort(String title, String pattern) {
  final text = _cleanText(title);
  if (text.isEmpty) return null;
  if (pattern.trim().isNotEmpty) {
    try {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(text);
      final named = match?.namedGroup('ep');
      final value = _episodeNumberFromText(named ?? match?.group(1) ?? '');
      if (value != null) return value;
    } catch (_) {
      // Fall through to generic title parsing.
    }
  }
  return _episodeNumberFromText(text);
}

int? _episodeNumberFromText(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final direct = int.tryParse(text);
  if (direct != null) return direct;
  final match = RegExp(r'\d+').firstMatch(text);
  if (match != null) return int.tryParse(match.group(0)!);
  return null;
}

String _xpathText(dom.Node root, String xpath) {
  final nodes = _xpathNodes(root, xpath);
  if (nodes.isEmpty) return '';
  return _cleanText(nodes.first.text ?? '');
}

String _xpathHref(dom.Node root, String xpath) {
  final attr = _xpathAttr(root, '$xpath/@href');
  if (attr.isNotEmpty) return attr;
  final nodes = _xpathNodes(root, xpath);
  if (nodes.isEmpty) return '';
  return _nodeHref(nodes.first);
}

String _xpathAttr(dom.Node root, String xpath) {
  if (xpath.trim().isEmpty) return '';
  try {
    final result = HtmlXPath.node(root).query(xpath).attr;
    return result?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

String _nodeHref(dom.Node node) {
  if (node is! dom.Element) return '';
  return (node.attributes['href'] ??
          node.attributes['data-href'] ??
          node.attributes['data-url'] ??
          '')
      .trim();
}

dom.Node? _pickEpisodeNode(List<dom.Node> nodes, AnimeEpisode episode) {
  if (nodes.isEmpty) return null;
  final index = episode.number - 1;
  if (index >= 0 && index < nodes.length) return nodes[index];
  final normalizedNumber = episode.number.toString();
  for (final node in nodes) {
    final text = _cleanText(node.text ?? '');
    if (text == normalizedNumber ||
        text.contains('第$normalizedNumber') ||
        text.toLowerCase().contains('ep$normalizedNumber')) {
      return node;
    }
  }
  return nodes.first;
}

String? _pickEpisodeSegment(List<String> segments, AnimeEpisode episode) {
  if (segments.isEmpty) return null;
  final index = episode.number - 1;
  if (index >= 0 && index < segments.length) return segments[index];
  final normalizedNumber = episode.number.toString();
  for (final segment in segments) {
    final text = _cleanText(segment);
    if (text == normalizedNumber ||
        text.contains('第$normalizedNumber') ||
        text.toLowerCase().contains('ep$normalizedNumber')) {
      return segment;
    }
  }
  return segments.first;
}

List<String> _segmentsByRule(String source, String rule) {
  final parts = rule.split('&&');
  if (parts.length != 2) return const [];
  final start = parts.first;
  final end = parts.last;
  if (start.isEmpty || end.isEmpty) return const [];

  final result = <String>[];
  var offset = 0;
  while (offset < source.length) {
    final startIndex = source.indexOf(start, offset);
    if (startIndex < 0) break;
    final endIndex = source.indexOf(end, startIndex + start.length);
    if (endIndex < 0) break;
    result.add(source.substring(startIndex, endIndex + end.length));
    offset = endIndex + end.length;
  }
  return result;
}

String _cutByRule(String source, String rule) {
  if (rule.trim().isEmpty) return '';
  final parts = rule.split('&&');
  if (parts.length != 2) return '';
  final start = parts.first;
  final end = parts.last;
  final startIndex = start.isEmpty ? 0 : source.indexOf(start);
  if (startIndex < 0) return '';
  final valueStart = startIndex + start.length;
  final endIndex = end.isEmpty
      ? source.length
      : source.indexOf(end, valueStart);
  if (endIndex < 0) return '';
  return source.substring(valueStart, endIndex).trim();
}

String? _extractByWildcardRule(String source, String rule) {
  if (rule.trim().isEmpty) return null;
  final parts = rule.split('&&');
  if (parts.length != 2) return null;
  final startRule = parts.first;
  final end = parts.last;
  var cursor = 0;
  for (final marker in startRule.split('*')) {
    if (marker.isEmpty) continue;
    final index = source.indexOf(marker, cursor);
    if (index < 0) return null;
    cursor = index + marker.length;
  }
  final endIndex = end.isEmpty ? source.length : source.indexOf(end, cursor);
  if (endIndex < 0) return null;
  final value = _decodePlayerUrl(source.substring(cursor, endIndex));
  return value.isEmpty ? null : value;
}

String? _extractPlayableUrl(String html, String baseUrl) {
  for (final match in RegExp(
    r'var\s+player_\w+\s*=\s*(\{.*?\})\s*(?:;|</script)',
    dotAll: true,
  ).allMatches(html)) {
    final object = match.group(1);
    if (object == null) continue;
    final url = _playerJsonUrl(object);
    if (url != null && url.isNotEmpty) {
      final normalized = _normalizePlayableUrl(url, baseUrl);
      if (_looksPlayable(normalized)) return normalized;
    }
  }

  for (final match in RegExp(
    r'"url"\s*:\s*"([^"]+)"',
    dotAll: true,
  ).allMatches(html)) {
    final url = _decodePlayerUrl(match.group(1) ?? '');
    final normalized = _normalizePlayableUrl(url, baseUrl);
    if (_looksPlayable(normalized)) return normalized;
  }

  final directMatch = RegExp(
    r'https?:\\?/\\?/[^\s"<>]+?\.(?:m3u8|mp4|flv|m4v)(?:\?[^\s"<>]*)?',
    caseSensitive: false,
  ).firstMatch(html);
  if (directMatch == null) return null;
  return _normalizePlayableUrl(
    _decodePlayerUrl(directMatch.group(0) ?? ''),
    baseUrl,
  );
}

String? _playerJsonUrl(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is Map) {
      return _decodePlayerUrl(decoded['url'], decoded['encrypt']);
    }
  } catch (_) {
    final match = RegExp(
      r'''['"]url['"]\s*:\s*['"]([^'"]+)['"]''',
    ).firstMatch(source);
    if (match != null) return _decodePlayerUrl(match.group(1));
  }
  return null;
}

String _decodePlayerUrl(Object? raw, [Object? encrypt]) {
  var text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return '';
  text = text.replaceAll(r'\/', '/').replaceAll(r'\\/', '/');
  text = text.replaceAll(r'\u002F', '/').replaceAll(r'\u002f', '/');

  final encryptValue = encrypt?.toString();
  if (encryptValue == '2') {
    try {
      text = utf8.decode(base64Decode(text));
    } catch (_) {
      return text;
    }
  }
  if (encryptValue == '1' ||
      text.startsWith('http%3A') ||
      text.startsWith('https%3A')) {
    try {
      text = Uri.decodeFull(text);
    } catch (_) {
      return text;
    }
  }
  return text;
}

String _normalizePlayableUrl(String url, String baseUrl) {
  final decoded = _decodePlayerUrl(url);
  if (decoded.isEmpty) return decoded;
  return _absoluteUrl(decoded, baseUrl);
}

bool _looksPlayable(String url) {
  final lower = url.toLowerCase();
  if (lower.startsWith('magnet:') || lower.contains('ed2k://')) return false;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return false;
  }
  if (_isExplicitPlayableUrl(lower)) return true;
  return !lower.endsWith('.html') && !lower.contains('/vodplay/');
}

bool _isExplicitPlayableUrl(String url) {
  final lower = url.toLowerCase();
  return RegExp(
        r'\.(?:m3u8|mp4|flv|m4v)(?:$|[?#])',
        caseSensitive: false,
      ).hasMatch(lower) ||
      lower.contains('/m3u8') ||
      lower.contains('type=m3u8');
}

String _absoluteUrl(String value, String baseUrl) {
  final text = _decodePlayerUrl(value).trim();
  if (text.isEmpty) return '';
  if (text.startsWith('//')) return 'https:$text';
  final uri = Uri.tryParse(text);
  if (uri != null && uri.hasScheme) return text;
  final base = Uri.tryParse(baseUrl);
  if (base == null) return text;
  return base.resolve(text).toString();
}

String _searchUrl(String template, String keyword) {
  final encoded = Uri.encodeQueryComponent(keyword);
  return template
      .replaceAll('@keyword', encoded)
      .replaceAll('{keyword}', encoded)
      .replaceAll('{wd}', encoded)
      .replaceAll('{pg}', '1');
}

String _animekoSearchUrl(String template, String keyword) {
  return _searchUrl(template, keyword);
}

String _searchBody(String template, String keyword) {
  return template
      .replaceAll('{wd}', Uri.encodeQueryComponent(keyword))
      .replaceAll('@keyword', Uri.encodeQueryComponent(keyword))
      .replaceAll('{pg}', '1');
}

List<String> _searchKeywords(AnimeSubject subject) {
  final values = <String>[subject.title, subject.originalTitle];
  final seen = <String>{};
  return values
      .where((item) {
        final normalized = _normalizeTitle(item);
        return normalized.isNotEmpty && seen.add(normalized);
      })
      .map((item) => item.trim())
      .toList(growable: false);
}

List<String> _animekoSearchKeywords(
  AnimeSubject subject,
  AnimekoWebSelectorConfig config,
) {
  final seen = <String>{};
  return _searchKeywords(subject)
      .map(
        (item) => config.searchRemoveSpecial
            ? item.replaceAll(RegExp(r'[^\w\u4e00-\u9fffぁ-んァ-ン一-龥]+'), ' ')
            : item,
      )
      .map(
        (item) => config.searchUseOnlyFirstWord
            ? item.split(RegExp(r'\s+')).first
            : item,
      )
      .map((item) => item.trim())
      .where((item) {
        final normalized = _normalizeTitle(item);
        return normalized.isNotEmpty && seen.add(normalized);
      })
      .toList(growable: false);
}

String _animekoVideoReferer(AnimekoWebSelectorConfig config, String fallback) {
  final referer = config.videoReferer.trim();
  return referer.isEmpty ? fallback : referer;
}

_RankedResult<_SearchHit>? _rankBestHit(
  List<_SearchHit> hits,
  AnimeSubject subject,
  int preference,
) {
  if (hits.isEmpty) return null;
  var best = hits.first;
  var bestScore = -1;
  for (final hit in hits) {
    final score = _matchScore(hit.title, subject);
    if (score > bestScore) {
      best = hit;
      bestScore = score;
    }
  }
  return bestScore <= 0
      ? null
      : _RankedResult(value: best, score: bestScore, preference: preference);
}

int _matchScore(String title, AnimeSubject subject) {
  final candidate = _normalizeTitle(title);
  final targets = [
    _normalizeTitle(subject.title),
    _normalizeTitle(subject.originalTitle),
  ].where((item) => item.isNotEmpty);
  var score = 0;
  for (final target in targets) {
    if (candidate == target) {
      score = score < 100 ? 100 : score;
    } else if (candidate.contains(target) || target.contains(candidate)) {
      score = score < 80 ? 80 : score;
    } else {
      final overlap = target.runes
          .where((char) => candidate.runes.contains(char))
          .length;
      if (overlap >= 2 && score < 30) score = 30;
    }
  }
  return score;
}

String _normalizeTitle(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[\s·・:：!！?？,，.。_\-—]+'), '')
      .trim();
}

String _cleanText(String value) {
  final text = html_parser.parseFragment(value).text;
  return text
          ?.replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll('&nbsp;', ' ')
          .trim() ??
      '';
}

String _friendlyError(Object error) {
  final text = error.toString();
  if (text.contains('TimeoutException')) return '解析超时，当前规则源响应太慢。';
  if (text.contains('HTTP')) return '规则源请求失败：$text';
  if (text.contains('SocketException')) return '网络不可用或规则源无法访问。';
  return '解析失败：$text';
}

Map<String, String> _videoProbeHeaders(Map<String, String> headers) {
  return {...headers, 'Accept': '*/*', 'Range': 'bytes=0-2048'};
}

String _shortError(Object error) {
  final text = error.toString();
  if (text.contains('SocketException')) return '网络不可用或源站无法访问';
  if (text.contains('HandshakeException')) return '证书或 TLS 握手失败';
  if (text.contains('ClientException')) return '连接被中断';
  return text.length > 60 ? '${text.substring(0, 60)}...' : text;
}

String _formatForUrl(String url, String fallback) {
  final lower = url.toLowerCase();
  if (lower.contains('.m3u8') || lower.contains('type=m3u8')) return 'HLS';
  if (lower.contains('.mp4')) return 'MP4';
  if (lower.contains('.flv')) return 'FLV';
  return fallback;
}

String _sizeLabelForUrl(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('4k') || lower.contains('2160')) return '4K';
  if (lower.contains('1080')) return '1080P';
  if (lower.contains('720')) return '720P';
  return '--';
}
