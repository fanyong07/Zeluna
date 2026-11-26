import 'dart:collection';
import 'dart:math';

import '../core/identity/stable_identity.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import 'canonical_work_key.dart';

const recommendationBehaviorStorageKey = 'recommendation.behavior.v1';
const recommendationServedStorageKey = 'recommendation.served.v1';

String recommendationScopedStorageKey(String? accountId, String storageKey) {
  final normalized = accountId?.trim() ?? '';
  return normalized.isEmpty ? storageKey : 'account.$normalized.$storageKey';
}

class CatalogRankingListEntry {
  const CatalogRankingListEntry({
    required this.provider,
    required this.kind,
    required this.rank,
  });

  factory CatalogRankingListEntry.fromJson(Map<String, dynamic> json) =>
      CatalogRankingListEntry(
        provider: json['provider']?.toString().trim() ?? '',
        kind: json['kind']?.toString().trim() ?? '',
        rank: (json['rank'] as num?)?.toInt() ?? 0,
      );

  final String provider;
  final String kind;
  final int rank;

  bool get isValid => provider.isNotEmpty && kind.isNotEmpty && rank > 0;

  Map<String, Object> toJson() => <String, Object>{
    'provider': provider,
    'kind': kind,
    'rank': rank,
  };
}

class CatalogRankingEvidence {
  const CatalogRankingEvidence({
    this.batchId,
    this.rankedAt,
    this.globalScore,
    this.lists = const <CatalogRankingListEntry>[],
    this.bangumiRank,
    this.bangumiScore,
    this.bangumiVotes,
    this.tmdbRank,
    this.tmdbScore,
    this.tmdbVotes,
    this.tmdbPopularity,
    this.freshness = 0,
  });

  factory CatalogRankingEvidence.fromJson(Map<String, dynamic> json) {
    final nested = json['ranking'];
    final source = nested is Map ? nested.cast<String, dynamic>() : json;
    final rankedAt = DateTime.tryParse(source['rankedAt']?.toString() ?? '');
    final rawLists = source['lists'];
    final lists = <CatalogRankingListEntry>[];
    if (rawLists is Iterable) {
      for (final raw in rawLists.whereType<Map>()) {
        final entry = CatalogRankingListEntry.fromJson(
          raw.cast<String, dynamic>(),
        );
        if (entry.isValid) lists.add(entry);
      }
    }
    return CatalogRankingEvidence(
      batchId: _blankToNull(source['batchId']?.toString()),
      rankedAt: rankedAt,
      globalScore: (source['globalScore'] as num?)?.toDouble(),
      lists: List<CatalogRankingListEntry>.unmodifiable(lists),
      bangumiRank: (source['bangumiRank'] as num?)?.toInt(),
      bangumiScore: (source['bangumiScore'] as num?)?.toDouble(),
      bangumiVotes: (source['bangumiVotes'] as num?)?.toInt(),
      tmdbRank: (source['tmdbRank'] as num?)?.toInt(),
      tmdbScore: (source['tmdbScore'] as num?)?.toDouble(),
      tmdbVotes: (source['tmdbVotes'] as num?)?.toInt(),
      tmdbPopularity: (source['tmdbPopularity'] as num?)?.toDouble(),
      freshness: (source['freshness'] as num?)?.toDouble() ?? 0,
    );
  }

  final String? batchId;
  final DateTime? rankedAt;
  final double? globalScore;
  final List<CatalogRankingListEntry> lists;

  final int? bangumiRank;
  final double? bangumiScore;
  final int? bangumiVotes;
  final int? tmdbRank;
  final double? tmdbScore;
  final int? tmdbVotes;
  final double? tmdbPopularity;

  /// Optional 0..1 caller-provided freshness evidence.
  final double freshness;

