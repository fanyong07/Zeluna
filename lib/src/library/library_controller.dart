import 'dart:async';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../accounts/account_controller.dart';
import '../accounts/local_account_repository.dart';
import '../core/identity/stable_identity.dart';
import '../domain/anime_models.dart';
import '../sync/cloud_sync_transport.dart';

abstract interface class LibraryStorage {
  Object? get(String key);

  Future<void> put(String key, Object? value);
}

final class HiveLibraryStorage implements LibraryStorage {
  const HiveLibraryStorage(this._box);

  final Box<dynamic> _box;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);
}

final class LibraryMutationContext {
  const LibraryMutationContext({
    required this.accountId,
    required this.contextVersion,
  });

  final String? accountId;
  final int contextVersion;
}

typedef LibrarySnapshotPublisher = void Function(LibrarySnapshot snapshot);
typedef LibraryHistorySynchronizer =
    Future<void> Function(
      LibraryMutationContext context,
      AnimeSubject subject,
      AnimeEpisode? episode,
    );
typedef LibraryCloudMutationWriter =
    Future<bool> Function(
      LibraryMutationContext context,
      CloudSyncRecordType type,
      LibraryEntry entry, {
      required bool deleted,
    });
typedef LibraryPlaybackMutationWriter =
    Future<bool> Function(LibraryMutationContext context, LibraryEntry entry);

final class LibrarySnapshot {
  const LibrarySnapshot({
    this.favorites = const [],
    this.history = const [],
    this.following = const [],
    this.imageFavorites = const [],
    this.feedbacks = const [],
  });

  final List<LibraryEntry> favorites;
  final List<LibraryEntry> history;
  final List<LibraryEntry> following;
  final List<LibraryEntry> imageFavorites;
  final List<LocalFeedback> feedbacks;

  LibrarySnapshot copyWith({
    List<LibraryEntry>? favorites,
    List<LibraryEntry>? history,
    List<LibraryEntry>? following,
    List<LibraryEntry>? imageFavorites,
    List<LocalFeedback>? feedbacks,
  }) => LibrarySnapshot(
    favorites: favorites ?? this.favorites,
    history: history ?? this.history,
    following: following ?? this.following,
    imageFavorites: imageFavorites ?? this.imageFavorites,
    feedbacks: feedbacks ?? this.feedbacks,
  );
}

/// Owns account-scoped local library state and ordered persistence.
///
/// Cloud synchronization remains an explicit port so the later Sync domain can
/// consume mutations without taking ownership of local Hive state.
final class LibraryController {
  LibraryController({
    required LibraryStorage storage,
    required LibrarySnapshotPublisher publishSnapshot,
    required LibraryHistorySynchronizer syncHistory,
    LibraryCloudMutationWriter? writeCloudMutation,
    LibraryPlaybackMutationWriter? writePlaybackMutation,
    DateTime Function()? now,
  }) : _storage = storage,
       _publishSnapshot = publishSnapshot,
       _syncHistory = syncHistory,
       _writeCloudMutation = writeCloudMutation,
       _writePlaybackMutation = writePlaybackMutation,
       _now = now ?? DateTime.now;

  final LibraryStorage _storage;
  final LibrarySnapshotPublisher _publishSnapshot;
  final LibraryHistorySynchronizer _syncHistory;
  final LibraryCloudMutationWriter? _writeCloudMutation;
  final LibraryPlaybackMutationWriter? _writePlaybackMutation;
  final DateTime Function() _now;

  LibrarySnapshot _snapshot = const LibrarySnapshot();
  String? _accountId;
  var _contextVersion = 0;
  var _scopeEpoch = 0;
  var _loaded = false;
  var _disposed = false;
  Future<void> _mutationQueue = Future<void>.value();

  LibrarySnapshot get snapshot => _snapshot;
  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;
  bool get isLoaded => _loaded;

