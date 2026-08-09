import 'dart:math';

import '../core/identity/stable_identity.dart';
import '../domain/subject_content_type.dart';
import 'recommendation_controller.dart';
import 'recommendation_models.dart';
import 'recommendation_profile.dart';

const recommendationColdStartQuotaPerType = 8;
const recommendationMatureMinimumPerType = 4;
const recommendationMatureMaximumPerType = 12;
const recommendationDefaultTotalSlots = 24;
const recommendationExplorationRatio = 0.10;

class RankedCatalogCandidate {
  const RankedCatalogCandidate({
    required this.candidate,
    required this.score,
    required this.chartScore,
    required this.personalizationScore,
    required this.explorationScore,
    required this.exploration,
  });

  final CatalogCandidate candidate;
  final double score;
  final double chartScore;
  final double personalizationScore;
  final double explorationScore;
  final bool exploration;
}

class RecommendationRankingResult {
  RecommendationRankingResult({
    required Map<SubjectContentType, List<RankedCatalogCandidate>> byType,
    required List<RankedCatalogCandidate> ordered,
    required Map<SubjectContentType, int> quotas,
    required this.explorationCount,
    required this.mature,
    required this.seed,
  }) : byType = immutableMap(<SubjectContentType, List<RankedCatalogCandidate>>{
         for (final entry in byType.entries)
           entry.key: List<RankedCatalogCandidate>.unmodifiable(entry.value),
       }),
       ordered = List<RankedCatalogCandidate>.unmodifiable(ordered),
       quotas = immutableMap(quotas);

  final Map<SubjectContentType, List<RankedCatalogCandidate>> byType;
  final List<RankedCatalogCandidate> ordered;
  final Map<SubjectContentType, int> quotas;
  final int explorationCount;
  final bool mature;
  final String seed;

  List<RecommendationServedEvent> servedEvents({
    required DateTime servedAt,
    required String surface,
  }) => ordered
      .map(
        (item) => RecommendationServedEvent.forCandidate(
          candidate: item.candidate,
          servedAt: servedAt,
          surface: surface,
        ),
      )
      .toList(growable: false);
}

String recommendationStableSeed({
  required String? accountId,
  required DateTime date,
  int nonce = 0,
}) {
  final account = accountId?.trim().isNotEmpty == true
      ? accountId!.trim()
      : 'guest';
  final day =
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  return stableDigest('recommendation-seed|v1|$account|$day|$nonce');
}

RecommendationRankingResult rankCatalog({
  required Iterable<CatalogCandidate> candidates,
  required RecommendationSnapshot snapshot,
  required DateTime now,
  int nonce = 0,
  int totalSlots = recommendationDefaultTotalSlots,
  bool excludeKnownWorks = true,
}) {
  if (totalSlots <= 0) {
    throw ArgumentError.value(totalSlots, 'totalSlots', 'Must be positive.');
  }
  final profile = snapshot.profile;
  final seed = recommendationStableSeed(
    accountId: snapshot.accountId,
    date: now,
    nonce: nonce,
  );
  final unique = _deduplicateCandidates(candidates)
      .where((item) => !profile.isBlocked(item.workKey, now))
      .where(
        (item) =>
            !excludeKnownWorks || !profile.knownWorkKeys.contains(item.workKey),
      )
      .toList(growable: false);
  final available = <SubjectContentType, int>{
    for (final type in SubjectContentType.values)
      type: unique.where((item) => item.contentType == type).length,
  };
  final targetQuotas = profile.stage != RecommendationProfileStage.cold
      ? _personalizedQuotas(
          profile.contentTypeWeights,
          available,
          totalSlots: totalSlots,
        )
      : <SubjectContentType, int>{
          for (final type in SubjectContentType.values)
            type: min(
              recommendationColdStartQuotaPerType,
              available[type] ?? 0,
            ),
        };
  final quotaTotal = targetQuotas.values.fold<int>(0, (a, b) => a + b);
  final explorationSlots = quotaTotal > 0
      ? max(1, (quotaTotal * recommendationExplorationRatio).round())
      : 0;
  final provisionalByType =
      <SubjectContentType, List<RankedCatalogCandidate>>{};
  for (final type in SubjectContentType.values) {
    final typeCandidates =
        unique
            .where((item) => item.contentType == type)
            .map(
              (candidate) => _scoreCandidate(
                candidate,
                profile: profile,
                now: now,
                stage: profile.stage,
                seed: seed,
              ),
            )
            .toList(growable: false)
          ..sort((a, b) => _compareRanked(a, b, seed));
    final quota = targetQuotas[type] ?? 0;
    provisionalByType[type] = typeCandidates
        .take(quota)
        .toList(growable: false);
  }
  final provisionalOrdered = <RankedCatalogCandidate>[
    for (final type in SubjectContentType.values)
      ...provisionalByType[type] ?? const [],
  ];
  final explorationKeys =
      (provisionalOrdered.toList(growable: false)..sort((a, b) {
            final byExploration = b.explorationScore.compareTo(
              a.explorationScore,
            );
            if (byExploration != 0) return byExploration;
            return a.candidate.workKey.compareTo(b.candidate.workKey);
          }))
          .take(explorationSlots)
          .map((item) => item.candidate.workKey)
          .toSet();
  RankedCatalogCandidate markExploration(RankedCatalogCandidate item) =>
      explorationKeys.contains(item.candidate.workKey)
      ? RankedCatalogCandidate(
          candidate: item.candidate,
          score: item.score,
          chartScore: item.chartScore,
          personalizationScore: item.personalizationScore,
          explorationScore: item.explorationScore,
          exploration: true,
        )
      : item;
  final byType = <SubjectContentType, List<RankedCatalogCandidate>>{
    for (final type in SubjectContentType.values)
      type: provisionalByType[type]!
          .map(markExploration)
          .toList(growable: false),
  };
  final ordered = <RankedCatalogCandidate>[
    for (final type in SubjectContentType.values) ...byType[type]!,
  ];
  final actualQuotas = <SubjectContentType, int>{
    for (final type in SubjectContentType.values) type: byType[type]!.length,
  };
  return RecommendationRankingResult(
    byType: byType,
    ordered: ordered,
    quotas: actualQuotas,
    explorationCount: ordered.where((item) => item.exploration).length,
    mature: profile.isMature,
    seed: seed,
  );
}

