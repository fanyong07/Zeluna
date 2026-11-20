import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../core/identity/stable_identity.dart';
import '../core/network/media_request_headers.dart';
import '../core/network/network_http_client.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import 'android_csp_bridge.dart';
import 'animeko_webview_sniffer.dart';
import 'csp_rule_support.dart';
import 'drpy_runtime.dart';
import 'rule_models.dart';
import 'kazumi_api.dart';
import 'rule_media_resolver.dart';
import 'rule_http_policy.dart';
import 'rule_page_client.dart';
import 'rule_playback_cancellation.dart';
import 'rule_security.dart';

// Preserve the existing public import surface for callers.
export 'rule_playback_cancellation.dart';
export 'rule_page_client.dart' show HttpException;
export 'rule_http_policy.dart'
    show ruleRequestUriForWebTest, ruleRequestHeadersForWebTest;

// Keep the resolver parts in one library so policy, state, and helpers stay private.
part 'playback_resolver/anime_site_apis.dart';
part 'playback_resolver/animeko.dart';
part 'playback_resolver/candidate_search.dart';
part 'playback_resolver/media_metadata.dart';
part 'playback_resolver/media_probe.dart';
part 'playback_resolver/page_sources.dart';
part 'playback_resolver/script_sources.dart';
part 'playback_resolver/tvbox_api.dart';

final Object _rulePlaybackResolveContextKey = Object();
final Object _drpyPublicMediaProbeKey = Object();

RulePageRequestScope? get _activeRulePlaybackResolveContext =>
    Zone.current[_rulePlaybackResolveContextKey] as RulePageRequestScope?;

bool get _requiresDrpyPublicMediaProbe =>
    Zone.current[_drpyPublicMediaProbeKey] == true;

