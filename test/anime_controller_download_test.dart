import 'dart:async';
import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/media_download_backend.dart';
import 'package:anime/src/data/media_download_result.dart';
import 'package:anime/src/data/media_download_service.dart';
import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/data/peertube_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('旧外部源离线下载链路', () {
    test(
      'controller skips HLS and switches to the next single-file line',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'anime-controller-download-',
        );
        Hive.init(root.path);
        final settings = await Hive.openBox<dynamic>('anime.settings.v2');
        await settings.put('services', _offlineServices.toJson());
        await settings.close();

        final backend = _FallbackDownloadBackend(root);
        final service = MediaDownloadService(backend: backend);
        final container = ProviderContainer(
          overrides: [
            mediaDownloadServiceProvider.overrideWithValue(service),
            peerTubeRepositoryProvider.overrideWithValue(
              _DownloadPeerTubeRepository(),
            ),
            sourceCatalogRepositoryProvider.overrideWithValue(
              const _EmptySourceCatalogRepository(),
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          service.dispose();
          await Hive.close();
          if (await root.exists()) await root.delete(recursive: true);
        });

        await container.read(animeControllerProvider.future);
        final controller = container.read(animeControllerProvider.notifier);
        expect(await controller.queueOffline(_subject, _episode), '已加入下载队列');

        MediaDownloadTask? task;
        for (var i = 0; i < 100; i++) {
          task = container
              .read(animeControllerProvider)
              .value
              ?.offlineTasks
              .firstOrNull;
          if (task?.status == MediaDownloadTaskStatus.completed) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(task?.status, MediaDownloadTaskStatus.completed);
        expect(backend.urls, [
          'https://cdn.example/failing.mp4',
          'https://cdn.example/fallback?id=1',
        ]);
        expect(task?.providerName, 'Fallback API');
        expect(task?.downloadedBytes, 4096);
        expect(task?.localPlaybackLine?.url, startsWith('file:'));
      },
    );

    test(
      'removing a resolving task never starts the eventual download',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'anime-controller-remove-',
        );
        Hive.init(root.path);
        final settings = await Hive.openBox<dynamic>('anime.settings.v2');
        await settings.put('services', _offlineServices.toJson());
        await settings.close();

        final repository = _BlockingPeerTubeRepository();
        final backend = _FallbackDownloadBackend(root);
        final service = MediaDownloadService(backend: backend);
        final container = ProviderContainer(
          overrides: [
            mediaDownloadServiceProvider.overrideWithValue(service),
            peerTubeRepositoryProvider.overrideWithValue(repository),
            sourceCatalogRepositoryProvider.overrideWithValue(
              const _EmptySourceCatalogRepository(),
            ),
          ],
        );
        addTearDown(() async {
          if (!repository.lines.isCompleted) {
            repository.lines.complete(const []);
          }
          container.dispose();
          service.dispose();
          await Hive.close();
          if (await root.exists()) await root.delete(recursive: true);
        });

        await container.read(animeControllerProvider.future);
        final controller = container.read(animeControllerProvider.notifier);
        await controller.queueOffline(_subject, _episode);
        final taskId = container
            .read(animeControllerProvider)
            .value!
            .offlineTasks
            .single
            .id;

        await controller
            .removeDownload(taskId)
            .timeout(const Duration(milliseconds: 500));
        expect(
          container.read(animeControllerProvider).value!.offlineTasks,
          isEmpty,
        );

        repository.lines.complete(const [
          PlaybackLine(
            id: 'late',
            episodeId: 101,
            providerId: 'late',
            providerName: 'Late MP4',
            title: 'Late',
            quality: '720p',
            format: 'MP4',
            url: 'https://cdn.example/late.mp4',
            available: true,
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(backend.urls, isEmpty);
      },
    );

    test(
      'late completion cannot revive a cancelled task and removes artifacts',
      () async {
        final harness = await _LateDownloadHarness.start('cancel');
        addTearDown(harness.dispose);

        await harness.controller.cancelDownload(harness.taskId);
        expect(harness.task.status, MediaDownloadTaskStatus.cancelled);

        await harness.completeBackend();
        await _waitUntil(() async {
          return !await harness.backend.temporary.exists() &&
              !await harness.backend.target.exists();
        });

        final task = harness.task;
        expect(task.status, MediaDownloadTaskStatus.cancelled);
        expect(task.localPath, isNull);
        expect(task.temporaryPath, isNull);
        expect(
          harness.backend.deletedPaths,
          containsAll([
            harness.backend.temporary.path,
            harness.backend.target.path,
          ]),
        );
      },
    );

    test('late completion cannot overwrite a paused task', () async {
      final harness = await _LateDownloadHarness.start('pause');
      addTearDown(harness.dispose);

      await harness.controller.pauseDownload(harness.taskId);
      expect(harness.task.status, MediaDownloadTaskStatus.paused);

      await harness.completeBackend();
      await _waitUntil(() => !harness.service.isActive(harness.taskId));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final task = harness.task;
      expect(await harness.backend.target.exists(), isTrue);
      expect(task.status, MediaDownloadTaskStatus.paused);
      expect(task.localPath, isNull);
      expect(task.message, '下载已暂停');
    });

    test(
      'persisted active task is restored as resumable paused task',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'anime-controller-restore-',
        );
        Hive.init(root.path);
        final settings = await Hive.openBox<dynamic>('anime.settings.v2');
        await settings.put('services', _offlineServices.toJson());
        await settings.close();
        final partial = File('${root.path}/restore.part');
        await partial.writeAsBytes(List<int>.filled(1024, 3));
        final stored = MediaDownloadTask(
          id: 'restore',
          subject: _subject,
          episode: _episode,
          createdAt: DateTime.utc(2026, 7, 18),
          updatedAt: DateTime.utc(2026, 7, 18),
          status: MediaDownloadTaskStatus.downloading,
          providerName: 'Direct MP4',
          format: 'MP4',
          url: 'https://cdn.example/video.mp4',
          downloadedBytes: 1024,
          totalBytes: 4096,
          temporaryPath: partial.path,
        );
        final library = await Hive.openBox<dynamic>('anime.library.v2');
        await library.put('offlineTasks', [stored.toJson()]);
        await library.close();

        final backend = _FallbackDownloadBackend(root);
        final service = MediaDownloadService(backend: backend);
        final container = ProviderContainer(
          overrides: [
            mediaDownloadServiceProvider.overrideWithValue(service),
            peerTubeRepositoryProvider.overrideWithValue(
              _DownloadPeerTubeRepository(),
            ),
            sourceCatalogRepositoryProvider.overrideWithValue(
              const _EmptySourceCatalogRepository(),
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          service.dispose();
          await Hive.close();
          if (await root.exists()) await root.delete(recursive: true);
        });

        final state = await container.read(animeControllerProvider.future);
        final restored = state.offlineTasks.single;

        expect(restored.status, MediaDownloadTaskStatus.paused);
        expect(restored.downloadedBytes, 1024);
        expect(restored.temporaryPath, partial.path);
        expect(restored.message, contains('可以继续下载'));
      },
    );
  }, skip: 'v3 下载必须改用统一后端线路，PeerTube/本地源回退已退出运行链路');
}