  double get chartScore {
    final publishedScore = globalScore;
    if (publishedScore != null && publishedScore.isFinite) {
      return publishedScore.clamp(0.0, 1.0);
    }
    final providerScores = <double>[];
    final bangumi = _providerScore(
      rank: bangumiRank,
      rating: bangumiScore,
      votes: bangumiVotes,
    );
    if (bangumi != null) providerScores.add(bangumi);
    final tmdb = _providerScore(
      rank: tmdbRank,
      rating: tmdbScore,
      votes: tmdbVotes,
      popularity: tmdbPopularity,
    );
    if (tmdb != null) providerScores.add(tmdb);
    final base = providerScores.isEmpty
        ? 0.0
        : providerScores.reduce((a, b) => a + b) / providerScores.length;
    return (base * 0.9 + freshness.clamp(0.0, 1.0) * 0.1).clamp(0.0, 1.0);
  }

  CatalogRankingEvidence merge(CatalogRankingEvidence other) {
    final differentBatches =
        batchId != null &&
        other.batchId != null &&
        batchId != other.batchId &&
        rankedAt != null &&
        other.rankedAt != null &&
        rankedAt != other.rankedAt;
    if (differentBatches) {
      final newer = other.rankedAt!.isAfter(rankedAt!) ? other : this;
      final older = identical(newer, other) ? this : other;
      final newerProviders = newer._providers;
      if (newerProviders.isEmpty) return newer;

      // Replace evidence only for providers present in the newer batch while
      // retaining disjoint providers. This prevents an old Bangumi batch from
      // pinning its historical score and also avoids a newer TMDB batch
      // deleting Bangumi list provenance for the same canonical work.
      final mergedLists = <String, CatalogRankingListEntry>{};
      for (final item in <CatalogRankingListEntry>[
        ...newer.lists,
        ...older.lists.where(
          (item) => !newerProviders.contains(item.provider.toLowerCase()),
        ),
      ]) {
        if (!item.isValid) continue;
        final key = '${item.provider.toLowerCase()}|${item.kind.toLowerCase()}';
        final current = mergedLists[key];
        if (current == null || item.rank < current.rank) {
          mergedLists[key] = item;
        }
      }
      final replacesBangumi = newerProviders.contains('bangumi');
      final replacesTmdb = newerProviders.contains('tmdb');
      return CatalogRankingEvidence(
        batchId: newer.batchId ?? older.batchId,
        rankedAt: newer.rankedAt ?? older.rankedAt,
        globalScore: newer.globalScore ?? older.globalScore,
        lists: List<CatalogRankingListEntry>.unmodifiable(mergedLists.values),
        bangumiRank: replacesBangumi ? newer.bangumiRank : older.bangumiRank,
        bangumiScore: replacesBangumi ? newer.bangumiScore : older.bangumiScore,
        bangumiVotes: replacesBangumi ? newer.bangumiVotes : older.bangumiVotes,
        tmdbRank: replacesTmdb ? newer.tmdbRank : older.tmdbRank,
        tmdbScore: replacesTmdb ? newer.tmdbScore : older.tmdbScore,
        tmdbVotes: replacesTmdb ? newer.tmdbVotes : older.tmdbVotes,
        tmdbPopularity: replacesTmdb
            ? newer.tmdbPopularity
            : older.tmdbPopularity,
        freshness: newer.freshness,
      );
    }
    final mergedLists = <String, CatalogRankingListEntry>{};
    for (final item in <CatalogRankingListEntry>[...lists, ...other.lists]) {
      if (!item.isValid) continue;
      final key = '${item.provider.toLowerCase()}|${item.kind.toLowerCase()}';
      final current = mergedLists[key];
      if (current == null || item.rank < current.rank) {
        mergedLists[key] = item;
      }
    }
    final otherIsNewer =
        rankedAt == null ||
        (other.rankedAt != null && other.rankedAt!.isAfter(rankedAt!));
    return CatalogRankingEvidence(
      batchId: otherIsNewer
          ? other.batchId ?? batchId
          : batchId ?? other.batchId,
      rankedAt: _latestDate(rankedAt, other.rankedAt),
      globalScore: _maxFinite(globalScore, other.globalScore),
      lists: List<CatalogRankingListEntry>.unmodifiable(mergedLists.values),
      bangumiRank: _minPositive(bangumiRank, other.bangumiRank),
      bangumiScore: _maxNullable(bangumiScore, other.bangumiScore),
      bangumiVotes: _maxNullableInt(bangumiVotes, other.bangumiVotes),
      tmdbRank: _minPositive(tmdbRank, other.tmdbRank),
      tmdbScore: _maxNullable(tmdbScore, other.tmdbScore),
      tmdbVotes: _maxNullableInt(tmdbVotes, other.tmdbVotes),
      tmdbPopularity: _maxNullable(tmdbPopularity, other.tmdbPopularity),
      freshness: max(freshness, other.freshness),
    );
  }