  Future<LibrarySnapshot> loadForAccount({
    required String? accountId,
    required int contextVersion,
  }) async {
    _ensureNotDisposed();
    final scope = _LibraryScope(
      accountId: accountId,
      contextVersion: contextVersion,
      epoch: ++_scopeEpoch,
    );
    _accountId = accountId;
    _contextVersion = contextVersion;
    _loaded = false;
    await _mutationQueue;
    _ensureConfigured(scope);
    _snapshot = _freeze(
      LibrarySnapshot(
        favorites: _readEntries(scope, 'favorites'),
        history: _readEntries(scope, 'history'),
        following: _readEntries(scope, 'following'),
        imageFavorites: _readEntries(scope, 'imageFavorites'),
        feedbacks: _readFeedbacks(scope),
      ),
    );
    _loaded = true;
    return _snapshot;
  }

  Future<bool> toggleFavorite(AnimeSubject subject) => _mutate((scope) async {
    final previous = _entryForSubject(_snapshot.favorites, subject);
    final next = _toggleSubject(_snapshot.favorites, subject, _now());
    _publish(scope, _snapshot.copyWith(favorites: next));
    final current = _entryForSubject(next, subject);
    await _recordCloudLibrary(
      scope,
      CloudSyncRecordType.favorite,
      current ?? previous!,
      deleted: current == null,
    );
    await _persistEntries(scope, 'favorites', next);
    _ensureScope(scope);
    return next.any((item) => sameSubjectIdentity(item.subject, subject));
  });

  Future<bool> toggleFollowing(AnimeSubject subject) => _mutate((scope) async {
    final previous = _entryForSubject(_snapshot.following, subject);
    final next = _toggleSubject(_snapshot.following, subject, _now());
    _publish(scope, _snapshot.copyWith(following: next));
    final current = _entryForSubject(next, subject);
    await _recordCloudLibrary(
      scope,
      CloudSyncRecordType.following,
      current ?? previous!,
      deleted: current == null,
    );
    await _persistEntries(scope, 'following', next);
    _ensureScope(scope);
    return next.any((item) => sameSubjectIdentity(item.subject, subject));
  });

  Future<bool> addHistory(
    AnimeSubject subject,
    AnimeEpisode? episode, {
    int? expectedContextVersion,
  }) => _mutate((scope) async {
    if (expectedContextVersion != null &&
        expectedContextVersion != scope.contextVersion) {
      return false;
    }
    final previous = _entryForSubject(_snapshot.history, subject);
    final sameEpisode = previous?.episode?.id == episode?.id;
    final entry = LibraryEntry(
      subject: subject,
      episode: episode,
      updatedAt: _now(),
      note: episode == null ? '打开详情' : '播放到 ${episode.displayTitle}',
      positionSeconds: sameEpisode ? previous!.positionSeconds : 0,
      durationSeconds: sameEpisode ? previous!.durationSeconds : 0,
    );
    final next = <LibraryEntry>[
      entry,
      ..._snapshot.history.where(
        (item) => !sameSubjectIdentity(item.subject, subject),
      ),
    ].take(80).toList(growable: false);
    _publish(scope, _snapshot.copyWith(history: next));
    await _recordCloudLibrary(
      scope,
      CloudSyncRecordType.history,
      entry,
      deleted: false,
    );
    await _persistEntries(scope, 'history', next);
    _ensureScope(scope);
    await _syncHistory(
      LibraryMutationContext(
        accountId: scope.accountId,
        contextVersion: scope.contextVersion,
      ),
      subject,
      episode,
    );
    return _isCurrent(scope);
  });