Future<void> _waitUntil(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the download state to settle');
}

class _LateDownloadHarness {
  _LateDownloadHarness._({
    required this.root,
    required this.backend,
    required this.service,
    required this.container,
    required this.controller,
    required this.taskId,
  });

  final Directory root;
  final _LateCompletedDownloadBackend backend;
  final MediaDownloadService service;
  final ProviderContainer container;
  final AnimeController controller;
  final String taskId;

  static Future<_LateDownloadHarness> start(String name) async {
    final root = await Directory.systemTemp.createTemp(
      'anime-controller-late-$name-',
    );
    Hive.init(root.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    await settings.put('services', _offlineServices.toJson());
    await settings.close();
    final backend = _LateCompletedDownloadBackend(root);
    final service = MediaDownloadService(backend: backend);
    final container = ProviderContainer(
      overrides: [
        mediaDownloadServiceProvider.overrideWithValue(service),
        peerTubeRepositoryProvider.overrideWithValue(
          _SingleDownloadPeerTubeRepository(),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
      ],
    );
    await container.read(animeControllerProvider.future);
    final controller = container.read(animeControllerProvider.notifier);
    await controller.queueOffline(_subject, _episode);
    final taskId = container
        .read(animeControllerProvider)
        .value!
        .offlineTasks
        .single
        .id;
    await backend.started.future.timeout(const Duration(seconds: 2));
    return _LateDownloadHarness._(
      root: root,
      backend: backend,
      service: service,
      container: container,
      controller: controller,
      taskId: taskId,
    );
  }

  MediaDownloadTask get task => container
      .read(animeControllerProvider)
      .value!
      .offlineTasks
      .singleWhere((item) => item.id == taskId);

  Future<void> completeBackend() async {
    backend.complete();
    await backend.finished.future.timeout(const Duration(seconds: 2));
  }

  Future<void> dispose() async {
    backend.complete();
    if (backend.started.isCompleted) {
      await backend.finished.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    container.dispose();
    service.dispose();
    await Hive.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _LateCompletedDownloadBackend implements MediaDownloadBackend {
  _LateCompletedDownloadBackend(this.root);

  final Directory root;
  final Completer<void> started = Completer<void>();
  final Completer<void> _release = Completer<void>();
  final Completer<void> finished = Completer<void>();
  final List<String> deletedPaths = [];

  late final File temporary;
  late final File target;

  void complete() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  }) async {
    if (!started.isCompleted) started.complete();
    try {
      await _release.future;
      temporary = File('${root.path}/${request.taskId}.part');
      target = File('${root.path}/${request.taskId}.mp4');
      await temporary.writeAsBytes(List<int>.filled(256, 1));
      await target.writeAsBytes(List<int>.filled(4096, 2));
      onProgress(
        MediaDownloadProgress(
          downloadedBytes: 4096,
          totalBytes: 4096,
          temporaryPath: temporary.path,
          targetPath: target.path,
        ),
      );
      return MediaDownloadResult(
        outcome: MediaDownloadOutcome.completed,
        message: '迟到的下载完成结果',
        path: target.path,
        temporaryPath: temporary.path,
        bytes: 4096,
        totalBytes: 4096,
      );
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    deletedPaths.add(path);
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> fileExists(String path) => File(path).exists();
}

class _FallbackDownloadBackend implements MediaDownloadBackend {
  _FallbackDownloadBackend(this.root);

  final Directory root;
  final List<String> urls = [];

  @override
  Future<MediaDownloadResult> download({
    required MediaDownloadRequest request,
    required MediaDownloadControl control,
    required void Function(MediaDownloadProgress progress) onProgress,
  }) async {
    urls.add(request.url);
    final temporary = File('${root.path}/${request.taskId}.part');
    final target = File('${root.path}/${request.taskId}.mp4');
    if (request.url.contains('failing.mp4')) {
      await temporary.writeAsBytes(List<int>.filled(256, 1));
      onProgress(
        MediaDownloadProgress(
          downloadedBytes: 256,
          totalBytes: 4096,
          temporaryPath: temporary.path,
          targetPath: target.path,
        ),
      );
      return MediaDownloadResult(
        outcome: MediaDownloadOutcome.failed,
        message: '模拟线路失败',
        path: target.path,
        temporaryPath: temporary.path,
        bytes: 256,
        totalBytes: 4096,
      );
    }
    await target.writeAsBytes(List<int>.filled(4096, 2));
    onProgress(
      MediaDownloadProgress(
        downloadedBytes: 4096,
        totalBytes: 4096,
        temporaryPath: temporary.path,
        targetPath: target.path,
      ),
    );
    return MediaDownloadResult(
      outcome: MediaDownloadOutcome.completed,
      message: '下载完成',
      path: target.path,
      temporaryPath: temporary.path,
      bytes: 4096,
      totalBytes: 4096,
    );
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> fileExists(String path) => File(path).exists();
}

class _DownloadPeerTubeRepository extends PeerTubeRepository {
  @override
  Future<List<AnimeSubject>> trending({int page = 1, int limit = 24}) async =>
      const [];

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    return const [
      PlaybackLine(
        id: 'hls',
        episodeId: 101,
        providerId: 'hls',
        providerName: 'HLS',
        title: 'HLS',
        quality: '1080p',
        format: 'HLS',
        url: 'https://cdn.example/master.m3u8',
        available: true,
      ),
      PlaybackLine(
        id: 'direct-failure',
        episodeId: 101,
        providerId: 'direct-failure',
        providerName: 'Direct MP4',
        title: 'MP4',
        quality: '720p',
        format: 'MP4',
        url: 'https://cdn.example/failing.mp4',
        available: true,
      ),
      PlaybackLine(
        id: 'fallback',
        episodeId: 101,
        providerId: 'fallback',
        providerName: 'Fallback API',
        title: 'Fallback',
        quality: '720p',
        format: 'unknown',
        url: 'https://cdn.example/fallback?id=1',
        available: true,
      ),
    ];
  }
}

class _BlockingPeerTubeRepository extends PeerTubeRepository {
  final lines = Completer<List<PlaybackLine>>();

  @override
  Future<List<AnimeSubject>> trending({int page = 1, int limit = 24}) async =>
      const [];

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) => lines.future;
}

class _SingleDownloadPeerTubeRepository extends PeerTubeRepository {
  @override
  Future<List<AnimeSubject>> trending({int page = 1, int limit = 24}) async =>
      const [];

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    return const [
      PlaybackLine(
        id: 'late-completion',
        episodeId: 101,
        providerId: 'late-completion',
        providerName: 'Late MP4',
        title: 'Late completion',
        quality: '720p',
        format: 'MP4',
        url: 'https://cdn.example/late-completion.mp4',
        available: true,
      ),
    ];
  }
}

class _EmptySourceCatalogRepository extends SourceCatalogRepository {
  const _EmptySourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

const _offlineServices = ExternalServiceSettings(
  mediaMetadataEnabled: false,
  tmdbEnabled: false,
  cinemetaEnabled: false,
  peerTubeEnabled: true,
  wikimediaCommonsEnabled: false,
  anilistEnabled: false,
  jikanEnabled: false,
  kitsuEnabled: false,
  bangumiEnabled: false,
  publicCollectionSyncEnabled: false,
  dandanplayDanmakuEnabled: false,
  bilibiliDanmakuEnabled: false,
);

const _subject = AnimeSubject(
  id: 1,
  title: '测试动画',
  originalTitle: 'Test Anime',
  summary: 'summary',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'PeerTube',
  language: '中文',
  region: 'example.test',
  status: '开放许可',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'peertube:test',
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
