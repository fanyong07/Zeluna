import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/identity/stable_identity.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../recommendations/recommendation_models.dart';
import 'zeluna_backend_playback_repository.dart';

class ZelunaBackendCatalogRepository {
  ZelunaBackendCatalogRepository({
    required String baseUrl,
    required http.Client client,
    NetworkServiceKind service = NetworkServiceKind.officialPlaybackBackend,
    bool allowInsecureSelfHosted = false,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _baseUri = ZelunaBackendPlaybackRepository.normalizeBaseUrl(
         baseUrl,
         service: service,
         allowInsecureSelfHosted: allowInsecureSelfHosted,
       ),
       _client = client;

  final Uri? _baseUri;
  final http.Client _client;
  final Duration requestTimeout;

  bool get isConfigured => _baseUri != null;

  Future<List<AnimeSubject>> search(String query) async {
    final value = query.trim();
    if (_baseUri == null || value.isEmpty) return const [];
    final response = await _get(
      const ['api', 'v3', 'catalog', 'search'],
      query: {'query': value, 'content_type': 'anime,tv,movie', 'limit': '60'},
    );
    return _subjects(response);
  }

  Future<List<AnimeSubject>> home(SubjectContentType type) async {
    final candidates = await homeCandidates(type);
    return List<AnimeSubject>.unmodifiable(
      candidates.map((candidate) => candidate.subject),
    );
  }

  Future<List<CatalogCandidate>> homeCandidates(SubjectContentType type) async {
    if (_baseUri == null) return const [];
    final value = switch (type) {
      SubjectContentType.anime => 'anime',
      SubjectContentType.series => 'tv',
      SubjectContentType.movie => 'movie',
    };
    final response = await _get(
      ['api', 'v3', 'catalog', 'home', value],
      query: const {'limit': '240'},
    );
    return _candidates(response, type);
  }

  Future<AnimeDetailBundle?> detail(AnimeSubject subject) async {
    final stableId = stableSubjectId(subject);
    if (_baseUri == null || stableId == null) return null;
    final response = await _get(['api', 'v3', 'catalog', 'subject', stableId]);
    if (response == null || response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return null;
    final json = decoded.cast<Object?, Object?>();
    if (json['detail_complete'] != true) return null;
    final detailed = _subject(json);
    if (detailed == null) return null;
    final rawEpisodes = json['episodes'];
    final episodes = <AnimeEpisode>[];
    if (rawEpisodes is List) {
      for (var index = 0; index < rawEpisodes.length; index++) {
        final raw = rawEpisodes[index];
        if (raw is! Map) continue;
        final item = raw.cast<Object?, Object?>();
        final number = _int(item['number'], fallback: index + 1);
        episodes.add(
          AnimeEpisode(
            id: _stableEpisodeId(detailed, number),
            subjectId: detailed.id,
            number: number,
            title: item['title']?.toString() ?? '',
            airdate: _nullIfBlank(item['airdate']),
            duration: item['duration']?.toString() ?? '',
            description: item['summary']?.toString() ?? '',
          ),
        );
      }
    }
    if (episodes.isEmpty && detailed.totalEpisodes > 0) {
      for (var number = 1; number <= detailed.totalEpisodes; number++) {
        episodes.add(
          AnimeEpisode(
            id: _stableEpisodeId(detailed, number),
            subjectId: detailed.id,
            number: number,
            title: '',
            airdate: null,
            duration: '',
            description: '',
          ),
        );
      }
    }
    return AnimeDetailBundle(
      subject: detailed.copyWith(totalEpisodes: episodes.length),
      episodes: List.unmodifiable(episodes),
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }

  Future<http.Response?> _get(
    List<String> segments, {
    Map<String, String>? query,
  }) async {
    try {
      final response = await _client
          .get(_endpoint(segments, query: query))
          .timeout(requestTimeout);
      return response.statusCode == 200 ? response : null;
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    } on FormatException {
      return null;
    }
  }

  List<AnimeSubject> _subjects(http.Response? response) {
    if (response == null) return const [];
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) return const [];
      final subjects = <AnimeSubject>[];
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final subject = _subject(raw.cast<Object?, Object?>());
        if (subject != null) subjects.add(subject);
      }
      return List.unmodifiable(subjects);
    } on FormatException {
      return const [];
    }
  }

  List<CatalogCandidate> _candidates(
    http.Response? response,
    SubjectContentType type,
  ) {
    if (response == null) return const [];
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) return const [];
      final candidates = <CatalogCandidate>[];
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final json = raw.cast<Object?, Object?>();
        final subject = _subject(json);
        if (subject == null) continue;
        candidates.add(
          CatalogCandidate(
            subject: subject,
            contentType: type,
            evidence: _rankingEvidence(json['ranking']),
            externalIds: _externalIds(
              json['external_ids'] ?? json['externalIds'],
            ),
          ),
        );
      }
      return List<CatalogCandidate>.unmodifiable(candidates);
    } on FormatException {
      return const [];
    }
  }

  AnimeSubject? _subject(Map<Object?, Object?> json) {
    final stableId = json['stable_id']?.toString().trim() ?? '';
    final identity = _parseStableId(stableId);
    final title = json['title']?.toString().trim() ?? '';
    if (identity == null || title.isEmpty) return null;
    final genres = json['genres'];
    final categories = genres is List
        ? genres
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .map((item) => AnimeCategory(name: item))
              .toList(growable: false)
        : const <AnimeCategory>[];
    return AnimeSubject(
      id: identity.$2,
      title: title,
      originalTitle: json['original_title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      coverUrl: _nullIfBlank(json['cover_url']),
      bannerUrl: _nullIfBlank(json['banner_url']),
      date: _nullIfBlank(json['date']),
      platform: identity.$1 == 'tmdb:movie' ? '电影' : 'TV',
      language: json['language']?.toString() ?? '',
      region: json['region']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      categories: categories,
      tags: const [],
      totalEpisodes: _int(json['total_episodes']),
      ratingScore: _doubleOrNull(json['rating']),
      ratingTotal: _intOrNull(json['rating_count']),
      source: identity.$1,
    );
  }

  Uri _endpoint(List<String> segments, {Map<String, String>? query}) {
    final base = _baseUri!;
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((item) => item.isNotEmpty),
        ...segments,
      ],
      queryParameters: query,
    );
  }
}

