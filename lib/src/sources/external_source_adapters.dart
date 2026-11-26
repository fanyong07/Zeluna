import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../core/identity/stable_identity.dart';
import '../core/network/network_http_client.dart';
import '../domain/anime_models.dart';
import 'source_catalog_models.dart';
import 'source_proxy_uri.dart';

typedef SourceAdapterClock = DateTime Function();

/// A small, controller-friendly contract shared by runtime source adapters.
abstract interface class SourceSearchAdapter<T> {
  bool supports(VideoSource source);

  Future<SourceAdapterBatch<T>> search({
    required Iterable<VideoSource> sources,
    required String query,
    int limit = 60,
  });

  void clearCache();

  void close();
}

class SourceAdapterBatch<T> {
  const SourceAdapterBatch({this.items = const [], this.failures = const []});

  final List<T> items;
  final List<SourceAdapterFailure> failures;

  bool get hasFailures => failures.isNotEmpty;
}

class SourceAdapterFailure {
  const SourceAdapterFailure({
    required this.sourceId,
    required this.sourceName,
    required this.message,
  });

  final String sourceId;
  final String sourceName;
  final String message;
}

/// Conservative URL validation for catalog-controlled remote requests.
///
/// Redirects are checked again by the HTTP transport. Hostnames that resolve
/// to private addresses still need to be blocked by a production proxy; this
/// client-side guard prevents direct private literals and common local names.
class SourceUriPolicy {
  const SourceUriPolicy();

  bool isAllowed(Uri uri, {Set<String> allowedHosts = const {}}) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    if (!uri.hasAuthority || uri.host.trim().isEmpty) return false;
    if (uri.userInfo.isNotEmpty) return false;

    final host = _normalizedHost(uri.host);
    if (host.isEmpty || _isBlockedHost(host)) return false;
    if (allowedHosts.isNotEmpty) {
      final normalizedAllowed = allowedHosts.map(_normalizedHost).toSet();
      if (!normalizedAllowed.contains(host)) return false;
    }
    return true;
  }

  void ensureAllowed(Uri uri, {Set<String> allowedHosts = const {}}) {
    if (!isAllowed(uri, allowedHosts: allowedHosts)) {
      throw const SourceAdapterException('地址协议或主机不在允许范围内。');
    }
  }
}

