import 'dart:async';

import 'package:anime/src/accounts/account_controller.dart';
import 'package:anime/src/data/media_download_backend.dart';
import 'package:anime/src/data/media_download_result.dart';
import 'package:anime/src/data/media_download_service.dart';
import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/downloads/download_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'late old-account result cannot control, publish, or persist over the same task in a new account',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend();
      final service = MediaDownloadService(backend: backend);
      final published = <DownloadSnapshot>[];
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) async => const [_line],
        publishSnapshot: published.add,
        progressPersistInterval: Duration.zero,
      );
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      await controller.queueOffline(_subject, _episode);
      await _waitUntil(() => backend.calls.length == 1);
      final taskId = controller.snapshot.tasks.single.id;
      final oldCall = backend.calls.single;

      await controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
      );
      await controller.queueOffline(_subject, _episode);
      await _waitUntil(() => backend.calls.length == 2);
      final newCall = backend.calls.last;

      expect(oldCall.request.taskId, isNot(newCall.request.taskId));
      controller.cancelOwnedDownload('account-a', taskId);
      expect(oldCall.control.reason, MediaDownloadStopReason.cancel);
      expect(newCall.control.reason, isNull);

      oldCall.completeSuccess('old-account-final.mp4');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await _waitUntil(
        () => backend.deletedPaths.contains('old-account-final.mp4'),
      );
      expect(controller.accountId, 'account-b');
      expect(
        controller.snapshot.tasks.single.status,
        MediaDownloadTaskStatus.downloading,
      );

      newCall.completeSuccess('new-account-final.mp4');
      await _waitUntil(
        () =>
            controller.snapshot.tasks.single.status ==
            MediaDownloadTaskStatus.completed,
      );
      expect(
        controller.snapshot.tasks.single.localPath,
        'new-account-final.mp4',
      );

      final accountA = storage.tasksFor('account-a');
      final accountB = storage.tasksFor('account-b');
      expect(accountA.single['status'], isNot('completed'));
      expect(accountB.single['localPath'], 'new-account-final.mp4');
      expect(
        published.where(
          (snapshot) => snapshot.tasks.any(
            (task) => task.localPath == 'old-account-final.mp4',
          ),
        ),
        isEmpty,
      );
    },
  );

  test(
    'removing while resolving stays removed after the resolver returns',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend();
      final service = MediaDownloadService(backend: backend);
      final resolver = Completer<List<PlaybackLine>>();
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) => resolver.future,
        publishSnapshot: (_) {},
      );
      addTearDown(() {
        if (!resolver.isCompleted) resolver.complete(const []);
        controller.dispose();
        service.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      await controller.queueOffline(_subject, _episode);
      final taskId = controller.snapshot.tasks.single.id;
      await controller.removeDownload(taskId);
      expect(controller.snapshot.tasks, isEmpty);
      expect(storage.tasksFor('account-a'), isEmpty);

      resolver.complete(const [_line]);
      await _flushAsync();
      expect(controller.snapshot.tasks, isEmpty);
      expect(storage.tasksFor('account-a'), isEmpty);
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'late completion after pause remains paused and removes orphan output',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend();
      final service = MediaDownloadService(backend: backend);
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) async => const [_line],
        publishSnapshot: (_) {},
      );
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      await controller.queueOffline(_subject, _episode);
      await _waitUntil(() => backend.calls.length == 1);
      final taskId = controller.snapshot.tasks.single.id;
      final call = backend.calls.single;

      await controller.pauseDownload(taskId);
      expect(call.control.reason, MediaDownloadStopReason.pause);
      expect(
        controller.snapshot.tasks.single.status,
        MediaDownloadTaskStatus.paused,
      );

      call.completeSuccess('late-paused-final.mp4');
      await _waitUntil(
        () => backend.deletedPaths.contains('late-paused-final.mp4'),
      );
      expect(
        controller.snapshot.tasks.single.status,
        MediaDownloadTaskStatus.paused,
      );
      expect(controller.snapshot.tasks.single.localPath, isNull);
    },
  );

  test(
    'late completion after cancel remains cancelled and is cleaned up',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend();
      final service = MediaDownloadService(backend: backend);
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) async => const [_line],
        publishSnapshot: (_) {},
      );
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      await controller.queueOffline(_subject, _episode);
      await _waitUntil(() => backend.calls.length == 1);
      final taskId = controller.snapshot.tasks.single.id;
      final call = backend.calls.single;

      await controller.cancelDownload(taskId);
      expect(call.control.reason, MediaDownloadStopReason.cancel);
      call.completeSuccess('late-cancelled-final.mp4');
      await _waitUntil(
        () => backend.deletedPaths.contains('late-cancelled-final.mp4'),
      );
      expect(
        controller.snapshot.tasks.single.status,
        MediaDownloadTaskStatus.cancelled,
      );
      expect(controller.snapshot.tasks.single.localPath, isNull);
    },
  );

  test(
    'an in-flight progress write remains bound to its original account',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend();
      final service = MediaDownloadService(backend: backend);
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) async => const [_line],
        publishSnapshot: (_) {},
        progressPersistInterval: Duration.zero,
      );
      addTearDown(() {
        storage.releaseBlockedWrite();
        for (final call in backend.calls) {
          if (!call.result.isCompleted) {
            call.result.complete(
              const MediaDownloadResult(
                outcome: MediaDownloadOutcome.cancelled,
                message: 'test teardown',
              ),
            );
          }
        }
        controller.dispose();
        service.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      await controller.queueOffline(_subject, _episode);
      await _waitUntil(() => backend.calls.length == 1);
      storage.blockNextWrite();
      backend.calls.single.onProgress(
        const MediaDownloadProgress(
          downloadedBytes: 256,
          totalBytes: 1024,
          temporaryPath: 'account-a.part',
          targetPath: '',
        ),
      );
      await _waitUntil(() => storage.blockedWriteKey != null);
      expect(storage.blockedWriteKey, 'account.account-a.offlineTasks');

      final switchFuture = controller.loadForAccount(
        accountId: 'account-b',
        contextVersion: 2,
      );
      await _flushAsync();
      storage.releaseBlockedWrite();
      await switchFuture;

      expect(storage.tasksFor('account-a').single['downloadedBytes'], 256);
      expect(storage.tasksFor('account-b'), isEmpty);
      expect(controller.accountId, 'account-b');
      expect(controller.snapshot.tasks, isEmpty);
    },
  );

  test(
    'startup recovery normalizes interrupted and missing-file tasks in the account scope',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend(existingPaths: {'partial-ok'});
      final service = MediaDownloadService(backend: backend);
      final now = DateTime.utc(2026, 8, 2, 12);
      storage.seed('account-a', [
        _task('active', MediaDownloadTaskStatus.downloading),
        _task(
          'missing-complete',
          MediaDownloadTaskStatus.completed,
          localPath: 'missing-final.mp4',
        ),
        _task(
          'partial',
          MediaDownloadTaskStatus.paused,
          temporaryPath: 'partial-ok',
          downloadedBytes: 128,
          totalBytes: 1024,
        ),
      ]);
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) async => const [_line],
        publishSnapshot: (_) {},
        now: () => now,
      );
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      final snapshot = await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 7,
      );
      final byId = {for (final task in snapshot.tasks) task.id: task};
      expect(byId['active']!.status, MediaDownloadTaskStatus.paused);
      expect(byId['active']!.message, contains('上次下载已中断'));
      expect(byId['missing-complete']!.status, MediaDownloadTaskStatus.missing);
      expect(byId['missing-complete']!.localPath, 'missing-final.mp4');
      expect(byId['partial']!.status, MediaDownloadTaskStatus.paused);
      expect(byId['partial']!.temporaryPath, 'partial-ok');
      expect(byId['partial']!.downloadedBytes, 128);
      expect(storage.writeKeys, everyElement('account.account-a.offlineTasks'));
    },
  );

  test(
    'limits concurrent downloads and releases the slot after verification',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend();
      final service = MediaDownloadService(backend: backend);
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) async => const [_line],
        publishSnapshot: (_) {},
        maxConcurrentDownloads: 1,
      );
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      await controller.queueOffline(_subject, _episode);
      await controller.queueOffline(_subject, _episode2);
      await _waitUntil(() => backend.calls.length == 1);
      backend.calls.first.completeSuccess('first.mp4');
      await _waitUntil(() => backend.calls.length == 2);
      expect(backend.calls[1].request.url, _line.url);
      backend.calls[1].completeSuccess('second.mp4');
      await _waitUntil(
        () => controller.snapshot.tasks.every(
          (task) => task.status == MediaDownloadTaskStatus.completed,
        ),
      );
    },
  );

  test('retries a failed line with bounded exponential backoff', () async {
    final storage = _MemoryDownloadStorage();
    final backend = _ControlledDownloadBackend();
    final service = MediaDownloadService(backend: backend);
    final controller = DownloadController(
      storage: storage,
      service: service,
      resolveLines: (_, _) async => const [_line],
      publishSnapshot: (_) {},
      retryBaseDelay: const Duration(milliseconds: 1),
    );
    addTearDown(() {
      controller.dispose();
      service.dispose();
    });

    await controller.loadForAccount(accountId: 'account-a', contextVersion: 1);
    await controller.queueOffline(_subject, _episode);
    await _waitUntil(() => backend.calls.length == 1);
    backend.calls.first.completeFailure();
    await _waitUntil(() => backend.calls.length == 2);
    backend.calls[1].completeSuccess('retried.mp4');
    await _waitUntil(
      () =>
          controller.snapshot.tasks.single.status ==
          MediaDownloadTaskStatus.completed,
    );
  });

  test(
    'reports account/work usage and leaves orphan deletion explicit',
    () async {
      final storage = _MemoryDownloadStorage();
      final backend = _ControlledDownloadBackend(existingPaths: {'owned.mp4'});
      backend.storageEntries.addAll([
        MediaDownloadStorageEntry(
          path: 'owned.mp4',
          bytes: 4,
          modifiedAt: DateTime.utc(2000, 1, 1),
        ),
        MediaDownloadStorageEntry(
          path: 'orphan.part',
          bytes: 3,
          modifiedAt: DateTime.utc(2000, 1, 1),
        ),
      ]);
      storage.seed('account-a', [
        _task(
          'owned',
          MediaDownloadTaskStatus.completed,
          localPath: 'owned.mp4',
          downloadedBytes: 4,
          totalBytes: 4,
        ),
      ]);
      final service = MediaDownloadService(backend: backend);
      final controller = DownloadController(
        storage: storage,
        service: service,
        resolveLines: (_, _) async => const [_line],
        publishSnapshot: (_) {},
      );
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      await controller.loadForAccount(
        accountId: 'account-a',
        contextVersion: 1,
      );
      final report = await controller.storageSnapshot();
      expect(report.totalBytes, 7);
      expect(report.accountBytes, 4);
      expect(report.byWorkBytes[_subject.identityKey], 4);
      expect(report.orphanedPaths, ['orphan.part']);
      expect(report.failedPaths, isEmpty);
      expect(report.expiredTemporaryPaths, ['orphan.part']);
      expect(backend.deletedPaths, isEmpty);
    },
  );
}