CatalogRankingEvidence _rankingEvidence(Object? value) {
  if (value is! Map) return const CatalogRankingEvidence();
  final json = value.cast<Object?, Object?>();
  final lists = <CatalogRankingListEntry>[];
  final rawLists = json['lists'];
  if (rawLists is List) {
    for (final raw in rawLists) {
      if (raw is! Map) continue;
      final item = raw.cast<Object?, Object?>();
      final entry = CatalogRankingListEntry(
        provider: item['provider']?.toString().trim() ?? '',
        kind: item['kind']?.toString().trim() ?? '',
        rank: _int(item['rank']),
      );
      if (entry.isValid) lists.add(entry);
    }
  }
  return CatalogRankingEvidence(
    batchId: _nullIfBlank(json['batchId']),
    rankedAt: _rankingDateTime(json['rankedAt']),
    globalScore: _finiteDoubleOrNull(json['globalScore']),
    lists: List<CatalogRankingListEntry>.unmodifiable(lists),
  );
}

Map<String, String> _externalIds(Object? value) {
  if (value is! Map) return const <String, String>{};
  final result = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key?.toString().trim() ?? '';
    final identifier = entry.value?.toString().trim() ?? '';
    if (key.isNotEmpty && identifier.isNotEmpty) result[key] = identifier;
  }
  return result;
}

DateTime? _rankingDateTime(Object? value) {
  if (value == null) return null;
  final numeric = value is num ? value.toDouble() : double.tryParse('$value');
  if (numeric != null && numeric.isFinite) {
    final milliseconds = numeric.abs() >= 100000000000
        ? numeric.round()
        : (numeric * 1000).round();
    try {
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    } on RangeError {
      return null;
    }
  }
  return DateTime.tryParse(value.toString())?.toUtc();
}

String? stableSubjectId(AnimeSubject subject) {
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

(String, int)? _parseStableId(String value) {
  final parts = value.split(':');
  if (parts.length == 2 && parts.first == 'bangumi') {
    final id = int.tryParse(parts[1]);
    return id == null ? null : ('bangumi', id);
  }
  if (parts.length == 3 && parts.first == 'tmdb') {
    final id = int.tryParse(parts[2]);
    if (id == null || (parts[1] != 'tv' && parts[1] != 'movie')) return null;
    return ('tmdb:${parts[1] == 'tv' ? 'series' : 'movie'}:$id', id);
  }
  return null;
}

int _stableEpisodeId(AnimeSubject subject, int number) {
  final subjectKey =
      stableSubjectId(subject) ??
      stableSubjectKey(source: subject.source, identifier: subject.id);
  return stableInt63(
    stableEpisodeKey(subjectKey: subjectKey, normalizedNumber: number),
  );
}

int _int(Object? value, {int fallback = 0}) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;

int? _intOrNull(Object? value) {
  if (value == null) return null;
  return _int(value);
}

double? _doubleOrNull(Object? value) {
  if (value == null) return null;
  return value is num ? value.toDouble() : double.tryParse('$value');
}

double? _finiteDoubleOrNull(Object? value) {
  final parsed = _doubleOrNull(value);
  return parsed?.isFinite == true ? parsed : null;
}

String? _nullIfBlank(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
