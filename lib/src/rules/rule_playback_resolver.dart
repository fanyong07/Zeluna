import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../domain/anime_models.dart';
import 'android_csp_bridge.dart';
import 'animeko_webview_sniffer.dart';
import 'csp_rule_support.dart';
import 'drpy_runtime.dart';
import 'rule_models.dart';

const _playableProbeTimeout = Duration(seconds: 6);
const _playlistMetadataTimeout = Duration(seconds: 3);
const _metadataEnrichmentBudget = Duration(seconds: 2);
const _probeChunkIdleTimeout = Duration(milliseconds: 300);
const _initialProbeRangeEnd = 2048;
const _maxBinaryProbeSampleBytes = 64 * 1024;
const _maxManifestProbeSampleBytes = 512 * 1024;
const _minimumBinaryProbeBytes = 4 * 1024;
const _maxDrpyMediaRedirects = 3;
const _maxConcurrentPlayableProbes = 4;
const _maxConcurrentMetadataProbes = 4;
const _responseCacheTtl = Duration(minutes: 5);
const _availableProbeCacheTtl = Duration(minutes: 2);
const _failedProbeCacheTtl = Duration(seconds: 20);
const _maxResponseCacheEntries = 128;
const _maxProbeCacheEntries = 256;

class RulePlaybackCancellationToken {
  final Set<void Function()> _callbacks = <void Function()>{};
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = _callbacks.toList(growable: false);
    _callbacks.clear();
    for (final callback in callbacks) {
      try {
        callback();
      } catch (_) {
        // Cancellation is best-effort; one client must not prevent the rest
        // of the lookup session from being stopped.
      }
    }
  }

  void Function() register(void Function() callback) {
    if (_cancelled) {
      try {
        callback();
      } catch (_) {
        // Already cancelled: registering work must not revive or fail it.
      }
      return () {};
    }
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }
}

final Object _rulePlaybackResolveContextKey = Object();
final Object _drpyPublicMediaProbeKey = Object();

class _RulePlaybackResolveContext {
  const _RulePlaybackResolveContext(this.cancellationToken);

  final RulePlaybackCancellationToken? cancellationToken;
}

_RulePlaybackResolveContext? get _activeRulePlaybackResolveContext =>
    Zone.current[_rulePlaybackResolveContextKey]
        as _RulePlaybackResolveContext?;

bool get _requiresDrpyPublicMediaProbe =>
    Zone.current[_drpyPublicMediaProbeKey] == true;

class RulePlaybackResolver {
  RulePlaybackResolver({
    http.Client? client,
    http.Client? drpyPublicClient,
    AndroidCspBridge? cspBridge,
    DrpyRuntime? drpyRuntime,
    AnimekoWebViewSniffer? animekoWebViewSniffer,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client,
       _drpyPublicClient = drpyPublicClient,
       _cspBridge = cspBridge ?? AndroidCspBridge(),
       _drpyRuntime = drpyRuntime ?? DrpyRuntime(),
       _animekoWebViewSniffer =
           animekoWebViewSniffer ?? createAnimekoWebViewSniffer();

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  final http.Client? _client;
  final http.Client? _drpyPublicClient;
  final AndroidCspBridge _cspBridge;
  final DrpyRuntime _drpyRuntime;
  final AnimekoWebViewSniffer _animekoWebViewSniffer;
  final Duration timeout;
  final Map<String, _TimedCacheEntry<String>> _responseCache = {};
  final Map<String, Future<String>> _responseRequests = {};
  final Map<String, _TimedCacheEntry<_PlayableProbeResult>> _probeCache = {};
  final Map<String, Future<_PlayableProbeResult>> _probeRequests = {};
  final _playableProbeLimiter = _AsyncLimiter(_maxConcurrentPlayableProbes);
  final _metadataProbeLimiter = _AsyncLimiter(_maxConcurrentMetadataProbes);
  Future<AndroidCspCapabilities>? _cspCapabilitiesRequest;
  final Map<String, Future<void>> _cspPreparationRequests = {};
  var _cacheGeneration = 0;

  void clearCaches() {
    _cacheGeneration++;
    _responseCache.clear();
    _responseRequests.clear();
    _probeCache.clear();
    _probeRequests.clear();
  }

  /// Verifies a concrete media URL before it is handed to the player.
  ///
  /// `PlaybackLine.available` is intentionally upgraded here from a source
  /// claim to a real network/media probe result. This is also used by direct
  /// sources (backend client candidates/M3U/open media) that do not go through
  /// a rule parser.
  Future<PlaybackLine> verifyPlaybackLine({
    required PlaybackLine line,
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) return line;
    final rawUrl = line.url?.trim() ?? '';
    final target = Uri.tryParse(rawUrl);
    if (target == null ||
        !const {'http', 'https'}.contains(target.scheme.toLowerCase()) ||
        target.host.isEmpty) {
      // Local/offline media is validated by the native player. Network-like
      // lines with no valid HTTP endpoint must never be marked playable.
      if (target != null && target.scheme.toLowerCase() == 'file') return line;
      return _copyPlaybackLineWithProbe(
        line,
        const _PlayableProbeResult(false, '视频地址格式不正确。'),
      );
    }

    final resolveContext = _RulePlaybackResolveContext(cancellationToken);
    return runZoned(() async {
      final injectedClient = line.publicHttpOnly
          ? _drpyPublicClient ?? _client
          : _client;
      final ownedClient = injectedClient == null;
      final client =
          injectedClient ??
          (line.publicHttpOnly
              ? _drpyRuntime.createPublicHttpClient()
              : http.Client());
      try {
        final headers = <String, String>{
          'User-Agent': _desktopUserAgent,
          ...line.headers,
        };
        if (line.publicHttpOnly) {
          await _drpyRuntime.ensurePublicUri(target);
        }
        final probe = await runZoned(
          () => _probePlayableUrl(
            client,
            rawUrl,
            headers,
            enrichMetadata: enrichMetadata,
            forceRefresh: forceRefresh,
          ),
          zoneValues: line.publicHttpOnly
              ? {_drpyPublicMediaProbeKey: true}
              : const <Object, Object?>{},
        );
        return _copyPlaybackLineWithProbe(line, probe);
      } catch (error) {
        if (cancellationToken?.isCancelled ?? false) return line;
        return _copyPlaybackLineWithProbe(
          line,
          _PlayableProbeResult(false, _friendlyError(error)),
        );
      } finally {
        if (ownedClient) client.close();
      }
    }, zoneValues: {_rulePlaybackResolveContextKey: resolveContext});
  }

  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) return const [];
    final resolveContext = _RulePlaybackResolveContext(cancellationToken);
    return runZoned(() async {
      if (rule.requiresCaptcha || rule.unsupportedReason != null) {
        if (rule.engine.toLowerCase() == 'android-csp') return const [];
        return [
          _unavailableLine(
            rule,
            subject,
            episode,
            rule.unsupportedReason ?? '该规则需要验证码或 WebView 手动处理，解析器不会绕过验证。',
          ),
        ];
      }

      final isDrpy = rule.engine.toLowerCase() == 'drpy-js';
      final injectedClient = isDrpy ? _drpyPublicClient ?? _client : _client;
      final ownedClient = injectedClient == null;
      final client =
          injectedClient ??
          (isDrpy ? _drpyRuntime.createPublicHttpClient() : http.Client());
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
          'drpy-js' => await _resolveDrpy(
            client,
            rule,
            subject,
            episode,
            verifyPlayable: verifyPlayable,
          ),
          'android-csp' => await _resolveAndroidCsp(
            client,
            rule,
            subject,
            episode,
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
          'aikanbot-api' => await _resolveAikanbotApi(
            client,
            rule,
            subject,
            episode,
            verifyPlayable: verifyPlayable,
          ),
          'sorani-api' => await _resolveSoraniApi(
            client,
            rule,
            subject,
            episode,
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
        if (cancellationToken?.isCancelled ?? false) return const [];
        return [
          _unavailableLine(rule, subject, episode, _friendlyError(error)),
        ];
      } finally {
        started.stop();
        if (ownedClient) client.close();
      }
    }, zoneValues: {_rulePlaybackResolveContextKey: resolveContext});
  }

  Future<List<PlaybackLine>> _resolveDrpy(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    final raw = rule.rawConfig;
    final inlineSource = raw['inlineSource']?.toString() ?? '';
    final extUrl = raw['extUrl']?.toString() ?? '';
    final runtimeResult = await _drpyRuntime.resolve(
      DrpyRuntimeRequest(
        ruleId: rule.id,
        keyword: subject.title,
        episodeNumber: episode.number,
        episodeTitle: episode.title,
        ruleSource: inlineSource,
        ruleUrl: extUrl,
        requestHeaders: rule.requestHeaders,
        credentialOrigin: rule.baseUrl,
      ),
      client: client,
    );
    if (runtimeResult.error != null || runtimeResult.candidates.isEmpty) {
      return const [];
    }

    final lines = <PlaybackLine>[];
    for (final candidate in runtimeResult.candidates) {
      if (candidate.requiresSniffing) continue;
      if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ??
          false) {
        return const [];
      }
      var referer = '';
      for (final entry in candidate.headers.entries) {
        if (entry.key.toLowerCase() == 'referer' &&
            entry.value.trim().isNotEmpty) {
          referer = entry.value.trim();
          break;
        }
      }
      final playableUrl = _normalizePlayableUrl(candidate.url, referer);
      final target = Uri.tryParse(playableUrl);
      if (target == null ||
          !const {'http', 'https'}.contains(target.scheme.toLowerCase()) ||
          target.host.isEmpty) {
        continue;
      }
      try {
        await _drpyRuntime.ensurePublicUri(target);
      } catch (_) {
        continue;
      }
      final baseHeaders = _headers(rule: rule, referer: referer);
      final credentialOrigin = Uri.tryParse(rule.baseUrl.trim());
      final headers = credentialOrigin == null
          ? _withoutOriginBoundMediaHeaders(baseHeaders)
          : _mediaChildHeaders(credentialOrigin, target, baseHeaders);
      for (final entry in candidate.headers.entries) {
        final name = entry.key.trim();
        final value = entry.value.trim();
        if (name.isNotEmpty && value.isNotEmpty) headers[name] = value;
      }
      final probe = await runZoned(
        () => _playableCandidateStatus(
          client,
          playableUrl,
          headers,
          verifyPlayable: verifyPlayable,
        ),
        zoneValues: {_drpyPublicMediaProbeKey: true},
      );
      if (!probe.available) continue;
      final lineName = candidate.lineName.trim().isEmpty
          ? rule.name
          : candidate.lineName.trim();
      lines.add(
        _availableLine(
          rule,
          episode,
          url: playableUrl,
          title: '${episode.displayTitle} 路 $lineName',
          probe: probe,
          referer: referer,
          headers: headers,
          publicHttpOnly: true,
        ),
      );
    }
    return lines;
  }

