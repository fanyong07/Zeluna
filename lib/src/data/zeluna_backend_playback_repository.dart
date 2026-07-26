import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../rules/rule_playback_resolver.dart';
import 'playback_source_repository.dart';

class ZelunaBackendPlaybackRepository implements PlaybackSourceRepository {
  ZelunaBackendPlaybackRepository({
    required String baseUrl,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 6),
  }) : _baseUri = normalizeBaseUrl(baseUrl),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri? _baseUri;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  bool get isConfigured => _baseUri != null;

  static Uri? normalizeBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
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
      return _loadLines(stableId, subject, episode, cancellationToken);
    } on TimeoutException {
      return const [];
    } on http.ClientException {
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
    RulePlaybackCancellationToken? cancellationToken,
  ) async {
    if (cancellationToken?.isCancelled == true) return const [];
    final uri = _endpoint(
      ['api', 'v3', 'playback', stableId],
      query: {
        'episode': '${episode.number}',
        'title': subject.title,
        'original_title': subject.originalTitle,
        'content_type': switch (subjectContentTypeOf(subject)) {
          SubjectContentType.anime => 'anime',
          SubjectContentType.series => 'tv',
          SubjectContentType.movie => 'movie',
        },
        if (subject.year != '未知') 'year': subject.year,
      },
    );
    try {
      final response = await _client.get(uri).timeout(requestTimeout);
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
        if (mediaUri == null ||
            !mediaUri.hasAuthority ||
            (mediaUri.scheme != 'http' && mediaUri.scheme != 'https')) {
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
        lines.add(
          PlaybackLine(
            id: 'zeluna:${_stableHash('$stableId|${episode.number}|$url')}',
            episodeId: episode.id,
            providerId: 'zeluna:$stableId',
            providerName: _providerName(source),
            title: json['title']?.toString().trim().isNotEmpty == true
                ? json['title'].toString().trim()
                : '聚合线路${index + 1}',
            quality: json['quality']?.toString().trim() ?? '',
            format: json['format']?.toString().trim() ?? 'auto',
            url: url,
            headers: Map<String, String>.unmodifiable(headers),
            publicHttpOnly: true,
            available: true,
            message: cached ? '聚合后端缓存线路' : '聚合后端已验证线路',
          ),
        );
      }
      return lines;
    } on TimeoutException {
      return const [];
    } on http.ClientException {
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

String? _stableSubjectId(AnimeSubject subject) {
  final source = subject.source.trim().toLowerCase();
  if (source == 'bangumi') return 'bangumi:${subject.id}';
  final parts = source.split(':');
  if (parts.length == 3 && parts.first == 'tmdb') {
    final mediaType = parts[1] == 'series' ? 'tv' : parts[1];
    if ((mediaType == 'tv' || mediaType == 'movie') &&
        int.tryParse(parts[2]) != null) {
      return 'tmdb:$mediaType:${parts[2]}';
    }
  }
  return null;
}

String _providerName(String source) {
  final value = source.isNotEmpty ? source : 'Zeluna';
  final parts = value.split(':');
  final site = parts.length >= 2 ? parts[1].trim() : value.trim();
  return site.isEmpty ? 'Zeluna 聚合后端' : 'Zeluna · $site';
}

String _stableHash(String value) {
  var hash = 0x811C9DC5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
