import 'dart:async';
import 'dart:math';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../domain/anime_models.dart';
import 'cloud_sync_transport.dart';

typedef SyncHistoryUploader =
    Future<bool> Function(
      AnimeSubject subject,
      AnimeEpisode? episode,
      ExternalServiceSettings services,
    );
typedef SyncContextGuard = bool Function(int contextVersion);
typedef SyncLocalSnapshotReader = SyncLocalSnapshot Function();
typedef SyncRecordApplier = Future<void> Function(CloudSyncRecord record);
typedef SyncStatusPublisher = void Function(SyncStatus status);

abstract interface class SyncStorage {
  Object? get(String key);

  Future<void> put(String key, Object? value);
}

final class HiveSyncStorage implements SyncStorage {
  const HiveSyncStorage(this._box);

  final Box<dynamic> _box;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);
}

enum SyncPhase { localOnly, checking, pending, synced, offline, expired, error }

final class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.pendingMutations = 0,
    this.lastSyncedAt,
  });

  const SyncStatus.localOnly()
    : phase = SyncPhase.localOnly,
      pendingMutations = 0,
      lastSyncedAt = null;

  final SyncPhase phase;
  final int pendingMutations;
  final DateTime? lastSyncedAt;

  bool get isCloudCurrent => phase == SyncPhase.synced;
}

final class SyncLocalSnapshot {
  const SyncLocalSnapshot({
    this.favorites = const [],
    this.following = const [],
    this.history = const [],
    this.appearance = const AppearanceSettings(),
    this.playback = const PlaybackSettings(),
  });

  final List<LibraryEntry> favorites;
  final List<LibraryEntry> following;
  final List<LibraryEntry> history;
  final AppearanceSettings appearance;
  final PlaybackSettings playback;
}

/// Owns account-scoped cloud synchronization and the retained compatibility
/// collection side effect.
///
/// Cloud mutations use a durable write-ahead queue. Local controllers publish
/// UI state first, append here before writing their ordinary snapshot, and let
/// remote records enter through [applyRecord] so a pull never creates an echo
/// mutation. Authentication remains inside [CloudSyncTransport].
final class SyncController {
  SyncController({
    required SyncHistoryUploader uploadHistory,
    required SyncContextGuard isContextCurrent,
    CloudSyncTransport? cloudTransport,
    SyncStorage? storage,
    SyncLocalSnapshotReader? readLocalSnapshot,
    SyncRecordApplier? applyRecord,
    SyncStatusPublisher? publishStatus,
    this.operationTimeout = const Duration(seconds: 10),
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
    Random? secureRandom,
  }) : assert(operationTimeout > Duration.zero),
       assert(retryDelay > Duration.zero),
       _uploadHistory = uploadHistory,
       _isContextCurrent = isContextCurrent,
       _cloudTransport = cloudTransport,
       _storage = storage,
       _readLocalSnapshot = readLocalSnapshot,
       _applyRecord = applyRecord,
       _publishStatus = publishStatus,
       _now = now ?? DateTime.now,
       _secureRandom = secureRandom ?? Random.secure();

  static const _deviceKey = 'sync.device.v1';
  static const _stateSuffix = 'syncState.v1';
  static const _schemaVersion = 1;
  static const _maxReceipts = 200;
  static const _maxNetworkBatches = 20;

  final SyncHistoryUploader _uploadHistory;
  final SyncContextGuard _isContextCurrent;
  final CloudSyncTransport? _cloudTransport;
  final SyncStorage? _storage;
  final SyncLocalSnapshotReader? _readLocalSnapshot;
  final SyncRecordApplier? _applyRecord;
  final SyncStatusPublisher? _publishStatus;
  final DateTime Function() _now;
  final Random _secureRandom;
  final Duration operationTimeout;
  final Duration retryDelay;

  String? _accountId;
  var _contextVersion = 0;
  var _scopeEpoch = 0;
  var _loaded = false;
  var _disposed = false;
  var _cloudReady = false;
  var _authExpired = false;
  ExternalServiceSettings _services = const ExternalServiceSettings();
  _PersistentSyncState _persistentState = const _PersistentSyncState();
  SyncStatus _status = const SyncStatus.localOnly();
  Future<void> _compatibilityQueue = Future<void>.value();
  Future<void> _writeQueue = Future<void>.value();
  Future<void> _networkQueue = Future<void>.value();
  Timer? _retryTimer;

  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;
  SyncStatus get status => _status;