  Future<List<PlaybackLine>> _resolveAndroidCsp(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    if (!_cspBridge.isSupported) return const [];
    final raw = rule.rawConfig;
    final spiderMd5 = androidCspSpiderMd5(raw);
    final api = androidCspApi(raw);
    if (spiderMd5 == null ||
        api.isEmpty ||
        !isAuditedAndroidCspConfig(raw, fallbackApi: api)) {
      return const [];
    }

    try {
      final capabilities = await _cspCapabilities();
      final package = capabilities.packageForMd5(spiderMd5);
      if (package == null || !package.allowsApi(api)) return const [];
      await _prepareCspPackage(spiderMd5);
      if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ??
          false) {
        return const [];
      }

      final rawSiteKey = androidCspSiteKey(raw, rule.id);
      final siteKey = rawSiteKey.length <= 150
          ? rawSiteKey
          : '${rawSiteKey.substring(0, 120)}:${rule.id.hashCode}';
      final site = AndroidCspSite(
        spiderMd5: spiderMd5,
        siteKey: siteKey,
        api: api,
        ext: androidCspEncodedExt(raw),
      );
      await _cspBridge.initialize(site);

      _RankedResult<Map<String, dynamic>>? bestMatch;
      var preference = 0;
      for (final keyword in _searchKeywords(subject)) {
        if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ??
            false) {
          return const [];
        }
        try {
          final decoded = jsonDecode(
            await _cspBridge.searchContent(
              site: site,
              keyword: keyword,
              quick: false,
              page: '1',
            ),
          );
          final ranked = _rankBestTvBoxItem(
            _tvBoxItems(decoded),
            subject,
            preference++,
          );
          if (ranked != null &&
              (bestMatch == null || ranked.score > bestMatch.score)) {
            bestMatch = ranked;
          }
        } catch (_) {
          preference++;
        }
      }
      var item = bestMatch?.value;
      if (item == null) return const [];

      if (_tvBoxPlayUrl(item).isEmpty) {
        final vodId = item['vod_id']?.toString().trim() ?? '';
        if (vodId.isEmpty) return const [];
        final details = _tvBoxItems(
          jsonDecode(await _cspBridge.detailContent(site: site, ids: [vodId])),
        );
        if (details.isEmpty) return const [];
        item = details.first;
      }

