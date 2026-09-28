import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/sync/cloud_sync_transport.dart';
import 'package:anime/src/sync/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final remoteCases = <String, CloudSyncRecord>{
    for (final deleted in [false, true])
      deleted ? 'tombstone' : 'favorite': _recordFromMutation(
        CloudSyncMutation.library(
          mutationId: 'sync:v1:remote-device:000000000011',
          type: CloudSyncRecordType.favorite,
          entry: _entry,
          deleted: deleted,
        ),
        11,
      ),
    'appearance setting': _settingsRecord(
      type: CloudSyncRecordType.appearanceSettings,
      revision: 11,
      payload: const AppearanceSettings(reduceMotion: true).toJson(),
    ),
    'playback setting': _settingsRecord(
      type: CloudSyncRecordType.playbackSettings,
      revision: 11,
      payload: const PlaybackSettings(speed: 1.5).toJson(),
    ),
  };
  for (final scenario in remoteCases.entries) {
    test(
      'push acknowledgement does not skip an unseen remote ${scenario.key}',
      () async {
        final mutation = CloudSyncMutation.library(
          mutationId: 'sync:v1:$_deviceId:000000000001',
          type: CloudSyncRecordType.history,
          entry: _entry,
        );
        final remote = scenario.value;
        final ownRecord = _recordFromMutation(mutation, 12);
        final storage = _MemorySyncStorage()
          ..values['sync.device.v1'] = _deviceId
          ..values[_stateKey('account-a')] = _state(
            migrated: true,
            cursor: 10,
            counter: 1,
            queue: [mutation],
          );
        final transport = _FakeSyncTransport()
          ..remoteRecords.addAll([remote, ownRecord])
          ..pushResults.add(
            CloudSyncPushResult(acknowledged: [ownRecord], nextRevision: 12),
          );
        final applied = <CloudSyncRecord>[];
        final controller = _controller(
          storage: storage,
          transport: transport,
          applyRecord: (record) async => applied.add(record),
        );
        addTearDown(controller.dispose);

        _load(controller, 'account-a', 1);
        await controller.settle();

        expect(transport.afterRevisions, [10]);
        expect(applied.where((record) => record.serverRevision == 11), [
          remote,
        ]);
        expect(_stateJson(storage, 'account-a')['cursor'], 12);
        expect(_queue(storage, 'account-a'), isEmpty);
        expect(transport.pushed, hasLength(1), reason: 'pull must not echo');
        expect(controller.status.phase, SyncPhase.synced);
      },
    );
  }

  test(
    'push success and pull timeout preserve cursor across restart',
    () async {
      final mutation = CloudSyncMutation.library(
        mutationId: 'sync:v1:$_deviceId:000000000001',
        type: CloudSyncRecordType.favorite,
        entry: _entry,
      );
      final ownRecord = _recordFromMutation(mutation, 12);
      final remote = remoteCases['appearance setting']!;
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId
        ..values[_stateKey('account-a')] = _state(
          migrated: true,
          cursor: 10,
          counter: 1,
          queue: [mutation],
        );
      final transport = _FakeSyncTransport()
        ..pushResults.add(
          CloudSyncPushResult(acknowledged: [ownRecord], nextRevision: 12),
        )
        ..pullFailure = TimeoutException('synthetic pull timeout');
      final first = _controller(storage: storage, transport: transport);
      addTearDown(first.dispose);
      _load(first, 'account-a', 1);
      await first.settle();

      expect(first.status.phase, SyncPhase.offline);
      expect(_queue(storage, 'account-a'), isEmpty);
      expect(_stateJson(storage, 'account-a')['cursor'], 10);
      expect(_stateJson(storage, 'account-a')['receipts'], [
        {'mutationId': mutation.mutationId, 'serverRevision': 12},
      ]);
      first.dispose();

      final online = _FakeSyncTransport()
        ..remoteRecords.addAll([remote, ownRecord]);
      final applied = <CloudSyncRecord>[];
      final restarted = _controller(
        storage: storage,
        transport: online,
        applyRecord: (record) async => applied.add(record),
      );
      addTearDown(restarted.dispose);
      _load(restarted, 'account-a', 1);
      await restarted.settle();

      expect(
        online.pushCalls,
        0,
        reason: 'successful receipt survives restart',
      );
      expect(online.afterRevisions, [10]);
      expect(applied, [remote, ownRecord]);
      expect(_stateJson(storage, 'account-a')['cursor'], 12);
      expect(restarted.status.phase, SyncPhase.synced);
    },
  );

  test('only fully applied pull pages persist a cursor', () async {
    final records = List.generate(
      201,
      (index) => _recordFromMutation(
        CloudSyncMutation.library(
          mutationId: 'sync:v1:remote-device:page-$index',
          type: CloudSyncRecordType.favorite,
          entry: LibraryEntry(
            subject: _entry.subject.copyWith(
              stableKey: 'bangumi:${index + 100}',
            ),
            updatedAt: _entry.updatedAt,
          ),
        ),
        index + 11,
      ),
    );
    final storage = _MemorySyncStorage()
      ..values['sync.device.v1'] = _deviceId
      ..values[_stateKey('account-a')] = _state(migrated: true, cursor: 10);
    final transport = _FakeSyncTransport()..remoteRecords.addAll(records);
    var failApply = true;
    final applied = <CloudSyncRecord>[];
    final controller = _controller(
      storage: storage,
      transport: transport,
      applyRecord: (record) async {
        if (failApply && record.serverRevision == 211) {
          throw StateError('synthetic local write failure');
        }
        applied.add(record);
      },
    );
    addTearDown(controller.dispose);
    _load(controller, 'account-a', 1);
    await controller.settle();

    expect(transport.afterRevisions, [10, 210]);
    expect(applied, records.take(200));
    expect(_stateJson(storage, 'account-a')['cursor'], 210);
    expect(controller.status.phase, SyncPhase.error);

    failApply = false;
    await controller.synchronize();
    await controller.settle();
    expect(transport.afterRevisions, [10, 210, 210]);
    expect(applied, records);
    expect(_stateJson(storage, 'account-a')['cursor'], 211);
    expect(transport.pushCalls, 0);
    expect(controller.status.phase, SyncPhase.synced);
  });

  for (final missing in [false, true]) {
    test('strict ack validation retains queue for missing=$missing', () async {
      final pending = CloudSyncMutation.library(
        mutationId: 'sync:v1:$_deviceId:000000000001',
        type: CloudSyncRecordType.favorite,
        entry: _entry,
      );
      final unrelated = CloudSyncMutation.library(
        mutationId: 'sync:v1:remote-device:000000000099',
        type: CloudSyncRecordType.favorite,
        entry: _entry,
      );
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId
        ..values[_stateKey('account-a')] = _state(
          migrated: true,
          cursor: 10,
          counter: 1,
          queue: [pending],
        );
      final transport = _FakeSyncTransport()
        ..pushResults.add(
          CloudSyncPushResult(
            acknowledged: missing ? [] : [_recordFromMutation(unrelated, 12)],
            nextRevision: 12,
          ),
        );
      final applied = <CloudSyncRecord>[];
      final controller = _controller(
        storage: storage,
        transport: transport,
        applyRecord: (record) async => applied.add(record),
      );
      addTearDown(controller.dispose);
      _load(controller, 'account-a', 1);
      await controller.settle();

      expect(controller.status.phase, SyncPhase.error);
      expect(
        _queue(storage, 'account-a').single['mutationId'],
        pending.mutationId,
      );
      expect(_stateJson(storage, 'account-a')['receipts'], isEmpty);
      expect(_stateJson(storage, 'account-a')['cursor'], 10);
      expect(transport.pullCalls, 0);
      expect(applied, isEmpty);
    });
  }

  for (final lostResponse in [true, false]) {
    test(
      'strict sync accepts current-record ack (lost response=$lostResponse)',
      () async {
        CloudSyncMutation mutationFor(String id, LibraryEntry entry) =>
            lostResponse
            ? CloudSyncMutation.library(
                mutationId: id,
                type: CloudSyncRecordType.history,
                entry: entry,
              )
            : CloudSyncMutation.playbackPosition(mutationId: id, entry: entry);
        final submitted = mutationFor(
          'sync:v1:$_deviceId:000000000001',
          _entry,
        );
        final current = mutationFor(
          'sync:v1:remote-device:000000000012',
          _entry.copyWith(
            positionSeconds: 360,
            updatedAt: DateTime.utc(2026, 8, 8, 1),
          ),
        );
        final storage = _MemorySyncStorage()
          ..values['sync.device.v1'] = _deviceId
          ..values[_stateKey('account-a')] = _state(
            migrated: true,
            cursor: 10,
            counter: 1,
            queue: [submitted],
          );
        if (lostResponse) {
          final lost = _FakeSyncTransport()
            ..loseNextPushResponse = true
            ..pushResults.add(
              CloudSyncPushResult(
                acknowledged: [_recordFromMutation(submitted, 11)],
                nextRevision: 11,
              ),
            );
          final first = _controller(storage: storage, transport: lost);
          addTearDown(first.dispose);
          _load(first, 'account-a', 1);
          await first.settle();
          expect(first.status.phase, SyncPhase.offline);
          expect(lost.pushed.single.single.mutationId, submitted.mutationId);
          expect(
            _queue(storage, 'account-a').single['mutationId'],
            submitted.mutationId,
          );
          expect(_stateJson(storage, 'account-a')['cursor'], 10);
          expect(_stateJson(storage, 'account-a')['receipts'], isEmpty);
          first.dispose();
        }
        // Same wire contract exercised by server/tests/test_sync_api.py:
        // ack ID is A, payload/revision remain B; pull still identifies B.
        final transport = _FakeSyncTransport()
          ..pushResults.add(
            CloudSyncPushResult.fromJson({
              'acknowledged': [
                {
                  'type': current.type.wireName,
                  'record_id': current.recordId,
                  'payload': current.payload,
                  'deleted': false,
                  'client_mutation_id': submitted.mutationId,
                  'server_revision': 12,
                },
              ],
              'next_revision': 12,
            }),
          )
          ..remoteRecords.add(_recordFromMutation(current, 12));
        final applied = <CloudSyncRecord>[];
        final restarted = _controller(
          storage: storage,
          transport: transport,
          applyRecord: (record) async => applied.add(record),
        );
        addTearDown(restarted.dispose);
        _load(restarted, 'account-a', 1);
        await restarted.settle();

        expect(transport.pushed.single.single.toJson(), submitted.toJson());
        expect(transport.afterRevisions, [10]);
        expect(applied.map((record) => record.clientMutationId), [
          submitted.mutationId,
          current.mutationId,
        ]);
        expect(applied.map((record) => record.payload['positionSeconds']), [
          360,
          360,
        ]);
        expect(_queue(storage, 'account-a'), isEmpty);
        expect(_stateJson(storage, 'account-a')['receipts'], [
          {'mutationId': submitted.mutationId, 'serverRevision': 12},
        ]);
        expect(_stateJson(storage, 'account-a')['cursor'], 12);
        expect(restarted.status.phase, SyncPhase.synced);
      },
    );
  }

  test('guest scope stays local and never creates sync persistence', () async {
    final storage = _MemorySyncStorage();
    final transport = _FakeSyncTransport();
    final controller = _controller(storage: storage, transport: transport);
    addTearDown(controller.dispose);

    controller.loadForAccount(
      accountId: null,
      contextVersion: 1,
      services: const ExternalServiceSettings(),
    );
    await controller.settle();

    expect(controller.status.phase, SyncPhase.localOnly);
    expect(storage.values, isEmpty);
    expect(transport.pushCalls, 0);
    expect(transport.pullCalls, 0);
  });

  test(
    'sync storage failure is surfaced without breaking local startup',
    () async {
      final storage = _MemorySyncStorage()..failWrites = true;
      final controller = _controller(
        storage: storage,
        transport: _FakeSyncTransport(),
      );
      addTearDown(controller.dispose);

      _load(controller, 'account-a', 1);
      await controller.settle();

      expect(controller.status.phase, SyncPhase.error);
    },
  );

  test('offline mutation survives restart with the same mutation id', () async {
    final storage = _MemorySyncStorage()
      ..values['sync.device.v1'] = _deviceId
      ..values[_stateKey('account-a')] = _state(migrated: true);
    final offline = _FakeSyncTransport()..unavailable = true;
    final first = _controller(storage: storage, transport: offline);
    addTearDown(first.dispose);
    _load(first, 'account-a', 1);
    await first.settle();

    expect(
      await first.enqueueLibrary(
        accountId: 'account-a',
        contextVersion: 1,
        type: CloudSyncRecordType.favorite,
        entry: _entry,
      ),
      isTrue,
    );
    await first.settle();
    final pendingBefore = _queue(storage, 'account-a').single;
    expect(first.status.phase, SyncPhase.offline);

    first.dispose();
    final online = _FakeSyncTransport()
      ..remoteRecords.add(
        _recordFromMutation(CloudSyncMutation.fromJson(pendingBefore), 1),
      );
    final restarted = _controller(storage: storage, transport: online);
    addTearDown(restarted.dispose);
    _load(restarted, 'account-a', 1);
    await restarted.settle();

    expect(online.pushed.single.single.mutationId, pendingBefore['mutationId']);
    expect(_queue(storage, 'account-a'), isEmpty);
    expect(restarted.status.phase, SyncPhase.synced);
    expect(_stateJson(storage, 'account-a')['cursor'], greaterThan(0));
    expect(_stateJson(storage, 'account-a')['receipts'], isNotEmpty);
  });

  test(
    'counter remains monotonic while unsent records are compacted',
    () async {
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId
        ..values[_stateKey('account-a')] = _state(migrated: true);
      final transport = _FakeSyncTransport()..unavailable = true;
      final controller = _controller(storage: storage, transport: transport);
      addTearDown(controller.dispose);
      _load(controller, 'account-a', 1);
      await controller.settle();

      await controller.enqueueAppearance(
        accountId: 'account-a',
        contextVersion: 1,
        settings: const AppearanceSettings(compactMode: true),
      );
      await controller.enqueueAppearance(
        accountId: 'account-a',
        contextVersion: 1,
        settings: const AppearanceSettings(reduceMotion: true),
      );
      await controller.settle();

      final state = _stateJson(storage, 'account-a');
      final queue = (state['queue'] as List).cast<Map>();
      expect(queue, hasLength(1));
      expect(state['counter'], 2);
      expect(queue.single['mutationId'], endsWith('000000000002'));
      expect((queue.single['payload'] as Map)['reduceMotion'], isTrue);
    },
  );

  test(
    'initial migration pulls remote settings before creating baseline',
    () async {
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId;
      var snapshot = const SyncLocalSnapshot(
        appearance: AppearanceSettings(compactMode: true),
        playback: PlaybackSettings(speed: 1.5),
      );
      final transport = _FakeSyncTransport()
        ..pullResults.add(
          CloudSyncPullResult(
            records: [
              _settingsRecord(
                type: CloudSyncRecordType.appearanceSettings,
                revision: 4,
                payload: const AppearanceSettings(reduceMotion: true).toJson(),
              ),
              _settingsRecord(
                type: CloudSyncRecordType.playbackSettings,
                revision: 5,
                payload: const PlaybackSettings(speed: 2).toJson(),
              ),
            ],
            nextRevision: 5,
          ),
        );
      final applied = <CloudSyncRecord>[];
      final controller = _controller(
        storage: storage,
        transport: transport,
        readSnapshot: () => snapshot,
        applyRecord: (record) async {
          applied.add(record);
          if (record.type == CloudSyncRecordType.appearanceSettings) {
            snapshot = SyncLocalSnapshot(
              appearance: AppearanceSettings.fromJson(record.payload),
              playback: snapshot.playback,
            );
          } else if (record.type == CloudSyncRecordType.playbackSettings) {
            snapshot = SyncLocalSnapshot(
              appearance: snapshot.appearance,
              playback: PlaybackSettings.fromJson(record.payload),
            );
          }
        },
      );
      addTearDown(controller.dispose);

      _load(controller, 'account-a', 1);
      await controller.settle();

      expect(applied, hasLength(2));
      expect(snapshot.appearance.reduceMotion, isTrue);
      expect(snapshot.playback.speed, 2);
      expect(
        transport.pushed,
        isEmpty,
        reason: 'remote settings must win bootstrap',
      );
      expect(_stateJson(storage, 'account-a')['migrated'], isTrue);
      expect(controller.status.phase, SyncPhase.synced);
    },
  );

  test(
    'late old-account acknowledgement cannot clear or apply its queue',
    () async {
      final oldMutation = CloudSyncMutation.library(
        mutationId: 'sync:v1:$_deviceId:000000000001',
        type: CloudSyncRecordType.favorite,
        entry: _entry,
      );
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId
        ..values[_stateKey('account-a')] = _state(
          migrated: true,
          counter: 1,
          queue: [oldMutation],
        )
        ..values[_stateKey('account-b')] = _state(migrated: true);
      final gate = Completer<void>();
      final transport = _FakeSyncTransport()..pushGate = gate;
      final applied = <CloudSyncRecord>[];
      var activeVersion = 1;
      final controller = _controller(
        storage: storage,
        transport: transport,
        activeVersion: () => activeVersion,
        applyRecord: (record) async => applied.add(record),
      );
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
        controller.dispose();
      });

      _load(controller, 'account-a', 1);
      await _waitUntil(() => transport.pushCalls == 1);
      activeVersion = 2;
      _load(controller, 'account-b', 2);
      gate.complete();
      await controller.settle();

      expect(_queue(storage, 'account-a'), hasLength(1));
      expect(_queue(storage, 'account-b'), isEmpty);
      expect(applied, isEmpty);
      expect(controller.accountId, 'account-b');
    },
  );

  test(
    'expired authentication retains the queue and performs no retry',
    () async {
      final mutation = CloudSyncMutation.library(
        mutationId: 'sync:v1:$_deviceId:000000000001',
        type: CloudSyncRecordType.favorite,
        entry: _entry,
      );
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId
        ..values[_stateKey('account-a')] = _state(
          migrated: true,
          counter: 1,
          queue: [mutation],
        );
      final transport = _FakeSyncTransport()..expired = true;
      final controller = _controller(
        storage: storage,
        transport: transport,
        retryDelay: const Duration(milliseconds: 10),
      );
      addTearDown(controller.dispose);

      _load(controller, 'account-a', 1);
      await controller.settle();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(controller.status.phase, SyncPhase.expired);
      expect(_queue(storage, 'account-a'), hasLength(1));
      expect(transport.pushCalls, 1);
    },
  );

  test(
    'transient failure retries after reconnect and acknowledges once',
    () async {
      final mutation = CloudSyncMutation.library(
        mutationId: 'sync:v1:$_deviceId:000000000001',
        type: CloudSyncRecordType.favorite,
        entry: _entry,
      );
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId
        ..values[_stateKey('account-a')] = _state(
          migrated: true,
          counter: 1,
          queue: [mutation],
        );
      final transport = _FakeSyncTransport()..unavailable = true;
      final controller = _controller(
        storage: storage,
        transport: transport,
        retryDelay: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);

      _load(controller, 'account-a', 1);
      await controller.settle();
      expect(controller.status.phase, SyncPhase.offline);
      transport.unavailable = false;
      await _waitUntil(() => transport.pushCalls >= 2);
      await controller.settle();

      expect(_queue(storage, 'account-a'), isEmpty);
      expect(controller.status.phase, SyncPhase.synced);
    },
  );

  test(
    'two-device merged acknowledgement replaces the local pending value',
    () async {
      final storage = _MemorySyncStorage()
        ..values['sync.device.v1'] = _deviceId
        ..values[_stateKey('account-a')] = _state(migrated: true);
      final mergedEntry = _entry.copyWith(
        positionSeconds: 360,
        durationSeconds: 1440,
        updatedAt: DateTime.utc(2026, 8, 8, 1),
      );
      final mergedMutation = CloudSyncMutation.library(
        mutationId: 'sync:v1:$_deviceId:000000000001',
        type: CloudSyncRecordType.history,
        entry: mergedEntry,
      );
      final transport = _FakeSyncTransport()
        ..pushResults.add(
          CloudSyncPushResult(
            acknowledged: [_recordFromMutation(mergedMutation, 9)],
            nextRevision: 9,
          ),
        )
        ..remoteRecords.add(_recordFromMutation(mergedMutation, 9));
      final applied = <CloudSyncRecord>[];
      final controller = _controller(
        storage: storage,
        transport: transport,
        applyRecord: (record) async => applied.add(record),
      );
      addTearDown(controller.dispose);
      _load(controller, 'account-a', 1);
      await controller.settle();

      await controller.enqueueLibrary(
        accountId: 'account-a',
        contextVersion: 1,
        type: CloudSyncRecordType.history,
        entry: _entry,
      );
      await controller.settle();

      expect(applied, hasLength(2), reason: 'ack then idempotent pull');
      expect(applied.map((record) => record.payload['positionSeconds']), [
        360,
        360,
      ]);
      expect(_queue(storage, 'account-a'), isEmpty);
      expect(_stateJson(storage, 'account-a')['cursor'], 9);
    },
  );
}