  void loadForAccount({
    required String? accountId,
    required int contextVersion,
    required ExternalServiceSettings services,
  }) {
    _ensureNotDisposed();
    _retryTimer?.cancel();
    _retryTimer = null;
    _accountId = accountId;
    _contextVersion = contextVersion;
    _services = services;
    _scopeEpoch++;
    _loaded = true;
    _cloudReady = false;
    _authExpired = false;
    _persistentState = const _PersistentSyncState();
    final scope = _scope();
    if (accountId == null || !_hasCloudDependencies) {
      _setStatus(scope, const SyncStatus.localOnly());
      return;
    }
    _setStatus(scope, const SyncStatus(phase: SyncPhase.checking));
    unawaited(
      _write<void>(() async {
        if (!_isCurrent(scope)) return;
        try {
          _persistentState = _readPersistentState(accountId);
          await _ensureDeviceId();
          if (!_isCurrent(scope)) return;
          _cloudReady = true;
          _setStatus(
            scope,
            SyncStatus(
              phase: _persistentState.queue.isEmpty
                  ? SyncPhase.checking
                  : SyncPhase.pending,
              pendingMutations: _persistentState.queue.length,
              lastSyncedAt: _persistentState.lastSyncedAt,
            ),
          );
          _scheduleCloudSync(scope);
        } on FormatException {
          _setStatus(
            scope,
            SyncStatus(
              phase: SyncPhase.error,
              lastSyncedAt: _persistentState.lastSyncedAt,
            ),
          );
        } on Object {
          _setStatus(
            scope,
            SyncStatus(
              phase: SyncPhase.error,
              lastSyncedAt: _persistentState.lastSyncedAt,
            ),
          );
        }
      }),
    );
  }

  void applyServices(
    ExternalServiceSettings services, {
    required int contextVersion,
  }) {
    final scope = _scope();
    if (scope.contextVersion != contextVersion || !_isCurrent(scope)) return;
    final syncEnabledChanged =
        _services.publicCollectionSyncEnabled !=
        services.publicCollectionSyncEnabled;
    _services = services;
    if (syncEnabledChanged) _scopeEpoch++;
  }

  Future<bool> enqueueLibrary({
    required String? accountId,
    required int contextVersion,
    required CloudSyncRecordType type,
    required LibraryEntry entry,
    bool deleted = false,
  }) => _enqueueCloudMutation(
    accountId: accountId,
    contextVersion: contextVersion,
    create: (mutationId) => CloudSyncMutation.library(
      mutationId: mutationId,
      type: type,
      entry: entry,
      deleted: deleted,
    ),
  );

  Future<bool> enqueuePlaybackPosition({
    required String? accountId,
    required int contextVersion,
    required LibraryEntry entry,
  }) => _enqueueCloudMutation(
    accountId: accountId,
    contextVersion: contextVersion,
    create: (mutationId) => CloudSyncMutation.playbackPosition(
      mutationId: mutationId,
      entry: entry,
    ),
  );

  Future<bool> enqueueAppearance({
    required String? accountId,
    required int contextVersion,
    required AppearanceSettings settings,
  }) => _enqueueCloudMutation(
    accountId: accountId,
    contextVersion: contextVersion,
    create: (mutationId) => CloudSyncMutation.appearance(
      mutationId: mutationId,
      settings: settings,
    ),
  );

  Future<bool> enqueuePlaybackSettings({
    required String? accountId,
    required int contextVersion,
    required PlaybackSettings settings,
  }) => _enqueueCloudMutation(
    accountId: accountId,
    contextVersion: contextVersion,
    create: (mutationId) => CloudSyncMutation.playbackSettings(
      mutationId: mutationId,
      settings: settings,
    ),
  );

  Future<void> synchronize() async {
    final scope = _scope();
    if (scope.accountId == null || !_cloudReady || _authExpired) return;
    _scheduleCloudSync(scope);
    await _networkQueue;
  }

