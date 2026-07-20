import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../domain/anime_models.dart';
import 'rule_models.dart';

const _playableProbeTimeout = Duration(seconds: 6);
const _playlistMetadataTimeout = Duration(seconds: 3);
const _metadataEnrichmentBudget = Duration(seconds: 2);
const _probeChunkIdleTimeout = Duration(milliseconds: 300);
const _initialProbeRangeEnd = 2048;
const _maxBinaryProbeSampleBytes = 64 * 1024;
const _maxManifestProbeSampleBytes = 512 * 1024;
const _maxConcurrentPlayableProbes = 4;
const _maxConcurrentMetadataProbes = 4;
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
  final _playableProbeLimiter = _AsyncLimiter(_maxConcurrentPlayableProbes);
  final _metadataProbeLimiter = _AsyncLimiter(_maxConcurrentMetadataProbes);
  var _cacheGeneration = 0;

  void clearCaches() {
    _cacheGeneration++;
    _responseCache.clear();
    _responseRequests.clear();
    _probeCache.clear();
    _probeRequests.clear();
  }

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
        'tvbox-xml-api' => await _resolveTvBoxXmlApi(
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
              probe: probe,
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
              latency: probe.latency,
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
              probe: probe,
              referer: playPageUrl,
              headers: headers,
            )
          : _deadLine(
              rule,
              episode,
              url: playableUrl,
              title: title,
              latency: probe.latency,
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
              probe: probe,
              referer: playPageUrl,
              headers: headers,
            )
          : _deadLine(
              rule,
              episode,
              url: normalizedPlayableUrl,
              title: title,
              latency: probe.latency,
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
    return _resolveTvBoxApi(
      client,
      rule,
      subject,
      episode,
      started,
      apiLabel: 'JSON',
      decodeItems: (text) => _tvBoxItems(jsonDecode(text)),
      verifyPlayable: verifyPlayable,
    );
  }

  Future<List<PlaybackLine>> _resolveTvBoxXmlApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required bool verifyPlayable,
  }) async {
    return _resolveTvBoxApi(
      client,
      rule,
      subject,
      episode,
      started,
      apiLabel: 'XML',
      decodeItems: _tvBoxXmlItems,
      verifyPlayable: verifyPlayable,
    );
  }

  Future<List<PlaybackLine>> _resolveTvBoxApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode,
    Stopwatch started, {
    required String apiLabel,
    required List<Map<String, dynamic>> Function(String) decodeItems,
    required bool verifyPlayable,
  }) async {
    final endpoint = Uri.tryParse(rule.baseUrl.trim());
    if (endpoint == null || !endpoint.hasScheme || endpoint.host.isEmpty) {
      return [
        _unavailableLine(
          rule,
          subject,
          episode,
          '该 TVBox $apiLabel 源缺少有效接口地址。',
        ),
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
            decodeItems,
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
        for (final detailUri in _tvBoxDetailUris(endpoint, vodId)) {
          try {
            final details = decodeItems(
              await _get(
                client,
                detailUri,
                _headers(rule: rule, referer: endpoint.toString()),
              ),
            );
            if (details.isEmpty) continue;
            item = details.first;
            if (_tvBoxPlayUrl(item).isNotEmpty) {
              break;
            }
          } catch (_) {
            // 聚合接口的 detail/videolist 支持并不一致，逐个尝试。
          }
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
    List<Map<String, dynamic>> Function(String) decodeItems,
  ) async {
    try {
      final items = decodeItems(
        await _get(
          client,
          searchUri,
          _headers(rule: rule, referer: endpoint.toString()),
        ),
      );
      return _rankBestTvBoxItem(items, subject, preference);
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
            probe: probe,
            referer: endpoint.toString(),
            headers: headers,
          )
        : _deadLine(
            rule,
            episode,
            url: playableUrl,
            title: title,
            latency: probe.latency,
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

    final cacheGeneration = _cacheGeneration;
    final request = client
        .get(requestUri, headers: requestHeaders)
        .timeout(timeout)
        .then(_responseText);
    _responseRequests[key] = request;
    try {
      final result = await request;
      if (cacheGeneration == _cacheGeneration) {
        _storeCacheValue(
          _responseCache,
          key,
          result,
          _responseCacheTtl,
          _maxResponseCacheEntries,
        );
      }
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

    final cacheGeneration = _cacheGeneration;
    final request = client
        .post(requestUri, headers: requestHeaders, body: body)
        .timeout(timeout)
        .then(_responseText);
    _responseRequests[key] = request;
    try {
      final result = await request;
      if (cacheGeneration == _cacheGeneration) {
        _storeCacheValue(
          _responseCache,
          key,
          result,
          _responseCacheTtl,
          _maxResponseCacheEntries,
        );
      }
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
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  PlaybackLine _availableLine(
    RulePlugin rule,
    AnimeEpisode episode, {
    required String url,
    required String title,
    required _PlayableProbeResult probe,
    required String referer,
    String? quality,
    Map<String, String>? headers,
  }) {
    final normalizedUrl = _normalizePlayableUrl(url, referer);
    final detectedQuality = _probeResolutionLabel(
      probe.videoWidth,
      probe.videoHeight,
    );
    return PlaybackLine(
      id: 'rule:${rule.id}:${episode.id}:${normalizedUrl.hashCode}',
      episodeId: episode.id,
      providerId: rule.id,
      providerName: rule.name,
      title: title,
      quality:
          detectedQuality ??
          quality ??
          _resolutionLabelForUrl(normalizedUrl) ??
          (rule.tags.contains('4K') ? '4K/HD' : '分辨率未知'),
      format: probe.format ?? _formatForUrl(normalizedUrl, rule.engine),
      url: normalizedUrl,
      headers: headers ?? _headers(rule: rule, referer: referer),
      latency: probe.latency,
      sizeLabel: _probeSizeLabel(probe),
      sizeBytes: probe.sizeBytes,
      sizeEstimated: probe.sizeEstimated,
      videoWidth: probe.videoWidth,
      videoHeight: probe.videoHeight,
      bitrate: probe.bitrate,
      codecs: probe.codecs,
      isLive: probe.isLive,
      adaptive: probe.adaptive,
      available: true,
      message: '已解析到当前集的播放地址。',
    );
  }

  PlaybackLine _deadLine(
    RulePlugin rule,
    AnimeEpisode episode, {
    required String url,
    required String title,
    required Duration? latency,
    required String message,
    required Map<String, String> headers,
  }) {
    final normalizedUrl = _normalizePlayableUrl(url, headers['Referer'] ?? '');
    return PlaybackLine(
      // Keep the same logical id as the optimistic quick result so a failed
      // verified probe replaces it instead of leaving a stale playable row.
      id: 'rule:${rule.id}:${episode.id}:${normalizedUrl.hashCode}',
      episodeId: episode.id,
      providerId: rule.id,
      providerName: rule.name,
      title: title,
      quality: rule.tags.contains('4K') ? '4K/HD' : 'HD',
      format: _formatForUrl(normalizedUrl, rule.engine),
      url: normalizedUrl,
      headers: headers,
      latency: latency,
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
    final sourceHeaders = _videoProbeHeaders(headers);
    final requestHeaders = _ruleRequestHeaders(target, sourceHeaders);
    final key = _requestCacheKey('PROBE', requestUri, requestHeaders);
    final cached = _freshCacheValue(_probeCache, key);
    if (cached != null) return cached;

    final existing = _probeRequests[key];
    if (existing != null) return existing;

    final cacheGeneration = _cacheGeneration;
    final request = _playableProbeLimiter.run(
      () => _performPlayableProbe(
        client,
        sourceUri: target,
        requestUri: requestUri,
        headers: requestHeaders,
        sourceHeaders: sourceHeaders,
      ),
    );
    _probeRequests[key] = request;
    try {
      final result = await request;
      if (cacheGeneration == _cacheGeneration) {
        _storeCacheValue(
          _probeCache,
          key,
          result,
          result.available ? _availableProbeCacheTtl : _failedProbeCacheTtl,
          _maxProbeCacheEntries,
        );
      }
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
    http.Client client, {
    required Uri sourceUri,
    required Uri requestUri,
    required Map<String, String> headers,
    required Map<String, String> sourceHeaders,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final sample = await _sendPlayableProbe(
        client,
        requestUri,
        headers,
        timeout: _playableProbeTimeout,
      );
      stopwatch.stop();
      final response = sample.response;
      final measuredLatency = sample.latency ?? stopwatch.elapsed;
      if (response.statusCode >= 200 && response.statusCode < 400) {
        _ProbeMediaMetadata metadata;
        try {
          metadata = await _probeMediaMetadata(
            client,
            sourceUri: sourceUri,
            sourceHeaders: sourceHeaders,
            sample: sample,
          );
        } catch (_) {
          // Metadata is optional. Once the CDN has returned a successful
          // response, a malformed manifest/container must not kill the line.
          metadata = const _ProbeMediaMetadata();
        }
        return _PlayableProbeResult(
          true,
          '',
          latency: measuredLatency,
          format: metadata.format,
          sizeBytes: metadata.sizeBytes,
          sizeEstimated: metadata.sizeEstimated,
          videoWidth: metadata.videoWidth,
          videoHeight: metadata.videoHeight,
          bitrate: metadata.bitrate,
          codecs: metadata.codecs,
          isLive: metadata.isLive,
          adaptive: metadata.adaptive,
        );
      }
      if (response.statusCode == 403) {
        return _PlayableProbeResult(
          false,
          '视频 CDN 拒绝访问，可能有防盗链或地区限制。',
          latency: measuredLatency,
        );
      }
      if (response.statusCode == 404) {
        return _PlayableProbeResult(
          false,
          '视频 CDN 返回 404，这条播放地址已经失效。',
          latency: measuredLatency,
        );
      }
      return _PlayableProbeResult(
        false,
        '视频 CDN 返回 HTTP ${response.statusCode}。',
        latency: measuredLatency,
      );
    } on TimeoutException {
      stopwatch.stop();
      return _PlayableProbeResult(
        false,
        '视频 CDN 连接超时。',
        latency: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      return _PlayableProbeResult(
        false,
        '视频 CDN 无法访问：${_shortError(error)}',
        latency: stopwatch.elapsed,
      );
    }
  }

  Future<_ProbeMediaMetadata> _probeMediaMetadata(
    http.Client client, {
    required Uri sourceUri,
    required Map<String, String> sourceHeaders,
    required _PlayableProbeResponse sample,
  }) async {
    var metadata = _mediaMetadataFromSample(sourceUri, sample);
    final needsExpandedManifest =
        !sample.sampleComplete &&
        (metadata.format == 'HLS' || metadata.format == 'DASH');
    final needsExtraRequest =
        needsExpandedManifest ||
        (metadata.format == 'HLS' &&
            (metadata.variantUri != null ||
                (!metadata.isLive && metadata.sampleSegmentUri != null)));
    if (!needsExtraRequest) return metadata;
    final enriched = await _metadataProbeLimiter.runIfAvailable(() async {
      final enrichmentStopwatch = Stopwatch()..start();
      Duration requestTimeout() {
        final remaining =
            _metadataEnrichmentBudget - enrichmentStopwatch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Media metadata enrichment timed out.');
        }
        return remaining < _playlistMetadataTimeout
            ? remaining
            : _playlistMetadataTimeout;
      }

      var enriched = metadata;
      try {
        if (needsExpandedManifest) {
          final expandedSample = await _sendPlayableProbe(
            client,
            _ruleRequestUri(sourceUri),
            _ruleRequestHeaders(
              sourceUri,
              _manifestProbeHeaders(sourceHeaders),
            ),
            timeout: requestTimeout(),
          );
          if (expandedSample.response.statusCode >= 200 &&
              expandedSample.response.statusCode < 400) {
            enriched = _mediaMetadataFromSample(sourceUri, expandedSample);
          }
        }
        if (enriched.format != 'HLS') return enriched;

        final variantUri = enriched.variantUri;
        if (variantUri != null) {
          final childHeaders = _mediaChildHeaders(
            sourceUri,
            variantUri,
            sourceHeaders,
          );
          final variantSample = await _sendPlayableProbe(
            client,
            _ruleRequestUri(variantUri),
            _ruleRequestHeaders(
              variantUri,
              _manifestProbeHeaders(childHeaders),
            ),
            timeout: requestTimeout(),
          );
          if (variantSample.response.statusCode >= 200 &&
              variantSample.response.statusCode < 400) {
            final media = _mediaMetadataFromSample(variantUri, variantSample);
            var sizeBytes = media.sizeBytes;
            var sizeEstimated = media.sizeEstimated;
            final durationSeconds = media.durationSeconds;
            if (sizeBytes == null &&
                !media.isLive &&
                durationSeconds != null &&
                durationSeconds > 0 &&
                enriched.bitrate != null &&
                enriched.bitrate! > 0) {
              sizeBytes = (enriched.bitrate! * durationSeconds / 8).round();
              sizeEstimated = true;
            }
            enriched = enriched.copyWith(
              sizeBytes: sizeBytes,
              sizeEstimated: sizeEstimated,
              isLive: media.isLive,
              durationSeconds: durationSeconds,
              sampleSegmentUri: media.sampleSegmentUri,
              sampleSegmentDurationSeconds: media.sampleSegmentDurationSeconds,
            );
          }
        }
        if (enriched.sizeBytes == null && !enriched.isLive) {
          enriched = await _estimateHlsSizeFromSegment(
            client,
            metadata: enriched,
            credentialSourceUri: sourceUri,
            sourceHeaders: sourceHeaders,
            timeout: requestTimeout(),
          );
        }
      } catch (_) {
        // 规格补全失败不影响线路可播放性，保留首个清单已经确认的信息。
      }
      return enriched;
    });
    return enriched ?? metadata;
  }

  Future<_ProbeMediaMetadata> _estimateHlsSizeFromSegment(
    http.Client client, {
    required _ProbeMediaMetadata metadata,
    required Uri credentialSourceUri,
    required Map<String, String> sourceHeaders,
    required Duration timeout,
  }) async {
    final segmentUri = metadata.sampleSegmentUri;
    final segmentDuration = metadata.sampleSegmentDurationSeconds;
    final totalDuration = metadata.durationSeconds;
    if (segmentUri == null ||
        segmentDuration == null ||
        segmentDuration <= 0 ||
        totalDuration == null ||
        totalDuration <= 0) {
      return metadata;
    }
    final segmentSample = await _sendPlayableProbe(
      client,
      _ruleRequestUri(segmentUri),
      _ruleRequestHeaders(
        segmentUri,
        _mediaChildHeaders(credentialSourceUri, segmentUri, sourceHeaders),
      ),
      timeout: timeout,
    );
    if (segmentSample.response.statusCode < 200 ||
        segmentSample.response.statusCode >= 400) {
      return metadata;
    }
    final segmentBytes = _responseTotalBytes(segmentSample.response);
    if (segmentBytes == null || segmentBytes <= 0) return metadata;
    final estimatedBytes = (segmentBytes * totalDuration / segmentDuration)
        .round();
    return metadata.copyWith(sizeBytes: estimatedBytes, sizeEstimated: true);
  }

  Future<_PlayableProbeResponse> _sendPlayableProbe(
    http.Client client,
    Uri requestUri,
    Map<String, String> headers, {
    required Duration timeout,
  }) {
    final abortTrigger = Completer<void>();
    final operation = () async {
      final stopwatch = Stopwatch()..start();
      final request = http.AbortableRequest(
        'GET',
        requestUri,
        abortTrigger: abortTrigger.future,
      )..headers.addAll(headers);
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        stopwatch.stop();
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        return _PlayableProbeResponse(response, latency: stopwatch.elapsed);
      }
      final stream = StreamIterator<List<int>>(response.stream);
      final sample = <int>[];
      Duration? firstByteLatency;
      final manifestResponse = _isManifestResponse(requestUri, response);
      final sampleLimit = manifestResponse
          ? _maxManifestProbeSampleBytes
          : _maxBinaryProbeSampleBytes;
      final contentLength = int.tryParse(
        response.headers['content-length'] ?? '',
      );
      final targetBytes = contentLength == null || contentLength <= 0
          ? null
          : contentLength.clamp(1, sampleLimit);
      final readChunkedManifest = targetBytes == null && manifestResponse;
      var sampleComplete = false;
      try {
        // 清单读取到 EOF/上限；未知长度的二进制只读首块，避免 Range 被忽略后持续下载。
        var firstChunk = true;
        while (sample.length < sampleLimit) {
          var idleTimedOut = false;
          final hasNext = firstChunk || !readChunkedManifest
              ? await stream.moveNext()
              : await stream.moveNext().timeout(
                  _probeChunkIdleTimeout,
                  onTimeout: () {
                    idleTimedOut = true;
                    return false;
                  },
                );
          if (!hasNext) {
            final totalBytes = _responseTotalBytes(response);
            sampleComplete =
                !idleTimedOut &&
                (totalBytes == null || totalBytes <= sample.length);
            break;
          }
          firstByteLatency ??= stopwatch.elapsed;
          final chunk = stream.current;
          final remaining = sampleLimit - sample.length;
          sample.addAll(
            chunk.length <= remaining ? chunk : chunk.take(remaining),
          );
          firstChunk = false;
          if (targetBytes != null && sample.length >= targetBytes) {
            final totalBytes = _responseTotalBytes(response);
            sampleComplete = totalBytes != null && totalBytes <= sample.length;
            break;
          }
          if (targetBytes == null && !readChunkedManifest) break;
        }
      } finally {
        stopwatch.stop();
        await stream.cancel();
      }
      return _PlayableProbeResponse(
        response,
        sample: List<int>.unmodifiable(sample),
        latency: firstByteLatency ?? stopwatch.elapsed,
        sampleComplete: sampleComplete,
      );
    }();
    return operation.timeout(
      timeout,
      onTimeout: () {
        if (!abortTrigger.isCompleted) abortTrigger.complete();
        throw TimeoutException('Media probe timed out after $timeout.');
      },
    );
  }
}

class _PlayableProbeResponse {
  const _PlayableProbeResponse(
    this.response, {
    this.sample = const [],
    this.latency,
    this.sampleComplete = false,
  });

  final http.StreamedResponse response;
  final List<int> sample;
  final Duration? latency;
  final bool sampleComplete;
}

class _ProbeMediaMetadata {
  const _ProbeMediaMetadata({
    this.format,
    this.sizeBytes,
    this.sizeEstimated = false,
    this.videoWidth,
    this.videoHeight,
    this.bitrate,
    this.codecs,
    this.isLive = false,
    this.adaptive = false,
    this.variantUri,
    this.durationSeconds,
    this.sampleSegmentUri,
    this.sampleSegmentDurationSeconds,
  });

  final String? format;
  final int? sizeBytes;
  final bool sizeEstimated;
  final int? videoWidth;
  final int? videoHeight;
  final int? bitrate;
  final String? codecs;
  final bool isLive;
  final bool adaptive;
  final Uri? variantUri;
  final double? durationSeconds;
  final Uri? sampleSegmentUri;
  final double? sampleSegmentDurationSeconds;

  _ProbeMediaMetadata copyWith({
    int? sizeBytes,
    bool? sizeEstimated,
    bool? isLive,
    double? durationSeconds,
    Uri? sampleSegmentUri,
    double? sampleSegmentDurationSeconds,
  }) {
    return _ProbeMediaMetadata(
      format: format,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sizeEstimated: sizeEstimated ?? this.sizeEstimated,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      bitrate: bitrate,
      codecs: codecs,
      isLive: isLive ?? this.isLive,
      adaptive: adaptive,
      variantUri: variantUri,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      sampleSegmentUri: sampleSegmentUri ?? this.sampleSegmentUri,
      sampleSegmentDurationSeconds:
          sampleSegmentDurationSeconds ?? this.sampleSegmentDurationSeconds,
    );
  }
}

_ProbeMediaMetadata _mediaMetadataFromSample(
  Uri sourceUri,
  _PlayableProbeResponse sample,
) {
  final text = utf8.decode(sample.sample, allowMalformed: true);
  final format = _detectedMediaFormat(
    sourceUri,
    sample.response.headers['content-type'],
    text,
  );
  if (format == 'HLS') {
    return _hlsProbeMetadata(
      sourceUri,
      text,
      sampleComplete: sample.sampleComplete,
    );
  }
  if (format == 'DASH') return _dashProbeMetadata(sourceUri, text);

  final dimensions = format == 'MP4'
      ? _mp4Dimensions(sample.sample) ?? _resolutionDimensionsForUrl(sourceUri)
      : _resolutionDimensionsForUrl(sourceUri);
  return _ProbeMediaMetadata(
    format: format,
    sizeBytes: _responseTotalBytes(sample.response),
    videoWidth: dimensions?.width,
    videoHeight: dimensions?.height,
  );
}

final RegExp _hlsExtensionPattern = RegExp(r'\.m3u8(?:$|[?#])');
final RegExp _dashExtensionPattern = RegExp(r'\.mpd(?:$|[?#])');
final RegExp _mp4ExtensionPattern = RegExp(r'\.(?:mp4|m4v)(?:$|[?#])');
final RegExp _webmExtensionPattern = RegExp(r'\.webm(?:$|[?#])');
final RegExp _flvExtensionPattern = RegExp(r'\.flv(?:$|[?#])');
final RegExp _mkvExtensionPattern = RegExp(r'\.mkv(?:$|[?#])');
final RegExp _manifestExtensionPattern = RegExp(r'\.(?:m3u8|mpd)(?:$|[?#])');

String? _detectedMediaFormat(
  Uri sourceUri,
  String? rawContentType,
  String sampleText,
) {
  final contentType = (rawContentType ?? '').toLowerCase();
  final lowerUrl = sourceUri.toString().toLowerCase();
  final trimmed = sampleText.trimLeft();
  if (trimmed.startsWith('#EXTM3U') ||
      contentType.contains('mpegurl') ||
      _hlsExtensionPattern.hasMatch(lowerUrl)) {
    return 'HLS';
  }
  if (trimmed.startsWith('<MPD') ||
      trimmed.contains('<MPD ') ||
      contentType.contains('dash+xml') ||
      _dashExtensionPattern.hasMatch(lowerUrl)) {
    return 'DASH';
  }
  if (contentType.contains('video/mp4') ||
      _mp4ExtensionPattern.hasMatch(lowerUrl)) {
    return 'MP4';
  }
  if (contentType.contains('webm') ||
      _webmExtensionPattern.hasMatch(lowerUrl)) {
    return 'WebM';
  }
  if (contentType.contains('x-flv') ||
      _flvExtensionPattern.hasMatch(lowerUrl)) {
    return 'FLV';
  }
  if (contentType.contains('matroska') ||
      _mkvExtensionPattern.hasMatch(lowerUrl)) {
    return 'MKV';
  }
  return null;
}

bool _isManifestResponse(Uri requestUri, http.StreamedResponse response) {
  final contentType = response.headers['content-type']?.toLowerCase() ?? '';
  if (contentType.contains('mpegurl') || contentType.contains('dash+xml')) {
    return true;
  }
  final target = _proxyUpstreamUri(requestUri) ?? requestUri;
  final lower = target.toString().toLowerCase();
  return _manifestExtensionPattern.hasMatch(lower);
}

Uri _resolvePlaylistReference(Uri playlistUri, String rawReference) {
  final reference = Uri.tryParse(rawReference.trim());
  if (reference == null) return playlistUri.resolve(rawReference);
  final upstream = _proxyUpstreamUri(reference);
  if (upstream != null) {
    if (kIsWeb) {
      return reference.hasScheme ? reference : Uri.base.resolveUri(reference);
    }
    return upstream;
  }
  return playlistUri.resolveUri(reference);
}

Uri? _proxyUpstreamUri(Uri uri) {
  if (uri.path != '/media-proxy') return null;
  final rawTarget = uri.queryParameters['url'];
  final target = rawTarget == null ? null : Uri.tryParse(rawTarget);
  if (target == null ||
      !const {'http', 'https'}.contains(target.scheme.toLowerCase()) ||
      target.host.isEmpty) {
    return null;
  }
  return target;
}

int? _responseTotalBytes(http.StreamedResponse response) {
  final contentRange = response.headers['content-range'] ?? '';
  final rangeMatch = RegExp(r'/\s*(\d+)\s*$').firstMatch(contentRange);
  final rangeTotal = int.tryParse(rangeMatch?.group(1) ?? '');
  if (rangeTotal != null && rangeTotal > 0) return rangeTotal;
  if (response.statusCode != 200) return null;
  final contentLength = int.tryParse(response.headers['content-length'] ?? '');
  return contentLength != null && contentLength > 0 ? contentLength : null;
}

_ProbeMediaMetadata _hlsProbeMetadata(
  Uri sourceUri,
  String manifest, {
  required bool sampleComplete,
}) {
  final lines = manifest
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.trim())
      .toList(growable: false);
  final variants = <_HlsProbeVariant>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    final attributes = _parseHlsAttributes(
      line.substring(line.indexOf(':') + 1),
    );
    String? uriText;
    for (var uriIndex = index + 1; uriIndex < lines.length; uriIndex++) {
      final candidate = lines[uriIndex];
      if (candidate.isEmpty || candidate.startsWith('#')) continue;
      uriText = candidate;
      break;
    }
    if (uriText == null) continue;
    final dimensions = _resolutionDimensions(attributes['RESOLUTION'] ?? '');
    variants.add(
      _HlsProbeVariant(
        uri: _resolvePlaylistReference(sourceUri, uriText),
        width: dimensions?.width,
        height: dimensions?.height,
        bitrate:
            int.tryParse(attributes['AVERAGE-BANDWIDTH'] ?? '') ??
            int.tryParse(attributes['BANDWIDTH'] ?? ''),
        codecs: attributes['CODECS'],
      ),
    );
  }
  if (variants.isNotEmpty) {
    variants.sort((left, right) {
      final pixels = right.pixelCount.compareTo(left.pixelCount);
      if (pixels != 0) return pixels;
      return (right.bitrate ?? 0).compareTo(left.bitrate ?? 0);
    });
    final selected = variants.first;
    return _ProbeMediaMetadata(
      format: 'HLS',
      videoWidth: selected.width,
      videoHeight: selected.height,
      bitrate: selected.bitrate,
      codecs: selected.codecs,
      adaptive: true,
      variantUri: selected.uri,
    );
  }

  final hasEndList = lines.contains('#EXT-X-ENDLIST');
  final durationSeconds = lines
      .where((line) => line.startsWith('#EXTINF:'))
      .map((line) => line.substring('#EXTINF:'.length).split(',').first)
      .map(double.tryParse)
      .whereType<double>()
      .fold<double>(0, (total, duration) => total + duration);
  var byteRangeBytes = 0;
  var mediaSegmentCount = 0;
  var rangedMediaSegmentCount = 0;
  Uri? sampleSegmentUri;
  double? sampleSegmentDurationSeconds;
  double? pendingDuration;
  int? pendingByteRangeBytes;
  for (final line in lines) {
    if (line.startsWith('#EXTINF:')) {
      pendingDuration = double.tryParse(
        line.substring('#EXTINF:'.length).split(',').first,
      );
      continue;
    }
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      pendingByteRangeBytes = int.tryParse(
        line.substring('#EXT-X-BYTERANGE:'.length).split('@').first.trim(),
      );
      continue;
    }
    if (line.isEmpty || line.startsWith('#') || pendingDuration == null) {
      continue;
    }
    mediaSegmentCount++;
    if (pendingByteRangeBytes != null && pendingByteRangeBytes > 0) {
      rangedMediaSegmentCount++;
      byteRangeBytes += pendingByteRangeBytes;
    }
    sampleSegmentUri ??= _resolvePlaylistReference(sourceUri, line);
    sampleSegmentDurationSeconds ??= pendingDuration;
    pendingDuration = null;
    pendingByteRangeBytes = null;
  }
  final hasExactByteRangeTotal =
      mediaSegmentCount > 0 &&
      rangedMediaSegmentCount == mediaSegmentCount &&
      byteRangeBytes > 0;
  final dimensions = _resolutionDimensionsForUrl(sourceUri);
  return _ProbeMediaMetadata(
    format: 'HLS',
    sizeBytes: hasEndList && hasExactByteRangeTotal ? byteRangeBytes : null,
    videoWidth: dimensions?.width,
    videoHeight: dimensions?.height,
    isLive: sampleComplete && !hasEndList,
    durationSeconds: hasEndList && durationSeconds > 0 ? durationSeconds : null,
    sampleSegmentUri: hasEndList ? sampleSegmentUri : null,
    sampleSegmentDurationSeconds: hasEndList
        ? sampleSegmentDurationSeconds
        : null,
  );
}

_ProbeMediaMetadata _dashProbeMetadata(Uri sourceUri, String manifest) {
  try {
    final document = XmlDocument.parse(manifest);
    final elements = document.descendants.whereType<XmlElement>().toList();
    final mpd = _firstOrNull(
      elements.where((item) => item.name.local == 'MPD'),
    );
    final isDynamic = mpd?.getAttribute('type')?.toLowerCase() == 'dynamic';
    final durationSeconds = _parseIsoDurationSeconds(
      mpd?.getAttribute('mediaPresentationDuration') ??
          _firstOrNull(
            elements
                .where((item) => item.name.local == 'Period')
                .map((item) => item.getAttribute('duration'))
                .whereType<String>(),
          ),
    );
    final allRepresentations = elements
        .where((item) => item.name.local == 'Representation')
        .toList();
    final audioRepresentations = allRepresentations.where((item) {
      final mimeType = _xmlInheritedAttribute(item, 'mimeType') ?? '';
      final contentType = _xmlInheritedAttribute(item, 'contentType') ?? '';
      return mimeType.toLowerCase().startsWith('audio/') ||
          contentType.toLowerCase() == 'audio';
    }).toList();
    var representations = allRepresentations.where((item) {
      final mimeType = _xmlInheritedAttribute(item, 'mimeType') ?? '';
      final contentType = _xmlInheritedAttribute(item, 'contentType') ?? '';
      return mimeType.toLowerCase().startsWith('video/') ||
          contentType.toLowerCase() == 'video' ||
          _xmlInheritedInt(item, 'width') != null ||
          _xmlInheritedInt(item, 'height') != null;
    }).toList();
    if (representations.isEmpty) {
      representations = allRepresentations
          .where((item) => !audioRepresentations.contains(item))
          .toList();
    }
    if (representations.isEmpty) representations = [...allRepresentations];
    representations.sort((left, right) {
      final leftWidth = _xmlInheritedInt(left, 'width') ?? 0;
      final leftHeight = _xmlInheritedInt(left, 'height') ?? 0;
      final rightWidth = _xmlInheritedInt(right, 'width') ?? 0;
      final rightHeight = _xmlInheritedInt(right, 'height') ?? 0;
      final pixels = (rightWidth * rightHeight).compareTo(
        leftWidth * leftHeight,
      );
      if (pixels != 0) return pixels;
      return (_xmlInheritedInt(right, 'bandwidth') ?? 0).compareTo(
        _xmlInheritedInt(left, 'bandwidth') ?? 0,
      );
    });
    final selected = _firstOrNull(representations);
    audioRepresentations.sort(
      (left, right) => (_xmlInheritedInt(right, 'bandwidth') ?? 0).compareTo(
        _xmlInheritedInt(left, 'bandwidth') ?? 0,
      ),
    );
    final selectedAudio = _firstOrNull(audioRepresentations);
    final width = selected == null ? null : _xmlInheritedInt(selected, 'width');
    final height = selected == null
        ? null
        : _xmlInheritedInt(selected, 'height');
    final videoBitrate = selected == null
        ? null
        : _xmlInheritedInt(selected, 'bandwidth');
    final audioBitrate = selectedAudio == null
        ? null
        : _xmlInheritedInt(selectedAudio, 'bandwidth');
    final bitrate = videoBitrate == null && audioBitrate == null
        ? null
        : (videoBitrate ?? 0) + (audioBitrate ?? 0);
    final videoCodecs = selected == null
        ? null
        : _xmlInheritedAttribute(selected, 'codecs');
    final audioCodecs = selectedAudio == null
        ? null
        : _xmlInheritedAttribute(selectedAudio, 'codecs');
    final codecs = [
      videoCodecs,
      audioCodecs,
    ].whereType<String>().where((item) => item.trim().isNotEmpty).join(',');
    final estimatedBytes =
        !isDynamic &&
            durationSeconds != null &&
            durationSeconds > 0 &&
            bitrate != null &&
            bitrate > 0
        ? (bitrate * durationSeconds / 8).round()
        : null;
    final fallbackDimensions = _resolutionDimensionsForUrl(sourceUri);
    return _ProbeMediaMetadata(
      format: 'DASH',
      sizeBytes: estimatedBytes,
      sizeEstimated: estimatedBytes != null,
      videoWidth: width ?? fallbackDimensions?.width,
      videoHeight: height ?? fallbackDimensions?.height,
      bitrate: bitrate,
      codecs: codecs.isEmpty ? null : codecs,
      isLive: isDynamic,
      adaptive: representations.length > 1,
      durationSeconds: durationSeconds,
    );
  } catch (_) {
    final dimensions = _resolutionDimensionsForUrl(sourceUri);
    return _ProbeMediaMetadata(
      format: 'DASH',
      videoWidth: dimensions?.width,
      videoHeight: dimensions?.height,
    );
  }
}

Map<String, String> _parseHlsAttributes(String value) {
  final result = <String, String>{};
  var index = 0;
  while (index < value.length) {
    while (index < value.length &&
        (value.codeUnitAt(index) == 44 || value.codeUnitAt(index) == 32)) {
      index++;
    }
    final equals = value.indexOf('=', index);
    if (equals < 0) break;
    final key = value.substring(index, equals).trim().toUpperCase();
    index = equals + 1;
    String parsed;
    if (index < value.length && value.codeUnitAt(index) == 34) {
      index++;
      final end = value.indexOf('"', index);
      if (end < 0) {
        parsed = value.substring(index);
        index = value.length;
      } else {
        parsed = value.substring(index, end);
        index = end + 1;
      }
    } else {
      final comma = value.indexOf(',', index);
      if (comma < 0) {
        parsed = value.substring(index).trim();
        index = value.length;
      } else {
        parsed = value.substring(index, comma).trim();
        index = comma + 1;
      }
    }
    if (key.isNotEmpty) result[key] = parsed;
  }
  return result;
}

class _HlsProbeVariant {
  const _HlsProbeVariant({
    required this.uri,
    this.width,
    this.height,
    this.bitrate,
    this.codecs,
  });

  final Uri uri;
  final int? width;
  final int? height;
  final int? bitrate;
  final String? codecs;

  int get pixelCount => (width ?? 0) * (height ?? 0);
}

class _ResolutionDimensions {
  const _ResolutionDimensions({this.width, this.height});

  final int? width;
  final int? height;
}

_ResolutionDimensions? _resolutionDimensions(String value) {
  final match = RegExp(
    r'(\d{2,5})\s*x\s*(\d{2,5})',
    caseSensitive: false,
  ).firstMatch(value);
  final width = int.tryParse(match?.group(1) ?? '');
  final height = int.tryParse(match?.group(2) ?? '');
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return _ResolutionDimensions(width: width, height: height);
}

_ResolutionDimensions? _resolutionDimensionsForUrl(Uri uri) {
  final text = Uri.decodeFull(uri.toString());
  final exact = _resolutionDimensions(text);
  if (exact != null) return exact;
  final lower = text.toLowerCase();
  if (RegExp(r'(^|[^a-z0-9])4k([^a-z0-9]|$)').hasMatch(lower) ||
      RegExp(r'(^|[^0-9])2160p?([^0-9]|$)').hasMatch(lower)) {
    return const _ResolutionDimensions(width: 3840, height: 2160);
  }
  for (final height in const [1440, 1080, 720, 576, 480, 360, 240]) {
    if (RegExp('(^|[^0-9])${height}p?([^0-9]|\$)').hasMatch(lower)) {
      return _ResolutionDimensions(height: height);
    }
  }
  return null;
}

_ResolutionDimensions? _mp4Dimensions(List<int> bytes) {
  if (bytes.length < 92) return null;
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  _ResolutionDimensions? best;
  for (var typeOffset = 4; typeOffset + 4 <= bytes.length; typeOffset++) {
    if (bytes[typeOffset] != 0x74 ||
        bytes[typeOffset + 1] != 0x6B ||
        bytes[typeOffset + 2] != 0x68 ||
        bytes[typeOffset + 3] != 0x64) {
      continue;
    }
    final dataOffset = typeOffset + 4;
    if (dataOffset >= bytes.length) continue;
    final version = bytes[dataOffset];
    final widthOffset = dataOffset + (version == 1 ? 88 : 76);
    final heightOffset = widthOffset + 4;
    if (heightOffset + 4 > bytes.length) continue;
    final width = data.getUint32(widthOffset, Endian.big) >> 16;
    final height = data.getUint32(heightOffset, Endian.big) >> 16;
    if (width < 16 || width > 16384 || height < 16 || height > 16384) {
      continue;
    }
    final candidate = _ResolutionDimensions(width: width, height: height);
    if (best == null ||
        width * height > (best.width ?? 0) * (best.height ?? 0)) {
      best = candidate;
    }
  }
  return best;
}

String? _xmlInheritedAttribute(XmlElement element, String name) {
  XmlNode? current = element;
  while (current is XmlElement) {
    final value = current.getAttribute(name)?.trim();
    if (value != null && value.isNotEmpty) return value;
    current = current.parent;
  }
  return null;
}

T? _firstOrNull<T>(Iterable<T> values) {
  for (final value in values) {
    return value;
  }
  return null;
}

int? _xmlInheritedInt(XmlElement element, String name) {
  return int.tryParse(_xmlInheritedAttribute(element, name) ?? '');
}

double? _parseIsoDurationSeconds(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final match = RegExp(
    r'^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
  ).firstMatch(value.trim().toUpperCase());
  if (match == null) return null;
  final days = double.tryParse(match.group(1) ?? '') ?? 0;
  final hours = double.tryParse(match.group(2) ?? '') ?? 0;
  final minutes = double.tryParse(match.group(3) ?? '') ?? 0;
  final seconds = double.tryParse(match.group(4) ?? '') ?? 0;
  return days * 86400 + hours * 3600 + minutes * 60 + seconds;
}

class _AsyncLimiter {
  _AsyncLimiter(this.limit) : assert(limit > 0);

  final int limit;
  var _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<T> run<T>(Future<T> Function() action) async {
    if (_active >= limit) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<T?> runIfAvailable<T>(Future<T> Function() action) async {
    // Metadata is optional. Skipping enrichment when all slots are busy keeps
    // a confirmed playable line inside the repository's lookup budget.
    if (_active >= limit) return null;
    _active++;
    try {
      return await action();
    } finally {
      _release();
    }
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // Transfer the active slot directly to the oldest waiter so a newly
      // arriving task cannot overtake it or briefly exceed the limit.
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
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
  return _ruleRequestUriForPlatform(target, isWeb: kIsWeb, baseUri: Uri.base);
}

Uri _ruleRequestUriForPlatform(
  Uri target, {
  required bool isWeb,
  required Uri baseUri,
}) {
  if (!isWeb) return target;
  if (!const {'http', 'https'}.contains(baseUri.scheme.toLowerCase())) {
    return target;
  }
  final host = target.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return target;
  }
  return baseUri.resolve(
    '/media-proxy?url=${Uri.encodeQueryComponent(target.toString())}',
  );
}

Map<String, String> _ruleRequestHeaders(
  Uri target,
  Map<String, String> headers,
) {
  return _ruleRequestHeadersForPlatform(
    target,
    headers,
    isWeb: kIsWeb,
    baseUri: Uri.base,
  );
}

Map<String, String> _ruleRequestHeadersForPlatform(
  Uri target,
  Map<String, String> headers, {
  required bool isWeb,
  required Uri baseUri,
}) {
  if (!isWeb) return headers;
  final requestUri = _ruleRequestUriForPlatform(
    target,
    isWeb: true,
    baseUri: baseUri,
  );
  final usesMediaProxy =
      requestUri.path == '/media-proxy' && requestUri.origin == baseUri.origin;
  if (!usesMediaProxy) return headers;
  const upstreamNames = <String, String>{
    'user-agent': 'X-Upstream-User-Agent',
    'referer': 'X-Upstream-Referer',
    'authorization': 'X-Upstream-Authorization',
    'cookie': 'X-Upstream-Cookie',
    'x-appid': 'X-Upstream-X-AppId',
    'x-timestamp': 'X-Upstream-X-Timestamp',
    'x-signature': 'X-Upstream-X-Signature',
  };
  final result = <String, String>{};
  for (final entry in headers.entries) {
    final upstreamName = upstreamNames[entry.key.toLowerCase()];
    if (upstreamName != null && entry.value.trim().isNotEmpty) {
      result[upstreamName] = entry.value;
    } else {
      result[entry.key] = entry.value;
    }
  }
  return result;
}

@visibleForTesting
Uri ruleRequestUriForWebTest(Uri target, Uri baseUri) =>
    _ruleRequestUriForPlatform(target, isWeb: true, baseUri: baseUri);

@visibleForTesting
Map<String, String> ruleRequestHeadersForWebTest(
  Uri target,
  Map<String, String> headers,
  Uri baseUri,
) => _ruleRequestHeadersForPlatform(
  target,
  headers,
  isWeb: true,
  baseUri: baseUri,
);

class _PlayableProbeResult {
  const _PlayableProbeResult(
    this.available,
    this.message, {
    this.latency,
    this.format,
    this.sizeBytes,
    this.sizeEstimated = false,
    this.videoWidth,
    this.videoHeight,
    this.bitrate,
    this.codecs,
    this.isLive = false,
    this.adaptive = false,
  });

  final bool available;
  final String message;
  final Duration? latency;
  final String? format;
  final int? sizeBytes;
  final bool sizeEstimated;
  final int? videoWidth;
  final int? videoHeight;
  final int? bitrate;
  final String? codecs;
  final bool isLive;
  final bool adaptive;
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

List<Uri> _tvBoxDetailUris(Uri endpoint, String vodId) {
  final result = <String, Uri>{};
  for (final action in const ['detail', 'videolist']) {
    final query = <String, String>{...endpoint.queryParameters}
      ..remove('wd')
      ..['ac'] = action
      ..['ids'] = vodId;
    final uri = endpoint.replace(queryParameters: query);
    result[uri.toString()] = uri;
  }
  return result.values.toList(growable: false);
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

List<Map<String, dynamic>> _tvBoxXmlItems(String source) {
  final document = XmlDocument.parse(source);
  final videos = document.descendants.whereType<XmlElement>().where(
    (element) => element.name.local.toLowerCase() == 'video',
  );
  return videos
      .map((video) {
        final playSources = <String>[];
        final playGroups = <String>[];
        final downloads = video.descendants.whereType<XmlElement>().where(
          (element) => element.name.local.toLowerCase() == 'dd',
        );
        for (final download in downloads) {
          final playText = download.innerText.trim();
          if (playText.isEmpty) continue;
          playGroups.add(playText);
          final flag = download.getAttribute('flag')?.trim() ?? '';
          playSources.add(flag.isEmpty ? '线路${playSources.length + 1}' : flag);
        }
        return <String, dynamic>{
          'vod_id': _xmlChildText(video, const ['id', 'vod_id']),
          'vod_name': _xmlChildText(video, const ['name', 'vod_name', 'title']),
          'vod_play_from': playSources.join(r'$$$'),
          'vod_play_url': playGroups.join(r'$$$'),
        };
      })
      .toList(growable: false);
}

String _xmlChildText(XmlElement parent, List<String> names) {
  final normalized = names.map((name) => name.toLowerCase()).toSet();
  for (final child in parent.childElements) {
    if (normalized.contains(child.name.local.toLowerCase())) {
      return child.innerText.trim();
    }
  }
  return '';
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
    r'https?:\\?/\\?/[^\s"<>]+?\.(?:m3u8|mpd|mp4|webm|mkv|flv|m4v)(?:\?[^\s"<>]*)?',
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
        r'\.(?:m3u8|mpd|mp4|webm|mkv|flv|m4v)(?:$|[?#])',
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

final RegExp _titleSeparatorPattern = RegExp(r'[\s·・:：!！?？,，.。_\-—]+');
final RegExp _whitespacePattern = RegExp(r'\s+');

String _normalizeTitle(String value) {
  return value.toLowerCase().replaceAll(_titleSeparatorPattern, '').trim();
}

String _cleanText(String value) {
  // Only spin up the HTML parser when the string actually contains markup or
  // entities; plain titles/channel names just need whitespace collapsing.
  if (!value.contains('<') && !value.contains('&')) {
    return value.replaceAll(_whitespacePattern, ' ').trim();
  }
  final text = html_parser.parseFragment(value).text;
  return text
          ?.replaceAll(_whitespacePattern, ' ')
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
  return {
    ...headers,
    'Accept': '*/*',
    'Range': 'bytes=0-$_initialProbeRangeEnd',
  };
}

Map<String, String> _manifestProbeHeaders(Map<String, String> headers) {
  return {...headers, 'Range': 'bytes=0-${_maxManifestProbeSampleBytes - 1}'};
}

const _originBoundMediaHeaders = <String>{
  'authorization',
  'proxy-authorization',
  'cookie',
  'cookie2',
  'x-api-key',
  'x-auth-token',
  'x-access-token',
  'x-appid',
  'x-timestamp',
  'x-signature',
  'x-upstream-authorization',
  'x-upstream-cookie',
  'x-upstream-x-appid',
  'x-upstream-x-timestamp',
  'x-upstream-x-signature',
};

Map<String, String> _mediaChildHeaders(
  Uri credentialSourceUri,
  Uri childUri,
  Map<String, String> headers,
) {
  if (_sameMediaOrigin(credentialSourceUri, childUri)) return headers;
  return {
    for (final entry in headers.entries)
      if (!_originBoundMediaHeaders.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
  };
}

bool _sameMediaOrigin(Uri left, Uri right) {
  final leftOrigin = _normalizedMediaOrigin(_proxyUpstreamUri(left) ?? left);
  final rightOrigin = _normalizedMediaOrigin(_proxyUpstreamUri(right) ?? right);
  return leftOrigin != null && leftOrigin == rightOrigin;
}

String? _normalizedMediaOrigin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https' || uri.host.isEmpty) return null;
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
  return '$scheme://${uri.host.toLowerCase()}:$port';
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
  if (lower.contains('.mpd') || lower.contains('type=mpd')) return 'DASH';
  if (lower.contains('.mp4')) return 'MP4';
  if (lower.contains('.webm')) return 'WebM';
  if (lower.contains('.mkv')) return 'MKV';
  if (lower.contains('.flv')) return 'FLV';
  final normalizedFallback = fallback.trim().toUpperCase();
  return switch (normalizedFallback) {
    'HLS' || 'M3U8' => 'HLS',
    'DASH' || 'MPD' => 'DASH',
    'MP4' => 'MP4',
    'WEBM' => 'WebM',
    'MKV' => 'MKV',
    'FLV' => 'FLV',
    _ => '',
  };
}

String? _probeResolutionLabel(int? width, int? height) {
  if (height != null && height > 0) return '${height}P';
  if (width != null && width >= 3800) return '2160P';
  return null;
}

String? _resolutionLabelForUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final dimensions = _resolutionDimensionsForUrl(uri);
  return _probeResolutionLabel(dimensions?.width, dimensions?.height);
}

String? _probeSizeLabel(_PlayableProbeResult probe) {
  if (probe.isLive) return '动态流';
  final bytes = probe.sizeBytes;
  if (bytes == null || bytes <= 0) return null;
  final value = (bytes / 1024 / 1024).toStringAsFixed(1);
  return '${probe.sizeEstimated ? '约 ' : ''}$value MB';
}
