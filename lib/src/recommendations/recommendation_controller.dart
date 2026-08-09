import 'dart:async';

import 'recommendation_models.dart';
import 'recommendation_profile.dart';

const recommendationBehaviorLimit = 500;
const recommendationBehaviorRetention = Duration(days: 180);
const recommendationServedLimit = 300;
const recommendationServedRetention = Duration(days: 14);

typedef RecommendationSnapshotListener =
    void Function(RecommendationSnapshot snapshot);

class RecommendationSnapshot {
  RecommendationSnapshot({
    required this.accountId,
    required this.contextVersion,
    required List<RecommendationEvent> behaviors,
    required List<RecommendationServedEvent> served,
    required this.profile,
    required this.generatedAt,
  }) : behaviors = List<RecommendationEvent>.unmodifiable(behaviors),
       served = List<RecommendationServedEvent>.unmodifiable(served);

  factory RecommendationSnapshot.empty({
    String? accountId,
    int contextVersion = 0,
    DateTime? generatedAt,
  }) => RecommendationSnapshot(
    accountId: accountId,
    contextVersion: contextVersion,
    behaviors: const <RecommendationEvent>[],
    served: const <RecommendationServedEvent>[],
    profile: RecommendationProfile.empty(),
    generatedAt: generatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String? accountId;
  final int contextVersion;
  final List<RecommendationEvent> behaviors;
  final List<RecommendationServedEvent> served;
  final RecommendationProfile profile;
  final DateTime generatedAt;
}

/// Owns the bounded, account-scoped local recommendation event timeline.
///
/// It deliberately knows nothing about Hive, Riverpod or UI widgets. A caller
/// supplies a tiny store adapter and an account context version. Every queued
/// write re-checks its captured scope so an old account cannot write into a
/// newly selected account.
final class RecommendationController {
  RecommendationController({
    required RecommendationEventStore store,
    RecommendationSnapshotListener? onChanged,
    DateTime Function()? clock,
  }) : _store = store,
       _onChanged = onChanged,
       _clock = clock ?? DateTime.now;

  final RecommendationEventStore _store;
  final RecommendationSnapshotListener? _onChanged;
  final DateTime Function() _clock;

  RecommendationSnapshot _snapshot = RecommendationSnapshot.empty();
  String? _accountId;
  var _contextVersion = 0;
  var _scopeEpoch = 0;
  var _loaded = false;
  var _disposed = false;
  Future<void> _writeQueue = Future<void>.value();

  RecommendationSnapshot get snapshot => _snapshot;
  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;
  bool get isLoaded => _loaded;

  Future<RecommendationSnapshot> loadForAccount({
    required String? accountId,
    required int contextVersion,
  }) async {
    _ensureNotDisposed();
    final normalizedAccountId = _normalizeAccountId(accountId);
    final scope = _RecommendationScope(
      accountId: normalizedAccountId,
      contextVersion: contextVersion,
      epoch: ++_scopeEpoch,
    );
    _accountId = normalizedAccountId;
    _contextVersion = contextVersion;
    _loaded = false;
    await _writeQueue;
    _ensureConfigured(scope);
    final now = _clock();
    final behaviors = _readBehaviors(normalizedAccountId, now);
    final served = _readServed(normalizedAccountId, now);
    _snapshot = _buildSnapshot(scope, behaviors, served, now);
    _loaded = true;
    _onChanged?.call(_snapshot);
    return _snapshot;
  }

  Future<bool> record(
    RecommendationEvent event, {
    int? expectedContextVersion,
  }) => _mutate((scope) async {
    if (expectedContextVersion != null &&
        expectedContextVersion != scope.contextVersion) {
      return false;
    }
    final now = _clock();
    final next = _boundedBehaviors(<RecommendationEvent>[
      event,
      ..._snapshot.behaviors.where((item) => item.id != event.id),
    ], now);
    await _store.write(
      recommendationScopedStorageKey(
        scope.accountId,
        recommendationBehaviorStorageKey,
      ),
      _behaviorPayload(next),
    );
    _ensureScope(scope);
    _publish(scope, next, _snapshot.served, now);
    return true;
  });

  Future<bool> recordServed(
    Iterable<RecommendationServedEvent> events, {
    int? expectedContextVersion,
  }) => _mutate((scope) async {
    if (expectedContextVersion != null &&
        expectedContextVersion != scope.contextVersion) {
      return false;
    }
    final incoming = events.toList(growable: false);
    if (incoming.isEmpty) return true;
    final ids = incoming.map((item) => item.id).toSet();
    final now = _clock();
    final next = _boundedServed(<RecommendationServedEvent>[
      ...incoming,
      ..._snapshot.served.where((item) => !ids.contains(item.id)),
    ], now);
    await _store.write(
      recommendationScopedStorageKey(
        scope.accountId,
        recommendationServedStorageKey,
      ),
      _servedPayload(next),
    );
    _ensureScope(scope);
    _publish(scope, _snapshot.behaviors, next, now);
    return true;
  });

