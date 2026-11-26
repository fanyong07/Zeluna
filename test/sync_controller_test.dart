import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/sync/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabled compatibility sync never invokes the uploader', () async {
    var calls = 0;
    final controller = _controller(
      activeVersion: () => 1,
      upload: (_, _, _) async {
        calls++;
        return true;
      },
    );
    addTearDown(controller.dispose);
    _load(
      controller,
      accountId: 'account-a',
      contextVersion: 1,
      services: _disabledServices,
    );

    expect(
      await _sync(controller, accountId: 'account-a', contextVersion: 1),
      isFalse,
    );
    expect(calls, 0);
  });

  test('history uploads are serialized in local mutation order', () async {
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final started = <int>[];
    final controller = _controller(
      activeVersion: () => 1,
      upload: (_, episode, _) async {
        started.add(episode!.id);
        await (episode.id == _episode.id
            ? firstGate.future
            : secondGate.future);
        return true;
      },
    );
    addTearDown(() {
      if (!firstGate.isCompleted) firstGate.complete();
      if (!secondGate.isCompleted) secondGate.complete();
      controller.dispose();
    });
    _load(controller, accountId: 'account-a', contextVersion: 1);

    final first = _sync(controller, accountId: 'account-a', contextVersion: 1);
    final second = controller.syncHistory(
      accountId: 'account-a',
      contextVersion: 1,
      subject: _subject,
      episode: _episode2,
    );
    await _waitUntil(() => started.length == 1);
    expect(started, [_episode.id]);
    firstGate.complete();
    await _waitUntil(() => started.length == 2);
    expect(started, [_episode.id, _episode2.id]);
    secondGate.complete();

    expect(await first, isTrue);
    expect(await second, isTrue);
  });

  test('account switch rejects queued and late old-account results', () async {
    var activeVersion = 1;
    final firstGate = Completer<void>();
    var calls = 0;
    final controller = _controller(
      activeVersion: () => activeVersion,
      upload: (_, _, _) async {
        calls++;
        if (calls == 1) await firstGate.future;
        return true;
      },
    );
    addTearDown(() {
      if (!firstGate.isCompleted) firstGate.complete();
      controller.dispose();
    });
    _load(controller, accountId: 'account-a', contextVersion: 1);
    final inFlight = _sync(
      controller,
      accountId: 'account-a',
      contextVersion: 1,
    );
    final queued = _sync(controller, accountId: 'account-a', contextVersion: 1);
    await _waitUntil(() => calls == 1);

    activeVersion = 2;
    _load(controller, accountId: 'account-b', contextVersion: 2);
    firstGate.complete();
    expect(await inFlight, isFalse);
    expect(await queued, isFalse);
    expect(calls, 1, reason: 'the queued account A upload must never start');

    expect(
      await _sync(controller, accountId: 'account-b', contextVersion: 2),
      isTrue,
    );
    expect(calls, 2);
  });

  test('service updates invalidate old work and gate later uploads', () async {
    var calls = 0;
    final controller = _controller(
      activeVersion: () => 1,
      upload: (_, _, _) async {
        calls++;
        return true;
      },
    );
    addTearDown(controller.dispose);
    _load(controller, accountId: 'account-a', contextVersion: 1);
    expect(
      await _sync(controller, accountId: 'account-a', contextVersion: 1),
      isTrue,
    );

    controller.applyServices(_disabledServices, contextVersion: 1);
    expect(
      await _sync(controller, accountId: 'account-a', contextVersion: 1),
      isFalse,
    );
    controller.applyServices(_enabledServices, contextVersion: 1);
    expect(
      await _sync(controller, accountId: 'account-a', contextVersion: 1),
      isTrue,
    );
    expect(calls, 2);
  });

  test('optional upload timeout is isolated from the local mutation', () async {
    final gate = Completer<bool>();
    final controller = _controller(
      activeVersion: () => 1,
      operationTimeout: const Duration(milliseconds: 20),
      upload: (_, _, _) => gate.future,
    );
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(false);
      controller.dispose();
    });
    _load(controller, accountId: 'account-a', contextVersion: 1);

    expect(
      await _sync(controller, accountId: 'account-a', contextVersion: 1),
      isFalse,
    );
    await controller.settle();
  });
}

SyncController _controller({
  required int Function() activeVersion,
  required SyncHistoryUploader upload,
  Duration operationTimeout = const Duration(seconds: 1),
}) => SyncController(
  uploadHistory: upload,
  isContextCurrent: (version) => version == activeVersion(),
  operationTimeout: operationTimeout,
);

void _load(
  SyncController controller, {
  required String accountId,
  required int contextVersion,
  ExternalServiceSettings services = _enabledServices,
}) => controller.loadForAccount(
  accountId: accountId,
  contextVersion: contextVersion,
  services: services,
);

Future<bool> _sync(
  SyncController controller, {
  required String accountId,
  required int contextVersion,
}) => controller.syncHistory(
  accountId: accountId,
  contextVersion: contextVersion,
  subject: _subject,
  episode: _episode,
);

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for sync.');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

const _enabledServices = ExternalServiceSettings(
  publicCollectionSyncEnabled: true,
);
const _disabledServices = ExternalServiceSettings(
  publicCollectionSyncEnabled: false,
);

const _subject = AnimeSubject(
  id: 1,
  title: 'Test subject',
  originalTitle: 'Test subject',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-08-02',
  platform: 'TV',
  language: 'ja',
  region: 'JP',
  status: 'airing',
  categories: [],
  tags: [],
  totalEpisodes: 2,
  source: 'bangumi',
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: 'Episode 1',
  airdate: '2026-08-02',
  duration: '24:00',
  description: '',
);

const _episode2 = AnimeEpisode(
  id: 102,
  subjectId: 1,
  number: 2,
  title: 'Episode 2',
  airdate: '2026-08-09',
  duration: '24:00',
  description: '',
);