SyncController _controller({
  required _MemorySyncStorage storage,
  required _FakeSyncTransport transport,
  int Function()? activeVersion,
  SyncLocalSnapshot Function()? readSnapshot,
  Future<void> Function(CloudSyncRecord)? applyRecord,
  Duration retryDelay = const Duration(days: 1),
}) => SyncController(
  uploadHistory: (_, _, _) async => false,
  isContextCurrent: (version) => version == (activeVersion?.call() ?? 1),
  cloudTransport: transport,
  storage: storage,
  readLocalSnapshot: readSnapshot ?? () => const SyncLocalSnapshot(),
  applyRecord: applyRecord ?? (_) async {},
  publishStatus: (_) {},
  operationTimeout: const Duration(seconds: 1),
  retryDelay: retryDelay,
);

void _load(SyncController controller, String accountId, int contextVersion) {
  controller.loadForAccount(
    accountId: accountId,
    contextVersion: contextVersion,
    services: const ExternalServiceSettings(),
  );
}

class _MemorySyncStorage implements SyncStorage {
  final values = <String, Object?>{};
  bool failWrites = false;

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    if (failWrites) throw StateError('storage unavailable');
    values[key] = value;
  }
}

class _FakeSyncTransport implements CloudSyncTransport {
  final pushed = <List<CloudSyncMutation>>[];
  final pullResults = <CloudSyncPullResult>[];
  final remoteRecords = <CloudSyncRecord>[];
  final afterRevisions = <int>[];
  Object? pullFailure;
  final pushResults = <CloudSyncPushResult>[];
  bool unavailable = false;
  bool loseNextPushResponse = false;
  bool expired = false;
  Completer<void>? pushGate;
  int pushCalls = 0;
  int pullCalls = 0;
  int _revision = 0;