  Future<void> clearForCurrentAccount({int? expectedContextVersion}) =>
      _mutate((scope) async {
        if (expectedContextVersion != null &&
            expectedContextVersion != scope.contextVersion) {
          return;
        }
        await _deleteScope(scope.accountId);
        _ensureScope(scope);
        _publish(scope, const [], const [], _clock());
      });

  /// Merges guest events into a new account without overwriting existing
  /// account events, then removes the guest keys. This is idempotent by event
  /// ID and can safely be retried after an interrupted registration.
  Future<void> migrateGuestToAccount(String accountId) async {
    _ensureNotDisposed();
    final normalized = _normalizeAccountId(accountId);
    if (normalized == null) throw ArgumentError.value(accountId, 'accountId');
    final operation = _writeQueue.then((_) async {
      final now = _clock();
      final guestBehaviors = _readBehaviors(null, now);
      final accountBehaviors = _readBehaviors(normalized, now);
      final guestServed = _readServed(null, now);
      final accountServed = _readServed(normalized, now);
      final behaviors = _mergeBehaviors(accountBehaviors, guestBehaviors, now);
      final served = _mergeServed(accountServed, guestServed, now);
      await _store.write(
        recommendationScopedStorageKey(
          normalized,
          recommendationBehaviorStorageKey,
        ),
        _behaviorPayload(behaviors),
      );
      await _store.write(
        recommendationScopedStorageKey(
          normalized,
          recommendationServedStorageKey,
        ),
        _servedPayload(served),
      );
      await _deleteScope(null);
      if (_loaded && _accountId == normalized) {
        final scope = _currentScope;
        _publish(scope, behaviors, served, now);
      } else if (_loaded && _accountId == null) {
        final scope = _currentScope;
        _publish(scope, const [], const [], now);
      }
    });
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }

  Future<void> clearForAccount(String? accountId) async {
    _ensureNotDisposed();
    final normalized = _normalizeAccountId(accountId);
    final operation = _writeQueue.then((_) async {
      await _deleteScope(normalized);
      if (_loaded && _accountId == normalized) {
        final scope = _currentScope;
        _publish(scope, const [], const [], _clock());
      }
    });
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }

  Future<void> settleWrites() => _writeQueue;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    _scopeEpoch++;
  }