  Future<bool> syncHistory({
    required String? accountId,
    required int contextVersion,
    required AnimeSubject subject,
    required AnimeEpisode? episode,
  }) {
    final scope = _scope();
    if (scope.accountId != accountId ||
        scope.contextVersion != contextVersion ||
        !_isCurrent(scope) ||
        !_services.publicCollectionSyncEnabled) {
      return Future<bool>.value(false);
    }
    final services = _services;
    final completer = Completer<bool>();
    final operation = _compatibilityQueue.then((_) async {
      if (!_isCurrent(scope)) {
        completer.complete(false);
        return;
      }
      var acknowledged = false;
      try {
        acknowledged = await _uploadHistory(
          subject,
          episode,
          services,
        ).timeout(operationTimeout);
      } catch (_) {
        // This optional compatibility side effect is isolated from the durable
        // Zeluna sync protocol and from the already-persisted local mutation.
      }
      completer.complete(_isCurrent(scope) && acknowledged);
    });
    _compatibilityQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return completer.future;
  }

  Future<void> settle() async {
    await _compatibilityQueue;
    await _writeQueue;
    await _networkQueue;
    await _writeQueue;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    _scopeEpoch++;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool get _hasCloudDependencies =>
      _cloudTransport != null &&
      _storage != null &&
      _readLocalSnapshot != null &&
      _applyRecord != null;

  Future<bool> _enqueueCloudMutation({
    required String? accountId,
    required int contextVersion,
    required CloudSyncMutation Function(String mutationId) create,
  }) async {
    final scope = _scope();
    if (scope.accountId == null ||
        scope.accountId != accountId ||
        scope.contextVersion != contextVersion ||
        !_isCurrent(scope)) {
      return false;
    }
    final stored = await _write<bool>(() async {
      if (!_isCurrent(scope) || !_cloudReady) return false;
      final mutation = create(await _nextMutationId());
      final compacted =
          _persistentState.queue
              .where(
                (item) =>
                    item.type != mutation.type ||
                    item.recordId != mutation.recordId,
              )
              .toList(growable: true)
            ..add(mutation);
      _persistentState = _persistentState.copyWith(queue: compacted);
      await _persistState(scope);
      if (!_isCurrent(scope)) return false;
      _setStatus(
        scope,
        SyncStatus(
          phase: _authExpired ? SyncPhase.expired : SyncPhase.pending,
          pendingMutations: compacted.length,
          lastSyncedAt: _persistentState.lastSyncedAt,
        ),
      );
      return true;
    });
    if (stored && !_authExpired) _scheduleCloudSync(scope);
    return stored;
  }

  void _scheduleCloudSync(_SyncScope scope) {
    if (!_isCurrent(scope) || !_cloudReady || _authExpired) return;
    final operation = _networkQueue.then((_) => _runCloudSync(scope));
    _networkQueue = operation.then<void>((_) {}, onError: (_, _) {});
  }

  Future<void> _runCloudSync(_SyncScope scope) async {
    if (!_isCurrent(scope) || !_cloudReady || _authExpired) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    try {
      await _pushPending(scope);
      if (!_isCurrent(scope)) return;
      if (!_persistentState.migrated) {
        final remoteIdentities = await _pullPages(
          scope,
          afterRevision: 0,
          advanceCursor: false,
        );
        if (!_isCurrent(scope)) return;
        await _write<void>(() async {
          if (!_isCurrent(scope)) return;
          final baseline = _buildMigrationMutations(remoteIdentities);
          final queue = [..._persistentState.queue];
          for (final mutation in baseline) {
            queue.removeWhere(
              (item) =>
                  item.type == mutation.type &&
                  item.recordId == mutation.recordId,
            );
            queue.add(mutation);
          }
          _persistentState = _persistentState.copyWith(
            migrated: true,
            queue: queue,
          );
          await _persistState(scope);
        });
        await _pushPending(scope);
      }
      if (!_isCurrent(scope)) return;
      await _pullPages(
        scope,
        afterRevision: _persistentState.cursor,
        advanceCursor: true,
      );
      if (!_isCurrent(scope)) return;
      final syncedAt = _now().toUtc();
      await _write<void>(() async {
        if (!_isCurrent(scope)) return;
        _persistentState = _persistentState.copyWith(lastSyncedAt: syncedAt);
        await _persistState(scope);
      });
      _setStatus(
        scope,
        SyncStatus(
          phase: _persistentState.queue.isEmpty
              ? SyncPhase.synced
              : SyncPhase.pending,
          pendingMutations: _persistentState.queue.length,
          lastSyncedAt: syncedAt,
        ),
      );
    } on CloudSyncAuthenticationException {
      if (!_isCurrent(scope)) return;
      _authExpired = true;
      _setStatus(
        scope,
        SyncStatus(
          phase: SyncPhase.expired,
          pendingMutations: _persistentState.queue.length,
          lastSyncedAt: _persistentState.lastSyncedAt,
        ),
      );
    } on TimeoutException {
      _markOffline(scope);
    } on CloudSyncUnavailableException {
      _markOffline(scope);
    } on Object {
      if (!_isCurrent(scope)) return;
      _setStatus(
        scope,
        SyncStatus(
          phase: SyncPhase.error,
          pendingMutations: _persistentState.queue.length,
          lastSyncedAt: _persistentState.lastSyncedAt,
        ),
      );
    }
  }

  void _markOffline(_SyncScope scope) {
    if (!_isCurrent(scope)) return;
    _setStatus(
      scope,
      SyncStatus(
        phase: SyncPhase.offline,
        pendingMutations: _persistentState.queue.length,
        lastSyncedAt: _persistentState.lastSyncedAt,
      ),
    );
    _retryTimer = Timer(retryDelay, () {
      if (_isCurrent(scope) && !_authExpired) _scheduleCloudSync(scope);
    });
  }

  Future<void> _pushPending(_SyncScope scope) async {
    for (var batch = 0; batch < _maxNetworkBatches; batch++) {
      if (!_isCurrent(scope)) return;
      await _writeQueue;
      final pending = _persistentState.queue.take(100).toList(growable: false);
      if (pending.isEmpty) return;
      final result = await _cloudTransport!
          .push(pending)
          .timeout(operationTimeout);
      if (!_isCurrent(scope)) return;
      final expectedIds = pending.map((item) => item.mutationId).toSet();
      final acknowledged = result.acknowledged
          .where((item) => expectedIds.contains(item.clientMutationId))
          .toList(growable: false);
      if (acknowledged.length != pending.length) {
        throw const CloudSyncProtocolException();
      }
      await _applyRecords(scope, acknowledged);
      if (!_isCurrent(scope)) return;
      final acknowledgedIds = acknowledged
          .map((item) => item.clientMutationId)
          .toSet();
      await _write<void>(() async {
        if (!_isCurrent(scope)) return;
        final receipts = [
          ..._persistentState.receipts,
          ...acknowledged.map(
            (item) => _SyncReceipt(
              mutationId: item.clientMutationId,
              serverRevision: item.serverRevision,
            ),
          ),
        ];
        final maxRevision = acknowledged.fold<int>(
          _persistentState.cursor,
          (value, item) => max(value, item.serverRevision),
        );
        _persistentState = _persistentState.copyWith(
          queue: _persistentState.queue
              .where((item) => !acknowledgedIds.contains(item.mutationId))
              .toList(growable: false),
          receipts: receipts.length <= _maxReceipts
              ? receipts
              : receipts.sublist(receipts.length - _maxReceipts),
          cursor: maxRevision,
        );
        await _persistState(scope);
      });
    }
    if (_persistentState.queue.isNotEmpty) {
      throw const CloudSyncProtocolException();
    }
  }

  Future<Set<String>> _pullPages(
    _SyncScope scope, {
    required int afterRevision,
    required bool advanceCursor,
  }) async {
    var cursor = afterRevision;
    final identities = <String>{};
    for (var batch = 0; batch < _maxNetworkBatches; batch++) {
      if (!_isCurrent(scope)) return identities;
      final result = await _cloudTransport!
          .pull(afterRevision: cursor)
          .timeout(operationTimeout);
      if (!_isCurrent(scope)) return identities;
      if (result.nextRevision < cursor) {
        throw const CloudSyncProtocolException();
      }
      identities.addAll(
        result.records.map((item) => _recordIdentity(item.type, item.recordId)),
      );
      await _applyRecords(scope, result.records);
      if (!_isCurrent(scope)) return identities;
      cursor = result.nextRevision;
      if (advanceCursor) {
        await _write<void>(() async {
          if (!_isCurrent(scope)) return;
          _persistentState = _persistentState.copyWith(
            cursor: max(_persistentState.cursor, cursor),
          );
          await _persistState(scope);
        });
      }
      if (result.records.length < 200) return identities;
    }
    throw const CloudSyncProtocolException();
  }

  Future<void> _applyRecords(
    _SyncScope scope,
    Iterable<CloudSyncRecord> records,
  ) async {
    for (final record in records) {
      if (!_isCurrent(scope)) return;
      await _applyRecord!(record);
    }
  }

  List<CloudSyncMutation> _buildMigrationMutations(Set<String> remote) {
    final snapshot = _readLocalSnapshot!();
    final mutations = <CloudSyncMutation>[];
    void addLibrary(CloudSyncRecordType type, Iterable<LibraryEntry> entries) {
      for (final entry in entries) {
        if (remote.contains(_recordIdentity(type, entry.subject.identityKey))) {
          continue;
        }
        mutations.add(
          CloudSyncMutation.library(
            mutationId: _nextMutationIdSync(),
            type: type,
            entry: entry,
          ),
        );
      }
    }

    addLibrary(CloudSyncRecordType.favorite, snapshot.favorites);
    addLibrary(CloudSyncRecordType.following, snapshot.following);
    addLibrary(CloudSyncRecordType.history, snapshot.history);
    for (final entry in snapshot.history.where(
      (item) => item.episode != null,
    )) {
      final recordId = entry.episode!.identityKey(
        subjectKey: entry.subject.identityKey,
      );
      if (!remote.contains(
        _recordIdentity(CloudSyncRecordType.playbackPosition, recordId),
      )) {
        mutations.add(
          CloudSyncMutation.playbackPosition(
            mutationId: _nextMutationIdSync(),
            entry: entry,
          ),
        );
      }
    }
    if (!remote.contains(
      _recordIdentity(
        CloudSyncRecordType.appearanceSettings,
        'settings:appearance',
      ),
    )) {
      mutations.add(
        CloudSyncMutation.appearance(
          mutationId: _nextMutationIdSync(),
          settings: snapshot.appearance,
        ),
      );
    }
    if (!remote.contains(
      _recordIdentity(
        CloudSyncRecordType.playbackSettings,
        'settings:playback',
      ),
    )) {
      mutations.add(
        CloudSyncMutation.playbackSettings(
          mutationId: _nextMutationIdSync(),
          settings: snapshot.playback,
        ),
      );
    }
    return mutations;
  }

  Future<String> _nextMutationId() async => _nextMutationIdSync();

  String _nextMutationIdSync() {
    final deviceId = _persistentState.deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw const FormatException('Cloud sync device identity is unavailable.');
    }
    final counter = _persistentState.counter + 1;
    _persistentState = _persistentState.copyWith(counter: counter);
    return 'sync:v1:$deviceId:${counter.toRadixString(16).padLeft(12, '0')}';
  }