  @override
  Future<CloudSyncPushResult> push(List<CloudSyncMutation> mutations) async {
    pushCalls++;
    if (expired) throw const CloudSyncAuthenticationException();
    if (unavailable) throw const CloudSyncUnavailableException();
    final gate = pushGate;
    if (gate != null) await gate.future;
    pushed.add(List<CloudSyncMutation>.from(mutations));
    final CloudSyncPushResult result;
    if (pushResults.isNotEmpty) {
      result = pushResults.removeAt(0);
    } else {
      final records = mutations
          .map((item) => _recordFromMutation(item, ++_revision))
          .toList(growable: false);
      result = CloudSyncPushResult(
        acknowledged: records,
        nextRevision: records.last.serverRevision,
      );
    }
    if (loseNextPushResponse) {
      loseNextPushResponse = false;
      throw const CloudSyncUnavailableException();
    }
    return result;
  }

  @override
  Future<CloudSyncPullResult> pull({
    required int afterRevision,
    int limit = 200,
  }) async {
    pullCalls++;
    afterRevisions.add(afterRevision);
    final failure = pullFailure;
    if (failure != null) throw failure;
    if (expired) throw const CloudSyncAuthenticationException();
    if (unavailable) throw const CloudSyncUnavailableException();
    if (pullResults.isNotEmpty) return pullResults.removeAt(0);
    final records =
        (remoteRecords
                .where((record) => record.serverRevision > afterRevision)
                .toList()
              ..sort((a, b) => a.serverRevision.compareTo(b.serverRevision)))
            .take(limit)
            .toList();
    return CloudSyncPullResult(
      records: records,
      nextRevision: records.isEmpty
          ? afterRevision
          : records.last.serverRevision,
    );
  }
}

