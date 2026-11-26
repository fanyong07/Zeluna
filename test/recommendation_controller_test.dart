import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStore implements RecommendationEventStore {
  final values = <String, Object>{};

  @override
  Future<void> delete(String storageKey) async => values.remove(storageKey);

  @override
  Object? read(String storageKey) => values[storageKey];

  @override
  Future<void> write(String storageKey, Object value) async {
    values[storageKey] = value;
  }
}

RecommendationEvent _behavior(int index, DateTime at) => RecommendationEvent(
  id: 'behavior-$index',
  type: RecommendationEventType.effectiveWatch,
  workKey: 'work-$index',
  occurredAt: at,
  contentType: SubjectContentType.anime,
);

RecommendationServedEvent _served(int index, DateTime at) =>
    RecommendationServedEvent(
      id: 'served-$index',
      workKey: 'served-work-$index',
      servedAt: at,
      contentType: SubjectContentType.anime,
      surface: 'home',
    );

void main() {
  test('uses the two agreed account-scoped storage keys', () async {
    final store = _MemoryStore();
    final now = DateTime.utc(2026, 8, 9);
    final controller = RecommendationController(store: store, clock: () => now);
    await controller.loadForAccount(accountId: 'a', contextVersion: 1);
    await controller.record(_behavior(1, now));
    await controller.recordServed([_served(1, now)]);

    expect(
      store.values,
      contains('account.a.$recommendationBehaviorStorageKey'),
    );
    expect(store.values, contains('account.a.$recommendationServedStorageKey'));
    expect(store.values, isNot(contains(recommendationBehaviorStorageKey)));
  });

  test('caps behavior at 500 and served history at 300', () async {
    final store = _MemoryStore();
    final now = DateTime.utc(2026, 8, 9);
    final controller = RecommendationController(store: store, clock: () => now);
    await controller.loadForAccount(accountId: 'a', contextVersion: 1);
    for (var i = 0; i < 520; i++) {
      await controller.record(_behavior(i, now.subtract(Duration(minutes: i))));
    }
    await controller.recordServed([
      for (var i = 0; i < 320; i++)
        _served(i, now.subtract(Duration(minutes: i))),
    ]);

    expect(controller.snapshot.behaviors, hasLength(500));
    expect(controller.snapshot.served, hasLength(300));
    expect(controller.snapshot.behaviors.first.id, 'behavior-0');
    expect(controller.snapshot.served.first.id, 'served-0');
  });

  test(
    'drops behavior older than 180 days and served rows older than 14 days',
    () async {
      final store = _MemoryStore();
      final now = DateTime.utc(2026, 8, 9);
      store.values[recommendationBehaviorStorageKey] = {
        'version': 1,
        'events': [
          _behavior(1, now.subtract(const Duration(days: 181))).toJson(),
          _behavior(2, now.subtract(const Duration(days: 180))).toJson(),
        ],
      };
      store.values[recommendationServedStorageKey] = {
        'version': 1,
        'events': [
          _served(1, now.subtract(const Duration(days: 15))).toJson(),
          _served(2, now.subtract(const Duration(days: 14))).toJson(),
        ],
      };
      final controller = RecommendationController(
        store: store,
        clock: () => now,
      );
      await controller.loadForAccount(accountId: null, contextVersion: 1);

      expect(controller.snapshot.behaviors.single.id, 'behavior-2');
      expect(controller.snapshot.served.single.id, 'served-2');
    },
  );

  test(
    'account switch isolates snapshots and rejects an old context version',
    () async {
      final store = _MemoryStore();
      final now = DateTime.utc(2026, 8, 9);
      final controller = RecommendationController(
        store: store,
        clock: () => now,
      );
      await controller.loadForAccount(accountId: 'a', contextVersion: 1);
      expect(await controller.record(_behavior(1, now)), isTrue);
      await controller.loadForAccount(accountId: 'b', contextVersion: 2);

      expect(controller.snapshot.behaviors, isEmpty);
      expect(
        await controller.record(_behavior(2, now), expectedContextVersion: 1),
        isFalse,
      );
      expect(controller.snapshot.behaviors, isEmpty);
      await controller.loadForAccount(accountId: 'a', contextVersion: 3);
      expect(controller.snapshot.behaviors.single.id, 'behavior-1');
    },
  );

  test('guest migration merges by event ID and clears guest keys', () async {
    final store = _MemoryStore();
    final now = DateTime.utc(2026, 8, 9);
    store.values[recommendationBehaviorStorageKey] = {
      'version': 1,
      'events': [_behavior(1, now).toJson()],
    };
    store.values[recommendationServedStorageKey] = {
      'version': 1,
      'events': [_served(1, now).toJson()],
    };
    store.values['account.a.$recommendationBehaviorStorageKey'] = {
      'version': 1,
      'events': [_behavior(1, now).toJson(), _behavior(2, now).toJson()],
    };
    final controller = RecommendationController(store: store, clock: () => now);
    await controller.loadForAccount(accountId: 'a', contextVersion: 1);
    await controller.migrateGuestToAccount('a');

    expect(controller.snapshot.behaviors, hasLength(2));
    expect(controller.snapshot.served, hasLength(1));
    expect(store.values, isNot(contains(recommendationBehaviorStorageKey)));
    expect(store.values, isNot(contains(recommendationServedStorageKey)));
  });

  test('malformed rows are skipped without losing the valid profile', () async {
    final store = _MemoryStore();
    final now = DateTime.utc(2026, 8, 9);
    store.values[recommendationBehaviorStorageKey] = {
      'version': 1,
      'events': [
        {'type': 'not-a-type'},
        _behavior(1, now).toJson(),
      ],
    };
    final controller = RecommendationController(store: store, clock: () => now);
    await controller.loadForAccount(accountId: null, contextVersion: 1);

    expect(controller.snapshot.behaviors.single.id, 'behavior-1');
    expect(controller.snapshot.profile.workWeights['work-1'], 2);
  });
}