class M3uChannel {
  const M3uChannel({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.name,
    required this.streamUri,
    this.group = '',
    this.tvgId = '',
    this.logoUrl,
    this.headers = const {},
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String name;
  final String group;
  final String tvgId;
  final String? logoUrl;
  final Uri streamUri;
  final Map<String, String> headers;

  bool get requiresExternalClient => false;

  String get subjectKey =>
      stableSubjectKey(source: 'm3u-channel:$sourceId', identifier: id);

  int get subjectId => stableInt63(subjectKey);

  int get episodeId => stableInt63(
    stableEpisodeKey(subjectKey: subjectKey, normalizedNumber: 1),
  );

  PlaybackLine toPlaybackLine({int? episodeId}) {
    return PlaybackLine(
      id: 'm3u:$sourceId:$id',
      episodeId: episodeId ?? this.episodeId,
      providerId: sourceId,
      providerName: sourceName,
      title: group.isEmpty ? name : '$name · $group',
      quality: '直播',
      format: _formatForStreamUri(streamUri),
      url: streamUri.toString(),
      headers: headers,
      isLive: true,
      available: true,
      message: '已从 M3U 解析直播地址，实际可用性会在打开时确认。',
    );
  }

  AnimeSubject toSubject() {
    final category = group.trim().isEmpty ? '直播' : group.trim();
    return AnimeSubject(
      id: subjectId,
      title: name,
      originalTitle: name,
      summary: group.trim().isEmpty
          ? '来自 $sourceName 的直播频道。'
          : '来自 $sourceName 的直播频道，分组：$group。',
      coverUrl: logoUrl,
      bannerUrl: null,
      date: null,
      platform: '直播',
      language: '未知',
      region: '未知',
      status: '直播',
      categories: [AnimeCategory(name: category)],
      tags: const [
        AnimeTag(name: '直播'),
        AnimeTag(name: 'M3U'),
      ],
      totalEpisodes: 1,
      source: 'm3u-channel:$sourceId:$id',
    );
  }

  AnimeEpisode toEpisode() {
    return AnimeEpisode(
      id: episodeId,
      subjectId: subjectId,
      number: 1,
      title: '直播',
      airdate: null,
      duration: '直播',
      description: group.trim().isEmpty ? name : '$name · $group',
      thumbnailUrl: logoUrl,
    );
  }

  AnimeDetailBundle toDetailBundle() {
    return AnimeDetailBundle(
      subject: toSubject(),
      episodes: [toEpisode()],
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }
}

class TorrentResource {
  const TorrentResource({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.title,
    required this.magnetUri,
    required this.infoHash,
    this.category = '',
    this.sizeLabel,
    this.publisher,
    this.postedAt,
    this.seeders,
    this.downloads,
    this.completions,
    this.detailUri,
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String category;
  final String? sizeLabel;
  final String? publisher;
  final DateTime? postedAt;
  final int? seeders;
  final int? downloads;
  final int? completions;
  final Uri magnetUri;
  final String infoHash;
  final Uri? detailUri;

  bool get requiresExternalClient => true;

  PlaybackLine toExternalPlaybackLine({required int episodeId}) {
    return PlaybackLine(
      id: 'external:$sourceId:$infoHash',
      episodeId: episodeId,
      providerId: sourceId,
      providerName: sourceName,
      title: title,
      quality: '外部资源',
      format: 'Magnet',
      url: magnetUri.toString(),
      sizeLabel: sizeLabel,
      available: false,
      message: 'BT/磁力资源需要交给外部客户端处理，内置播放器不会直接打开。',
    );
  }
}

class M3uPlaylistParser {
  const M3uPlaylistParser({
    this.uriPolicy = const SourceUriPolicy(),
    this.maxChannels = 5000,
  });

  final SourceUriPolicy uriPolicy;
  final int maxChannels;

  List<M3uChannel> parse({
    required VideoSource source,
    required Uri playlistUri,
    required String text,
  }) {
    final normalized = _stripBom(text);
    final lines = const LineSplitter().convert(normalized);
    final hasHeader = lines.any(
      (line) => line.trimLeft().toUpperCase().startsWith('#EXTM3U'),
    );
    if (!hasHeader) {
      throw const SourceAdapterException('返回内容不是有效的 M3U 播放列表。');
    }

    final channels = <M3uChannel>[];
    final seen = <String>{};
    _PendingM3uEntry? pending;
    var looseIndex = 0;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();
      if (upper.startsWith('#EXTINF:')) {
        pending = _parseExtInf(line);
        continue;
      }
      if (upper.startsWith('#EXTGRP:')) {
        final group = line.substring(line.indexOf(':') + 1).trim();
        if (pending != null && group.isNotEmpty) pending.group = group;
        continue;
      }
      if (upper.startsWith('#EXTVLCOPT:')) {
        if (pending != null) _applyVlcOption(pending.headers, line);
        continue;
      }
      if (upper.startsWith('#EXTHTTP:')) {
        if (pending != null) _applyExtHttp(pending.headers, line);
        continue;
      }
      if (line.startsWith('#')) continue;

      final split = _splitStreamUrlAndHeaders(line);
      final streamUri = _resolvePublicUri(split.url, playlistUri, uriPolicy);
      if (streamUri == null) {
        pending = null;
        continue;
      }

      final item = pending;
      final channelName = (item?.name ?? '').trim().isNotEmpty
          ? item!.name.trim()
          : (item?.attributes['tvg-name'] ?? '').trim().isNotEmpty
          ? item!.attributes['tvg-name']!.trim()
          : '频道 ${++looseIndex}';
      final group = (item?.group ?? item?.attributes['group-title'] ?? '')
          .trim();
      final tvgId = (item?.attributes['tvg-id'] ?? '').trim();
      final logo = _safeOptionalHttpUrl(
        item?.attributes['tvg-logo'],
        playlistUri,
        uriPolicy,
      );
      final identityKey = _m3uChannelIdentity(
        sourceId: source.id,
        tvgId: tvgId,
        name: channelName,
        group: group,
      );
      if (!seen.add(identityKey)) {
        pending = null;
        continue;
      }

      final headers = _sanitizeHeaders({
        ..._sourceHeadersForStream(source, streamUri),
        ...?item?.headers,
        ...split.headers,
      });
      channels.add(
        M3uChannel(
          id: _stableToken(identityKey),
          sourceId: source.id,
          sourceName: source.displayName,
          name: channelName,
          group: group,
          tvgId: tvgId,
          logoUrl: logo,
          streamUri: streamUri,
          headers: headers,
        ),
      );
      pending = null;
      if (channels.length >= maxChannels) break;
    }

    if (channels.isEmpty) {
      throw const SourceAdapterException('M3U 中没有可用的 HTTP/HTTPS 频道。');
    }
    return List.unmodifiable(channels);
  }
}

class M3uSourceAdapter implements SourceSearchAdapter<M3uChannel> {
  M3uSourceAdapter({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
    this.cacheTtl = const Duration(minutes: 20),
    this.failureTtl = const Duration(seconds: 30),
    this.maxPlaylistBytes = 5 * 1024 * 1024,
    this.uriPolicy = const SourceUriPolicy(),
    M3uPlaylistParser? parser,
    SourceAdapterClock? clock,
  }) : _client =
           client ??
           createUntrustedSourceHttpClient(
             maxResponseBytes: maxPlaylistBytes,
             timeout: timeout,
           ),
       _ownsClient = client == null,
       _parser = parser ?? M3uPlaylistParser(uriPolicy: uriPolicy),
       _cache = _TtlCache(clock: clock ?? DateTime.now, maxEntries: 48),
       _failureCache = _TtlCache(clock: clock ?? DateTime.now, maxEntries: 48);

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final Duration cacheTtl;
  final Duration failureTtl;
  final int maxPlaylistBytes;
  final SourceUriPolicy uriPolicy;
  final M3uPlaylistParser _parser;
  final _TtlCache<String, List<M3uChannel>> _cache;
  final _TtlCache<String, String> _failureCache;
  final Map<String, Future<List<M3uChannel>>> _inFlight = {};

  @override
  bool supports(VideoSource source) => source.kind == VideoSourceKind.liveM3u;

  @override
  Future<SourceAdapterBatch<M3uChannel>> search({
    required Iterable<VideoSource> sources,
    required String query,
    int limit = 60,
  }) async {
    final active = sources
        .where((source) => source.enabled && supports(source))
        .toList(growable: false);
    if (active.isEmpty) return const SourceAdapterBatch<M3uChannel>();

    final outcomes = await Future.wait([
      for (final source in active) _loadOutcome(source),
    ]);
    final failures = <SourceAdapterFailure>[];
    final scored = <_ScoredM3uChannel>[];
    final normalizedQuery = _normalizeSearchText(query);
    for (final outcome in outcomes) {
      if (outcome.failure != null) {
        failures.add(outcome.failure!);
        continue;
      }
      for (final channel in outcome.channels) {
        final score = _m3uSearchScore(channel, normalizedQuery);
        if (score >= 0) scored.add(_ScoredM3uChannel(channel, score));
      }
    }
    scored.sort((left, right) {
      final score = right.score.compareTo(left.score);
      if (score != 0) return score;
      final source = left.channel.sourceName.compareTo(
        right.channel.sourceName,
      );
      if (source != 0) return source;
      return left.channel.name.compareTo(right.channel.name);
    });
    final safeLimit = limit.clamp(1, 500);
    return SourceAdapterBatch(
      items: List.unmodifiable(
        scored.take(safeLimit).map((item) => item.channel),
      ),
      failures: List.unmodifiable(failures),
    );
  }

  Future<_M3uLoadOutcome> _loadOutcome(VideoSource source) async {
    try {
      return _M3uLoadOutcome(source: source, channels: await _load(source));
    } catch (error) {
      return _M3uLoadOutcome(
        source: source,
        failure: SourceAdapterFailure(
          sourceId: source.id,
          sourceName: source.displayName,
          message: _safeErrorMessage(error),
        ),
      );
    }
  }

  Future<M3uChannel?> resolveSubject({
    required Iterable<VideoSource> sources,
    required AnimeSubject subject,
  }) async {
    final marker = subject.source.trim();
    if (!marker.startsWith('m3u-channel:')) return null;

    for (final source in sources) {
      if (!source.enabled || !supports(source)) continue;
      final prefix = 'm3u-channel:${source.id}:';
      if (!marker.startsWith(prefix)) continue;
      final channelId = marker.substring(prefix.length).trim();
      if (channelId.isEmpty) return null;
      try {
        final channels = await _load(source);
        for (final channel in channels) {
          if (channel.id == channelId && channel.subjectId == subject.id) {
            return channel;
          }
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<List<M3uChannel>> _load(VideoSource source) {
    final key = _sourceCacheKey(source);
    final cached = _cache.get(key);
    if (cached != null) return Future.value(cached);
    final failed = _failureCache.get(key);
    if (failed != null) {
      return Future.error(SourceAdapterException(failed));
    }
    final existing = _inFlight[key];
    if (existing != null) return existing;

    late final Future<List<M3uChannel>> task;
    task = (() async {
      try {
        final uri = _sourceUri(source);
        uriPolicy.ensureAllowed(uri);
        final fetched =
            await _SafeTextFetcher(client: _client, uriPolicy: uriPolicy).get(
              uri,
              headers: _sanitizeHeaders(source.headers),
              timeout: timeout,
              maxBytes: maxPlaylistBytes,
              accept:
                  'application/vnd.apple.mpegurl,application/x-mpegURL,text/plain,*/*',
            );
        final channels = _parser.parse(
          source: source,
          playlistUri: fetched.finalUri,
          text: fetched.text,
        );
        _cache.set(key, channels, cacheTtl);
        _failureCache.remove(key);
        return channels;
      } catch (error) {
        final message = _safeErrorMessage(error);
        _failureCache.set(key, message, failureTtl);
        throw SourceAdapterException(message);
      } finally {
        _inFlight.remove(key);
      }
    })();
    _inFlight[key] = task;
    return task;
  }

  Uri _sourceUri(VideoSource source) {
    final value = source.importUrl.trim().isNotEmpty
        ? source.importUrl.trim()
        : source.baseUrl.trim();
    final uri = Uri.tryParse(value);
    if (uri == null) throw const SourceAdapterException('数据源地址格式不正确。');
    return uri;
  }

  String _sourceCacheKey(VideoSource source) {
    return '${source.id}|${source.importUrl}|${source.baseUrl}|'
        '${_headersCacheKey(source.headers)}';
  }

  @override
  void clearCache() {
    _cache.clear();
    _failureCache.clear();
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

class DmhySearchParser {
  const DmhySearchParser({this.uriPolicy = const SourceUriPolicy()});

  static const allowedHosts = {'dmhy.org', 'www.dmhy.org'};

  final SourceUriPolicy uriPolicy;

  List<TorrentResource> parse({
    required VideoSource source,
    required Uri searchUri,
    required String html,
  }) {
    final document = html_parser.parse(html);
    final rows = document.querySelectorAll('table#topic_list tbody tr');
    final results = <TorrentResource>[];
    final seen = <String>{};
    for (final row in rows) {
      final cells = row.querySelectorAll('td');
      final titleLink = row.querySelector('td.title a[href*="/topics/view/"]');
      final magnetLink = row.querySelector('a[href^="magnet:"]');
      final title = _cleanDomText(titleLink);
      final magnet = _validatedMagnet(magnetLink?.attributes['href']);
      if (title.isEmpty || magnet == null || !seen.add(magnet.infoHash)) {
        continue;
      }

      final detailUri = _safeDmhyDetailUri(
        titleLink?.attributes['href'],
        searchUri,
        uriPolicy,
      );
      results.add(
        TorrentResource(
          id: 'dmhy:${magnet.infoHash}',
          sourceId: source.id,
          sourceName: source.displayName,
          title: title,
          magnetUri: magnet.uri,
          infoHash: magnet.infoHash,
          category: cells.length > 1 ? _cleanDomText(cells[1]) : '',
          sizeLabel: cells.length > 4
              ? _blankToNull(_cleanDomText(cells[4]))
              : null,
          seeders: cells.length > 5
              ? _nullableCount(_cleanDomText(cells[5]))
              : null,
          downloads: cells.length > 6
              ? _nullableCount(_cleanDomText(cells[6]))
              : null,
          completions: cells.length > 7
              ? _nullableCount(_cleanDomText(cells[7]))
              : null,
          publisher: cells.length > 8
              ? _blankToNull(_cleanDomText(cells[8]))
              : null,
          postedAt: cells.isEmpty ? null : _dmhyDate(_cleanDomText(cells[0])),
          detailUri: detailUri,
        ),
      );
    }
    return List.unmodifiable(results);
  }
}

class DmhySourceAdapter implements SourceSearchAdapter<TorrentResource> {
  DmhySourceAdapter({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
    this.cacheTtl = const Duration(minutes: 3),
    this.failureTtl = const Duration(seconds: 30),
    this.maxResponseBytes = 4 * 1024 * 1024,
    this.uriPolicy = const SourceUriPolicy(),
    DmhySearchParser? parser,
    SourceAdapterClock? clock,
  }) : _client =
           client ??
           createUntrustedSourceHttpClient(
             maxResponseBytes: maxResponseBytes,
             timeout: timeout,
           ),
       _ownsClient = client == null,
       _parser = parser ?? DmhySearchParser(uriPolicy: uriPolicy),
       _cache = _TtlCache(clock: clock ?? DateTime.now, maxEntries: 64),
       _failureCache = _TtlCache(clock: clock ?? DateTime.now, maxEntries: 64);

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final Duration cacheTtl;
  final Duration failureTtl;
  final int maxResponseBytes;
  final SourceUriPolicy uriPolicy;
  final DmhySearchParser _parser;
  final _TtlCache<String, List<TorrentResource>> _cache;
  final _TtlCache<String, String> _failureCache;
  final Map<String, Future<List<TorrentResource>>> _inFlight = {};

  @override
  bool supports(VideoSource source) {
    if (source.kind != VideoSourceKind.torrent) return false;
    final site = source.rawConfig['site']?.toString().trim().toLowerCase();
    if (site == 'dmhy') return true;
    final uri = Uri.tryParse(source.baseUrl.trim());
    if (uri == null) return false;
    return DmhySearchParser.allowedHosts.contains(_normalizedHost(uri.host));
  }

  @override
  Future<SourceAdapterBatch<TorrentResource>> search({
    required Iterable<VideoSource> sources,
    required String query,
    int limit = 60,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const SourceAdapterBatch<TorrentResource>();
    if (keyword.length > 120) {
      return const SourceAdapterBatch<TorrentResource>(
        failures: [
          SourceAdapterFailure(
            sourceId: 'dmhy',
            sourceName: '动漫花园',
            message: '搜索关键词过长。',
          ),
        ],
      );
    }

    final active = sources
        .where(
          (source) => source.enabled && source.kind == VideoSourceKind.torrent,
        )
        .toList(growable: false);
    if (active.isEmpty) return const SourceAdapterBatch<TorrentResource>();

    final outcomes = await Future.wait([
      for (final source in active) _searchOutcome(source, keyword),
    ]);
    final failures = <SourceAdapterFailure>[];
    final unique = <String, TorrentResource>{};
    for (final outcome in outcomes) {
      if (outcome.failure != null) {
        failures.add(outcome.failure!);
        continue;
      }
      for (final item in outcome.items) {
        unique.putIfAbsent(item.infoHash, () => item);
      }
    }
    final safeLimit = limit.clamp(1, 200);
    return SourceAdapterBatch(
      items: List.unmodifiable(unique.values.take(safeLimit)),
      failures: List.unmodifiable(failures),
    );
  }

  Future<_TorrentLoadOutcome> _searchOutcome(
    VideoSource source,
    String keyword,
  ) async {
    if (!supports(source)) {
      return _TorrentLoadOutcome(
        source: source,
        failure: SourceAdapterFailure(
          sourceId: source.id,
          sourceName: source.displayName,
          message: '当前适配器只支持动漫花园公开检索。',
        ),
      );
    }
    try {
      return _TorrentLoadOutcome(
        source: source,
        items: await _searchSource(source, keyword),
      );
    } catch (error) {
      return _TorrentLoadOutcome(
        source: source,
        failure: SourceAdapterFailure(
          sourceId: source.id,
          sourceName: source.displayName,
          message: _safeErrorMessage(error),
        ),
      );
    }
  }

  Future<List<TorrentResource>> _searchSource(
    VideoSource source,
    String keyword,
  ) {
    final key = '${_sourceCacheKey(source)}|${_normalizeSearchText(keyword)}';
    final cached = _cache.get(key);
    if (cached != null) return Future.value(cached);
    final failed = _failureCache.get(key);
    if (failed != null) return Future.error(SourceAdapterException(failed));
    final existing = _inFlight[key];
    if (existing != null) return existing;

    late final Future<List<TorrentResource>> task;
    task = (() async {
      try {
        final uri = _dmhySearchUri(source, keyword);
        uriPolicy.ensureAllowed(
          uri,
          allowedHosts: DmhySearchParser.allowedHosts,
        );
        final fetched =
            await _SafeTextFetcher(client: _client, uriPolicy: uriPolicy).get(
              uri,
              allowedHosts: DmhySearchParser.allowedHosts,
              headers: _sanitizeHeaders({
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                    'AppleWebKit/537.36 Chrome/124 Safari/537.36',
                ...source.headers,
              }),
              timeout: timeout,
              maxBytes: maxResponseBytes,
              accept: 'text/html,application/xhtml+xml',
            );
        final items = _parser.parse(
          source: source,
          searchUri: fetched.finalUri,
          html: fetched.text,
        );
        _cache.set(key, items, cacheTtl);
        _failureCache.remove(key);
        return items;
      } catch (error) {
        final message = _safeErrorMessage(error);
        _failureCache.set(key, message, failureTtl);
        throw SourceAdapterException(message);
      } finally {
        _inFlight.remove(key);
      }
    })();
    _inFlight[key] = task;
    return task;
  }

  Uri _dmhySearchUri(VideoSource source, String keyword) {
    final template = source.endpoints['search']?.trim().isNotEmpty == true
        ? source.endpoints['search']!.trim()
        : source.rawConfig['searchUrl']?.toString().trim().isNotEmpty == true
        ? source.rawConfig['searchUrl'].toString().trim()
        : 'https://dmhy.org/topics/list?keyword={keyword}';
    if (template.contains('{keyword}')) {
      final uri = Uri.tryParse(
        template.replaceAll('{keyword}', Uri.encodeQueryComponent(keyword)),
      );
      if (uri == null) {
        throw const SourceAdapterException('BT 搜索地址格式不正确。');
      }
      return uri;
    }
    final base = Uri.tryParse(template);
    if (base == null) throw const SourceAdapterException('BT 搜索地址格式不正确。');
    return base.replace(
      queryParameters: {...base.queryParameters, 'keyword': keyword},
    );
  }

  String _sourceCacheKey(VideoSource source) {
    return '${source.id}|${source.baseUrl}|${source.endpoints['search']}|'
        '${_headersCacheKey(source.headers)}';
  }

  @override
  void clearCache() {
    _cache.clear();
    _failureCache.clear();
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

class SourceAdapterException implements Exception {
  const SourceAdapterException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _SafeTextFetcher {
  const _SafeTextFetcher({required this.client, required this.uriPolicy});

  final http.Client client;
  final SourceUriPolicy uriPolicy;

  Future<_FetchedSourceText> get(
    Uri initialUri, {
    required Duration timeout,
    required int maxBytes,
    required String accept,
    Map<String, String> headers = const {},
    Set<String> allowedHosts = const {},
  }) {
    return _getFollowingRedirects(
      initialUri,
      maxBytes: maxBytes,
      accept: accept,
      headers: headers,
      allowedHosts: allowedHosts,
    ).timeout(
      timeout,
      onTimeout: () => throw const SourceAdapterException('数据源请求超时。'),
    );
  }

  Future<_FetchedSourceText> _getFollowingRedirects(
    Uri initialUri, {
    required int maxBytes,
    required String accept,
    required Map<String, String> headers,
    required Set<String> allowedHosts,
  }) async {
    var current = initialUri;
    var requestHeaders = _sanitizeHeaders({'Accept': accept, ...headers});
    final usesSourceProxy =
        sourceProxyUri(initialUri, allowedHosts: allowedHosts) != initialUri;
    final proxySession = usesSourceProxy && headers.isNotEmpty
        ? await createSourceProxySession(
            target: initialUri,
            headers: headers,
            client: client,
          )
        : null;
    for (var redirectCount = 0; redirectCount <= 4; redirectCount++) {
      uriPolicy.ensureAllowed(current, allowedHosts: allowedHosts);
      final requestUri = sourceProxyUri(
        current,
        allowedHosts: allowedHosts,
        session: proxySession,
      );
      final usesProxy = requestUri != current;
      final request = http.Request('GET', requestUri)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll(
          usesProxy ? <String, String>{'Accept': accept} : requestHeaders,
        );
      final response = await client.send(request);
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        await _cancelResponse(response);
        if (location == null || location.trim().isEmpty) {
          throw const SourceAdapterException('数据源重定向缺少目标地址。');
        }
        if (redirectCount >= 4) {
          throw const SourceAdapterException('数据源重定向次数过多。');
        }
        final next = current.resolve(location.trim());
        if (current.origin != next.origin) {
          requestHeaders = _sourceRedirectHeaders(requestHeaders);
        }
        current = next;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final status = response.statusCode;
        await _cancelResponse(response);
        throw SourceAdapterException('数据源返回 HTTP $status。');
      }
      final contentLength = int.tryParse(
        response.headers['content-length'] ?? '',
      );
      if (contentLength != null && contentLength > maxBytes) {
        await _cancelResponse(response);
        throw const SourceAdapterException('数据源响应超过安全读取上限。');
      }
      final bytes = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response.stream) {
        total += chunk.length;
        if (total > maxBytes) {
          throw const SourceAdapterException('数据源响应超过安全读取上限。');
        }
        bytes.add(chunk);
      }
      var finalUri = current;
      if (usesProxy) {
        final reported = Uri.tryParse(
          response.headers['x-source-final-url']?.trim() ?? '',
        );
        if (reported != null) {
          uriPolicy.ensureAllowed(reported, allowedHosts: allowedHosts);
          finalUri = reported;
        }
      }
      return _FetchedSourceText(
        text: _decodeText(bytes.takeBytes()),
        finalUri: finalUri,
      );
    }
    throw const SourceAdapterException('数据源重定向次数过多。');
  }
}

class _FetchedSourceText {
  const _FetchedSourceText({required this.text, required this.finalUri});

  final String text;
  final Uri finalUri;
}

class _TtlCache<K, V> {
  _TtlCache({required SourceAdapterClock clock, required this.maxEntries})
    : _clock = clock;

  final SourceAdapterClock _clock;
  final int maxEntries;
  final LinkedHashMap<K, _CacheEntry<V>> _entries = LinkedHashMap();

  V? get(K key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (!_clock().isBefore(entry.expiresAt)) return null;
    _entries[key] = entry;
    return entry.value;
  }

  void set(K key, V value, Duration ttl) {
    _entries.remove(key);
    _entries[key] = _CacheEntry(value, _clock().add(ttl));
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(K key) => _entries.remove(key);

  void clear() => _entries.clear();
}

class _CacheEntry<T> {
  const _CacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;
}

class _PendingM3uEntry {
  _PendingM3uEntry({
    required this.name,
    required this.attributes,
    this.group = '',
  });

  final String name;
  final Map<String, String> attributes;
  final Map<String, String> headers = {};
  String group;
}

class _StreamUrlParts {
  const _StreamUrlParts(this.url, this.headers);

  final String url;
  final Map<String, String> headers;
}

class _ValidatedMagnet {
  const _ValidatedMagnet(this.uri, this.infoHash);

  final Uri uri;
  final String infoHash;
}

class _M3uLoadOutcome {
  const _M3uLoadOutcome({
    required this.source,
    this.channels = const [],
    this.failure,
  });

  final VideoSource source;
  final List<M3uChannel> channels;
  final SourceAdapterFailure? failure;
}

class _TorrentLoadOutcome {
  const _TorrentLoadOutcome({
    required this.source,
    this.items = const [],
    this.failure,
  });

  final VideoSource source;
  final List<TorrentResource> items;
  final SourceAdapterFailure? failure;
}

class _ScoredM3uChannel {
  const _ScoredM3uChannel(this.channel, this.score);

  final M3uChannel channel;
  final int score;
}

final RegExp _extInfAttributePattern = RegExp(
  r'''([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))''',
);

_PendingM3uEntry _parseExtInf(String line) {
  final comma = _unquotedCommaIndex(line);
  final metadata = comma < 0 ? line : line.substring(0, comma);
  final name = comma < 0 ? '' : line.substring(comma + 1).trim();
  final attributes = <String, String>{};
  for (final match in _extInfAttributePattern.allMatches(metadata)) {
    final key = match.group(1)?.toLowerCase();
    final value = match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
    if (key != null && key.isNotEmpty) attributes[key] = value.trim();
  }
  return _PendingM3uEntry(
    name: name,
    attributes: attributes,
    group: attributes['group-title'] ?? '',
  );
}

int _unquotedCommaIndex(String value) {
  var quote = '';
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if ((char == '"' || char == "'") && (quote.isEmpty || quote == char)) {
      quote = quote.isEmpty ? char : '';
    } else if (char == ',' && quote.isEmpty) {
      return index;
    }
  }
  return -1;
}

void _applyVlcOption(Map<String, String> headers, String line) {
  final value = line.substring(line.indexOf(':') + 1);
  final separator = value.indexOf('=');
  if (separator <= 0) return;
  final name = _canonicalHeaderName(value.substring(0, separator));
  final headerValue = value.substring(separator + 1).trim();
  if (name != null && _safeHeaderValue(headerValue)) {
    headers[name] = headerValue;
  }
}

void _applyExtHttp(Map<String, String> headers, String line) {
  final value = line.substring(line.indexOf(':') + 1).trim();
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      for (final entry in decoded.entries) {
        final name = _canonicalHeaderName(entry.key.toString());
        final headerValue = entry.value?.toString().trim() ?? '';
        if (name != null && _safeHeaderValue(headerValue)) {
          headers[name] = headerValue;
        }
      }
    }
  } catch (_) {
    // Ignore malformed optional per-channel headers.
  }
}

_StreamUrlParts _splitStreamUrlAndHeaders(String line) {
  final separator = line.indexOf('|');
  if (separator <= 0) return _StreamUrlParts(line.trim(), const {});
  final url = line.substring(0, separator).trim();
  final headers = <String, String>{};
  for (final pair in line.substring(separator + 1).split('&')) {
    final equals = pair.indexOf('=');
    if (equals <= 0) continue;
    final rawName = Uri.decodeQueryComponent(pair.substring(0, equals));
    final rawValue = Uri.decodeQueryComponent(pair.substring(equals + 1));
    final name = _canonicalHeaderName(rawName);
    if (name != null && _safeHeaderValue(rawValue)) headers[name] = rawValue;
  }
  return _StreamUrlParts(url, headers);
}

Uri? _resolvePublicUri(String value, Uri baseUri, SourceUriPolicy policy) {
  final text = value.trim();
  if (text.isEmpty) return null;
  try {
    final uri = baseUri.resolve(text);
    return policy.isAllowed(uri) ? uri : null;
  } catch (_) {
    return null;
  }
}

String? _safeOptionalHttpUrl(
  String? value,
  Uri baseUri,
  SourceUriPolicy policy,
) {
  if (value == null || value.trim().isEmpty) return null;
  return _resolvePublicUri(value, baseUri, policy)?.toString();
}

Map<String, String> _sanitizeHeaders(Map<String, String> headers) {
  final result = <String, String>{};
  for (final entry in headers.entries) {
    final name = _canonicalHeaderName(entry.key);
    final value = entry.value.trim();
    if (name != null && _safeHeaderValue(value)) result[name] = value;
  }
  return result;
}

Map<String, String> _sourceRedirectHeaders(Map<String, String> headers) {
  const safeAcrossOrigins = {
    'accept',
    'accept-language',
    'accept-encoding',
    'user-agent',
  };
  return {
    for (final entry in headers.entries)
      if (safeAcrossOrigins.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
  };
}

Map<String, String> _sourceHeadersForStream(VideoSource source, Uri streamUri) {
  final headers = _sanitizeHeaders(source.headers);
  final configuredUri = _configuredSourceUri(source);
  if (configuredUri != null && configuredUri.origin == streamUri.origin) {
    return headers;
  }
  return _sourceRedirectHeaders(headers);
}

Uri? _configuredSourceUri(VideoSource source) {
  final value = source.importUrl.trim().isNotEmpty
      ? source.importUrl.trim()
      : source.baseUrl.trim();
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme.toLowerCase() != 'http' &&
          uri.scheme.toLowerCase() != 'https')) {
    return null;
  }
  return uri;
}

String? _canonicalHeaderName(String value) {
  final normalized = value.trim().toLowerCase().replaceAll('_', '-');
  if (normalized.isEmpty ||
      !RegExp(r'^[a-z0-9-]+$').hasMatch(normalized) ||
      const {
        'host',
        'content-length',
        'connection',
        'transfer-encoding',
      }.contains(normalized)) {
    return null;
  }
  return switch (normalized) {
    'http-referrer' || 'referrer' || 'referer' => 'Referer',
    'http-user-agent' || 'user-agent' => 'User-Agent',
    'authorization' => 'Authorization',
    'cookie' => 'Cookie',
    'origin' => 'Origin',
    'accept' => 'Accept',
    'range' => 'Range',
    _ =>
      normalized
          .split('-')
          .map(
            (part) => part.isEmpty
                ? part
                : '${part[0].toUpperCase()}${part.substring(1)}',
          )
          .join('-'),
  };
}

bool _safeHeaderValue(String value) {
  return value.isNotEmpty && !value.contains('\r') && !value.contains('\n');
}

String _formatForStreamUri(Uri uri) {
  final text = uri.toString().toLowerCase();
  if (text.contains('.m3u8') || text.contains('type=m3u8')) return 'HLS';
  if (text.contains('.mp4')) return 'MP4';
  if (text.contains('.webm')) return 'WebM';
  if (text.contains('.flv')) return 'FLV';
  if (text.contains('.ts')) return 'MPEG-TS';
  return '直播流';
}

String _m3uChannelIdentity({
  required String sourceId,
  required String tvgId,
  required String name,
  required String group,
}) {
  final normalizedTvgId = _normalizeSearchText(tvgId);
  final normalizedName = _normalizeSearchText(name);
  final normalizedGroup = _normalizeSearchText(group);
  return '$sourceId|tvg:$normalizedTvgId|name:$normalizedName|'
      'group:$normalizedGroup';
}

int _m3uSearchScore(M3uChannel channel, String query) {
  if (query.isEmpty) return 0;
  final title = _normalizeSearchText(channel.name);
  final group = _normalizeSearchText(channel.group);
  final source = _normalizeSearchText(channel.sourceName);
  final tvgId = _normalizeSearchText(channel.tvgId);
  if (title == query) return 100;
  if (title.startsWith(query)) return 85;
  if (title.contains(query)) return 70;
  if (group.contains(query)) return 40;
  if (source.contains(query)) return 25;
  if (tvgId.contains(query)) return 15;
  return -1;
}

final RegExp _searchTextStripPattern = RegExp(
  r'[\s\p{P}\p{S}]+',
  unicode: true,
);

final RegExp _numericOrHexHostPattern = RegExp(r'^(?:0x[0-9a-f]+|\d+)$');
final RegExp _decimalOnlyPattern = RegExp(r'^\d+$');
final RegExp _decimalOrHexOctetPattern = RegExp(r'^(?:\d+|0x[0-9a-f]+)$');
final RegExp _hexGroupPattern = RegExp(r'^[0-9a-f]+$');
final RegExp _decimalOctetPattern = RegExp(r'^\d{1,3}$');

String _normalizeSearchText(String value) {
  return value.trim().toLowerCase().replaceAll(_searchTextStripPattern, '');
}

_ValidatedMagnet? _validatedMagnet(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'magnet') return null;
  String? xt;
  for (final entry in uri.queryParametersAll.entries) {
    if (entry.key.toLowerCase() == 'xt' && entry.value.isNotEmpty) {
      xt = entry.value.first;
      break;
    }
  }
  final match = RegExp(
    r'^urn:btih:([A-Fa-f0-9]{40}|[A-Za-z2-7]{32})$',
  ).firstMatch(xt ?? '');
  if (match == null) return null;
  return _ValidatedMagnet(uri, match.group(1)!.toLowerCase());
}

Uri? _safeDmhyDetailUri(String? value, Uri searchUri, SourceUriPolicy policy) {
  if (value == null || value.trim().isEmpty) return null;
  try {
    final uri = searchUri.resolve(value.trim());
    return policy.isAllowed(uri, allowedHosts: DmhySearchParser.allowedHosts)
        ? uri
        : null;
  } catch (_) {
    return null;
  }
}

String _cleanDomText(dom.Element? element) {
  return element?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
}

DateTime? _dmhyDate(String value) {
  final match = RegExp(
    r'(\d{4})/(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{1,2})',
  ).firstMatch(value);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
  );
}

int? _nullableCount(String value) {
  final match = RegExp(r'\d+').firstMatch(value.replaceAll(',', ''));
  return match == null ? null : int.tryParse(match.group(0)!);
}

String _decodeText(Uint8List bytes) {
  var offset = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    offset = 3;
  }
  return utf8.decode(bytes.sublist(offset), allowMalformed: true);
}

String _stripBom(String value) {
  return value.replaceFirst(RegExp(r'^\s*\uFEFF'), '');
}

bool _isRedirect(int statusCode) {
  return const {301, 302, 303, 307, 308}.contains(statusCode);
}

Future<void> _cancelResponse(http.StreamedResponse response) async {
  final subscription = response.stream.listen(null);
  await subscription.cancel();
}

String _safeErrorMessage(Object error) {
  if (error is SourceAdapterException) return error.message;
  if (error is TimeoutException) return '数据源请求超时。';
  if (error is FormatException || error is ArgumentError) {
    return '数据源内容格式不正确。';
  }
  if (error is http.ClientException) return '数据源网络请求失败。';
  return '数据源读取失败。';
}

String _headersCacheKey(Map<String, String> headers) {
  final entries = headers.entries.toList(growable: false)
    ..sort((left, right) => left.key.compareTo(right.key));
  return entries.map((entry) => '${entry.key}:${entry.value}').join('|');
}

String _normalizedHost(String host) {
  return host.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
}

bool _isBlockedHost(String host) {
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.lan') ||
      host.endsWith('.home')) {
    return true;
  }
  if (host.contains('%')) return true;
  if (host.contains(':')) {
    final bytes = _parseIpv6Bytes(host);
    return bytes == null || _isBlockedIpv6(bytes);
  }
  if (_numericOrHexHostPattern.hasMatch(host)) return true;

  final pieces = host.split('.');
  final allNumeric = pieces.every(_decimalOnlyPattern.hasMatch);
  final allNumericLike = pieces.every(_decimalOrHexOctetPattern.hasMatch);
  if (allNumericLike && !allNumeric) return true;
  if (allNumeric && pieces.length != 4) return true;
  if (pieces.length != 4 || !allNumeric) return false;
  if (pieces.any((piece) => piece.length > 1 && piece.startsWith('0'))) {
    return true;
  }
  final values = pieces.map(int.tryParse).toList(growable: false);
  if (values.any((value) => value == null || value < 0 || value > 255)) {
    return true;
  }
  final first = values[0]!;
  final second = values[1]!;
  final third = values[2]!;
  if (first == 0 || first == 10 || first == 127 || first >= 224) return true;
  if (first == 100 && second >= 64 && second <= 127) return true;
  if (first == 169 && second == 254) return true;
  if (first == 172 && second >= 16 && second <= 31) return true;
  if (first == 192 && second == 168) return true;
  if (first == 192 && second == 0 && third == 0) return true;
  if (first == 192 && second == 0 && third == 2) return true;
  if (first == 198 && (second == 18 || second == 19)) return true;
  if (first == 198 && second == 51 && third == 100) return true;
  if (first == 203 && second == 0 && third == 113) return true;
  return false;
}

List<int>? _parseIpv6Bytes(String host) {
  var value = host.trim().toLowerCase();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  if (value.isEmpty || value.contains('%')) return null;
  final compressionIndex = value.indexOf('::');
  if (compressionIndex >= 0 && value.indexOf('::', compressionIndex + 2) >= 0) {
    return null;
  }

  final hasCompression = compressionIndex >= 0;
  final leftText = hasCompression
      ? value.substring(0, compressionIndex)
      : value;
  final rightText = hasCompression ? value.substring(compressionIndex + 2) : '';
  final left = _parseIpv6Groups(leftText);
  final right = _parseIpv6Groups(rightText);
  if (left == null || right == null) return null;

  final missing = 8 - left.length - right.length;
  if ((hasCompression && missing < 1) || (!hasCompression && missing != 0)) {
    return null;
  }
  final groups = <int>[
    ...left,
    if (hasCompression) ...List<int>.filled(missing, 0),
    ...right,
  ];
  if (groups.length != 8) return null;
  return [
    for (final group in groups) ...[(group >> 8) & 0xff, group & 0xff],
  ];
}

List<int>? _parseIpv6Groups(String text) {
  if (text.isEmpty) return const [];
  final tokens = text.split(':');
  final groups = <int>[];
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.isEmpty) return null;
    if (token.contains('.')) {
      if (index != tokens.length - 1) return null;
      final ipv4 = _parseIpv4Bytes(token);
      if (ipv4 == null) return null;
      groups
        ..add((ipv4[0] << 8) | ipv4[1])
        ..add((ipv4[2] << 8) | ipv4[3]);
      continue;
    }
    if (token.length > 4 || !_hexGroupPattern.hasMatch(token)) {
      return null;
    }
    final value = int.tryParse(token, radix: 16);
    if (value == null || value < 0 || value > 0xffff) return null;
    groups.add(value);
  }
  return groups;
}

List<int>? _parseIpv4Bytes(String host) {
  final pieces = host.split('.');
  if (pieces.length != 4) return null;
  final values = <int>[];
  for (final piece in pieces) {
    if (!_decimalOctetPattern.hasMatch(piece)) return null;
    final value = int.tryParse(piece);
    if (value == null || value < 0 || value > 255) return null;
    values.add(value);
  }
  return values;
}

bool _isBlockedIpv6(List<int> bytes) {
  if (bytes.length != 16) return true;
  final allZero = bytes.every((value) => value == 0);
  if (allZero) return true;
  final loopback =
      bytes.take(15).every((value) => value == 0) && bytes[15] == 1;
  if (loopback) return true;

  // Unique local fc00::/7.
  if ((bytes[0] & 0xfe) == 0xfc) return true;
  // Link-local fe80::/10 and deprecated site-local fec0::/10.
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) >= 0x80) return true;
  // Multicast ff00::/8.
  if (bytes[0] == 0xff) return true;
  // IPv4-compatible and IPv4-mapped forms, including ::ffff:a.b.c.d.
  if (bytes.take(12).every((value) => value == 0) ||
      (bytes.take(10).every((value) => value == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff)) {
    return true;
  }
  return false;
}

String? _blankToNull(String value) {
  final text = value.trim();
  return text.isEmpty ? null : text;
}

String _stableToken(String value) {
  return stableDigest(
    'source-item|$stableIdentityVersion|$value',
  ).substring(0, 32);
}
