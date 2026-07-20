import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/anime_models.dart';
import 'bangumi_metadata_repository.dart';

/// A verified Chinese title/summary returned by a public metadata provider.
class ChineseMetadata {
  const ChineseMetadata({this.title, this.summary, required this.provider});

  final String? title;
  final String? summary;
  final String provider;

  bool get isEmpty => title == null && summary == null;
}

/// Adds Chinese titles and summaries without translating or guessing content.
///
/// Movie and series metadata is resolved in batches through Wikidata by IMDb
/// ID. Anime metadata is matched against Bangumi by exact normalized title,
/// with bounded concurrency to avoid flooding its public API.
class ChineseMetadataRepository {
  ChineseMetadataRepository({
    http.Client? client,
    BangumiMetadataRepository? bangumiRepository,
    Duration cacheTtl = const Duration(days: 7),
    Duration missCacheTtl = const Duration(hours: 6),
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _bangumiRepository = bangumiRepository ?? BangumiMetadataRepository(),
       _cacheTtl = cacheTtl,
       _missCacheTtl = missCacheTtl,
       _now = now ?? DateTime.now;

  static const _wikidataEndpoint = 'https://query.wikidata.org/sparql';
  static const _wikidataBatchSize = 40;
  static const _defaultAnimeLookupLimit = 36;
  static const _animeLookupConcurrency = 4;
  static final _imdbPattern = RegExp(r'\btt\d{5,12}\b', caseSensitive: false);
  static final _hanPattern = RegExp(r'[\u3400-\u9fff]');
  static final _kanaPattern = RegExp(
    r'[\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fd-\u30ff\u31f0-\u31ff\uff66-\uff9d]',
  );
  static final _hangulPattern = RegExp(
    r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]',
  );
  static final _separatorPattern = RegExp(
    r'[^a-z0-9\u3040-\u30ff\u3400-\u9fff]+',
  );

  final http.Client _client;
  final BangumiMetadataRepository _bangumiRepository;
  final Duration _cacheTtl;
  final Duration _missCacheTtl;
  final DateTime Function() _now;
  final Map<String, _CacheEntry> _cache = {};

  /// Enriches subjects in their original order and leaves unmatched data
  /// untouched. Existing Chinese text always wins over fetched metadata.
  Future<List<AnimeSubject>> enrichSubjects(
    Iterable<AnimeSubject> subjects, {
    bool useBangumiForAnime = true,
    int animeLookupLimit = _defaultAnimeLookupLimit,
  }) async {
    final items = subjects.toList(growable: false);
    if (items.isEmpty) return const [];

    final imdbIds = <String>{};
    final animeByKey = <String, AnimeSubject>{};
    for (final subject in items) {
      if (!_needsChineseMetadata(subject)) continue;
      final imdbId = _imdbIdFrom(subject);
      if (imdbId != null) {
        imdbIds.add(imdbId);
        continue;
      }
      if (useBangumiForAnime && _isExternalAnime(subject)) {
        final key = _animeCacheKey(subject);
        if (key.isNotEmpty) animeByKey.putIfAbsent(key, () => subject);
      }
    }

    final imdbMatchesFuture = _lookupWikidata(imdbIds);
    final animeMatchesFuture = useBangumiForAnime && animeLookupLimit > 0
        ? _lookupBangumiSubjects(animeByKey, lookupLimit: animeLookupLimit)
        : Future.value(const <String, ChineseMetadata>{});
    final results = await Future.wait([imdbMatchesFuture, animeMatchesFuture]);
    final imdbMatches = results[0];
    final animeMatches = results[1];

    return [
      for (final subject in items)
        _applyMetadata(
          subject,
          imdbMatches[_imdbIdFrom(subject)] ??
              animeMatches[_animeCacheKey(subject)],
        ),
    ];
  }

  Future<AnimeSubject> enrichSubject(
    AnimeSubject subject, {
    bool useBangumiForAnime = true,
  }) async {
    final results = await enrichSubjects(
      [subject],
      useBangumiForAnime: useBangumiForAnime,
      animeLookupLimit: 1,
    );
    return results.single;
  }

  void clearMemoryCache() => _cache.clear();

  Future<Map<String, ChineseMetadata>> _lookupWikidata(
    Set<String> imdbIds,
  ) async {
    if (imdbIds.isEmpty) return const {};
    final matches = <String, ChineseMetadata>{};
    final missing = <String>[];
    for (final imdbId in imdbIds) {
      final cached = _readCache('imdb:$imdbId');
      if (cached != null) {
        final metadata = cached.metadata;
        if (metadata != null) matches[imdbId] = metadata;
      } else {
        missing.add(imdbId);
      }
    }

    final batches = <List<String>>[];
    for (var start = 0; start < missing.length; start += _wikidataBatchSize) {
      final end = (start + _wikidataBatchSize).clamp(0, missing.length);
      batches.add(missing.sublist(start, end));
    }
    await _forEachConcurrent(
      batches,
      concurrency: 3,
      action: (batch) async {
        final response = await _fetchWikidataBatch(batch);
        if (!response.succeeded) return;
        for (final imdbId in batch) {
          final metadata = response.matches[imdbId];
          _writeCache('imdb:$imdbId', metadata);
          if (metadata != null) matches[imdbId] = metadata;
        }
      },
    );
    return matches;
  }

  Future<_WikidataBatchResult> _fetchWikidataBatch(List<String> imdbIds) async {
    if (imdbIds.isEmpty) return const _WikidataBatchResult.succeeded({});
    final values = imdbIds.map((id) => '"$id"').join(' ');
    final query =
        '''
SELECT ?imdb
  (SAMPLE(?zhCnLabelValue) AS ?zhCnLabel)
  (SAMPLE(?zhHansLabelValue) AS ?zhHansLabel)
  (SAMPLE(?zhLabelValue) AS ?zhLabel)
  (SAMPLE(?zhCnDescriptionValue) AS ?zhCnDescription)
  (SAMPLE(?zhHansDescriptionValue) AS ?zhHansDescription)
  (SAMPLE(?zhDescriptionValue) AS ?zhDescription)
WHERE {
  VALUES ?imdb { $values }
  ?item wdt:P345 ?imdb.
  OPTIONAL {
    ?item rdfs:label ?zhCnLabelValue.
    FILTER(LANG(?zhCnLabelValue) = "zh-cn")
  }
  OPTIONAL {
    ?item rdfs:label ?zhHansLabelValue.
    FILTER(LANG(?zhHansLabelValue) = "zh-hans")
  }
  OPTIONAL {
    ?item rdfs:label ?zhLabelValue.
    FILTER(LANG(?zhLabelValue) = "zh")
  }
  OPTIONAL {
    ?item schema:description ?zhCnDescriptionValue.
    FILTER(LANG(?zhCnDescriptionValue) = "zh-cn")
  }
  OPTIONAL {
    ?item schema:description ?zhHansDescriptionValue.
    FILTER(LANG(?zhHansDescriptionValue) = "zh-hans")
  }
  OPTIONAL {
    ?item schema:description ?zhDescriptionValue.
    FILTER(LANG(?zhDescriptionValue) = "zh")
  }
}
GROUP BY ?imdb
''';
    try {
      final response = await _client
          .get(
            Uri.parse(
              _wikidataEndpoint,
            ).replace(queryParameters: {'format': 'json', 'query': query}),
            headers: const {
              'Accept': 'application/sparql-results+json',
              'User-Agent': 'anime-app/1.0 (Chinese metadata client)',
            },
          )
          .timeout(const Duration(seconds: 16));
      if (response.statusCode != 200) {
        return const _WikidataBatchResult.failed();
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final bindings = decoded is Map
          ? ((decoded['results'] as Map?)?['bindings'] as List?)
          : null;
      if (bindings == null) return const _WikidataBatchResult.failed();

      final matches = <String, ChineseMetadata>{};
      for (final raw in bindings.whereType<Map>()) {
        final row = raw.cast<String, dynamic>();
        final imdbId = _bindingValue(row['imdb']).toLowerCase();
        if (!imdbIds.contains(imdbId)) continue;
        final title = _firstChineseBinding(row, const [
          'zhCnLabel',
          'zhHansLabel',
          'zhLabel',
        ]);
        final summary = _firstChineseBinding(row, const [
          'zhCnDescription',
          'zhHansDescription',
          'zhDescription',
        ]);
        final metadata = ChineseMetadata(
          title: title,
          summary: summary,
          provider: 'Wikidata',
        );
        if (!metadata.isEmpty) matches[imdbId] = metadata;
      }
      return _WikidataBatchResult.succeeded(matches);
    } catch (_) {
      return const _WikidataBatchResult.failed();
    }
  }

  Future<Map<String, ChineseMetadata>> _lookupBangumiSubjects(
    Map<String, AnimeSubject> animeByKey, {
    required int lookupLimit,
  }) async {
    if (animeByKey.isEmpty) return const {};
    final matches = <String, ChineseMetadata>{};
    final missing = <MapEntry<String, AnimeSubject>>[];
    for (final entry in animeByKey.entries) {
      final cached = _readCache(entry.key);
      if (cached != null) {
        final metadata = cached.metadata;
        if (metadata != null) matches[entry.key] = metadata;
      } else {
        missing.add(entry);
      }
    }

    final lookups = missing.take(lookupLimit).toList(growable: false);
    await _forEachConcurrent(
      lookups,
      concurrency: _animeLookupConcurrency,
      action: (entry) async {
        final result = await _fetchBangumiMatch(entry.value);
        if (!result.succeeded) return;
        _writeCache(entry.key, result.metadata);
        if (result.metadata != null) matches[entry.key] = result.metadata!;
      },
    );
    return matches;
  }

  Future<_BangumiLookupResult> _fetchBangumiMatch(AnimeSubject subject) async {
    final query = _bangumiLookupTerm(subject);
    if (query.isEmpty) return const _BangumiLookupResult.succeeded(null);
    try {
      final candidates = await _bangumiRepository
          .searchSubjects(keyword: query, limit: 8)
          .timeout(const Duration(seconds: 14));
      final aliases = {
        _normalizeTitle(subject.title),
        _normalizeTitle(subject.originalTitle),
      }..remove('');
      final exactMatches = candidates
          .where((candidate) {
            final candidateAliases = {
              _normalizeTitle(candidate.title),
              _normalizeTitle(candidate.originalTitle),
            }..remove('');
            return candidateAliases.any(aliases.contains);
          })
          .toList(growable: false);
      if (exactMatches.isEmpty) {
        return const _BangumiLookupResult.succeeded(null);
      }
      final subjectYear = _year(subject.date);
      final candidate = exactMatches.firstWhere(
        (item) => subjectYear != null && _year(item.date) == subjectYear,
        orElse: () => exactMatches.first,
      );
      final title = _verifiedChinese(candidate.title);
      final summary = _verifiedChinese(candidate.summary);
      final metadata = ChineseMetadata(
        title: title,
        summary: summary,
        provider: 'Bangumi',
      );
      return _BangumiLookupResult.succeeded(metadata.isEmpty ? null : metadata);
    } catch (_) {
      return const _BangumiLookupResult.failed();
    }
  }

  AnimeSubject _applyMetadata(AnimeSubject subject, ChineseMetadata? metadata) {
    if (metadata == null || metadata.isEmpty) return subject;
    final fetchedTitle = metadata.title?.trim();
    final fetchedSummary = metadata.summary?.trim();
    final title = _needsChineseText(subject.title) && fetchedTitle != null
        ? fetchedTitle
        : subject.title;
    final summary = _needsChineseText(subject.summary) && fetchedSummary != null
        ? fetchedSummary
        : subject.summary;
    if (title == subject.title && summary == subject.summary) return subject;
    return AnimeSubject(
      id: subject.id,
      title: title,
      originalTitle: subject.originalTitle.trim().isEmpty
          ? subject.title
          : subject.originalTitle,
      summary: summary,
      coverUrl: subject.coverUrl,
      bannerUrl: subject.bannerUrl,
      date: subject.date,
      platform: subject.platform,
      language: subject.language,
      region: subject.region,
      status: subject.status,
      categories: subject.categories,
      tags: subject.tags,
      totalEpisodes: subject.totalEpisodes,
      ratingScore: subject.ratingScore,
      ratingRank: subject.ratingRank,
      ratingTotal: subject.ratingTotal,
      source: subject.source,
    );
  }

  _CacheEntry? _readCache(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (!entry.expiresAt.isAfter(_now())) {
      _cache.remove(key);
      return null;
    }
    return entry;
  }

  void _writeCache(String key, ChineseMetadata? metadata) {
    _cache[key] = _CacheEntry(
      metadata: metadata,
      expiresAt: _now().add(metadata == null ? _missCacheTtl : _cacheTtl),
    );
  }

  static String? _imdbIdFrom(AnimeSubject subject) {
    final match = _imdbPattern.firstMatch(subject.source);
    return match?.group(0)?.toLowerCase();
  }

  static bool _isExternalAnime(AnimeSubject subject) {
    final source = subject.source.toLowerCase();
    return source == 'anilist' || source == 'jikan' || source == 'kitsu';
  }

  static bool _needsChineseMetadata(AnimeSubject subject) {
    return _needsChineseText(subject.title) ||
        _needsChineseText(subject.summary);
  }

  static bool _needsChineseText(String value) {
    final text = value.trim();
    if (text.isEmpty) return true;
    if (_kanaPattern.hasMatch(text) || _hangulPattern.hasMatch(text)) {
      return true;
    }
    return !_hanPattern.hasMatch(text);
  }

  static String? _verifiedChinese(String? value) {
    final text = value?.trim() ?? '';
    return text.isNotEmpty && _hanPattern.hasMatch(text) ? text : null;
  }

  static String _animeCacheKey(AnimeSubject subject) {
    if (!_isExternalAnime(subject)) return '';
    final title = _normalizeTitle(_bangumiLookupTerm(subject));
    if (title.isEmpty) return '';
    return 'anime:$title:${_year(subject.date) ?? 0}';
  }

  static String _bangumiLookupTerm(AnimeSubject subject) {
    final originalTitle = subject.originalTitle.trim();
    if (originalTitle.isNotEmpty) return originalTitle;
    return subject.title.trim();
  }

  static String _normalizeTitle(String value) {
    return value.toLowerCase().replaceAll(_separatorPattern, '');
  }

  static int? _year(String? date) {
    if (date == null) return null;
    final match = RegExp(r'(19|20)\d{2}').firstMatch(date);
    return int.tryParse(match?.group(0) ?? '');
  }

  static String _bindingValue(Object? value) {
    if (value is Map) return value['value']?.toString().trim() ?? '';
    return '';
  }

  static String? _firstChineseBinding(
    Map<String, dynamic> row,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = _verifiedChinese(_bindingValue(row[key]));
      if (value != null) return value;
    }
    return null;
  }

  static Future<void> _forEachConcurrent<T>(
    List<T> items, {
    required int concurrency,
    required Future<void> Function(T item) action,
  }) async {
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < items.length) {
        final index = nextIndex++;
        await action(items[index]);
      }
    }

    final workerCount = items.length < concurrency ? items.length : concurrency;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
  }
}

class _CacheEntry {
  const _CacheEntry({required this.metadata, required this.expiresAt});

  final ChineseMetadata? metadata;
  final DateTime expiresAt;
}

class _WikidataBatchResult {
  const _WikidataBatchResult.succeeded(this.matches) : succeeded = true;
  const _WikidataBatchResult.failed() : matches = const {}, succeeded = false;

  final Map<String, ChineseMetadata> matches;
  final bool succeeded;
}

class _BangumiLookupResult {
  const _BangumiLookupResult.succeeded(this.metadata) : succeeded = true;
  const _BangumiLookupResult.failed() : metadata = null, succeeded = false;

  final ChineseMetadata? metadata;
  final bool succeeded;
}