final class _MemoryDownloadStorage implements DownloadStorage {
  final Map<String, Object?> values = {};
  final List<String> writeKeys = [];
  Completer<void>? _nextWriteGate;
  Completer<void>? _blockedWriteGate;
  String? blockedWriteKey;

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    writeKeys.add(key);
    final gate = _nextWriteGate;
    if (gate != null) {
      _nextWriteGate = null;
      _blockedWriteGate = gate;
      blockedWriteKey = key;
      await gate.future;
      _blockedWriteGate = null;
      blockedWriteKey = null;
    }
    values[key] = value;
  }

  void blockNextWrite() {
    _nextWriteGate = Completer<void>();
  }

  void releaseBlockedWrite() {
    final gate = _blockedWriteGate ?? _nextWriteGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    _nextWriteGate = null;
  }

  void seed(String accountId, List<MediaDownloadTask> tasks) {
    values[AccountController.libraryKeyFor(accountId, 'offlineTasks')] = tasks
        .map((task) => task.toJson())
        .toList(growable: false);
  }

  List<Map<String, dynamic>> tasksFor(String accountId) {
    final value =
        values[AccountController.libraryKeyFor(accountId, 'offlineTasks')];
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
  }
}

final class _ControlledDownloadBackend implements MediaDownloadBackend {
  _ControlledDownloadBackend({Set<String>? existingPaths})
    : existingPaths = existingPaths ?? <String>{};