  Future<void> _ensureDeviceId() async {
    final storage = _storage!;
    final existing = storage.get(_deviceKey)?.toString().trim() ?? '';
    final deviceId = _validDeviceId(existing) ? existing : _newDeviceId();
    if (existing != deviceId) await storage.put(_deviceKey, deviceId);
    _persistentState = _persistentState.copyWith(deviceId: deviceId);
  }

  _PersistentSyncState _readPersistentState(String accountId) {
    final value = _storage!.get(_stateKey(accountId));
    if (value == null) return const _PersistentSyncState();
    if (value is! Map) throw const FormatException('Invalid sync state.');
    final json = value.map((key, value) => MapEntry(key.toString(), value));
    if (json['schemaVersion'] != _schemaVersion) {
      throw const FormatException('Unsupported sync state schema.');
    }
    final cursor = _nonNegativeInt(json['cursor']);
    final counter = _nonNegativeInt(json['counter']);
    final rawQueue = json['queue'];
    final rawReceipts = json['receipts'];
    if (rawQueue is! List || rawReceipts is! List) {
      throw const FormatException('Invalid sync state collections.');
    }
    final queue = rawQueue
        .map((item) => CloudSyncMutation.fromJson(_stringMap(item)))
        .toList(growable: false);
    final receipts = rawReceipts
        .map((item) => _SyncReceipt.fromJson(_stringMap(item)))
        .toList(growable: false);
    final syncedRaw = json['lastSyncedAt']?.toString() ?? '';
    final syncedAt = syncedRaw.isEmpty ? null : DateTime.tryParse(syncedRaw);
    if (syncedRaw.isNotEmpty && syncedAt == null) {
      throw const FormatException('Invalid sync timestamp.');
    }
    return _PersistentSyncState(
      migrated: json['migrated'] as bool? ?? false,
      cursor: cursor,
      counter: counter,
      queue: queue,
      receipts: receipts.length <= _maxReceipts
          ? receipts
          : receipts.sublist(receipts.length - _maxReceipts),
      lastSyncedAt: syncedAt?.toUtc(),
    );
  }

