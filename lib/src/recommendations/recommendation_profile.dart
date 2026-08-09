import 'dart:math';

import '../domain/subject_content_type.dart';
import 'recommendation_models.dart';

const recommendationProfileHalfLife = Duration(days: 90);
const recommendationNotInterestedRetention = Duration(days: 180);

const recommendationEventWeights = <RecommendationEventType, double>{
  RecommendationEventType.following: 5,
  RecommendationEventType.favorite: 4,
  RecommendationEventType.completed: 3,
  RecommendationEventType.effectiveWatch: 2,
  RecommendationEventType.firstFrame: 1,
};

enum RecommendationProfileStage { cold, warming, mature }

class RecommendationProfile {
  RecommendationProfile._({
    required Map<String, double> workWeights,
    required Map<String, double> featureWeights,
    required Map<SubjectContentType, double> contentTypeWeights,
    required Set<String> knownWorkKeys,
    required Map<String, DateTime> blockedUntil,
    required Map<String, int> servedCounts,
    required Map<String, DateTime> lastServedAt,
    required this.strongSignalCount,
    required this.effectiveSignalCount,
  }) : workWeights = immutableMap(workWeights),
       featureWeights = immutableMap(featureWeights),
       contentTypeWeights = immutableMap(contentTypeWeights),
       knownWorkKeys = Set<String>.unmodifiable(knownWorkKeys),
       blockedUntil = immutableMap(blockedUntil),
       servedCounts = immutableMap(servedCounts),
       lastServedAt = immutableMap(lastServedAt);

  factory RecommendationProfile.empty() => RecommendationProfile._(
    workWeights: const <String, double>{},
    featureWeights: const <String, double>{},
    contentTypeWeights: const <SubjectContentType, double>{},
    knownWorkKeys: const <String>{},
    blockedUntil: const <String, DateTime>{},
    servedCounts: const <String, int>{},
    lastServedAt: const <String, DateTime>{},
    strongSignalCount: 0,
    effectiveSignalCount: 0,
  );