  final Set<String> existingPaths;
  final List<String> deletedPaths = [];
  final List<_DownloadCall> calls = [];
  final List<MediaDownloadStorageEntry> storageEntries = [];

  @override
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  }) {
    final call = _DownloadCall(this, request, control, onProgress);
    calls.add(call);
    return call.result.future;
  }

  @override
  Future<bool> fileExists(String path) async => existingPaths.contains(path);

  @override
  Future<MediaDownloadVerification> verifyFile(
    String path, {
    int? expectedBytes,
  }) async => existingPaths.contains(path)
      ? MediaDownloadVerification(
          status: MediaDownloadFileStatus.valid,
          bytes: expectedBytes ?? 1024,
        )
      : const MediaDownloadVerification(
          status: MediaDownloadFileStatus.missing,
        );

  @override
  Future<List<MediaDownloadStorageEntry>> listStorageEntries() async =>
      List.unmodifiable(storageEntries);

  @override
  Future<void> deleteFile(String path) async {
    deletedPaths.add(path);
    existingPaths.remove(path);
  }
}

final class _DownloadCall {
  _DownloadCall(this.backend, this.request, this.control, this.onProgress);

  final _ControlledDownloadBackend backend;
  final MediaDownloadRequest request;
  final MediaDownloadControl control;
  final void Function(MediaDownloadProgress progress) onProgress;
  final Completer<MediaDownloadResult> result =
      Completer<MediaDownloadResult>();

