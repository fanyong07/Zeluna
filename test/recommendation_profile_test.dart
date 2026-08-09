import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

RecommendationEvent _event(
  RecommendationEventType type,
  String work,
  DateTime at, {
  SubjectContentType contentType = SubjectContentType.anime,
  Set<String> features = const {'tag:fantasy'},
  String? sessionId,
}) => RecommendationEvent(
  type: type,
  workKey: work,
  occurredAt: at,
  contentType: contentType,
  features: features,
  sessionId: sessionId,
);

void main() {
  test('profile applies the specified event weights', () {
    final now = DateTime.utc(2026, 8, 9);
    final profile = RecommendationProfile.fromEvents(
      behaviors: [
        _event(RecommendationEventType.following, 'follow', now),
        _event(RecommendationEventType.favorite, 'favorite', now),
        _event(RecommendationEventType.completed, 'completed', now),
        _event(RecommendationEventType.effectiveWatch, 'effective', now),
        _event(RecommendationEventType.firstFrame, 'first', now),
      ],
      served: const [],
      now: now,
    );

    expect(profile.workWeights['follow'], 5);
    expect(profile.workWeights['favorite'], 4);
    expect(profile.workWeights['completed'], 3);
    expect(profile.workWeights['effective'], 2);
    expect(profile.workWeights['first'], 1);
  });

  test('ninety days halves a signal weight', () {
    final now = DateTime.utc(2026, 8, 9);
    final profile = RecommendationProfile.fromEvents(
      behaviors: [
        _event(
          RecommendationEventType.following,
          'work',
          now.subtract(const Duration(days: 90)),
        ),
      ],
      served: const [],
      now: now,
    );

    expect(profile.workWeights['work'], closeTo(2.5, 0.000001));
  });

  test('unfollow and unfavorite remove stateful positive signals', () {
    final now = DateTime.utc(2026, 8, 9);
    final profile = RecommendationProfile.fromEvents(
      behaviors: [
        _event(
          RecommendationEventType.following,
          'work',
          now.subtract(const Duration(days: 2)),
        ),
        _event(
          RecommendationEventType.favorite,
          'work',
          now.subtract(const Duration(days: 2)),
        ),
        _event(
          RecommendationEventType.unfollowed,
          'work',
          now.subtract(const Duration(days: 1)),
        ),
        _event(
          RecommendationEventType.unfavorited,
          'work',
          now.subtract(const Duration(days: 1)),
        ),
      ],
      served: const [],
      now: now,
    );

    expect(profile.workWeights, isEmpty);
    expect(profile.knownWorkKeys, isEmpty);
  });

  test(
    'not interested lasts 180 days and a later explicit positive unblocks',
    () {
      final now = DateTime.utc(2026, 8, 9);
      final blocked = RecommendationProfile.fromEvents(
        behaviors: [
          _event(
            RecommendationEventType.notInterested,
            'work',
            now.subtract(const Duration(days: 179)),
          ),
        ],
        served: const [],
        now: now,
      );
      final restored = RecommendationProfile.fromEvents(
        behaviors: [
          _event(
            RecommendationEventType.notInterested,
            'work',
            now.subtract(const Duration(days: 3)),
          ),
          _event(
            RecommendationEventType.favorite,
            'work',
            now.subtract(const Duration(days: 1)),
          ),
        ],
        served: const [],
        now: now,
      );

      expect(blocked.isBlocked('work', now), isTrue);
      expect(restored.isBlocked('work', now), isFalse);
    },
  );

  test('three strong works or five effective works mature the profile', () {
    final now = DateTime.utc(2026, 8, 9);
    RecommendationProfile build(int count, RecommendationEventType type) =>
        RecommendationProfile.fromEvents(
          behaviors: [
            for (var i = 0; i < count; i++) _event(type, 'work-$i', now),
          ],
          served: const [],
          now: now,
        );

    expect(build(2, RecommendationEventType.favorite).isMature, isFalse);
    expect(build(3, RecommendationEventType.favorite).isMature, isTrue);
    expect(build(4, RecommendationEventType.effectiveWatch).isMature, isFalse);
    expect(build(5, RecommendationEventType.effectiveWatch).isMature, isTrue);
    expect(build(8, RecommendationEventType.firstFrame).isMature, isFalse);
    expect(build(5, RecommendationEventType.completed).isMature, isTrue);
  });

  test(
    'five watched episodes mature one work without double counting completion',
    () {
      final now = DateTime.utc(2026, 8, 9);
      final behaviors = <RecommendationEvent>[
        for (var episode = 1; episode <= 5; episode++) ...[
          _event(
            RecommendationEventType.effectiveWatch,
            'same-work',
            now,
            sessionId: 'episode:$episode',
          ),
          _event(
            RecommendationEventType.completed,
            'same-work',
            now,
            sessionId: 'episode:$episode',
          ),
        ],
      ];
      final profile = RecommendationProfile.fromEvents(
        behaviors: behaviors,
        served: const [],
        now: now,
      );

      expect(profile.effectiveSignalCount, 5);
      expect(profile.isMature, isTrue);
    },
  );
}