  factory RecommendationProfile.fromEvents({
    required Iterable<RecommendationEvent> behaviors,
    required Iterable<RecommendationServedEvent> served,
    required DateTime now,
  }) {
    final ordered = behaviors.toList(growable: false)
      ..sort((a, b) {
        final byTime = a.occurredAt.compareTo(b.occurredAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    final activeFollowing = <String, RecommendationEvent>{};
    final activeFavorites = <String, RecommendationEvent>{};
    final milestones = <RecommendationEvent>[];
    final notInterested = <String, RecommendationEvent>{};
    final latestExplicitPositive = <String, DateTime>{};

    for (final event in ordered) {
      switch (event.type) {
        case RecommendationEventType.following:
          activeFollowing[event.workKey] = event;
          latestExplicitPositive[event.workKey] = event.occurredAt;
        case RecommendationEventType.unfollowed:
          activeFollowing.remove(event.workKey);
        case RecommendationEventType.favorite:
          activeFavorites[event.workKey] = event;
          latestExplicitPositive[event.workKey] = event.occurredAt;
        case RecommendationEventType.unfavorited:
          activeFavorites.remove(event.workKey);
        case RecommendationEventType.completed ||
            RecommendationEventType.effectiveWatch ||
            RecommendationEventType.firstFrame:
          milestones.add(event);
          latestExplicitPositive[event.workKey] = event.occurredAt;
        case RecommendationEventType.notInterested:
          notInterested[event.workKey] = event;
      }
    }

    final positiveEvents = <RecommendationEvent>[
      ...activeFollowing.values,
      ...activeFavorites.values,
      ...milestones,
    ];
    final workWeights = <String, double>{};
    final featureWeights = <String, double>{};
    final contentTypeWeights = <SubjectContentType, double>{};
    final knownWorkKeys = <String>{};
    final strongWorkKeys = <String>{};
    final effectiveSessions = <String>{};

    for (final event in positiveEvents) {
      final baseWeight = recommendationEventWeights[event.type];
      if (baseWeight == null) continue;
      final weight =
          baseWeight * recommendationTimeDecay(event.occurredAt, now);
      if (weight <= 0) continue;
      workWeights.update(
        event.workKey,
        (value) => value + weight,
        ifAbsent: () => weight,
      );
      contentTypeWeights.update(
        event.contentType,
        (value) => value + weight,
        ifAbsent: () => weight,
      );
      for (final feature in event.features) {
        featureWeights.update(
          feature,
          (value) => value + weight,
          ifAbsent: () => weight,
        );
      }
      knownWorkKeys.add(event.workKey);
      if (event.type == RecommendationEventType.following ||
          event.type == RecommendationEventType.favorite) {
        strongWorkKeys.add(event.workKey);
      }
      if (event.type == RecommendationEventType.completed ||
          event.type == RecommendationEventType.effectiveWatch) {
        effectiveSessions.add(
          '${event.workKey}|${event.sessionId ?? event.id}',
        );
      }
    }

    final blockedUntil = <String, DateTime>{};
    for (final entry in notInterested.entries) {
      final positiveAt = latestExplicitPositive[entry.key];
      if (positiveAt != null && positiveAt.isAfter(entry.value.occurredAt)) {
        continue;
      }
      final until = entry.value.occurredAt.add(
        recommendationNotInterestedRetention,
      );
      if (until.isAfter(now)) blockedUntil[entry.key] = until;
    }

    final servedCounts = <String, int>{};
    final lastServedAt = <String, DateTime>{};
    for (final event in served) {
      // Today's display records must not perturb today's deterministic order.
      // They become eligible for repeat suppression after the date changes.
      if (_sameLocalDate(event.servedAt, now)) continue;
      servedCounts.update(
        event.workKey,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      final current = lastServedAt[event.workKey];
      if (current == null || event.servedAt.isAfter(current)) {
        lastServedAt[event.workKey] = event.servedAt;
      }
    }

    return RecommendationProfile._(
      workWeights: workWeights,
      featureWeights: featureWeights,
      contentTypeWeights: contentTypeWeights,
      knownWorkKeys: knownWorkKeys,
      blockedUntil: blockedUntil,
      servedCounts: servedCounts,
      lastServedAt: lastServedAt,
      strongSignalCount: strongWorkKeys.length,
      effectiveSignalCount: effectiveSessions.length,
    );
  }

  final Map<String, double> workWeights;
  final Map<String, double> featureWeights;
  final Map<SubjectContentType, double> contentTypeWeights;
  final Set<String> knownWorkKeys;
  final Map<String, DateTime> blockedUntil;
  final Map<String, int> servedCounts;
  final Map<String, DateTime> lastServedAt;
  final int strongSignalCount;
  final int effectiveSignalCount;

  RecommendationProfileStage get stage {
    if (isMature) return RecommendationProfileStage.mature;
    if (strongSignalCount > 0 || effectiveSignalCount > 0) {
      return RecommendationProfileStage.warming;
    }
    return RecommendationProfileStage.cold;
  }

  /// Three currently followed/favorited works or five effectively watched or
  /// completed works unlock mature quotas. First-frame events never mature a
  /// profile by themselves.
  bool get isMature => strongSignalCount >= 3 || effectiveSignalCount >= 5;

  bool isBlocked(String workKey, DateTime at) =>
      blockedUntil[workKey]?.isAfter(at) == true;

  double personalizationScore(CatalogCandidate candidate) {
    if (featureWeights.isEmpty && contentTypeWeights.isEmpty) return 0;
    final maxFeature = featureWeights.values.fold<double>(0, max);
    var featureScore = 0.0;
    var matched = 0;
    if (maxFeature > 0) {
      for (final feature in candidate.features) {
        final weight = featureWeights[feature];
        if (weight == null) continue;
        featureScore += weight / maxFeature;
        matched++;
      }
    }
    if (matched > 0) featureScore /= sqrt(matched);
    featureScore = featureScore.clamp(0.0, 1.0);

    final maxType = contentTypeWeights.values.fold<double>(0, max);
    final typeScore = maxType <= 0
        ? 0.0
        : ((contentTypeWeights[candidate.contentType] ?? 0) / maxType).clamp(
            0.0,
            1.0,
          );
    return (featureScore * 0.75 + typeScore * 0.25).clamp(0.0, 1.0);
  }

  double servedPenalty(String workKey, DateTime now) {
    final count = servedCounts[workKey] ?? 0;
    if (count == 0) return 1;
    return (1 / (1 + 0.18 * count)).clamp(0.15, 1.0);
  }
}

double recommendationTimeDecay(DateTime occurredAt, DateTime now) {
  final age = now.difference(occurredAt);
  if (age <= Duration.zero) return 1;
  return pow(
    0.5,
    age.inMilliseconds / recommendationProfileHalfLife.inMilliseconds,
  ).toDouble();
}

bool _sameLocalDate(DateTime first, DateTime second) {
  final localFirst = first.toLocal();
  final localSecond = second.toLocal();
  return localFirst.year == localSecond.year &&
      localFirst.month == localSecond.month &&
      localFirst.day == localSecond.day;
}