class RulePlaybackResolver {
  RulePlaybackResolver({
    http.Client? client,
    http.Client? rulePublicClient,
    http.Client? drpyPublicClient,
    AndroidCspBridge? cspBridge,
    DrpyRuntime? drpyRuntime,
    AnimekoWebViewSniffer? animekoWebViewSniffer,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client,
       _rulePublicClient = rulePublicClient,
       _drpyPublicClient = drpyPublicClient,
       _cspBridge = cspBridge ?? AndroidCspBridge(),
       _drpyRuntime = drpyRuntime ?? DrpyRuntime(),
       _animekoWebViewSniffer =
           animekoWebViewSniffer ?? createAnimekoWebViewSniffer();

  static const _desktopUserAgent = defaultMediaUserAgent;

  final http.Client? _client;
  final http.Client? _rulePublicClient;
  final http.Client? _drpyPublicClient;
  final AndroidCspBridge _cspBridge;
  final DrpyRuntime _drpyRuntime;
  final AnimekoWebViewSniffer _animekoWebViewSniffer;
  final Duration timeout;
  late final _pages = RulePageClient(timeout: timeout);
  final Map<String, _TimedCacheEntry<_PlayableProbeResult>> _probeCache = {};
  final Map<String, Future<_PlayableProbeResult>> _probeRequests = {};
  // Keep one of the four wire slots for an explicit open/refresh. Inventory
  // expansion can enqueue dozens of slow candidates and must not delay the
  // selected route behind them. Total probe concurrency remains bounded.
  final _playableProbeLimiter = _AsyncLimiter(_maxConcurrentPlayableProbes - 1);
  final _foregroundProbeLimiter = _AsyncLimiter(1);
  final _metadataProbeLimiter = _AsyncLimiter(_maxConcurrentMetadataProbes);
  Future<AndroidCspCapabilities>? _cspCapabilitiesRequest;
  final Map<String, Future<void>> _cspPreparationRequests = {};
  var _cacheGeneration = 0;

  void clearCaches() {
    _cacheGeneration++;
    _pages.clearCaches();
    _probeCache.clear();
    _probeRequests.clear();
  }

  /// Retires account/context-owned script state as well as transient caches.
  /// Ordinary force refreshes must continue using [clearCaches] instead.
  void resetExecutionScope() {
    _drpyRuntime.resetExecutionScope();
    clearCaches();
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
    if (line.clientResolver != null) {
      return _resolveBackendChapter(
        line,
        enrichMetadata: enrichMetadata,
        forceRefresh: forceRefresh,
        cancellationToken: cancellationToken,
      );
    }
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

    final resolveContext = RulePageRequestScope(
      cancellationToken,
      rule: _activeRulePlaybackResolveContext?.rule,
    );
    return runZoned(() async {
      final injectedClient = line.publicHttpOnly
          ? _drpyPublicClient ?? _client
          : _client;
      final ownedClient = injectedClient == null;
      final client =
          injectedClient ??
          (line.publicHttpOnly
              ? _drpyRuntime.createPublicHttpClient()
              : createTrustedMediaProbeHttpClient());
      try {
        final headers = effectiveMediaRequestHeaders(line.headers);
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
          _PlayableProbeResult(
            false,
            _friendlyError(error),
            errorCategory: _probeFailureCategory(error),
          ),
        );
      } finally {
        if (ownedClient) client.close();
      }
    }, zoneValues: {_rulePlaybackResolveContextKey: resolveContext});
  }

  /// Resolve the backend's explicit chapter task without installing a rule or
  /// treating its HTML as playable. The resulting request must pass the same
  /// manifest/segment probe as all other client-side media candidates.
  Future<PlaybackLine> _resolveBackendChapter(
    PlaybackLine line, {
    required bool enrichMetadata,
    required bool forceRefresh,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final descriptor = line.clientResolver!;
    final manifest = RulePermissionManifest.official(
      id: 'backend:kazumi:${descriptor.ruleId}',
      name: descriptor.ruleName,
      version: '1',
      engine: 'backend-chapter',
      contentTypes: const ['anime'],
      pageDomains: descriptor.pageHosts,
      mediaDomains: descriptor.mediaHosts,
      javascript: true,
      webViewSniffing: true,
      cleartextHttp: descriptor.pageUrl.scheme == 'http',
      customReferer: true,
      customUserAgent: true,
    );
    final rule = RulePlugin(
      id: manifest.id,
      name: descriptor.ruleName,
      version: '1',
      source: RuleSourceKind.kazumi,
      contentType: RuleContentType.anime,
      engine: 'backend-chapter',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      qualityScore: 0,
      tags: const ['Kazumi'],
      baseUrl: descriptor.pageUrl.toString(),
      searchUrl: '',
      searchable: false,
      quickSearch: false,
      filterable: false,
      permissionManifest: manifest,
    );
    final injected = _rulePublicClient ?? _client;
    final client =
        injected ?? createUntrustedSourceHttpClient(timeout: timeout);
    final child = RulePlaybackCancellationToken();
    final unlink = cancellationToken?.register(child.cancel);
    final timer = Timer(timeout, child.cancel);
    final watch = Stopwatch()..start();
    Map<String, String> headersFor(Uri referer) => {
      'Referer': referer.toString(),
      'User-Agent': descriptor.userAgent.isEmpty
          ? _desktopUserAgent
          : descriptor.userAgent,
    };
    try {
      final resolved = await runZoned(
        () async {
          final body = await _get(
            client,
            descriptor.pageUrl,
            headersFor(descriptor.referer),
          );
          return RuleMediaResolver(
            readPage: (uri, headers) => _get(client, uri, headers),
            extract: _extractCurrentChapterMedia,
            headersFor: headersFor,
            sniffer: _animekoWebViewSniffer,
          ).resolve(
            page: descriptor.pageUrl,
            body: body,
            manifest: _effectiveScopeManifest(rule),
            cancellationToken: child,
            budget: timeout - watch.elapsed,
          );
        },
        zoneValues: {
          _rulePlaybackResolveContextKey: RulePageRequestScope(
            child,
            rule: rule,
          ),
        },
      ).timeout(timeout);
      if (cancellationToken?.isCancelled == true) return line;
      if (resolved == null || child.isCancelled) {
        return _copyPlaybackLineWithProbe(
          line,
          const _PlayableProbeResult(false, '本集章节尚未解析出媒体，请尝试其他线路。'),
        );
      }
      final candidate = PlaybackLine(
        id: line.id,
        episodeId: line.episodeId,
        providerId: line.providerId,
        providerName: line.providerName,
        title: line.title,
        quality: line.quality,
        format: 'auto',
        url: resolved.url,
        headers: resolved.headers,
        publicHttpOnly: true,
        requiresClientProbe: true,
        cacheState: line.cacheState,
        sourceName: line.sourceName,
        sourceInventoryId: line.sourceInventoryId,
        clientQuerySupported: line.clientQuerySupported,
        queryLocation: line.queryLocation == 'hybrid' ? 'hybrid' : 'local',
        sourceAddress: line.sourceAddress,
        diagnosticStatus: PlaybackDiscoveryStatus.clientProbeRequired,
        queried: line.queried,
        aliasesAttempted: line.aliasesAttempted,
        searchHitCount: line.searchHitCount,
        bestMatchScore: line.bestMatchScore,
        matched: true,
        episodeFound: true,
        discoveryElapsed: line.discoveryElapsed,
        expiresAt: line.expiresAt,
        message: '本集媒体已解析，等待本机清单和首段验证',
      );
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Chapter resolution budget exhausted.');
      }
      final verified = await runZoned(
        () => verifyPlaybackLine(
          line: candidate,
          enrichMetadata: enrichMetadata,
          forceRefresh: forceRefresh,
          cancellationToken: child,
        ),
        zoneValues: {
          _rulePlaybackResolveContextKey: RulePageRequestScope(
            child,
            rule: rule,
          ),
        },
      ).timeout(remaining);
      if (cancellationToken?.isCancelled == true) return line;
      if (child.isCancelled) {
        throw TimeoutException('Chapter verification budget exhausted.');
      }
      return verified;
    } catch (error) {
      if (cancellationToken?.isCancelled == true) return line;
      return _copyPlaybackLineWithProbe(
        line,
        _PlayableProbeResult(
          false,
          _friendlyError(error),
          errorCategory: _probeFailureCategory(error),
        ),
      );
    } finally {
      watch.stop();
      timer.cancel();
      unlink?.call();
      child.cancel();
      if (injected == null) client.close();
    }
  }

  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) return const [];
    final resolveContext = RulePageRequestScope(cancellationToken, rule: rule);
    return runZoned(() async {
      if (rule.requiresManualVerification || rule.unsupportedReason != null) {
        if (rule.engine.toLowerCase() == 'android-csp') return const [];
        return [
          _unavailableLine(
            rule,
            subject,
            episode,
            rule.unsupportedReason ?? '这个来源要先在网页里手动过验证。',
          ),
        ];
      }

      final isDrpy = rule.engine.toLowerCase() == 'drpy-js';
      final injectedClient = isDrpy
          ? _drpyPublicClient ?? _rulePublicClient ?? _client
          : _rulePublicClient ?? _client;
      final ownedClient = injectedClient == null;
      final client =
          injectedClient ??
          (isDrpy
              ? _drpyRuntime.createPublicHttpClient()
              : createUntrustedSourceHttpClient());
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
          _ => [_unavailableLine(rule, subject, episode, '这类来源暂时不支持。')],
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

  Future<String> _get(
    http.Client client,
    Uri url,
    Map<String, String> headers,
  ) => _pages.get(
    client,
    url,
    headers,
    scope: _activeRulePlaybackResolveContext,
  );

  Future<String> _post(
    http.Client client,
    Uri url,
    String body,
    Map<String, String> headers,
  ) => _pages.post(
    client,
    url,
    body,
    headers,
    scope: _activeRulePlaybackResolveContext,
  );

  RulePermissionManifest _effectiveScopeManifest(RulePlugin rule) {
    final manifest = rule.effectiveManifest;
    final extraDomains =
        _activeRulePlaybackResolveContext?.verifiedRedirectDomains;
    if (extraDomains == null || extraDomains.isEmpty) return manifest;
    return manifest.copyWith(
      pageDomains: [...manifest.pageDomains, ...extraDomains],
    );
  }

  void _ensureSandboxedRuleUri(Uri uri, RuleUrlPurpose purpose) {
    final scope = _activeRulePlaybackResolveContext;
    final rule = scope?.rule;
    if (rule == null) return;
    if (!RuleUrlPolicy(rule.effectiveManifest).allows(
      uri,
      purpose,
      extraAllowedPageDomains: scope?.verifiedRedirectDomains ?? const [],
    )) {
      throw StateError('这个来源想访问未授权的网站，已拦下。');
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
    String? routeKey,
  }) {
    final normalizedUrl = _normalizePlayableUrl(url, referer);
    final lineHeaders = headers ?? _headers(rule: rule, referer: referer);
    final episodeKey = episode.identityKey();
    final detectedQuality = _probeResolutionLabel(
      probe.videoWidth,
      probe.videoHeight,
    );
    return PlaybackLine(
      id: stablePlaybackLineKey(
        providerId: routeKey == null ? rule.id : '${rule.id}|route:$routeKey',
        episodeKey: episodeKey,
        uri: normalizedUrl,
        headers: lineHeaders,
      ),
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
      headers: lineHeaders,
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
      clientVerified: probe.available,
      startupProfile: probe.startupProfile,
      available: true,
      message: '可以播放。',
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
    String? routeKey,
  }) {
    final normalizedUrl = _normalizePlayableUrl(url, headers['Referer'] ?? '');
    final episodeKey = episode.identityKey();
    return PlaybackLine(
      // Keep the same logical id as the optimistic quick result so a failed
      // verified probe replaces it instead of leaving a stale playable row.
      id: stablePlaybackLineKey(
        providerId: routeKey == null ? rule.id : '${rule.id}|route:$routeKey',
        episodeKey: episodeKey,
        uri: normalizedUrl,
        headers: headers,
      ),
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
    final manifest = rule.effectiveManifest;
    for (final entry in filterRuleRequestHeaders(
      rule.requestHeaders,
      manifest,
    ).entries) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isNotEmpty && value.isNotEmpty) headers[name] = value;
    }
    if (manifest.customUserAgent && userAgent.trim().isNotEmpty) {
      headers['User-Agent'] = userAgent.trim();
    }
    final refererValue = referer?.trim();
    if (manifest.customReferer &&
        refererValue != null &&
        refererValue.isNotEmpty) {
      headers['Referer'] = refererValue;
    } else if (manifest.customReferer &&
        !headers.containsKey('Referer') &&
        rule.baseUrl.trim().isNotEmpty) {
      headers['Referer'] = rule.baseUrl;
    }
    return headers;
  }
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
    clientResolver: line.clientResolver,
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
    sourceErrorCategory: probe.available
        ? line.sourceErrorCategory
        : (probe.errorCategory.isEmpty
              ? 'media_unreachable'
              : probe.errorCategory),
    sourceName: line.sourceName,
    sourceInventoryId: line.sourceInventoryId,
    clientQuerySupported: line.clientQuerySupported,
    queryLocation: line.queryLocation,
    sourceAddress: line.sourceAddress,
    diagnosticStatus: line.clientResolver != null && !probe.available
        ? PlaybackDiscoveryStatus.routeUnavailable
        : const {'local', 'hybrid'}.contains(line.queryLocation) &&
              line.diagnosticStatus ==
                  PlaybackDiscoveryStatus.clientProbeRequired
        ? (probe.available
              ? PlaybackDiscoveryStatus.matched
              : PlaybackDiscoveryStatus.routeUnavailable)
        : line.diagnosticStatus,
    queried: line.queried,
    aliasesAttempted: line.aliasesAttempted,
    searchHitCount: line.searchHitCount,
    bestMatchScore: line.bestMatchScore,
    matched: line.matched,
    episodeFound: line.episodeFound,
    discoveryElapsed: line.discoveryElapsed,
    expiresAt: line.expiresAt,
    available: probe.available,
    message: probe.available
        ? (const {'local', 'hybrid'}.contains(line.queryLocation)
              ? '本机媒体探测通过；实际播放以播放器为准'
              : line.message)
        : probe.message,
  );
}

String _friendlyError(Object error) {
  if (error is StateError) return error.message;
  final text = error.toString();
  if (text.contains('TimeoutException')) return '解析超时，当前来源响应太慢。';
  if (text.contains('HTTP')) return '这个来源请求失败了。';
  if (text.contains('SocketException')) return '网络不可用，或这个来源连不上。';
  return '这个来源暂时用不了。';
}