  Future<void> updatePlaybackProgress(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required Duration position,
    required Duration duration,
    int? expectedContextVersion,
  }) => _mutate((scope) async {
    if (expectedContextVersion != null &&
        expectedContextVersion != scope.contextVersion) {
      return;
    }
    var positionSeconds = position.inSeconds;
    final durationSeconds = duration.inSeconds;
    if (positionSeconds < 5) return;
    if (durationSeconds > 0 &&
        (positionSeconds >= durationSeconds - 15 ||
            positionSeconds / durationSeconds >= 0.98)) {
      positionSeconds = 0;
    }
    LibraryEntry? updatedEntry;
    final next = _snapshot.history
        .map((item) {
          if (!sameSubjectIdentity(item.subject, subject) ||
              item.episode?.id != episode.id) {
            return item;
          }
          updatedEntry = item.copyWith(
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            updatedAt: _now(),
          );
          return updatedEntry!;
        })
        .toList(growable: false);
    if (updatedEntry == null) return;
    _publish(scope, _snapshot.copyWith(history: next));
    await _recordCloudPlayback(scope, updatedEntry!);
    await _persistEntries(scope, 'history', next);
  });

  Future<void> addImageFavorite(AnimeSubject subject) => _mutate((scope) async {
    final next = <LibraryEntry>[
      LibraryEntry(subject: subject, updatedAt: _now(), note: '收藏封面图'),
      ..._snapshot.imageFavorites.where(
        (item) => !sameSubjectIdentity(item.subject, subject),
      ),
    ].take(80).toList(growable: false);
    _publish(scope, _snapshot.copyWith(imageFavorites: next));
    await _persistEntries(scope, 'imageFavorites', next);
  });

  Future<void> clear(String key) => _mutate((scope) async {
    final previousHistory = key == 'history'
        ? _snapshot.history
        : const <LibraryEntry>[];
    final next = switch (key) {
      'history' => _snapshot.copyWith(history: const []),
      'imageFavorites' => _snapshot.copyWith(imageFavorites: const []),
      'feedbacks' => _snapshot.copyWith(feedbacks: const []),
      _ => null,
    };
    if (next == null) return;
    _publish(scope, next);
    for (final entry in previousHistory) {
      await _recordCloudLibrary(
        scope,
        CloudSyncRecordType.history,
        entry,
        deleted: true,
      );
    }
    await _storage.put(_storageKey(scope.accountId, key), const []);
    _ensureScope(scope);
  });

  Future<void> submitFeedback({
    required String title,
    required String content,
    AnimeSubject? subject,
  }) => _mutate((scope) async {
    final timestamp = _now();
    final normalizedTitle = title.trim().isEmpty ? '未命名反馈' : title.trim();
    final normalizedContent = content.trim();
    final feedback = LocalFeedback(
      id: 'feedback:$stableIdentityVersion:${stableDigest('${scope.accountId ?? 'guest'}|${timestamp.toUtc().toIso8601String()}|$normalizedTitle|$normalizedContent')}',
      title: normalizedTitle,
      content: normalizedContent,
      createdAt: timestamp,
      subject: subject,
    );
    final next = <LocalFeedback>[
      feedback,
      ..._snapshot.feedbacks,
    ].take(80).toList(growable: false);
    _publish(scope, _snapshot.copyWith(feedbacks: next));
    await _storage.put(
      _storageKey(scope.accountId, 'feedbacks'),
      next.map((item) => item.toJson()).toList(growable: false),
    );
    _ensureScope(scope);
  });

  Future<void> settleWrites() => _mutationQueue;

  Future<void> applyRemoteRecord(CloudSyncRecord record) =>
      _mutate((scope) async {
        switch (record.type) {
          case CloudSyncRecordType.favorite:
            await _applyRemoteLibrary(scope, 'favorites', record);
          case CloudSyncRecordType.following:
            await _applyRemoteLibrary(scope, 'following', record);
          case CloudSyncRecordType.history:
            await _applyRemoteLibrary(scope, 'history', record);
          case CloudSyncRecordType.playbackPosition:
            await _applyRemotePlayback(scope, record);
          case CloudSyncRecordType.appearanceSettings ||
              CloudSyncRecordType.playbackSettings:
            throw ArgumentError.value(record.type, 'record');
        }
      });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    _scopeEpoch++;
  }

  Future<T> _mutate<T>(Future<T> Function(_LibraryScope scope) action) {
    final scope = _scope();
    final completer = Completer<T>();
    final operation = _mutationQueue.then((_) async {
      try {
        _ensureScope(scope);
        completer.complete(await action(scope));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _mutationQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return completer.future;
  }

  List<LibraryEntry> _readEntries(_LibraryScope scope, String key) {
    final value = _storage.get(_storageKey(scope.accountId, key));
    if (value is! List) return const [];
    final entries = <LibraryEntry>[];
    for (final raw in value.whereType<Map>()) {
      try {
        final entry = LibraryEntry.fromJson(raw.cast<String, dynamic>());
        if (entry.subject.title.trim().isNotEmpty) entries.add(entry);
      } catch (_) {
        // Preserve malformed persisted data; loading skips only the bad row.
      }
    }
    return entries;
  }

  List<LocalFeedback> _readFeedbacks(_LibraryScope scope) {
    final value = _storage.get(_storageKey(scope.accountId, 'feedbacks'));
    if (value is! List) return const [];
    final feedbacks = <LocalFeedback>[];
    for (final raw in value.whereType<Map>()) {
      try {
        final feedback = LocalFeedback.fromJson(raw.cast<String, dynamic>());
        if (feedback.title.trim().isNotEmpty) feedbacks.add(feedback);
      } catch (_) {
        // Preserve malformed persisted data; loading skips only the bad row.
      }
    }
    return feedbacks;
  }

  Future<void> _persistEntries(
    _LibraryScope scope,
    String key,
    List<LibraryEntry> entries,
  ) async {
    await _storage.put(
      _storageKey(scope.accountId, key),
      entries.map((item) => item.toJson()).toList(growable: false),
    );
    _ensureScope(scope);
  }

  Future<void> _recordCloudLibrary(
    _LibraryScope scope,
    CloudSyncRecordType type,
    LibraryEntry entry, {
    required bool deleted,
  }) async {
    final writer = _writeCloudMutation;
    if (writer == null || scope.accountId == null) return;
    try {
      await writer(
        LibraryMutationContext(
          accountId: scope.accountId,
          contextVersion: scope.contextVersion,
        ),
        type,
        entry,
        deleted: deleted,
      );
    } catch (_) {
      // Local persistence remains authoritative while sync reports its error.
    }
    _ensureScope(scope);
  }

  Future<void> _recordCloudPlayback(
    _LibraryScope scope,
    LibraryEntry entry,
  ) async {
    final writer = _writePlaybackMutation;
    if (writer == null || scope.accountId == null) return;
    try {
      await writer(
        LibraryMutationContext(
          accountId: scope.accountId,
          contextVersion: scope.contextVersion,
        ),
        entry,
      );
    } catch (_) {
      // Playback resume remains locally persisted when cloud sync is offline.
    }
    _ensureScope(scope);
  }

  Future<void> _applyRemoteLibrary(
    _LibraryScope scope,
    String key,
    CloudSyncRecord record,
  ) async {
    final current = switch (key) {
      'favorites' => _snapshot.favorites,
      'following' => _snapshot.following,
      'history' => _snapshot.history,
      _ => throw ArgumentError.value(key, 'key'),
    };
    final nextEntries = current
        .where((item) => item.subject.identityKey != record.recordId)
        .toList(growable: true);
    if (!record.deleted) {
      final entry = LibraryEntry.fromJson(record.payload);
      if (entry.subject.identityKey != record.recordId) {
        throw const FormatException('Remote library identity mismatch.');
      }
      nextEntries.insert(0, entry);
    }
    final bounded = nextEntries.take(80).toList(growable: false);
    final next = switch (key) {
      'favorites' => _snapshot.copyWith(favorites: bounded),
      'following' => _snapshot.copyWith(following: bounded),
      'history' => _snapshot.copyWith(history: bounded),
      _ => throw ArgumentError.value(key, 'key'),
    };
    _publish(scope, next);
    await _persistEntries(scope, key, bounded);
  }

  Future<void> _applyRemotePlayback(
    _LibraryScope scope,
    CloudSyncRecord record,
  ) async {
    final subjectJson = record.payload['subject'];
    final episodeJson = record.payload['episode'];
    if (subjectJson is! Map || episodeJson is! Map) {
      throw const FormatException('Remote playback payload is invalid.');
    }
    final subject = AnimeSubject.fromJson(subjectJson.cast<String, dynamic>());
    final episode = AnimeEpisode.fromJson(episodeJson.cast<String, dynamic>());
    if (episode.identityKey(subjectKey: subject.identityKey) !=
        record.recordId) {
      throw const FormatException('Remote playback identity mismatch.');
    }
    final updatedAt = DateTime.tryParse(
      record.payload['updatedAt']?.toString() ?? '',
    );
    if (updatedAt == null) {
      throw const FormatException('Remote playback timestamp is invalid.');
    }
    final position = (record.payload['positionSeconds'] as num?)?.toInt() ?? 0;
    final duration = (record.payload['durationSeconds'] as num?)?.toInt() ?? 0;
    final next = _snapshot.history.toList(growable: true);
    final index = next.indexWhere(
      (item) =>
          item.episode?.identityKey(subjectKey: item.subject.identityKey) ==
          record.recordId,
    );
    if (record.deleted) {
      if (index >= 0) {
        next[index] = next[index].copyWith(
          positionSeconds: 0,
          durationSeconds: 0,
          updatedAt: updatedAt,
        );
      }
    } else {
      final entry = LibraryEntry(
        subject: subject,
        episode: episode,
        updatedAt: updatedAt,
        note: index >= 0 ? next[index].note : '',
        positionSeconds: position,
        durationSeconds: duration,
      );
      if (index >= 0) {
        next[index] = entry;
      } else {
        next.insert(0, entry);
      }
    }
    final bounded = next.take(80).toList(growable: false);
    _publish(scope, _snapshot.copyWith(history: bounded));
    await _persistEntries(scope, 'history', bounded);
  }

  void _publish(_LibraryScope scope, LibrarySnapshot snapshot) {
    _ensureScope(scope);
    _snapshot = _freeze(snapshot);
    _publishSnapshot(_snapshot);
  }

  LibrarySnapshot _freeze(LibrarySnapshot snapshot) => LibrarySnapshot(
    favorites: List<LibraryEntry>.unmodifiable(snapshot.favorites),
    history: List<LibraryEntry>.unmodifiable(snapshot.history),
    following: List<LibraryEntry>.unmodifiable(snapshot.following),
    imageFavorites: List<LibraryEntry>.unmodifiable(snapshot.imageFavorites),
    feedbacks: List<LocalFeedback>.unmodifiable(snapshot.feedbacks),
  );

  String _storageKey(String? accountId, String key) =>
      AccountController.libraryKeyFor(accountId, key);

  _LibraryScope get _currentScope => _LibraryScope(
    accountId: _accountId,
    contextVersion: _contextVersion,
    epoch: _scopeEpoch,
  );

  _LibraryScope _scope() {
    _ensureNotDisposed();
    if (!_loaded) throw StateError('LibraryController has not been loaded');
    return _currentScope;
  }

  bool _isConfigured(_LibraryScope scope) =>
      !_disposed &&
      _accountId == scope.accountId &&
      _contextVersion == scope.contextVersion &&
      _scopeEpoch == scope.epoch;

  bool _isCurrent(_LibraryScope scope) => _loaded && _isConfigured(scope);

  void _ensureConfigured(_LibraryScope scope) {
    if (!_isConfigured(scope)) {
      throw const AccountException('账号已切换，请重新打开媒体库');
    }
  }

  void _ensureScope(_LibraryScope scope) {
    if (!_isCurrent(scope)) {
      throw const AccountException('账号已切换，请在当前账号下重新操作');
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('LibraryController has been disposed');
  }
}

final class _LibraryScope {
  const _LibraryScope({
    required this.accountId,
    required this.contextVersion,
    required this.epoch,
  });

  final String? accountId;
  final int contextVersion;
  final int epoch;
}

List<LibraryEntry> _toggleSubject(
  List<LibraryEntry> entries,
  AnimeSubject subject,
  DateTime timestamp,
) {
  final exists = entries.any(
    (item) => sameSubjectIdentity(item.subject, subject),
  );
  if (exists) {
    return entries
        .where((item) => !sameSubjectIdentity(item.subject, subject))
        .toList(growable: false);
  }
  return [LibraryEntry(subject: subject, updatedAt: timestamp), ...entries];
}

LibraryEntry? _entryForSubject(
  List<LibraryEntry> entries,
  AnimeSubject subject,
) {
  for (final entry in entries) {
    if (sameSubjectIdentity(entry.subject, subject)) return entry;
  }
  return null;
}