  void completeSuccess(String path) {
    backend.existingPaths.add(path);
    result.complete(
      MediaDownloadResult(
        outcome: MediaDownloadOutcome.completed,
        message: 'done',
        path: path,
        bytes: 1024,
        totalBytes: 1024,
      ),
    );
  }

  void completeFailure() {
    result.complete(
      const MediaDownloadResult(
        outcome: MediaDownloadOutcome.failed,
        message: 'temporary failure',
      ),
    );
  }
}

MediaDownloadTask _task(
  String id,
  MediaDownloadTaskStatus status, {
  String? temporaryPath,
  String? localPath,
  int downloadedBytes = 0,
  int totalBytes = 0,
}) {
  final timestamp = DateTime.utc(2026, 8, 1);
  return MediaDownloadTask(
    id: id,
    subject: _subject,
    episode: _episode,
    createdAt: timestamp,
    updatedAt: timestamp,
    status: status,
    temporaryPath: temporaryPath,
    localPath: localPath,
    downloadedBytes: downloadedBytes,
    totalBytes: totalBytes,
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition was not reached');
}

Future<void> _flushAsync() async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _subject = AnimeSubject(
  id: 1,
  title: '测试动画',
  originalTitle: 'Test Anime',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);

const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '第一集',
  airdate: '2026-01-01',
  duration: '24:00',
  description: '',
);

const _episode2 = AnimeEpisode(
  id: 102,
  subjectId: 1,
  number: 2,
  title: '第二集',
  airdate: '2026-01-08',
  duration: '24:00',
  description: '',
);

const _line = PlaybackLine(
  id: 'line-1',
  episodeId: 101,
  providerId: 'provider-1',
  providerName: 'Test Provider',
  title: 'Direct',
  quality: '1080p',
  format: 'MP4',
  url: 'https://media.example/video.mp4',
  available: true,
);