/// Re-ranks every eligible candidate without applying homepage quotas.
/// Category pages can use this API and preserve their complete result set.
List<RankedCatalogCandidate> rankAllCandidates({
  required Iterable<CatalogCandidate> candidates,
  required RecommendationSnapshot snapshot,
  required DateTime now,
  int nonce = 0,
  bool excludeKnownWorks = false,
}) {
  final profile = snapshot.profile;
  final seed = recommendationStableSeed(
    accountId: snapshot.accountId,
    date: now,
    nonce: nonce,
  );
  final ranked =
      _deduplicateCandidates(candidates)
          .where((item) => !profile.isBlocked(item.workKey, now))
          .where(
            (item) =>
                !excludeKnownWorks ||
                !profile.knownWorkKeys.contains(item.workKey),
          )
          .map(
            (candidate) => _scoreCandidate(
              candidate,
              profile: profile,
              now: now,
              stage: profile.stage,
              seed: seed,
              knownWorkPenalty:
                  !excludeKnownWorks &&
                      profile.knownWorkKeys.contains(candidate.workKey)
                  ? 0.35
                  : 1.0,
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => _compareRanked(a, b, seed));
  return _markExploration(ranked);
}

/// Full-list convenience API for a single anime/series/movie category.
List<RankedCatalogCandidate> rankCatalogForType({
  required SubjectContentType type,
  required Iterable<CatalogCandidate> candidates,
  required RecommendationSnapshot snapshot,
  required DateTime now,
  int nonce = 0,
  bool excludeKnownWorks = false,
}) => rankAllCandidates(
  candidates: candidates.where((item) => item.contentType == type),
  snapshot: snapshot,
  now: now,
  nonce: nonce,
  excludeKnownWorks: excludeKnownWorks,
);

/// Interleaves already ranked queues while avoiding adjacent type and genre
/// repetition whenever another candidate is available.
List<CatalogCandidate> interleaveRecommendationCandidates(
  Map<SubjectContentType, List<CatalogCandidate>> sourceQueues, {
  required String seed,
}) {
  final queues = <SubjectContentType, List<CatalogCandidate>>{
    for (final type in SubjectContentType.values)
      type: List<CatalogCandidate>.of(sourceQueues[type] ?? const []),
  };
  final types = SubjectContentType.values.toList(growable: false);
  final offset =
      seed.codeUnits.fold<int>(0, (sum, value) => sum + value) % types.length;
  final order = <SubjectContentType>[
    ...types.skip(offset),
    ...types.take(offset),
  ];
  final result = <CatalogCandidate>[];
  SubjectContentType? previousType;
  String? previousCategory;
  while (queues.values.any((items) => items.isNotEmpty)) {
    final available = order
        .where((type) => queues[type]!.isNotEmpty)
        .toList(growable: false);
    if (available.isEmpty) break;
    var eligible = available.length > 1
        ? available.where((type) => type != previousType).toList()
        : available;
    if (eligible.isEmpty) eligible = available;
    var chosenType = eligible.first;
    var chosenIndex = 0;
    if (previousCategory != null) {
      var foundAlternative = false;
      for (final type in eligible) {
        final queue = queues[type]!;
        for (var index = 0; index < queue.length; index++) {
          if (_primaryCategory(queue[index]) == previousCategory) continue;
          chosenType = type;
          chosenIndex = index;
          foundAlternative = true;
          break;
        }
        if (foundAlternative) break;
      }
    }
    final candidate = queues[chosenType]!.removeAt(chosenIndex);
    result.add(candidate);
    previousType = chosenType;
    previousCategory = _primaryCategory(candidate);
  }
  return result;
}

String? _primaryCategory(CatalogCandidate candidate) {
  for (final category in candidate.subject.categories) {
    final normalized = normalizeRecommendationFeature(category.name);
    if (normalized.isNotEmpty) return normalized;
  }
  return null;
}

List<CatalogCandidate> _deduplicateCandidates(
  Iterable<CatalogCandidate> candidates,
) {
  final unique = <String, CatalogCandidate>{};
  for (final candidate in candidates) {
    if (candidate.workKey.trim().isEmpty) continue;
    final current = unique[candidate.workKey];
    unique[candidate.workKey] = current == null
        ? candidate
        : current.merge(candidate);
  }
  return unique.values.toList(growable: false);
}

RankedCatalogCandidate _scoreCandidate(
  CatalogCandidate candidate, {
  required RecommendationProfile profile,
  required DateTime now,
  required RecommendationProfileStage stage,
  required String seed,
  double knownWorkPenalty = 1.0,
}) {
  final chartScore = candidate.evidence.chartScore;
  final personalizationScore = stage == RecommendationProfileStage.cold
      ? 0.0
      : profile.personalizationScore(candidate);
  final explorationScore = _stableUnit(
    '$seed|exploration-score|${candidate.workKey}',
  );
  final blend = switch (stage) {
    RecommendationProfileStage.cold =>
      chartScore * 0.90 + explorationScore * 0.10,
    RecommendationProfileStage.warming =>
      chartScore * 0.75 + personalizationScore * 0.15 + explorationScore * 0.10,
    RecommendationProfileStage.mature =>
      chartScore * 0.55 + personalizationScore * 0.35 + explorationScore * 0.10,
  };
  final servedPenalty = profile.servedPenalty(candidate.workKey, now);
  final tieBreaker = _stableUnit('$seed|rank|${candidate.workKey}') * 1e-9;
  return RankedCatalogCandidate(
    candidate: candidate,
    score: blend * servedPenalty * knownWorkPenalty + tieBreaker,
    chartScore: chartScore,
    personalizationScore: personalizationScore,
    explorationScore: explorationScore,
    exploration: false,
  );
}

Map<SubjectContentType, int> _personalizedQuotas(
  Map<SubjectContentType, double> preference,
  Map<SubjectContentType, int> available, {
  required int totalSlots,
}) {
  final quotas = <SubjectContentType, int>{
    for (final type in SubjectContentType.values)
      type: min(recommendationMatureMinimumPerType, available[type] ?? 0),
  };
  final target = min(
    totalSlots,
    SubjectContentType.values.fold<int>(
      0,
      (sum, type) =>
          sum + min(recommendationMatureMaximumPerType, available[type] ?? 0),
    ),
  );
  while (quotas.values.fold<int>(0, (a, b) => a + b) < target) {
    SubjectContentType? best;
    var bestPriority = -1.0;
    for (final type in SubjectContentType.values) {
      final quota = quotas[type] ?? 0;
      final cap = min(recommendationMatureMaximumPerType, available[type] ?? 0);
      if (quota >= cap) continue;
      final rawPreference = preference[type] ?? 0;
      final priority = (rawPreference > 0 ? rawPreference : 1) / (quota + 1);
      if (priority > bestPriority) {
        best = type;
        bestPriority = priority;
      }
    }
    if (best == null) break;
    quotas[best] = (quotas[best] ?? 0) + 1;
  }
  return quotas;
}

int _compareRanked(
  RankedCatalogCandidate first,
  RankedCatalogCandidate second,
  String seed,
) {
  final byScore = second.score.compareTo(first.score);
  if (byScore != 0) return byScore;
  return _stableToken(
    '$seed|rank|${first.candidate.workKey}',
  ).compareTo(_stableToken('$seed|rank|${second.candidate.workKey}'));
}

List<RankedCatalogCandidate> _markExploration(
  List<RankedCatalogCandidate> ranked,
) {
  if (ranked.isEmpty) return const [];
  final count = max(
    1,
    (ranked.length * recommendationExplorationRatio).round(),
  );
  final keys =
      (ranked.toList(growable: false)..sort((a, b) {
            final byExploration = b.explorationScore.compareTo(
              a.explorationScore,
            );
            return byExploration != 0
                ? byExploration
                : a.candidate.workKey.compareTo(b.candidate.workKey);
          }))
          .take(count)
          .map((item) => item.candidate.workKey)
          .toSet();
  return ranked
      .map(
        (item) => keys.contains(item.candidate.workKey)
            ? RankedCatalogCandidate(
                candidate: item.candidate,
                score: item.score,
                chartScore: item.chartScore,
                personalizationScore: item.personalizationScore,
                explorationScore: item.explorationScore,
                exploration: true,
              )
            : item,
      )
      .toList(growable: false);
}

String _stableToken(String input) => stableDigest(input);

double _stableUnit(String input) {
  final prefix = stableDigest(input).substring(0, 13);
  final value = int.parse(prefix, radix: 16);
  return value / 0xFFFFFFFFFFFFF;
}
