import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/identity/stable_identity.dart';
import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../rules/rule_playback_resolver.dart';
import 'playback_source_repository.dart';

class ZelunaBackendPlaybackRepository implements PlaybackSourceRepository {
  ZelunaBackendPlaybackRepository({
    required String baseUrl,
    http.Client? client,
    this.service = NetworkServiceKind.officialPlaybackBackend,
    this.allowInsecureSelfHosted = false,
    this.requestTimeout = const Duration(seconds: 18),
  }) : assert(
         service == NetworkServiceKind.officialPlaybackBackend ||
             service == NetworkServiceKind.selfHostedPlaybackBackend,
       ),
       _baseUri = normalizeBaseUrl(
         baseUrl,
         service: service,
         allowInsecureSelfHosted: allowInsecureSelfHosted,
       ),
       _client = client == null
           ? createNetworkHttpClient(
               NetworkRequestPolicy.forService(
                 service,
                 allowInsecureSelfHosted: allowInsecureSelfHosted,
               ),
             )
           : PolicyHttpClient(
               inner: client,
               ownsInner: false,
               policy: NetworkRequestPolicy.forService(
                 service,
                 allowInsecureSelfHosted: allowInsecureSelfHosted,
               ),
             ),
       _ownsClient = true;

  final Uri? _baseUri;
  final http.Client _client;
  final bool _ownsClient;
  final NetworkServiceKind service;
  final bool allowInsecureSelfHosted;
  final Duration requestTimeout;

  bool get isConfigured => _baseUri != null;