  Set<String> get _providers {
    final providers = <String>{
      for (final item in lists)
        if (item.isValid) item.provider.toLowerCase(),
    };
    if (bangumiRank != null || bangumiScore != null || bangumiVotes != null) {
      providers.add('bangumi');
    }
    if (tmdbRank != null ||
        tmdbScore != null ||
        tmdbVotes != null ||
        tmdbPopularity != null) {
      providers.add('tmdb');
    }
    return providers;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (batchId?.isNotEmpty == true) 'batchId': batchId,
    if (rankedAt != null) 'rankedAt': rankedAt!.toUtc().toIso8601String(),
    if (globalScore != null) 'globalScore': globalScore,
    if (lists.isNotEmpty)
      'lists': lists.map((item) => item.toJson()).toList(growable: false),
    if (bangumiRank != null) 'bangumiRank': bangumiRank,
    if (bangumiScore != null) 'bangumiScore': bangumiScore,
    if (bangumiVotes != null) 'bangumiVotes': bangumiVotes,
    if (tmdbRank != null) 'tmdbRank': tmdbRank,
    if (tmdbScore != null) 'tmdbScore': tmdbScore,
    if (tmdbVotes != null) 'tmdbVotes': tmdbVotes,
    if (tmdbPopularity != null) 'tmdbPopularity': tmdbPopularity,
    if (freshness != 0) 'freshness': freshness,
  };
}

class CatalogCandidate {
  CatalogCandidate({
    required AnimeSubject subject,
    CatalogRankingEvidence evidence = const CatalogRankingEvidence(),
    SubjectContentType? contentType,
    String? workKey,
    Set<String>? features,
    Map<String, String> externalIds = const <String, String>{},
  }) : this._(
         subject: subject,
         evidence: evidence,
         contentType: contentType ?? subjectContentTypeOf(subject),
         workKey: workKey?.trim().isNotEmpty == true
             ? workKey!.trim()
             : canonicalWorkKey(subject, externalIds: externalIds),
         features: features ?? recommendationFeaturesForSubject(subject),
         externalIds: externalIds,
       );

  CatalogCandidate._({
    required this.subject,
    required this.evidence,
    required this.contentType,
    required this.workKey,
    required Set<String> features,
    required Map<String, String> externalIds,
  }) : features = Set<String>.unmodifiable(
         features
             .map(normalizeRecommendationFeature)
             .where((item) => item.isNotEmpty),
       ),
       externalIds = Map<String, String>.unmodifiable(externalIds);

  final AnimeSubject subject;
  final CatalogRankingEvidence evidence;
  final SubjectContentType contentType;
  final String workKey;
  final Set<String> features;
  final Map<String, String> externalIds;

  CatalogCandidate merge(CatalogCandidate other) {
    if (workKey != other.workKey) {
      throw ArgumentError('Only candidates for the same work can be merged.');
    }
    final thisRankedAt = evidence.rankedAt;
    final otherRankedAt = other.evidence.rankedAt;
    final otherIsNewer =
        otherRankedAt != null &&
        (thisRankedAt == null || otherRankedAt.isAfter(thisRankedAt));
    final thisIsNewer =
        thisRankedAt != null &&
        (otherRankedAt == null || thisRankedAt.isAfter(otherRankedAt));
    final keepOther =
        otherIsNewer ||
        (!thisIsNewer &&
            (other.evidence.chartScore > evidence.chartScore ||
                (other.evidence.chartScore == evidence.chartScore &&
                    other.subject.identityKey.compareTo(subject.identityKey) <
                        0)));
    final representative = keepOther ? other : this;
    return CatalogCandidate._(
      subject: representative.subject,
      evidence: evidence.merge(other.evidence),
      contentType: representative.contentType,
      workKey: workKey,
      features: <String>{...features, ...other.features},
      externalIds: <String, String>{...externalIds, ...other.externalIds},
    );
  }
}