  Future<T> _mutate<T>(Future<T> Function(_RecommendationScope scope) action) {
    final scope = _scope();
    final completer = Completer<T>();
    final operation = _writeQueue.then((_) async {
      try {
        _ensureScope(scope);
        completer.complete(await action(scope));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return completer.future;
  }

  List<RecommendationEvent> _readBehaviors(String? accountId, DateTime now) {
    try {
      final raw = _store.read(
        recommendationScopedStorageKey(
          accountId,
          recommendationBehaviorStorageKey,
        ),
      );
      final rows = raw is Map ? raw['events'] : raw;
      if (rows is! Iterable) return const [];
      final events = <RecommendationEvent>[];
      for (final row in rows.whereType<Map>()) {
        try {
          events.add(RecommendationEvent.fromJson(row.cast<String, dynamic>()));
        } catch (_) {
          // One corrupt event never blocks the account's remaining profile.
        }
      }
      return _boundedBehaviors(events, now);
    } catch (_) {
      return const [];
    }
  }

  List<RecommendationServedEvent> _readServed(String? accountId, DateTime now) {
    try {
      final raw = _store.read(
        recommendationScopedStorageKey(
          accountId,
          recommendationServedStorageKey,
        ),
      );
      final rows = raw is Map ? raw['events'] : raw;
      if (rows is! Iterable) return const [];
      final events = <RecommendationServedEvent>[];
      for (final row in rows.whereType<Map>()) {
        try {
          events.add(
            RecommendationServedEvent.fromJson(row.cast<String, dynamic>()),
          );
        } catch (_) {
          // Ignore only the malformed event.
        }
      }
      return _boundedServed(events, now);
    } catch (_) {
      return const [];
    }
  }

  RecommendationSnapshot _buildSnapshot(
    _RecommendationScope scope,
    List<RecommendationEvent> behaviors,
    List<RecommendationServedEvent> served,
    DateTime now,
  ) => RecommendationSnapshot(
    accountId: scope.accountId,
    contextVersion: scope.contextVersion,
    behaviors: behaviors,
    served: served,
    profile: RecommendationProfile.fromEvents(
      behaviors: behaviors,
      served: served,
      now: now,
    ),
    generatedAt: now,
  );

  void _publish(
    _RecommendationScope scope,
    List<RecommendationEvent> behaviors,
    List<RecommendationServedEvent> served,
    DateTime now,
  ) {
    _ensureScope(scope);
    _snapshot = _buildSnapshot(scope, behaviors, served, now);
    _onChanged?.call(_snapshot);
  }

  Future<void> _deleteScope(String? accountId) async {
    await _store.delete(
      recommendationScopedStorageKey(
        accountId,
        recommendationBehaviorStorageKey,
      ),
    );
    await _store.delete(
      recommendationScopedStorageKey(accountId, recommendationServedStorageKey),
    );
  }

  _RecommendationScope get _currentScope => _RecommendationScope(
    accountId: _accountId,
    contextVersion: _contextVersion,
    epoch: _scopeEpoch,
  );

  _RecommendationScope _scope() {
    _ensureNotDisposed();
    if (!_loaded) throw StateError('RecommendationController is not loaded.');
    return _currentScope;
  }

  bool _isConfigured(_RecommendationScope scope) =>
      !_disposed &&
      scope.accountId == _accountId &&
      scope.contextVersion == _contextVersion &&
      scope.epoch == _scopeEpoch;

  bool _isCurrent(_RecommendationScope scope) =>
      _loaded && _isConfigured(scope);

  void _ensureConfigured(_RecommendationScope scope) {
    if (!_isConfigured(scope)) {
      throw StateError('Recommendation account context changed.');
    }
  }

  void _ensureScope(_RecommendationScope scope) {
    if (!_isCurrent(scope)) {
      throw StateError('Recommendation account context changed.');
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('RecommendationController is disposed.');
  }
}

final class _RecommendationScope {
  const _RecommendationScope({
    required this.accountId,
    required this.contextVersion,
    required this.epoch,
  });

  final String? accountId;
  final int contextVersion;
  final int epoch;
}

List<RecommendationEvent> _boundedBehaviors(
  Iterable<RecommendationEvent> events,
  DateTime now,
) {
  final cutoff = now.subtract(recommendationBehaviorRetention);
  final byId = <String, RecommendationEvent>{};
  for (final event in events) {
    if (event.occurredAt.isBefore(cutoff)) continue;
    final current = byId[event.id];
    if (current == null || event.occurredAt.isAfter(current.occurredAt)) {
      byId[event.id] = event;
    }
  }
  final bounded = byId.values.toList(growable: false)
    ..sort((a, b) {
      final byTime = b.occurredAt.compareTo(a.occurredAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  return List<RecommendationEvent>.unmodifiable(
    bounded.take(recommendationBehaviorLimit),
  );
}

List<RecommendationServedEvent> _boundedServed(
  Iterable<RecommendationServedEvent> events,
  DateTime now,
) {
  final cutoff = now.subtract(recommendationServedRetention);
  final byId = <String, RecommendationServedEvent>{};
  for (final event in events) {
    if (event.servedAt.isBefore(cutoff)) continue;
    final current = byId[event.id];
    if (current == null || event.servedAt.isAfter(current.servedAt)) {
      byId[event.id] = event;
    }
  }
  final bounded = byId.values.toList(growable: false)
    ..sort((a, b) {
      final byTime = b.servedAt.compareTo(a.servedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  return List<RecommendationServedEvent>.unmodifiable(
    bounded.take(recommendationServedLimit),
  );
}

List<RecommendationEvent> _mergeBehaviors(
  Iterable<RecommendationEvent> first,
  Iterable<RecommendationEvent> second,
  DateTime now,
) => _boundedBehaviors(<RecommendationEvent>[...first, ...second], now);

List<RecommendationServedEvent> _mergeServed(
  Iterable<RecommendationServedEvent> first,
  Iterable<RecommendationServedEvent> second,
  DateTime now,
) => _boundedServed(<RecommendationServedEvent>[...first, ...second], now);

Map<String, Object> _behaviorPayload(List<RecommendationEvent> events) =>
    <String, Object>{
      'version': 1,
      'events': events.map((item) => item.toJson()).toList(growable: false),
    };

Map<String, Object> _servedPayload(List<RecommendationServedEvent> events) =>
    <String, Object>{
      'version': 1,
      'events': events.map((item) => item.toJson()).toList(growable: false),
    };

String? _normalizeAccountId(String? value) {
  final normalized = value?.trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}