  static Uri? normalizeBaseUrl(
    String value, {
    NetworkServiceKind service = NetworkServiceKind.officialPlaybackBackend,
    bool allowInsecureSelfHosted = false,
  }) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return null;
    }
    if (service != NetworkServiceKind.officialPlaybackBackend &&
        service != NetworkServiceKind.selfHostedPlaybackBackend) {
      return null;
    }
    try {
      NetworkRequestPolicy.forService(
        service,
        allowInsecureSelfHosted: allowInsecureSelfHosted,
      ).ensureUriAllowed(uri);
    } on NetworkSecurityException {
      return null;
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    return linesForEpisodeMode(
      subject,
      episode,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (_baseUri == null || cancellationToken?.isCancelled == true) {
      return const [];
    }
    try {
      final stableId = _stableSubjectId(subject);
      if (stableId == null || cancellationToken?.isCancelled == true) {
        return const [];
      }
      return _loadLines(
        stableId,
        subject,
        episode,
        cancellationToken,
        expandAll: expandAll,
      );
    } on TimeoutException {
      return const [];
    } on http.ClientException {
      return const [];
    } on NetworkSecurityException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    final lines = await linesForEpisodeMode(
      subject,
      episode,
      expandAll: true,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken?.isCancelled == true) return;
    yield PlaybackLineLookupUpdate(
      lines: lines,
      completedRules: 1,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.complete,
    );
  }

  Future<List<PlaybackLine>> _loadLines(
    String stableId,
    AnimeSubject subject,
    AnimeEpisode episode,
    RulePlaybackCancellationToken? cancellationToken, {
    required bool expandAll,
  }) async {
    if (cancellationToken?.isCancelled == true) return const [];
    final query = {
      'episode': '${episode.number}',
      'title': subject.title,
      'original_title': subject.originalTitle,
      'content_type': switch (subjectContentTypeOf(subject)) {
        SubjectContentType.anime => 'anime',
        SubjectContentType.series => 'tv',
        SubjectContentType.movie => 'movie',
      },
      if (subject.year != '未知') 'year': subject.year,
    };
    final primaryUri = _endpoint(
      expandAll
          ? ['api', 'v3', 'playback', stableId]
          : ['api', 'v3', 'quick-playback', stableId],
      query: query,
    );
    try {
      var response = await _client.get(primaryUri).timeout(requestTimeout);
      // Keep new clients compatible while an older backend is being rolled
      // forward. A real quick response (including an empty list) is final.
      if (!expandAll &&
          (response.statusCode == 404 || response.statusCode == 405) &&
          cancellationToken?.isCancelled != true) {
        response = await _client
            .get(_endpoint(['api', 'v3', 'playback', stableId], query: query))
            .timeout(requestTimeout);
      }
      if (response.statusCode != 200 ||
          cancellationToken?.isCancelled == true) {
        return const [];
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) return const [];
      final lines = <PlaybackLine>[];
      for (var index = 0; index < decoded.length; index++) {
        final item = decoded[index];
        if (item is! Map) continue;
        final json = item.cast<Object?, Object?>();
        final url = json['url']?.toString().trim() ?? '';
        final mediaUri = Uri.tryParse(url);
        if (mediaUri != null && _isObviousPlaybackPageUri(mediaUri)) {
          continue;
        }
        final hasPlayableUrl =
            mediaUri != null &&
            mediaUri.hasAuthority &&
            (mediaUri.scheme == 'http' || mediaUri.scheme == 'https');
        final status = json['status']?.toString().trim().toLowerCase() ?? '';
        final requiresClientProbe =
            status == 'client_probe_required' && hasPlayableUrl;
        final serverVerified =
            hasPlayableUrl &&
            (status == 'server_verified' ||
                status == 'playable' ||
                (status.isEmpty && json['available'] != false));
        final available = serverVerified && json['available'] != false;
        if (json['available'] != false && !hasPlayableUrl) {
          continue;
        }
        final expiresAt = _epochDateTime(json['expires_at']);
        if (expiresAt != null &&
            expiresAt.isBefore(
              DateTime.now().add(const Duration(seconds: 15)),
            )) {
          continue;
        }
        final source = json['source']?.toString().trim() ?? '';
        final headers = <String, String>{};
        final rawHeaders = json['headers'];
        if (rawHeaders is Map) {
          for (final entry in rawHeaders.entries) {
            final name = entry.key.toString().trim();
            final value = entry.value?.toString().trim() ?? '';
            if (name.isNotEmpty && value.isNotEmpty) headers[name] = value;
          }
        }
        final cached = json['cached'] == true;
        final stale = json['stale'] == true;
        final rawCacheState = json['cache_state']?.toString().trim() ?? '';
        final cacheState = rawCacheState.isNotEmpty
            ? rawCacheState
            : stale
            ? 'stale'
            : cached
            ? 'fresh'
            : 'cold';
        final sourceErrorCategory =
            json['error_category']?.toString().trim() ?? '';
        final sourceLatencyMs = int.tryParse(
          json['source_latency_ms']?.toString() ?? '',
        );
        final startupLatencyMs = int.tryParse(
          json['startup_latency_ms']?.toString() ?? '',
        );
        final startupProfile = _startupProfileFromJson(json['startup_profile']);
        final providerId = _providerKey(source, stableId);
        final episodeKey = stableEpisodeKey(
          subjectKey: stableId,
          normalizedNumber: episode.number,
        );
        final lineId = hasPlayableUrl
            ? stablePlaybackLineKey(
                providerId: providerId,
                episodeKey: episodeKey,
                uri: url,
                headers: headers,
              )
            : 'line:$stableIdentityVersion:${stableDigest('placeholder|$providerId|$episodeKey|$source|${json['title'] ?? ''}|$status')}';
        lines.add(
          PlaybackLine(
            id: lineId,
            episodeId: episode.id,
            providerId: providerId,
            providerName: _providerName(source),
            title: json['title']?.toString().trim().isNotEmpty == true
                ? json['title'].toString().trim()
                : '聚合线路${index + 1}',
            quality: json['quality']?.toString().trim() ?? '',
            format: json['format']?.toString().trim() ?? 'auto',
            url: hasPlayableUrl ? url : null,
            headers: Map<String, String>.unmodifiable(headers),
            latency: startupLatencyMs != null && startupLatencyMs > 0
                ? Duration(milliseconds: startupLatencyMs)
                : sourceLatencyMs != null && sourceLatencyMs > 0
                ? Duration(milliseconds: sourceLatencyMs)
                : null,
            // Server-verified lines crossed the trusted backend boundary.
            // Candidate-only lines must repeat public-address, manifest and
            // first-segment validation from the user's own network.
            publicHttpOnly: requiresClientProbe,
            serverVerified: serverVerified,
            requiresClientProbe: requiresClientProbe,
            startupProfile: startupProfile,
            cacheState: cacheState,
            sourceErrorCategory: sourceErrorCategory,
            expiresAt: expiresAt,
            available: available,
            message: available
                ? (stale
                      ? '来自可用缓存，正在后台更新线路'
                      : cached
                      ? '来自在线服务（已缓存）'
                      : '在线服务已确认可播')
                : requiresClientProbe
                ? '正在用你的网络确认是否可播'
                : (json['message']?.toString().trim().isNotEmpty == true
                      ? json['message'].toString().trim()
                      : '暂时没有可播放的线路'),
          ),
        );
      }
      return lines;
    } on TimeoutException {
      return const [];
    } on http.ClientException {
      return const [];
    } on NetworkSecurityException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  Uri _endpoint(List<String> segments, {Map<String, String>? query}) {
    final base = _baseUri!;
    final baseSegments = base.pathSegments.where((item) => item.isNotEmpty);
    return base.replace(
      pathSegments: [...baseSegments, ...segments],
      queryParameters: query,
    );
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

String _startupProfileFromJson(Object? value) {
  return switch (value?.toString().trim().toLowerCase()) {
    PlaybackStartupProfile.hls => PlaybackStartupProfile.hls,
    PlaybackStartupProfile.mp4FastStart => PlaybackStartupProfile.mp4FastStart,
    PlaybackStartupProfile.mp4TailMoov => PlaybackStartupProfile.mp4TailMoov,
    _ => PlaybackStartupProfile.unknown,
  };
}

DateTime? _epochDateTime(Object? value) {
  final raw = int.tryParse(value?.toString() ?? '');
  if (raw == null || raw <= 0) return null;
  final milliseconds = raw > 10000000000 ? raw : raw * 1000;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
}

bool _isObviousPlaybackPageUri(Uri uri) {
  final path = uri.path.toLowerCase().replaceFirst(RegExp(r'/+$'), '');
  const mediaSuffixes = <String>{
    '.m3u8',
    '.mpd',
    '.mp4',
    '.m4v',
    '.mov',
    '.mkv',
    '.flv',
    '.webm',
  };
  if (mediaSuffixes.any(path.endsWith)) return false;
  if (const <String>{'.html', '.htm', '.shtml', '.xhtml'}.any(path.endsWith)) {
    return true;
  }
  final segments = uri.pathSegments
      .map((segment) => segment.trim().toLowerCase())
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.any(const <String>{'embed', 'iframe', 'player'}.contains)) {
    return true;
  }
  final last = segments.isEmpty ? '' : segments.last;
  return last.startsWith('player.') ||
      last.startsWith('player-') ||
      last.startsWith('player_') ||
      last.startsWith('embed.') ||
      last.startsWith('embed-') ||
      last.startsWith('embed_');
}

String? _stableSubjectId(AnimeSubject subject) {
  final source = subject.source.trim().toLowerCase();
  if (source == 'bangumi') {
    return stableSubjectKey(source: source, identifier: subject.id);
  }
  final parts = source.split(':');
  if (parts.length == 3 && parts.first == 'tmdb') {
    final mediaType = parts[1] == 'series' ? 'tv' : parts[1];
    if ((mediaType == 'tv' || mediaType == 'movie') &&
        int.tryParse(parts[2]) != null) {
      return stableSubjectKey(
        source: source,
        identifier: subject.id,
        mediaType: mediaType,
      );
    }
  }
  return null;
}

String _providerName(String source) {
  final value = source.isNotEmpty ? source : 'Zeluna';
  final parts = value.split(':');
  final site = parts.length >= 2 ? parts[1].trim() : value.trim();
  return site.isEmpty ? '在线服务' : '在线服务 · $site';
}

String _providerKey(String source, String stableId) {
  final parts = source.split(':');
  final site = parts.length >= 2 ? parts[1].trim() : '';
  return site.isEmpty ? 'zeluna:$stableId' : 'zeluna:site:$site';
}