Set<String> recommendationFeaturesForSubject(AnimeSubject subject) =>
    Set<String>.unmodifiable(
      <String>{
        for (final category in subject.categories)
          _prefixedFeature('category', category.name),
        for (final tag in subject.tags) _prefixedFeature('tag', tag.name),
        _prefixedFeature('language', subject.language),
        _prefixedFeature('region', subject.region),
        _prefixedFeature('platform', subject.platform),
        if (int.tryParse(subject.year) != null)
          _prefixedFeature('year', subject.year),
      }..removeWhere((item) => item.endsWith(':')),
    );

String _prefixedFeature(String prefix, String value) =>
    '$prefix:${normalizeRecommendationFeature(value)}';

String normalizeRecommendationFeature(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

enum RecommendationEventType {
  following,
  unfollowed,
  favorite,
  unfavorited,
  completed,
  effectiveWatch,
  firstFrame,
  notInterested,
}

class RecommendationEvent {
  RecommendationEvent({
    String? id,
    required this.type,
    required String workKey,
    required this.occurredAt,
    required this.contentType,
    Set<String> features = const <String>{},
    this.sessionId,
  }) : workKey = _requireWorkKey(workKey),
       features = Set<String>.unmodifiable(
         features
             .map(normalizeRecommendationFeature)
             .where((item) => item.isNotEmpty),
       ),
       id = _eventId(id, type.name, workKey, occurredAt, sessionId);

  factory RecommendationEvent.forSubject({
    String? id,
    required RecommendationEventType type,
    required AnimeSubject subject,
    required DateTime occurredAt,
    String? sessionId,
    Map<String, String> externalIds = const <String, String>{},
  }) => RecommendationEvent(
    id: id,
    type: type,
    workKey: canonicalWorkKey(subject, externalIds: externalIds),
    occurredAt: occurredAt,
    contentType: subjectContentTypeOf(subject),
    features: recommendationFeaturesForSubject(subject),
    sessionId: sessionId,
  );

  factory RecommendationEvent.fromJson(Map<String, dynamic> json) {
    final occurredAt = DateTime.tryParse(json['occurredAt']?.toString() ?? '');
    if (occurredAt == null) throw const FormatException('Invalid event time.');
    return RecommendationEvent(
      id: json['id']?.toString(),
      type: RecommendationEventType.values.byName(
        json['type']?.toString() ?? '',
      ),
      workKey: json['workKey']?.toString() ?? '',
      occurredAt: occurredAt,
      contentType: SubjectContentType.values.byName(
        json['contentType']?.toString() ?? '',
      ),
      features: _stringSet(json['features'], maxEntries: 32),
      sessionId: _blankToNull(json['sessionId']?.toString()),
    );
  }

  final String id;
  final RecommendationEventType type;
  final String workKey;
  final DateTime occurredAt;
  final SubjectContentType contentType;
  final Set<String> features;
  final String? sessionId;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'type': type.name,
    'workKey': workKey,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'contentType': contentType.name,
    if (features.isNotEmpty) 'features': features.toList(growable: false),
    if (sessionId?.isNotEmpty == true) 'sessionId': sessionId,
  };
}

class RecommendationServedEvent {
  RecommendationServedEvent({
    String? id,
    required String workKey,
    required this.servedAt,
    required this.contentType,
    required String surface,
  }) : workKey = _requireWorkKey(workKey),
       surface = surface.trim().isEmpty ? 'unknown' : surface.trim(),
       id = _eventId(id, 'served', workKey, servedAt, surface);