  Future<void> _persistState(_SyncScope scope) async {
    if (!_isCurrent(scope) || scope.accountId == null) return;
    await _storage!.put(_stateKey(scope.accountId!), _persistentState.toJson());
    if (!_isCurrent(scope)) return;
  }

  Future<T> _write<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final operation = _writeQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return completer.future;
  }

  void _setStatus(_SyncScope scope, SyncStatus status) {
    if (!_isCurrent(scope)) return;
    _status = status;
    _publishStatus?.call(status);
  }

  _SyncScope _scope() {
    _ensureNotDisposed();
    if (!_loaded) throw StateError('Sync controller is not configured.');
    return _SyncScope(
      accountId: _accountId,
      contextVersion: _contextVersion,
      epoch: _scopeEpoch,
    );
  }

  bool _isCurrent(_SyncScope scope) =>
      !_disposed &&
      _loaded &&
      scope.accountId == _accountId &&
      scope.contextVersion == _contextVersion &&
      scope.epoch == _scopeEpoch &&
      _isContextCurrent(scope.contextVersion);

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('Sync controller is disposed.');
  }

  String _newDeviceId() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _validDeviceId(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

  static String _stateKey(String accountId) =>
      'account.$accountId.$_stateSuffix';

  static String _recordIdentity(CloudSyncRecordType type, String recordId) =>
      '${type.wireName}|$recordId';
}