      final groups = _tvBoxPlayGroups(item);
      if (groups.isEmpty) return const [];
      return _collectPlaybackCandidates(
        [
          for (var index = 0; index < groups.length && index < 8; index++)
            () => _resolveAndroidCspLine(
              client,
              rule,
              episode,
              site,
              groups[index],
              androidCspVipFlags(raw),
              verifyPlayable: verifyPlayable,
            ),
        ],
        verifyPlayable: verifyPlayable,
        candidateTimeout: timeout,
      );
    } catch (_) {
      // CSP failures are remembered by the rule-health layer, but are not
      // emitted as dozens of dead playback rows. The imported rule remains.
      return const [];
    }
  }

  Future<PlaybackLine?> _resolveAndroidCspLine(
    http.Client client,
    RulePlugin rule,
    AnimeEpisode episode,
    AndroidCspSite site,
    _TvBoxPlayGroup group,
    List<String> vipFlags, {
    required bool verifyPlayable,
  }) async {
    final selected = _pickTvBoxEpisode(group.episodes, episode);
    if (selected == null) return null;
    try {
      final decoded = jsonDecode(
        await _cspBridge.playerContent(
          site: site,
          flag: group.name,
          id: selected.url,
          vipFlags: vipFlags,
        ),
      );
      if (decoded is! Map) return null;
      final result = decoded.cast<String, dynamic>();
      final rawUrl = result['url']?.toString().trim() ?? '';
      if (rawUrl.isEmpty) return null;
      final base = androidCspPinnedBase(site.spiderMd5);
      final playableUrl = _normalizePlayableUrl(rawUrl, base);
      if (!_looksPlayable(playableUrl)) return null;

      final parse = int.tryParse(result['parse']?.toString() ?? '') ?? 0;
      if (parse != 0 && !_isExplicitPlayableUrl(playableUrl)) return null;
      final playerHeaders = _cspPlayerHeaders(
        result['header'] ?? result['headers'],
      );
      final referer = _headerValue(playerHeaders, 'referer') ?? base;
      final headers = _headers(rule: rule, referer: referer)
        ..addAll(playerHeaders);
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
      );
      if (!probe.available) return null;
      final lineName = group.name.trim().isEmpty
          ? rule.name
          : group.name.trim();
      return _availableLine(
        rule,
        episode,
        url: playableUrl,
        title: '${selected.title} · $lineName',
        probe: probe,
        referer: referer,
        headers: headers,
      );
    } catch (_) {
      return null;
    }
  }

  Future<AndroidCspCapabilities> _cspCapabilities() =>
      _cspCapabilitiesRequest ??= _cspBridge.getCapabilities();

  Future<void> _prepareCspPackage(String spiderMd5) async {
    final existing = _cspPreparationRequests[spiderMd5];
    if (existing != null) return existing;
    late final Future<void> request;
    request = _cspBridge.prepare(spiderMd5).then<void>((prepared) {
      if (prepared.md5 != spiderMd5) {
        throw const AndroidCspException(
          'csp_artifact_hash_mismatch',
          'The prepared CSP package did not match the requested digest.',
        );
      }
    });
    _cspPreparationRequests[spiderMd5] = request;
    try {
      await request;
    } catch (_) {
      if (identical(_cspPreparationRequests[spiderMd5], request)) {
        _cspPreparationRequests.remove(spiderMd5);
      }
      rethrow;
    }
  }

  Map<String, String> _cspPlayerHeaders(Object? value) {
    Object? decoded = value;
    if (decoded is String && decoded.trim().startsWith('{')) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return const {};
      }
    }
    if (decoded is! Map) return const {};
    final result = <String, String>{};
    for (final entry in decoded.entries) {
      final name = entry.key.toString().trim();
      final headerValue = entry.value?.toString().trim() ?? '';
      if (name.isNotEmpty && headerValue.isNotEmpty) {
        result[name] = headerValue;
      }
    }
    return result;
  }

  String? _headerValue(Map<String, String> headers, String name) {
    final normalized = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == normalized) return entry.value;
    }
    return null;
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
    final verifyQuickCandidates = !verifyPlayable && episodeLinks.length > 1;

    final lines = await _collectPlaybackCandidates(
      [
        for (var index = 0; index < episodeLinks.length; index++)
          () => _resolveAnimekoLine(
            client,
            rule,
            config,
            episode,
            detailUrl,
            episodeLinks[index],
            index,
            started,
            verifyPlayable: verifyPlayable,
            verifyExplicitMedia: verifyQuickCandidates,
          ),
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
    );

    if (lines.isEmpty) {
      return [
        _unavailableLine(rule, subject, episode, '找到了播放页，但没有解析到 mp4/m3u8 直链。'),
      ];
    }
    return lines;
  }

  /// Aikanbot exposes its HLS inventory through a documented page-side JSON
  /// request.  Calling that endpoint avoids loading its ad-funded player while
  /// keeping the same search and episode selection users see in the browser.
  Future<List<PlaybackLine>> _resolveAikanbotApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    final detailUrl = await _findAikanbotDetailUrl(client, rule, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目。')];
    }
    final detailHtml = await _get(
      client,
      detailUrl,
      _headers(rule: rule, referer: rule.baseUrl),
    );
    final root = _documentRoot(detailHtml);
    final videoId =
        root.querySelector('#current_id')?.attributes['value'] ?? '';
    final encryptedToken =
        root.querySelector('#e_token')?.attributes['value'] ?? '';
    final mediaType = root.querySelector('#mtype')?.attributes['value'] ?? '';
    final token = _aikanbotToken(videoId, encryptedToken);
    if (videoId.isEmpty || mediaType.isEmpty || token.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '播放清单参数无效。')];
    }
    final inventoryUrl = detailUrl.replace(
      path: '/api/getResN',
      queryParameters: {'videoId': videoId, 'mtype': mediaType, 'token': token},
    );
    final decoded = jsonDecode(
      await _get(
        client,
        inventoryUrl,
        _headers(rule: rule, referer: detailUrl.toString()),
      ),
    );
    if (decoded is! Map || decoded['state'] != 1) {
      return [_unavailableLine(rule, subject, episode, '播放清单暂时不可用。')];
    }
    final data = decoded['data'];
    final rawLines = data is Map && data['list'] is List
        ? (data['list'] as List)
        : const <Object?>[];
    final candidates = <String>[];
    for (final rawLine in rawLines) {
      if (rawLine is! Map) continue;
      final url = _aikanbotEpisodeUrl(rawLine['resData'], episode.number);
      if (url != null) candidates.add(url);
      // A bounded first wave prevents one source with dozens of mirrors from
      // delaying the player. The normal health fallback still retries later.
      if (candidates.length >= 8) break;
    }
    if (candidates.isEmpty) {
      return [_unavailableLine(rule, subject, episode, '没有找到当前集的 HLS 线路。')];
    }
    final headers = _headers(rule: rule, referer: detailUrl.toString());
    final lines = await _collectPlaybackCandidates(
      [
        for (var index = 0; index < candidates.length; index++)
          () async {
            final url = candidates[index];
            final probe = await _playableCandidateStatus(
              client,
              url,
              headers,
              verifyPlayable: verifyPlayable,
            );
            final title = '${episode.displayTitle} · 镜像线路 ${index + 1}';
            return probe.available
                ? _availableLine(
                    rule,
                    episode,
                    url: url,
                    title: title,
                    probe: probe,
                    referer: detailUrl.toString(),
                    headers: headers,
                  )
                : _deadLine(
                    rule,
                    episode,
                    url: url,
                    title: title,
                    latency: probe.latency,
                    message: probe.message,
                    headers: headers,
                  );
          },
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
    );
    return lines.isEmpty
        ? [_unavailableLine(rule, subject, episode, '播放线路验证失败。')]
        : lines;
  }

  Future<Uri?> _findAikanbotDetailUrl(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
  ) async {
    for (final keyword in _searchKeywords(subject)) {
      final searchUrl = Uri.parse(
        '${rule.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/search',
      ).replace(queryParameters: {'q': keyword});
      final root = _documentRoot(
        await _get(
          client,
          searchUrl,
          _headers(rule: rule, referer: rule.baseUrl),
        ),
      );
      final hits = [
        for (final node in root.querySelectorAll('a.title-text'))
          _SearchHit(
            title: _cleanText(node.text),
            url: _absoluteUrl(node.attributes['href'] ?? '', rule.baseUrl),
          ),
      ].where((hit) => hit.title.isNotEmpty && hit.url.isNotEmpty).toList();
      final best = _rankBestHit(hits, subject, 0);
      if (best != null) return Uri.tryParse(best.value.url);
    }
    return null;
  }

  /// 青空次元的网页播放器会在播放时向其公开播放清单接口请求一个
  /// 短时 HLS 地址。这里复用同一套搜索、详情和清单流程，而不保存
  /// 会过期的媒体 URL。
  Future<List<PlaybackLine>> _resolveSoraniApi(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) async {
    final detailUrl = await _findSoraniDetailUrl(client, rule, subject);
    if (detailUrl == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前条目。')];
    }

    final apiHeaders = _soraniHeaders(rule);
    final decoded = jsonDecode(await _get(client, detailUrl, apiHeaders));
    final detail = _soraniData(decoded);
    final episodes = detail?['episodes'];
    if (episodes is! List) {
      return [_unavailableLine(rule, subject, episode, '详情页没有返回剧集列表。')];
    }
    final selected = _pickSoraniEpisode(episodes, episode.number);
    final episodeId = _soraniInt(selected?['episodeId']);
    if (episodeId == null) {
      return [_unavailableLine(rule, subject, episode, '没有匹配到当前集。')];
    }
    if (selected?['isVip'] == true) {
      return [_unavailableLine(rule, subject, episode, '当前集需要站点会员，未加入播放线路。')];
    }

    final lineCode = rule.rawConfig['lineCode']?.toString().trim();
    final apiRoot = Uri.parse(rule.baseUrl.replaceFirst(RegExp(r'/+$'), ''));
    final playUrl = apiRoot.replace(
      path: '${apiRoot.path}/api/video/episode/$episodeId/play',
      queryParameters: {
        'lineCode': lineCode == null || lineCode.isEmpty
            ? 'anime_jp_m3u8'
            : lineCode,
      },
    );
    final playDecoded = jsonDecode(await _get(client, playUrl, apiHeaders));
    final playback = _soraniData(playDecoded);
    final mediaUrl = playback?['playUrl']?.toString().trim() ?? '';
    if (playback?['canPlay'] != true || !_looksPlayable(mediaUrl)) {
      return [_unavailableLine(rule, subject, episode, '播放清单暂时不可用。')];
    }

    final probe = await _playableCandidateStatus(
      client,
      mediaUrl,
      apiHeaders,
      verifyPlayable: verifyPlayable,
    );
    final title = '${episode.displayTitle} · 青空线路';
    return [
      probe.available
          ? _availableLine(
              rule,
              episode,
              url: mediaUrl,
              title: title,
              probe: probe,
              referer: apiHeaders['Referer'] ?? rule.baseUrl,
              headers: apiHeaders,
            )
          : _deadLine(
              rule,
              episode,
              url: mediaUrl,
              title: title,
              latency: probe.latency,
              message: probe.message,
              headers: apiHeaders,
            ),
    ];
  }

  Future<Uri?> _findSoraniDetailUrl(
    http.Client client,
    RulePlugin rule,
    AnimeSubject subject,
  ) async {
    final root = Uri.parse(rule.baseUrl.replaceFirst(RegExp(r'/+$'), ''));
    for (final keyword in _searchKeywords(subject)) {
      final searchUrl = root.replace(
        path: '${root.path}/api/video',
        queryParameters: {
          'page': '1',
          'size': '20',
          'keyword': keyword,
          'enabled': 'true',
          'sortMode': 'latest',
          'sortDesc': 'true',
        },
      );
      final decoded = jsonDecode(
        await _get(client, searchUrl, _soraniHeaders(rule)),
      );
      final data = _soraniData(decoded);
      final records = data?['records'];
      if (records is! List) continue;
      final hits = <_SearchHit>[
        for (final record in records)
          if (record is Map)
            (() {
              final title = record['title']?.toString().trim() ?? '';
              final alias = record['alias']?.toString().trim() ?? '';
              final id = _soraniInt(record['id']);
              return _SearchHit(
                title: [
                  title,
                  alias,
                ].where((part) => part.isNotEmpty).join(' '),
                url: id == null ? '' : id.toString(),
              );
            })(),
      ].where((hit) => hit.title.isNotEmpty && hit.url.isNotEmpty).toList();
      final best = _rankBestHit(hits, subject, 0);
      if (best == null) continue;
      return root.replace(path: '${root.path}/api/video/${best.value.url}');
    }
    return null;
  }

  Map<String, dynamic>? _soraniData(Object? decoded) {
    if (decoded is! Map) return null;
    final data = decoded['data'];
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? _pickSoraniEpisode(List<dynamic> episodes, int number) {
    for (final raw in episodes) {
      if (raw is! Map) continue;
      final order = raw['episodeOrder'];
      if (order is num && order.round() == number) {
        return raw.cast<String, dynamic>();
      }
    }
    final index = number - 1;
    if (index >= 0 && index < episodes.length && episodes[index] is Map) {
      return (episodes[index] as Map).cast<String, dynamic>();
    }
    return null;
  }

  int? _soraniInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Map<String, String> _soraniHeaders(RulePlugin rule) => {
    ..._headers(rule: rule, referer: 'https://www.sorani.net/'),
    'Origin': 'https://www.sorani.net',
    'Accept': 'application/json, text/plain, */*',
  };

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
    bool verifyExplicitMedia = false,
  }) async {
    try {
      final playHtml = await _get(
        client,
        Uri.parse(link.url),
        _headers(rule: rule, referer: detailUrl.toString()),
      );
      var playableUrl = await _extractAnimekoPlayableUrl(
        client,
        rule,
        config,
        playHtml,
        link.url,
        get: (url, headers) => _get(client, url, headers),
      );
      var sniffedCookie = '';
      if ((playableUrl == null || !_looksPlayable(playableUrl)) &&
          _animekoWebViewSniffer.supported) {
        final sniffed = await _sniffAnimekoPlayableUrl(
          client,
          rule,
          config,
          link.url,
          detailUrl.toString(),
        );
        playableUrl = sniffed.url;
        sniffedCookie = sniffed.cookieHeader;
      }
      if (playableUrl == null || !_looksPlayable(playableUrl)) return null;

      final referer = _animekoVideoReferer(config, link.url);
      final headers = _animekoVideoHeaders(rule, config, referer);
      if (sniffedCookie.isNotEmpty) {
        headers['Cookie'] = _mergeCookieHeaders(
          headers['Cookie'] ?? '',
          sniffedCookie,
        );
      }
      final probe = await _playableCandidateStatus(
        client,
        playableUrl,
        headers,
        verifyPlayable: verifyPlayable,
        verifyExplicitMedia: verifyExplicitMedia,
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

  Future<({String? url, String cookieHeader})> _sniffAnimekoPlayableUrl(
    http.Client client,
    RulePlugin rule,
    AnimekoWebSelectorConfig config,
    String playPageUrl,
    String detailUrl,
  ) async {
    String? matchVideo(String value, String baseUrl) {
      final configured = _extractByRegex(
        value,
        config.matchVideoUrl,
        baseUrl: baseUrl,
      );
      if (configured != null && _looksPlayable(configured)) return configured;
      final fallback = _extractPlayableUrl(value, baseUrl);
      if (fallback != null && _looksPlayable(fallback)) return fallback;
      final absolute = _absoluteUrl(value, baseUrl);
      return _looksPlayable(absolute) ? absolute : null;
    }

    String? matchNested(String value, String baseUrl) {
      if (!config.enableNestedUrl || config.matchNestedUrl.trim().isEmpty) {
        return null;
      }
      return _extractByRegex(
        value,
        config.matchNestedUrl,
        baseUrl: baseUrl,
        requirePlayable: false,
      );
    }

    final result = await _animekoWebViewSniffer.sniff(
      AnimekoWebViewSniffRequest(
        pageUrl: Uri.parse(playPageUrl),
        headers: _animekoVideoHeaders(rule, config, detailUrl),
        matchVideo: matchVideo,
        matchNested: matchNested,
        timeout: const Duration(seconds: 8),
      ),
    );
    if (result == null) return (url: null, cookieHeader: '');
    var resolved = result.videoUrl;
    final nestedUrl = result.nestedUrl;
    if ((resolved == null || !_looksPlayable(resolved)) &&
        nestedUrl != null &&
        nestedUrl.trim().isNotEmpty) {
      final nestedHeaders = _animekoNestedHeaders(rule, config, playPageUrl);
      if (result.cookieHeader.isNotEmpty) {
        nestedHeaders['Cookie'] = _mergeCookieHeaders(
          nestedHeaders['Cookie'] ?? '',
          result.cookieHeader,
        );
      }
      final nestedHtml = await _get(
        client,
        Uri.parse(nestedUrl),
        nestedHeaders,
      );
      resolved = matchVideo(nestedHtml, nestedUrl);
    }
    return (url: resolved, cookieHeader: result.cookieHeader);
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
    final hits =
        config.subjectFormatId.trim().toLowerCase() == 'json-path-indexed'
        ? _animekoJsonSearchHits(
            searchHtml,
            config.rawBaseUrl.trim().isNotEmpty
                ? config.rawBaseUrl.trim()
                : rule.baseUrl,
            config,
          )
        : _animekoSearchHits(
            _documentRoot(searchHtml),
            searchUri.toString(),
            config,
          );
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
    final verifyQuickCandidates = !verifyPlayable && roadNodes.length > 1;

    final lines = await _collectPlaybackCandidates(
      [
        for (var roadIndex = 0; roadIndex < roadNodes.length; roadIndex++)
          () => _resolveKazumiLine(
            client,
            rule,
            config,
            episode,
            detailUrl,
            roadNodes[roadIndex],
            roadIndex,
            started,
            verifyPlayable: verifyPlayable,
            verifyExplicitMedia: verifyQuickCandidates,
          ),
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
      preferredQuickCandidate: verifyQuickCandidates
          ? _isHlsPlaybackLine
          : null,
      preferredCandidateGrace: const Duration(milliseconds: 1100),
    );

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
    bool verifyExplicitMedia = false,
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
        verifyExplicitMedia: verifyExplicitMedia,
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

    final lines = await _collectPlaybackCandidates(
      [
        for (var groupIndex = 0; groupIndex < playGroups.length; groupIndex++)
          () => _resolveXbpqLine(
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
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
    );

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
    final lines = await _collectPlaybackCandidates(
      [
        for (var index = 0; index < groups.length && index < 8; index++)
          () => _resolveTvBoxLine(
            client,
            rule,
            episode,
            endpoint,
            groups[index],
            started,
            verifyPlayable: verifyPlayable,
          ),
      ],
      verifyPlayable: verifyPlayable,
      candidateTimeout: timeout,
    );
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
    _throwIfLookupCancelled(url);
    final requestUri = _ruleRequestUri(url);
    final requestHeaders = _ruleRequestHeaders(url, headers);
    final key = _requestCacheKey('GET', requestUri, requestHeaders);
    final cached = _freshCacheValue(_responseCache, key);
    if (cached != null) return cached;

    final inFlightKey = _resolveScopedInFlightKey(key);
    final existing = _responseRequests[inFlightKey];
    if (existing != null) return existing;

    final cacheGeneration = _cacheGeneration;
    final request = _sendBufferedRequest(
      client,
      'GET',
      requestUri,
      requestHeaders,
    ).then(_responseText);
    _responseRequests[inFlightKey] = request;
    try {
      final result = await request;
      _throwIfLookupCancelled(requestUri);
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
      if (identical(_responseRequests[inFlightKey], request)) {
        _responseRequests.remove(inFlightKey);
      }
    }
  }

  Future<String> _post(
    http.Client client,
    Uri url,
    String body,
    Map<String, String> headers,
  ) async {
    _throwIfLookupCancelled(url);
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

    final inFlightKey = _resolveScopedInFlightKey(key);
    final existing = _responseRequests[inFlightKey];
    if (existing != null) return existing;

    final cacheGeneration = _cacheGeneration;
    final request = _sendBufferedRequest(
      client,
      'POST',
      requestUri,
      requestHeaders,
      body: body,
    ).then(_responseText);
    _responseRequests[inFlightKey] = request;
    try {
      final result = await request;
      _throwIfLookupCancelled(requestUri);
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
      if (identical(_responseRequests[inFlightKey], request)) {
        _responseRequests.remove(inFlightKey);
      }
    }
  }

  Future<http.Response> _sendBufferedRequest(
    http.Client client,
    String method,
    Uri uri,
    Map<String, String> headers, {
    String? body,
  }) async {
    final abortTrigger = Completer<void>();
    void abort() {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    }

    final cancellationToken =
        _activeRulePlaybackResolveContext?.cancellationToken;
    final unregisterCancellation = cancellationToken?.register(abort);
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abortTrigger.future,
    )..headers.addAll(headers);
    if (body != null) request.body = body;
    final operation = client.send(request).then(http.Response.fromStream);
    try {
      return await operation.timeout(
        timeout,
        onTimeout: () {
          abort();
          throw TimeoutException('Rule request timed out after $timeout.');
        },
      );
    } finally {
      unregisterCancellation?.call();
    }
  }

  String _resolveScopedInFlightKey(String key) {
    final context = _activeRulePlaybackResolveContext;
    return context == null ? key : '$key|resolve:${identityHashCode(context)}';
  }

  void _throwIfLookupCancelled([Uri? uri]) {
    if (_activeRulePlaybackResolveContext?.cancellationToken?.isCancelled ??
        false) {
      throw http.RequestAbortedException(uri);
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
    bool publicHttpOnly = false,
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
      publicHttpOnly: publicHttpOnly,
      startupProfile: probe.startupProfile,
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
    Map<String, String> headers, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
  }) async {
    final target = Uri.tryParse(url);
    if (target == null || !target.hasScheme) {
      return const _PlayableProbeResult(false, '视频地址格式不正确。');
    }
    _throwIfLookupCancelled(target);
    final requestUri = _ruleRequestUri(target);
    final sourceHeaders = _videoProbeHeaders(headers);
    final requestHeaders = _ruleRequestHeaders(target, sourceHeaders);
    final key = _requestCacheKey(
      '${enrichMetadata ? 'PROBE' : 'PROBE_QUICK'}'
      '${_requiresDrpyPublicMediaProbe ? '_DRPY_PUBLIC' : ''}',
      requestUri,
      requestHeaders,
    );
    if (!forceRefresh) {
      final cached = _freshCacheValue(_probeCache, key);
      if (cached != null) return cached;
    }

    final inFlightKey = _resolveScopedInFlightKey(key);
    final existing = _probeRequests[inFlightKey];
    if (existing != null) return existing;

    final cacheGeneration = _cacheGeneration;
    final request = _playableProbeLimiter.run(
      () => _performPlayableProbe(
        client,
        sourceUri: target,
        requestUri: requestUri,
        headers: requestHeaders,
        sourceHeaders: sourceHeaders,
        enrichMetadata: enrichMetadata,
      ),
    );
    _probeRequests[inFlightKey] = request;
    try {
      final result = await request;
      _throwIfLookupCancelled(requestUri);
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
      if (identical(_probeRequests[inFlightKey], request)) {
        _probeRequests.remove(inFlightKey);
      }
    }
  }

  Future<_PlayableProbeResult> _playableCandidateStatus(
    http.Client client,
    String url,
    Map<String, String> headers, {
    required bool verifyPlayable,
    bool verifyExplicitMedia = false,
  }) {
    // A URL-looking string is only a candidate. Even the quick path performs
    // a bounded media probe so dead CDN links and HTML error pages never leave
    // the resolver as `available=true`.
    return _probePlayableUrl(
      client,
      url,
      headers,
      enrichMetadata: verifyPlayable || verifyExplicitMedia,
    );
  }

  Future<_PlayableProbeResult> _performPlayableProbe(
    http.Client client, {
    required Uri sourceUri,
    required Uri requestUri,
    required Map<String, String> headers,
    required Map<String, String> sourceHeaders,
    required bool enrichMetadata,
  }) async {
    final stopwatch = Stopwatch()..start();

    Duration totalLatency() {
      if (stopwatch.isRunning) stopwatch.stop();
      return stopwatch.elapsed;
    }

    try {
      var sample = await _sendPlayableProbe(
        client,
        requestUri,
        headers,
        timeout: _playableProbeTimeout,
      );
      var response = sample.response;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (!sample.sampleComplete &&
            _isManifestResponse(requestUri, response)) {
          try {
            final expandedSample = await _sendPlayableProbe(
              client,
              _ruleRequestUri(sourceUri),
              _ruleRequestHeaders(
                sourceUri,
                _manifestProbeHeaders(sourceHeaders),
              ),
              timeout: _playlistMetadataTimeout,
            );
            if (expandedSample.response.statusCode >= 200 &&
                expandedSample.response.statusCode < 300) {
              sample = expandedSample;
              response = expandedSample.response;
            }
          } catch (_) {
            // The bounded initial sample is still validated below. If it does
            // not contain a complete manifest, the line will be rejected.
          }
        }
        final validation = _validatePlayableSample(sourceUri, sample);
        if (!validation.available) {
          return _PlayableProbeResult(
            false,
            validation.message,
            latency: totalLatency(),
          );
        }
        final detectedFormat = _detectedMediaFormat(
          sourceUri,
          response.headers['content-type'],
          utf8.decode(sample.sample, allowMalformed: true),
        );
        _ProbeMediaMetadata metadata;
        try {
          metadata = _mediaMetadataFromSample(sourceUri, sample);
          if (enrichMetadata) {
            metadata = await _probeMediaMetadata(
              client,
              sourceUri: sourceUri,
              sourceHeaders: sourceHeaders,
              sample: sample,
            );
          }
        } catch (_) {
          if (detectedFormat == 'HLS' || detectedFormat == 'DASH') {
            return _PlayableProbeResult(
              false,
              '媒体清单格式无效，无法确认真实播放分片。',
              latency: totalLatency(),
            );
          }
          // Container metadata is optional for a signature-confirmed file.
          metadata = const _ProbeMediaMetadata();
        }
        if (metadata.format == 'HLS') {
          final hlsFailure = await _verifyHlsMediaReachability(
            client,
            sourceUri: sourceUri,
            sourceHeaders: sourceHeaders,
            metadata: metadata,
          );
          if (hlsFailure != null) {
            return _PlayableProbeResult(
              false,
              hlsFailure,
              latency: totalLatency(),
            );
          }
        }
        if (metadata.format == 'DASH') {
          final dashFailure = await _verifyDashMediaReachability(
            client,
            sourceUri: sourceUri,
            sourceHeaders: sourceHeaders,
            metadata: metadata,
          );
          if (dashFailure != null) {
            return _PlayableProbeResult(
              false,
              dashFailure,
              latency: totalLatency(),
            );
          }
        }
        return _PlayableProbeResult(
          true,
          '',
          latency: totalLatency(),
          format: metadata.format,
          startupProfile: metadata.startupProfile,
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
          latency: totalLatency(),
        );
      }
      if (response.statusCode == 404) {
        return _PlayableProbeResult(
          false,
          '视频 CDN 返回 404，这条播放地址已经失效。',
          latency: totalLatency(),
        );
      }
      return _PlayableProbeResult(
        false,
        '视频 CDN 返回 HTTP ${response.statusCode}。',
        latency: totalLatency(),
      );
    } on TimeoutException {
      return _PlayableProbeResult(
        false,
        '视频 CDN 连接超时。',
        latency: totalLatency(),
      );
    } catch (error) {
      return _PlayableProbeResult(
        false,
        '视频 CDN 无法访问：${_shortError(error)}',
        latency: totalLatency(),
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
              sampleSegmentUris: media.sampleSegmentUris,
              segmentCandidates: media.segmentCandidates,
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

  Future<String?> _verifyHlsMediaReachability(
    http.Client client, {
    required Uri sourceUri,
    required Map<String, String> sourceHeaders,
    required _ProbeMediaMetadata metadata,
  }) async {
    final variants = metadata.variants.isNotEmpty
        ? metadata.variants.take(3).toList(growable: false)
        : metadata.variantUri == null
        ? const <_HlsProbeVariant>[]
        : <_HlsProbeVariant>[_HlsProbeVariant(uri: metadata.variantUri!)];
    if (variants.isEmpty) {
      return _verifyHlsSegments(
        client,
        credentialSourceUri: sourceUri,
        sourceHeaders: sourceHeaders,
        metadata: metadata,
      );
    }

    String? lastFailure;
    for (final variant in variants) {
      try {
        final variantHeaders = _mediaChildHeaders(
          sourceUri,
          variant.uri,
          sourceHeaders,
        );
        final variantSample = await _sendPlayableProbe(
          client,
          _ruleRequestUri(variant.uri),
          _ruleRequestHeaders(
            variant.uri,
            _manifestProbeHeaders(variantHeaders),
          ),
          timeout: _playlistMetadataTimeout,
        );
        final validation = _validatePlayableSample(variant.uri, variantSample);
        if (variantSample.response.statusCode < 200 ||
            variantSample.response.statusCode >= 300 ||
            !validation.available) {
          lastFailure = 'HLS 子清单已经失效。';
          continue;
        }
        final mediaMetadata = _mediaMetadataFromSample(
          variant.uri,
          variantSample,
        );
        final failure = await _verifyHlsSegments(
          client,
          credentialSourceUri: variant.uri,
          sourceHeaders: variantHeaders,
          metadata: mediaMetadata,
        );
        if (failure == null) return null;
        lastFailure = failure;
      } on TimeoutException {
        lastFailure = 'HLS 子清单或媒体分片验证超时。';
      } catch (_) {
        lastFailure = 'HLS 子清单无法解析或访问。';
      }
    }
    return lastFailure ?? 'HLS 主清单内没有可播放的子清单。';
  }

  Future<String?> _verifyHlsSegments(
    http.Client client, {
    required Uri credentialSourceUri,
    required Map<String, String> sourceHeaders,
    required _ProbeMediaMetadata metadata,
  }) async {
    final candidates = metadata.segmentCandidates.isNotEmpty
        ? metadata.segmentCandidates.take(3).toList(growable: false)
        : metadata.sampleSegmentUris.isNotEmpty
        ? metadata.sampleSegmentUris
              .take(3)
              .map((uri) => _HlsProbeSegment(uri: uri))
              .toList(growable: false)
        : metadata.sampleSegmentUri == null
        ? const <_HlsProbeSegment>[]
        : <_HlsProbeSegment>[_HlsProbeSegment(uri: metadata.sampleSegmentUri!)];
    if (candidates.isEmpty) {
      return 'HLS 清单没有返回可验证的媒体分片。';
    }
    var timedOut = false;
    final keyAvailability = <Uri, bool>{};
    for (final candidate in candidates) {
      try {
        var aes128KeyVerified = false;
        if (candidate.usesAes128) {
          final keyUri = candidate.keyUri;
          if (keyUri == null) continue;
          aes128KeyVerified =
              keyAvailability[keyUri] ??
              await _verifyHlsAes128Key(
                client,
                credentialSourceUri: credentialSourceUri,
                keyUri: keyUri,
                sourceHeaders: sourceHeaders,
              );
          keyAvailability[keyUri] = aes128KeyVerified;
          if (!aes128KeyVerified) continue;
        }
        final segmentUri = candidate.uri;
        final segmentHeaders = _mediaChildHeaders(
          credentialSourceUri,
          segmentUri,
          sourceHeaders,
        );
        final segmentSample = await _sendPlayableProbe(
          client,
          _ruleRequestUri(segmentUri),
          _ruleRequestHeaders(segmentUri, _videoProbeHeaders(segmentHeaders)),
          timeout: _playlistMetadataTimeout,
        );
        if (segmentSample.response.statusCode >= 200 &&
            segmentSample.response.statusCode < 300 &&
            (_validatePlayableSample(segmentUri, segmentSample).available ||
                (aes128KeyVerified &&
                    _isOpaqueEncryptedHlsSegment(segmentSample)))) {
          return null;
        }
      } on TimeoutException {
        timedOut = true;
      } catch (_) {
        // Try another recent/alternate segment before rejecting the line.
      }
    }
    return timedOut ? 'HLS 媒体分片验证超时。' : 'HLS 清单存在，但媒体分片无法读取。';
  }

  Future<bool> _verifyHlsAes128Key(
    http.Client client, {
    required Uri credentialSourceUri,
    required Uri keyUri,
    required Map<String, String> sourceHeaders,
  }) async {
    final keyHeaders = _mediaChildHeaders(
      credentialSourceUri,
      keyUri,
      sourceHeaders,
    );
    final sample = await _sendPlayableProbe(
      client,
      _ruleRequestUri(keyUri),
      _ruleRequestHeaders(keyUri, _videoProbeHeaders(keyHeaders)),
      timeout: _playlistMetadataTimeout,
    );
    return sample.response.statusCode >= 200 &&
        sample.response.statusCode < 300 &&
        sample.sample.length == 16;
  }

  Future<String?> _verifyDashMediaReachability(
    http.Client client, {
    required Uri sourceUri,
    required Map<String, String> sourceHeaders,
    required _ProbeMediaMetadata metadata,
  }) async {
    if (metadata.dashResources.isEmpty) {
      return 'DASH 清单没有可验证的初始化或媒体分片。';
    }
    for (final resource in metadata.dashResources.take(3)) {
      try {
        final childHeaders = _mediaChildHeaders(
          sourceUri,
          resource.uri,
          sourceHeaders,
        );
        final sample = await _sendPlayableProbe(
          client,
          _ruleRequestUri(resource.uri),
          _ruleRequestHeaders(resource.uri, _videoProbeHeaders(childHeaders)),
          timeout: _playlistMetadataTimeout,
        );
        if (sample.response.statusCode < 200 ||
            sample.response.statusCode >= 300 ||
            !_validatePlayableSample(resource.uri, sample).available) {
          return 'DASH ${resource.label}无法读取。';
        }
      } on TimeoutException {
        return 'DASH ${resource.label}验证超时。';
      } catch (_) {
        return 'DASH ${resource.label}无法访问。';
      }
    }
    return null;
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
  }) async {
    final stopwatch = Stopwatch()..start();
    final first = await _sendPlayableProbeOnce(
      client,
      requestUri,
      headers,
      timeout: timeout,
    );
    const rangeRejectedStatuses = <int>{400, 405, 416};
    final hasRange = headers.keys.any((name) => name.toLowerCase() == 'range');
    if (!hasRange ||
        !rangeRejectedStatuses.contains(first.response.statusCode)) {
      return first;
    }
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) return first;
    return _sendPlayableProbeOnce(
      client,
      requestUri,
      _withoutHeaderIgnoreCase(headers, 'range'),
      timeout: remaining,
    );
  }

  Future<_PlayableProbeResponse> _sendPlayableProbeOnce(
    http.Client client,
    Uri requestUri,
    Map<String, String> headers, {
    required Duration timeout,
  }) async {
    final drpyPublicOnly = _requiresDrpyPublicMediaProbe;
    final abortTrigger = Completer<void>();
    void abort() {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    }

    final cancellationToken =
        _activeRulePlaybackResolveContext?.cancellationToken;
    final unregisterCancellation = cancellationToken?.register(abort);
    final operation = () async {
      final stopwatch = Stopwatch()..start();
      var currentUri = requestUri;
      var currentHeaders = headers;
      late http.StreamedResponse response;
      for (var redirect = 0; ; redirect++) {
        if (drpyPublicOnly) {
          await _drpyRuntime.ensurePublicUri(
            _proxyUpstreamUri(currentUri) ?? currentUri,
          );
        }
        final request =
            http.AbortableRequest(
                'GET',
                currentUri,
                abortTrigger: abortTrigger.future,
              )
              ..followRedirects = !drpyPublicOnly
              ..headers.addAll(currentHeaders);
        response = await client.send(request);
        final location = response.headers['location'];
        if (!drpyPublicOnly ||
            !_isHttpRedirect(response.statusCode) ||
            location == null ||
            location.trim().isEmpty) {
          break;
        }
        if (redirect >= _maxDrpyMediaRedirects) {
          final subscription = response.stream.listen(null);
          await subscription.cancel();
          throw const HttpException('drpy media redirect limit reached.');
        }
        final nextUri = currentUri.resolve(location.trim());
        await _drpyRuntime.ensurePublicUri(
          _proxyUpstreamUri(nextUri) ?? nextUri,
        );
        currentHeaders = _mediaChildHeaders(
          currentUri,
          nextUri,
          currentHeaders,
        );
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        currentUri = nextUri;
      }
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
      final readUnknownLength = targetBytes == null;
      var sampleComplete = false;
      try {
        // 清单读取到 EOF/上限；未知长度的二进制累计到最小嗅探量，
        // 既允许容器签名跨 chunk，也避免 Range 被忽略后持续下载。
        var firstChunk = true;
        while (sample.length < sampleLimit) {
          var idleTimedOut = false;
          final hasNext = firstChunk || !readUnknownLength
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
          if (targetBytes == null &&
              !manifestResponse &&
              sample.length >= _minimumBinaryProbeBytes) {
            break;
          }
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
    try {
      return await operation.timeout(
        timeout,
        onTimeout: () {
          abort();
          throw TimeoutException('Media probe timed out after $timeout.');
        },
      );
    } finally {
      unregisterCancellation?.call();
    }
  }
}

bool _isHttpRedirect(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;

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
    this.startupProfile = PlaybackStartupProfile.unknown,
    this.sizeBytes,
    this.sizeEstimated = false,
    this.videoWidth,
    this.videoHeight,
    this.bitrate,
    this.codecs,
    this.isLive = false,
    this.adaptive = false,
    this.variantUri,
    this.variants = const <_HlsProbeVariant>[],
    this.durationSeconds,
    this.sampleSegmentUri,
    this.sampleSegmentUris = const <Uri>[],
    this.segmentCandidates = const <_HlsProbeSegment>[],
    this.sampleSegmentDurationSeconds,
    this.dashResources = const <_DashProbeResource>[],
  });

  final String? format;
  final String startupProfile;
  final int? sizeBytes;
  final bool sizeEstimated;
  final int? videoWidth;
  final int? videoHeight;
  final int? bitrate;
  final String? codecs;
  final bool isLive;
  final bool adaptive;
  final Uri? variantUri;
  final List<_HlsProbeVariant> variants;
  final double? durationSeconds;
  final Uri? sampleSegmentUri;
  final List<Uri> sampleSegmentUris;
  final List<_HlsProbeSegment> segmentCandidates;
  final double? sampleSegmentDurationSeconds;
  final List<_DashProbeResource> dashResources;

  _ProbeMediaMetadata copyWith({
    String? startupProfile,
    int? sizeBytes,
    bool? sizeEstimated,
    bool? isLive,
    double? durationSeconds,
    Uri? sampleSegmentUri,
    List<Uri>? sampleSegmentUris,
    List<_HlsProbeSegment>? segmentCandidates,
    double? sampleSegmentDurationSeconds,
  }) {
    return _ProbeMediaMetadata(
      format: format,
      startupProfile: startupProfile ?? this.startupProfile,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sizeEstimated: sizeEstimated ?? this.sizeEstimated,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      bitrate: bitrate,
      codecs: codecs,
      isLive: isLive ?? this.isLive,
      adaptive: adaptive,
      variantUri: variantUri,
      variants: variants,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      sampleSegmentUri: sampleSegmentUri ?? this.sampleSegmentUri,
      sampleSegmentUris: sampleSegmentUris ?? this.sampleSegmentUris,
      segmentCandidates: segmentCandidates ?? this.segmentCandidates,
      sampleSegmentDurationSeconds:
          sampleSegmentDurationSeconds ?? this.sampleSegmentDurationSeconds,
      dashResources: dashResources,
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
    ).copyWith(startupProfile: PlaybackStartupProfile.hls);
  }
  if (format == 'DASH') return _dashProbeMetadata(sourceUri, text);

  final dimensions = format == 'MP4'
      ? _mp4Dimensions(sample.sample) ?? _resolutionDimensionsForUrl(sourceUri)
      : _resolutionDimensionsForUrl(sourceUri);
  return _ProbeMediaMetadata(
    format: format,
    startupProfile: format == 'MP4'
        ? _mp4StartupProfile(sample.sample)
        : PlaybackStartupProfile.unknown,
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
  if (trimmed.startsWith('#EXTM3U')) {
    return 'HLS';
  }
  if (trimmed.startsWith('<MPD') || trimmed.contains('<MPD ')) {
    return 'DASH';
  }
  if (contentType.contains('mpegurl')) return 'HLS';
  if (contentType.contains('dash+xml')) return 'DASH';
  if (contentType.contains('video/mp4')) {
    return 'MP4';
  }
  if (contentType.contains('webm')) {
    return 'WebM';
  }
  if (contentType.contains('x-flv')) {
    return 'FLV';
  }
  if (contentType.contains('matroska')) {
    return 'MKV';
  }
  if (_hlsExtensionPattern.hasMatch(lowerUrl)) return 'HLS';
  if (_dashExtensionPattern.hasMatch(lowerUrl)) return 'DASH';
  if (_mp4ExtensionPattern.hasMatch(lowerUrl)) return 'MP4';
  if (_webmExtensionPattern.hasMatch(lowerUrl)) return 'WebM';
  if (_flvExtensionPattern.hasMatch(lowerUrl)) return 'FLV';
  if (_mkvExtensionPattern.hasMatch(lowerUrl)) return 'MKV';
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

Uri? _safeHttpPlaylistReference(Uri playlistUri, String rawReference) {
  try {
    final resolved = _resolvePlaylistReference(playlistUri, rawReference);
    final upstream = _proxyUpstreamUri(resolved) ?? resolved;
    if (!const {'http', 'https'}.contains(upstream.scheme.toLowerCase()) ||
        upstream.host.isEmpty) {
      return null;
    }
    return resolved;
  } catch (_) {
    return null;
  }
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
    final variantUri = _safeHttpPlaylistReference(sourceUri, uriText);
    if (variantUri != null) {
      variants.add(
        _HlsProbeVariant(
          uri: variantUri,
          width: dimensions?.width,
          height: dimensions?.height,
          bitrate:
              int.tryParse(attributes['AVERAGE-BANDWIDTH'] ?? '') ??
              int.tryParse(attributes['BANDWIDTH'] ?? ''),
          codecs: attributes['CODECS'],
        ),
      );
    }
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
      variants: List<_HlsProbeVariant>.unmodifiable(variants),
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
  final sampleSegmentUris = <Uri>[];
  final segmentCandidates = <_HlsProbeSegment>[];
  double? sampleSegmentDurationSeconds;
  double? pendingDuration;
  int? pendingByteRangeBytes;
  String? encryptionMethod;
  Uri? encryptionKeyUri;
  for (final line in lines) {
    if (line.startsWith('#EXTINF:')) {
      pendingDuration = double.tryParse(
        line.substring('#EXTINF:'.length).split(',').first,
      );
      continue;
    }
    if (line.startsWith('#EXT-X-KEY:')) {
      final attributes = _parseHlsAttributes(
        line.substring(line.indexOf(':') + 1),
      );
      final method = attributes['METHOD']?.trim().toUpperCase();
      if (method == null || method.isEmpty || method == 'NONE') {
        encryptionMethod = null;
        encryptionKeyUri = null;
      } else {
        encryptionMethod = method;
        final rawKeyUri = attributes['URI']?.trim();
        encryptionKeyUri = rawKeyUri == null || rawKeyUri.isEmpty
            ? null
            : _safeHttpPlaylistReference(sourceUri, rawKeyUri);
      }
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
    final segmentUri = _safeHttpPlaylistReference(sourceUri, line);
    if (segmentUri != null) {
      sampleSegmentUris.add(segmentUri);
      segmentCandidates.add(
        _HlsProbeSegment(
          uri: segmentUri,
          encryptionMethod: encryptionMethod,
          keyUri: encryptionKeyUri,
        ),
      );
    }
    sampleSegmentDurationSeconds ??= pendingDuration;
    pendingDuration = null;
    pendingByteRangeBytes = null;
  }
  final hasExactByteRangeTotal =
      mediaSegmentCount > 0 &&
      rangedMediaSegmentCount == mediaSegmentCount &&
      byteRangeBytes > 0;
  final dimensions = _resolutionDimensionsForUrl(sourceUri);
  final orderedSegmentUris = hasEndList
      ? sampleSegmentUris
      : sampleSegmentUris.reversed.toList(growable: false);
  final orderedSegmentCandidates = hasEndList
      ? segmentCandidates
      : segmentCandidates.reversed.toList(growable: false);
  sampleSegmentUri = _firstOrNull(orderedSegmentUris);
  return _ProbeMediaMetadata(
    format: 'HLS',
    sizeBytes: hasEndList && hasExactByteRangeTotal ? byteRangeBytes : null,
    videoWidth: dimensions?.width,
    videoHeight: dimensions?.height,
    isLive: sampleComplete && !hasEndList,
    durationSeconds: hasEndList && durationSeconds > 0 ? durationSeconds : null,
    sampleSegmentUri: sampleSegmentUri,
    sampleSegmentUris: List<Uri>.unmodifiable(orderedSegmentUris),
    segmentCandidates: List<_HlsProbeSegment>.unmodifiable(
      orderedSegmentCandidates,
    ),
    sampleSegmentDurationSeconds: sampleSegmentDurationSeconds,
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
    final resources = selected == null
        ? const <_DashProbeResource>[]
        : _dashProbeResources(sourceUri, selected);
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
      dashResources: resources,
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

List<_DashProbeResource> _dashProbeResources(
  Uri manifestUri,
  XmlElement representation,
) {
  final resources = <_DashProbeResource>[];
  final baseUri = _dashRepresentationBaseUri(manifestUri, representation);
  final templateAttributes = _dashSegmentTemplateAttributes(representation);
  if (templateAttributes.isNotEmpty) {
    final initialization = _dashExpandTemplate(
      templateAttributes['initialization'],
      representation,
      templateAttributes,
    );
    final media = _dashExpandTemplate(
      templateAttributes['media'],
      representation,
      templateAttributes,
    );
    final initializationUri = initialization == null
        ? null
        : _safeHttpPlaylistReference(baseUri, initialization);
    final mediaUri = media == null
        ? null
        : _safeHttpPlaylistReference(baseUri, media);
    if (initializationUri != null) {
      resources.add(_DashProbeResource(initializationUri, '初始化分片'));
    }
    if (mediaUri != null && mediaUri != initializationUri) {
      resources.add(_DashProbeResource(mediaUri, '媒体分片'));
    }
  }

  if (resources.isEmpty) {
    final segmentList = _dashInheritedChild(representation, 'SegmentList');
    if (segmentList != null) {
      final initialization = _xmlDirectChild(segmentList, 'Initialization');
      final initializationSource = initialization?.getAttribute('sourceURL');
      final initializationUri = initializationSource == null
          ? null
          : _safeHttpPlaylistReference(baseUri, initializationSource);
      if (initializationUri != null) {
        resources.add(_DashProbeResource(initializationUri, '初始化分片'));
      }
      final firstSegment = _firstOrNull(
        _xmlDirectChildren(segmentList, 'SegmentURL'),
      );
      final mediaSource = firstSegment?.getAttribute('media');
      final mediaUri = mediaSource == null
          ? null
          : _safeHttpPlaylistReference(baseUri, mediaSource);
      if (mediaUri != null && mediaUri != initializationUri) {
        resources.add(_DashProbeResource(mediaUri, '媒体分片'));
      }
    }
  }

  if (resources.isEmpty) {
    final segmentBase = _dashInheritedChild(representation, 'SegmentBase');
    final directBase = _xmlDirectChild(representation, 'BaseURL');
    if (directBase != null || (segmentBase != null && baseUri != manifestUri)) {
      resources.add(_DashProbeResource(baseUri, '媒体文件'));
    }
  }
  return List<_DashProbeResource>.unmodifiable(resources);
}

Uri _dashRepresentationBaseUri(Uri manifestUri, XmlElement representation) {
  final hierarchy = <XmlElement>[];
  XmlNode? current = representation;
  while (current is XmlElement) {
    hierarchy.add(current);
    current = current.parent;
  }
  var result = manifestUri;
  for (final element in hierarchy.reversed) {
    final baseText = _xmlDirectChild(element, 'BaseURL')?.innerText.trim();
    if (baseText != null && baseText.isNotEmpty) {
      result = _safeHttpPlaylistReference(result, baseText) ?? result;
    }
  }
  return result;
}

Map<String, String> _dashSegmentTemplateAttributes(XmlElement representation) {
  final hierarchy = <XmlElement>[];
  XmlNode? current = representation;
  while (current is XmlElement) {
    hierarchy.add(current);
    current = current.parent;
  }
  final result = <String, String>{};
  XmlElement? timelineSource;
  for (final element in hierarchy.reversed) {
    final template = _xmlDirectChild(element, 'SegmentTemplate');
    if (template == null) continue;
    for (final attribute in template.attributes) {
      result[attribute.name.local] = attribute.value;
    }
    if (_xmlDirectChild(template, 'SegmentTimeline') != null) {
      timelineSource = template;
    }
  }
  final timeline = timelineSource == null
      ? null
      : _xmlDirectChild(timelineSource, 'SegmentTimeline');
  final firstTimelineEntry = timeline == null
      ? null
      : _firstOrNull(_xmlDirectChildren(timeline, 'S'));
  final timelineStart = firstTimelineEntry?.getAttribute('t');
  if (timelineStart != null && timelineStart.isNotEmpty) {
    result['_firstTime'] = timelineStart;
  }
  return result;
}

String? _dashExpandTemplate(
  String? template,
  XmlElement representation,
  Map<String, String> attributes,
) {
  if (template == null || template.trim().isEmpty) return null;
  var result = template.trim();
  final representationId = representation.getAttribute('id') ?? '';
  final bandwidth =
      representation.getAttribute('bandwidth') ??
      _xmlInheritedAttribute(representation, 'bandwidth') ??
      '';
  result = result
      .replaceAll(r'$RepresentationID$', representationId)
      .replaceAll(r'$Bandwidth$', bandwidth);
  final number = int.tryParse(attributes['startNumber'] ?? '') ?? 1;
  result = result.replaceAllMapped(RegExp(r'\$Number(?:%0(\d+)d)?\$'), (match) {
    final width = int.tryParse(match.group(1) ?? '') ?? 0;
    return width <= 0 ? '$number' : number.toString().padLeft(width, '0');
  });
  if (result.contains(r'$Time$')) {
    final firstTime = attributes['_firstTime'];
    if (firstTime == null || firstTime.isEmpty) return null;
    result = result.replaceAll(r'$Time$', firstTime);
  }
  return result.replaceAll(r'$$', r'$');
}

XmlElement? _dashInheritedChild(XmlElement element, String localName) {
  XmlNode? current = element;
  while (current is XmlElement) {
    final child = _xmlDirectChild(current, localName);
    if (child != null) return child;
    current = current.parent;
  }
  return null;
}

XmlElement? _xmlDirectChild(XmlElement element, String localName) {
  for (final child in element.childElements) {
    if (child.name.local == localName) return child;
  }
  return null;
}

List<XmlElement> _xmlDirectChildren(XmlElement element, String localName) {
  return element.childElements
      .where((child) => child.name.local == localName)
      .toList(growable: false);
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

class _HlsProbeSegment {
  const _HlsProbeSegment({
    required this.uri,
    this.encryptionMethod,
    this.keyUri,
  });

  final Uri uri;
  final String? encryptionMethod;
  final Uri? keyUri;

  bool get usesAes128 => encryptionMethod?.toUpperCase() == 'AES-128';
}

class _DashProbeResource {
  const _DashProbeResource(this.uri, this.label);

  final Uri uri;
  final String label;
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
    this.startupProfile = PlaybackStartupProfile.unknown,
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
  final String startupProfile;
  final int? sizeBytes;
  final bool sizeEstimated;
  final int? videoWidth;
  final int? videoHeight;
  final int? bitrate;
  final String? codecs;
  final bool isLive;
  final bool adaptive;
}

PlaybackLine _copyPlaybackLineWithProbe(
  PlaybackLine line,
  _PlayableProbeResult probe,
) {
  final detectedFormat = probe.format?.trim() ?? '';
  return PlaybackLine(
    id: line.id,
    episodeId: line.episodeId,
    providerId: line.providerId,
    providerName: line.providerName,
    title: line.title,
    quality: line.quality,
    format: detectedFormat.isEmpty ? line.format : detectedFormat,
    url: line.url,
    headers: line.headers,
    latency: probe.latency ?? line.latency,
    sizeLabel: line.sizeLabel,
    sizeBytes: probe.sizeBytes ?? line.sizeBytes,
    sizeEstimated: probe.sizeBytes == null
        ? line.sizeEstimated
        : probe.sizeEstimated,
    videoWidth: probe.videoWidth ?? line.videoWidth,
    videoHeight: probe.videoHeight ?? line.videoHeight,
    bitrate: probe.bitrate ?? line.bitrate,
    codecs: probe.codecs ?? line.codecs,
    isLive: probe.available ? probe.isLive || line.isLive : line.isLive,
    adaptive: probe.available ? probe.adaptive || line.adaptive : line.adaptive,
    publicHttpOnly: line.publicHttpOnly,
    serverVerified: line.serverVerified,
    requiresClientProbe: false,
    clientVerified: probe.available || line.clientVerified,
    startupProfile:
        probe.available &&
            probe.startupProfile != PlaybackStartupProfile.unknown
        ? probe.startupProfile
        : line.startupProfile,
    cacheState: line.cacheState,
    sourceErrorCategory: line.sourceErrorCategory,
    expiresAt: line.expiresAt,
    available: probe.available,
    message: probe.available ? line.message : probe.message,
  );
}

_PlayableProbeResult _validatePlayableSample(
  Uri sourceUri,
  _PlayableProbeResponse sample,
) {
  final bytes = sample.sample;
  final rawContentType =
      sample.response.headers['content-type']?.toLowerCase() ?? '';
  final contentType = rawContentType.split(';').first.trim();
  final text = utf8.decode(bytes, allowMalformed: true);
  final trimmed = text.trimLeft();
  if (bytes.isEmpty) {
    return const _PlayableProbeResult(false, '视频地址返回了空内容。');
  }
  final lowerText = trimmed.toLowerCase();
  final looksLikeHtml =
      lowerText.startsWith('<!doctype html') ||
      lowerText.startsWith('<html') ||
      lowerText.startsWith('<head') ||
      lowerText.startsWith('<body') ||
      lowerText.contains('<html');
  if (looksLikeHtml) {
    return const _PlayableProbeResult(false, '视频地址返回的是网页或错误信息，不是媒体内容。');
  }

  final format = _detectedMediaFormat(sourceUri, rawContentType, text);
  if (format == 'HLS') {
    final manifestLines = trimmed
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .toList(growable: false);
    final hasHeader =
        manifestLines.isNotEmpty && manifestLines.first == '#EXTM3U';
    final hasMediaReference = manifestLines.any(
      (line) => line.isNotEmpty && !line.startsWith('#'),
    );
    if (!hasHeader || !hasMediaReference) {
      return const _PlayableProbeResult(false, '视频地址返回的 HLS 清单无效或没有媒体分片。');
    }
    return const _PlayableProbeResult(true, '');
  }
  if (format == 'DASH') {
    try {
      final document = XmlDocument.parse(trimmed);
      if (document.rootElement.name.local != 'MPD') {
        return const _PlayableProbeResult(false, '视频地址返回的 DASH 清单无效。');
      }
    } catch (_) {
      return const _PlayableProbeResult(false, '视频地址返回的 DASH 清单无效。');
    }
    return const _PlayableProbeResult(true, '');
  }

  final hasMp4Signature = _hasIsoBmffSignature(bytes);
  final hasEbmlSignature = _sampleStartsWith(bytes, const [
    0x1A,
    0x45,
    0xDF,
    0xA3,
  ]);
  final hasFlvSignature = _sampleStartsWith(bytes, const [0x46, 0x4C, 0x56]);
  final hasTransportStreamSignature = _hasMpegTransportStreamSignature(bytes);
  final binaryMediaSignature =
      hasMp4Signature ||
      hasEbmlSignature ||
      hasFlvSignature ||
      hasTransportStreamSignature;

  if (format == 'MP4') {
    return hasMp4Signature
        ? const _PlayableProbeResult(true, '')
        : const _PlayableProbeResult(false, '视频地址没有返回有效的 MP4 数据。');
  }
  if (format == 'WebM' || format == 'MKV') {
    return hasEbmlSignature
        ? const _PlayableProbeResult(true, '')
        : const _PlayableProbeResult(false, '视频地址没有返回有效的视频容器数据。');
  }
  if (format == 'FLV') {
    return hasFlvSignature
        ? const _PlayableProbeResult(true, '')
        : const _PlayableProbeResult(false, '视频地址没有返回有效的 FLV 数据。');
  }
  if (binaryMediaSignature) {
    return const _PlayableProbeResult(true, '');
  }

  final looksLikeStructuredError =
      contentType.contains('json') ||
      contentType.contains('xml') ||
      lowerText.startsWith('{') ||
      lowerText.startsWith('[') ||
      lowerText.startsWith('<?xml');
  if (contentType.contains('text/html') || looksLikeStructuredError) {
    return const _PlayableProbeResult(false, '视频地址返回的是网页或错误信息，不是媒体内容。');
  }
  return const _PlayableProbeResult(false, '视频地址没有返回可识别的媒体内容。');
}

bool _sampleStartsWith(List<int> bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return false;
  }
  return true;
}

bool _isOpaqueEncryptedHlsSegment(_PlayableProbeResponse sample) {
  final bytes = sample.sample;
  if (bytes.length < 16) return false;
  final contentType =
      sample.response.headers['content-type']?.toLowerCase() ?? '';
  if (contentType.contains('text/') ||
      contentType.contains('json') ||
      contentType.contains('xml')) {
    return false;
  }
  final prefix = utf8
      .decode(bytes.take(512).toList(growable: false), allowMalformed: true)
      .trimLeft()
      .toLowerCase();
  if (prefix.startsWith('<!doctype') ||
      prefix.startsWith('<html') ||
      prefix.startsWith('{') ||
      prefix.startsWith('[') ||
      prefix.contains('access denied') ||
      prefix.contains('not found')) {
    return false;
  }
  final sampled = bytes.take(512).toList(growable: false);
  final printable = sampled.where((value) {
    return value == 9 ||
        value == 10 ||
        value == 13 ||
        (value >= 32 && value <= 126);
  }).length;
  return printable / sampled.length < 0.85;
}

bool _hasIsoBmffSignature(List<int> bytes) {
  var offset = 0;
  final limit = bytes.length < 64 ? bytes.length : 64;
  while (offset + 8 <= limit) {
    final size =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final type = String.fromCharCodes(bytes.skip(offset + 4).take(4));
    final plausibleSize =
        size == 0 || size == 1 || (size >= 8 && size <= 64 * 1024 * 1024);
    if (plausibleSize && const {'ftyp', 'styp', 'moof'}.contains(type)) {
      return true;
    }
    if (size < 8 || size > limit - offset) break;
    offset += size;
  }
  return false;
}

String _mp4StartupProfile(List<int> bytes) {
  var offset = 0;
  var sawMoov = false;
  var sawMdat = false;
  while (offset + 8 <= bytes.length) {
    var size = _readBigEndianUint32(bytes, offset);
    final type = String.fromCharCodes(bytes.skip(offset + 4).take(4));
    var headerSize = 8;
    if (size == 1) {
      if (offset + 16 > bytes.length) break;
      size = _readBigEndianUint64(bytes, offset + 8);
      headerSize = 16;
    }
    // styp/moof identifies fragmented ISO-BMFF. It does not prove that a
    // classic MP4 stores its moov box at the tail.
    if (type == 'styp' || type == 'moof') {
      return PlaybackStartupProfile.unknown;
    }
    if (type == 'moov') {
      if (sawMdat) return PlaybackStartupProfile.mp4TailMoov;
      sawMoov = true;
    }
    if (type == 'mdat') {
      if (sawMoov) return PlaybackStartupProfile.mp4FastStart;
      sawMdat = true;
    }
    if (size == 0 || size < headerSize) break;
    final nextOffset = offset + size;
    if (nextOffset <= offset || nextOffset > bytes.length) break;
    offset = nextOffset;
  }
  return PlaybackStartupProfile.unknown;
}

int _readBigEndianUint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readBigEndianUint64(List<int> bytes, int offset) =>
    (_readBigEndianUint32(bytes, offset) << 32) |
    _readBigEndianUint32(bytes, offset + 4);

bool _hasMpegTransportStreamSignature(List<int> bytes) {
  for (final stride in const <int>[188, 192, 204]) {
    final maxStart = stride < 32 ? stride : 32;
    for (var start = 0; start < maxStart; start++) {
      final second = start + stride;
      if (second >= bytes.length ||
          bytes[start] != 0x47 ||
          bytes[second] != 0x47) {
        continue;
      }
      final third = second + stride;
      if (third < bytes.length && bytes[third] != 0x47) continue;
      return true;
    }
  }
  return false;
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

String _aikanbotToken(String videoId, String encryptedToken) {
  if (videoId.length < 4 || encryptedToken.isEmpty) return '';
  var remaining = encryptedToken;
  final chunks = <String>[];
  for (final digit in videoId.substring(videoId.length - 4).codeUnits) {
    if (digit < 48 || digit > 57) return '';
    final offset = (digit - 48) % 3 + 1;
    if (remaining.length < offset + 8) return '';
    chunks.add(remaining.substring(offset, offset + 8));
    remaining = remaining.substring(offset + 8);
  }
  return chunks.join();
}

String? _aikanbotEpisodeUrl(Object? raw, int episodeNumber) {
  if (raw is! String || raw.trim().isEmpty || episodeNumber < 1) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  for (final group in decoded) {
    if (group is! Map) continue;
    final entries = group['url']?.toString().split('#') ?? const <String>[];
    if (episodeNumber > entries.length) continue;
    final pair = entries[episodeNumber - 1].split(r'$');
    if (pair.length < 2) continue;
    final url = pair.sublist(1).join(r'$').trim();
    if (_looksPlayable(url)) return url;
  }
  return null;
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

Future<List<PlaybackLine>> _collectPlaybackCandidates(
  List<Future<PlaybackLine?> Function()> requests, {
  required bool verifyPlayable,
  Duration candidateTimeout = const Duration(seconds: 10),
  bool Function(PlaybackLine line)? preferredQuickCandidate,
  Duration preferredCandidateGrace = Duration.zero,
}) async {
  if (requests.isEmpty) return const [];
  if (verifyPlayable) {
    return (await Future.wait(
      requests.map((start) async {
        try {
          return await start().timeout(candidateTimeout);
        } catch (_) {
          // Keep verified siblings when one playback road is slow or broken.
          return null;
        }
      }),
    )).whereType<PlaybackLine>().toList(growable: false);
  }

  // The startup lookup only needs one usable route. Waiting for every road in
  // the same rule made one slow play page hold back faster siblings and often
  // pushed the whole rule beyond the outer quick-lookup budget. Start at most
  // three roads and stop dispatching new ones as soon as a playable line wins.
  const concurrency = 3;
  final completer = Completer<List<PlaybackLine>>();
  PlaybackLine? firstUnavailable;
  PlaybackLine? fallbackAvailable;
  Timer? preferenceTimer;
  var nextIndex = 0;
  var active = 0;
  var completed = 0;

  void completeWith(PlaybackLine line) {
    if (completer.isCompleted) return;
    preferenceTimer?.cancel();
    completer.complete(<PlaybackLine>[line]);
  }

  late void Function() dispatch;

  Future<void> run(Future<PlaybackLine?> Function() start) async {
    try {
      final line = await start();
      if (line != null && line.available && !completer.isCompleted) {
        final prefers = preferredQuickCandidate;
        if (prefers == null || prefers(line)) {
          completeWith(line);
        } else {
          fallbackAvailable ??= line;
          if (preferredCandidateGrace <= Duration.zero) {
            completeWith(line);
          } else {
            preferenceTimer ??= Timer(preferredCandidateGrace, () {
              final fallback = fallbackAvailable;
              if (fallback != null) completeWith(fallback);
            });
          }
        }
      } else if (line != null) {
        firstUnavailable ??= line;
      }
    } catch (_) {
      // A failed road must not delay another road that is already playable.
    } finally {
      active--;
      completed++;
      if (!completer.isCompleted) {
        final fallback = fallbackAvailable;
        if (fallback != null) {
          // Once a usable fallback exists, do not start more roads. Give only
          // the already-running siblings a bounded chance to return the
          // preferred streaming format, then avoid a fixed grace delay when
          // every sibling has already completed.
          if (active == 0) completeWith(fallback);
        } else if (completed == requests.length) {
          final unavailable = firstUnavailable;
          completer.complete(
            unavailable == null
                ? const <PlaybackLine>[]
                : <PlaybackLine>[unavailable],
          );
        } else {
          dispatch();
        }
      }
    }
  }

  dispatch = () {
    while (!completer.isCompleted &&
        fallbackAvailable == null &&
        active < concurrency &&
        nextIndex < requests.length) {
      final start = requests[nextIndex++];
      active++;
      unawaited(run(start));
    }
  };

  dispatch();
  return completer.future;
}

bool _isHlsPlaybackLine(PlaybackLine line) =>
    line.format.trim().toUpperCase() == 'HLS' ||
    (line.url?.toLowerCase().contains('.m3u8') ?? false);

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

List<_SearchHit> _animekoJsonSearchHits(
  String body,
  String baseUrl,
  AnimekoWebSelectorConfig config,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  final names = _jsonPathValues(
    decoded,
    config.subjectJsonPathIndexed.selectNames,
  );
  final links = _jsonPathValues(
    decoded,
    config.subjectJsonPathIndexed.selectLinks,
  );
  final length = names.length < links.length ? names.length : links.length;
  return [
    for (var i = 0; i < length; i++)
      _SearchHit(
        title: _cleanText(names[i]),
        url: _absoluteUrl(links[i], baseUrl),
      ),
  ].where((item) => item.title.isNotEmpty && item.url.isNotEmpty).toList();
}

/// Minimal JSONPath reader that supports the dotted `$.a.b[*].field` shape used
/// by Animeko `json-path-indexed` sources. It intentionally avoids a full
/// JSONPath engine: only child access and the `[*]` wildcard are handled.
List<String> _jsonPathValues(Object? root, String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return const [];
  var expression = trimmed;
  if (expression.startsWith(r'$')) expression = expression.substring(1);
  expression = expression.replaceAll('[*]', '.[*]');
  final segments = expression
      .split('.')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();

  var current = <Object?>[root];
  for (final segment in segments) {
    final next = <Object?>[];
    if (segment == '[*]') {
      for (final node in current) {
        if (node is List) next.addAll(node);
      }
    } else {
      final key = segment.replaceAll(RegExp(r'''^['"]|['"]$'''), '');
      for (final node in current) {
        if (node is Map) next.add(node[key]);
      }
    }
    current = next;
    if (current.isEmpty) return const [];
  }

  return current
      .where((value) => value != null)
      .map((value) => value.toString().trim())
      .where((value) => value.isNotEmpty)
      .toList();
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

String _mergeCookieHeaders(String configured, String observed) {
  final cookies = <String, String>{};
  for (final header in [configured, observed]) {
    for (final pair in header.split(';')) {
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      if (name.isNotEmpty) cookies[name] = value;
    }
  }
  return cookies.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');
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
  final result = _withoutHeaderIgnoreCase(
    _withoutHeaderIgnoreCase(headers, 'accept'),
    'range',
  );
  result['Accept'] = '*/*';
  result['Range'] = 'bytes=0-$_initialProbeRangeEnd';
  return result;
}

Map<String, String> _manifestProbeHeaders(Map<String, String> headers) {
  return _withoutHeaderIgnoreCase(headers, 'range')
    ..['Range'] = 'bytes=0-${_maxManifestProbeSampleBytes - 1}';
}

Map<String, String> _withoutHeaderIgnoreCase(
  Map<String, String> headers,
  String name,
) {
  final normalized = name.toLowerCase();
  return {
    for (final entry in headers.entries)
      if (entry.key.toLowerCase() != normalized) entry.key: entry.value,
  };
}

const _originBoundMediaHeaders = <String>{
  'authorization',
  'proxy-authorization',
  'cookie',
  'cookie2',
  'api-key',
  'x-api-key',
  'access-token',
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

Map<String, String> _withoutOriginBoundMediaHeaders(
  Map<String, String> headers,
) => {
  for (final entry in headers.entries)
    if (!_originBoundMediaHeaders.contains(entry.key.toLowerCase()))
      entry.key: entry.value,
};

Map<String, String> _mediaChildHeaders(
  Uri credentialSourceUri,
  Uri childUri,
  Map<String, String> headers,
) {
  if (_sameMediaOrigin(credentialSourceUri, childUri)) return headers;
  return _withoutOriginBoundMediaHeaders(headers);
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