  factory RecommendationServedEvent.forCandidate({
    String? id,
    required CatalogCandidate candidate,
    required DateTime servedAt,
    required String surface,
  }) => RecommendationServedEvent(
    id: id,
    workKey: candidate.workKey,
    servedAt: servedAt,
    contentType: candidate.contentType,
    surface: surface,
  );

  factory RecommendationServedEvent.fromJson(Map<String, dynamic> json) {
    final servedAt = DateTime.tryParse(json['servedAt']?.toString() ?? '');
    if (servedAt == null) throw const FormatException('Invalid served time.');
    return RecommendationServedEvent(
      id: json['id']?.toString(),
      workKey: json['workKey']?.toString() ?? '',
      servedAt: servedAt,
      contentType: SubjectContentType.values.byName(
        json['contentType']?.toString() ?? '',
      ),
      surface: json['surface']?.toString() ?? '',
    );
  }

  final String id;
  final String workKey;
  final DateTime servedAt;
  final SubjectContentType contentType;
  final String surface;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'workKey': workKey,
    'servedAt': servedAt.toUtc().toIso8601String(),
    'contentType': contentType.name,
    'surface': surface,
  };
}

abstract interface class RecommendationEventStore {
  Object? read(String storageKey);

  Future<void> write(String storageKey, Object value);

  Future<void> delete(String storageKey);
}

double? _providerScore({
  int? rank,
  double? rating,
  int? votes,
  double? popularity,
}) {
  if (rank == null && rating == null && votes == null && popularity == null) {
    return null;
  }
  var total = 0.0;
  var weight = 0.0;
  if (rank != null && rank > 0) {
    total += (1 / (1 + log(rank))) * 0.35;
    weight += 0.35;
  }
  if (rating != null && rating.isFinite) {
    total += (rating / 10).clamp(0.0, 1.0) * 0.45;
    weight += 0.45;
  }
  if (votes != null && votes >= 0) {
    total += (votes / (votes + 500)).clamp(0.0, 1.0) * 0.1;
    weight += 0.1;
  }
  if (popularity != null && popularity.isFinite && popularity >= 0) {
    total += (popularity / (popularity + 100)).clamp(0.0, 1.0) * 0.1;
    weight += 0.1;
  }
  return weight == 0 ? 0 : (total / weight).clamp(0.0, 1.0);
}

int? _minPositive(int? first, int? second) {
  final values = <int>[?first, ?second].where((item) => item > 0).toList();
  return values.isEmpty ? null : values.reduce(min);
}

double? _maxNullable(double? first, double? second) {
  if (first == null) return second;
  if (second == null) return first;
  return max(first, second);
}

int? _maxNullableInt(int? first, int? second) {
  if (first == null) return second;
  if (second == null) return first;
  return max(first, second);
}

DateTime? _latestDate(DateTime? first, DateTime? second) {
  if (first == null) return second;
  if (second == null) return first;
  return first.isAfter(second) ? first : second;
}

double? _maxFinite(double? first, double? second) {
  final values = <double>[
    if (first?.isFinite == true) first!,
    if (second?.isFinite == true) second!,
  ];
  return values.isEmpty ? null : values.reduce(max);
}

String _requireWorkKey(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 300) {
    throw ArgumentError.value(value, 'workKey');
  }
  return normalized;
}

String _eventId(
  String? provided,
  String kind,
  String workKey,
  DateTime time,
  String? discriminator,
) {
  final normalized = provided?.trim() ?? '';
  if (normalized.isNotEmpty) return normalized;
  return 'recommendation:$stableIdentityVersion:${stableDigest('$kind|$workKey|${time.toUtc().toIso8601String()}|${discriminator ?? ''}')}';
}

Set<String> _stringSet(Object? value, {required int maxEntries}) {
  if (value is! Iterable) return const <String>{};
  return value
      .map((item) => normalizeRecommendationFeature(item.toString()))
      .where((item) => item.isNotEmpty)
      .take(maxEntries)
      .toSet();
}

String? _blankToNull(String? value) {
  final normalized = value?.trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

UnmodifiableMapView<K, V> immutableMap<K, V>(Map<K, V> value) =>
    UnmodifiableMapView<K, V>(Map<K, V>.of(value));
