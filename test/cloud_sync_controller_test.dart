import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/sync/cloud_sync_transport.dart';
import 'package:anime/src/sync/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    final online = _FakeSyncTransport();
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

      await controller.enqueueLibrary(
        accountId: 'account-a',
        contextVersion: 1,
        type: CloudSyncRecordType.history,
        entry: _entry,
      );
      await controller.settle();

      expect(applied, hasLength(1));
      expect(applied.single.payload['positionSeconds'], 360);
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
  final pushResults = <CloudSyncPushResult>[];
  bool unavailable = false;
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
    if (pushResults.isNotEmpty) return pushResults.removeAt(0);
    final records = mutations
        .map((item) => _recordFromMutation(item, ++_revision))
        .toList(growable: false);
    return CloudSyncPushResult(
      acknowledged: records,
      nextRevision: records.last.serverRevision,
    );
  }

  @override
  Future<CloudSyncPullResult> pull({
    required int afterRevision,
    int limit = 200,
  }) async {
    pullCalls++;
    if (expired) throw const CloudSyncAuthenticationException();
    if (unavailable) throw const CloudSyncUnavailableException();
    if (pullResults.isNotEmpty) return pullResults.removeAt(0);
    return CloudSyncPullResult(records: const [], nextRevision: afterRevision);
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
  List<CloudSyncMutation> queue = const [],
}) => {
  'schemaVersion': 1,
  'migrated': migrated,
  'cursor': 0,
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