final class _PersistentSyncState {
  const _PersistentSyncState({
    this.deviceId,
    this.migrated = false,
    this.cursor = 0,
    this.counter = 0,
    this.queue = const [],
    this.receipts = const [],
    this.lastSyncedAt,
  });

  final String? deviceId;
  final bool migrated;
  final int cursor;
  final int counter;
  final List<CloudSyncMutation> queue;
  final List<_SyncReceipt> receipts;
  final DateTime? lastSyncedAt;

  _PersistentSyncState copyWith({
    String? deviceId,
    bool? migrated,
    int? cursor,
    int? counter,
    List<CloudSyncMutation>? queue,
    List<_SyncReceipt>? receipts,
    DateTime? lastSyncedAt,
  }) => _PersistentSyncState(
    deviceId: deviceId ?? this.deviceId,
    migrated: migrated ?? this.migrated,
    cursor: cursor ?? this.cursor,
    counter: counter ?? this.counter,
    queue: queue ?? this.queue,
    receipts: receipts ?? this.receipts,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': SyncController._schemaVersion,
    'migrated': migrated,
    'cursor': cursor,
    'counter': counter,
    'queue': queue.map((item) => item.toJson()).toList(growable: false),
    'receipts': receipts.map((item) => item.toJson()).toList(growable: false),
    if (lastSyncedAt != null)
      'lastSyncedAt': lastSyncedAt!.toUtc().toIso8601String(),
  };
}

final class _SyncReceipt {
  const _SyncReceipt({required this.mutationId, required this.serverRevision});

  factory _SyncReceipt.fromJson(Map<String, dynamic> json) {
    final mutationId = json['mutationId']?.toString() ?? '';
    if (mutationId.length < 16 ||
        mutationId.length > 100 ||
        !RegExp(r'^[A-Za-z0-9:_-]+$').hasMatch(mutationId)) {
      throw const FormatException('Invalid persisted sync receipt.');
    }
    return _SyncReceipt(
      mutationId: mutationId,
      serverRevision: _nonNegativeInt(json['serverRevision']),
    );
  }

  final String mutationId;
  final int serverRevision;

  Map<String, dynamic> toJson() => {
    'mutationId': mutationId,
    'serverRevision': serverRevision,
  };
}

final class _SyncScope {
  const _SyncScope({
    required this.accountId,
    required this.contextVersion,
    required this.epoch,
  });

  final String? accountId;
  final int contextVersion;
  final int epoch;
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected persisted map.');
  return value.map((key, value) => MapEntry(key.toString(), value));
}

int _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value.toInt() != value) {
    throw const FormatException('Expected a non-negative integer.');
  }
  return value.toInt();
}