CloudSyncRecord _recordFromMutation(CloudSyncMutation mutation, int revision) =>
    CloudSyncRecord.fromJson({
      'type': mutation.type.wireName,
      'record_id': mutation.recordId,
      'payload': mutation.payload,
      'deleted': mutation.deleted,
      'client_mutation_id': mutation.mutationId,
      'server_revision': revision,
    });

CloudSyncRecord _settingsRecord({
  required CloudSyncRecordType type,
  required int revision,
  required Map<String, dynamic> payload,
}) => CloudSyncRecord.fromJson({
  'type': type.wireName,
  'record_id': type == CloudSyncRecordType.appearanceSettings
      ? 'settings:appearance'
      : 'settings:playback',
  'payload': payload,
  'deleted': false,
  'client_mutation_id': 'sync:v1:remote-device:$revision',
  'server_revision': revision,
});

Map<String, dynamic> _state({
  required bool migrated,
  int counter = 0,
  int cursor = 0,
  List<CloudSyncMutation> queue = const [],
}) => {
  'schemaVersion': 1,
  'migrated': migrated,
  'cursor': cursor,
  'counter': counter,
  'queue': queue.map((item) => item.toJson()).toList(),
  'receipts': <Object?>[],
};

Map<String, dynamic> _stateJson(_MemorySyncStorage storage, String accountId) =>
    (storage.values[_stateKey(accountId)]! as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _queue(
  _MemorySyncStorage storage,
  String accountId,
) => (_stateJson(storage, accountId)['queue'] as List)
    .map((item) => (item as Map).cast<String, dynamic>())
    .toList();

String _stateKey(String accountId) => 'account.$accountId.syncState.v1';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for sync.');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

const _deviceId = '0123456789abcdef0123456789abcdef';

final _entry = LibraryEntry(
  subject: const AnimeSubject(
    id: 1,
    title: 'Test subject',
    originalTitle: 'Test subject',
    summary: '',
    coverUrl: null,
    bannerUrl: null,
    date: '2026-08-08',
    platform: 'TV',
    language: 'ja',
    region: 'JP',
    status: 'airing',
    categories: [],
    tags: [],
    totalEpisodes: 12,
    source: 'bangumi',
  ),
  episode: const AnimeEpisode(
    id: 101,
    subjectId: 1,
    number: 1,
    title: 'Episode 1',
    airdate: '2026-08-08',
    duration: '24:00',
    description: '',
  ),
  updatedAt: DateTime.utc(2026, 8, 8),
  positionSeconds: 120,
  durationSeconds: 1440,
);
