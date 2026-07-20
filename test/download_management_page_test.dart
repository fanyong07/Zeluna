import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('download page shows real progress and pause action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _DownloadPageController.pausedTaskId = null;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_DownloadPageController.new),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('离线缓存'), findsOneWidget);
    expect(find.text('全部下载'), findsOneWidget);
    expect(find.text('返回'), findsNothing);
    expect(find.text('正在下载'), findsOneWidget);
    expect(find.textContaining('512.0 KB / 1.0 MB'), findsOneWidget);
    final progress = tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.any((item) => item.value == 0.5), isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(_DownloadPageController.pausedTaskId, 'task-1');
  });

  testWidgets('download task layout stays usable at 320 logical pixels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_DownloadPageController.new),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('离线缓存'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'download does not open an old local file after the account context changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const DownloadManagementPage(),
          ),
          GoRoute(
            path: '/player',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('不应打开的播放页'))),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(
              _StaleDownloadPageController.new,
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('播放本地文件'));
      await tester.pumpAndSettle();

      expect(find.text('不应打开的播放页'), findsNothing);
      expect(find.byType(DownloadManagementPage), findsOneWidget);
    },
  );
}

class _DownloadPageController extends AnimeController {
  static String? pausedTaskId;

  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: BangumiMetadataRepository().fallbackHomeFeed(),
    offlineTasks: [_task],
  );

  @override
  Future<void> pauseDownload(String taskId) async {
    pausedTaskId = taskId;
  }
}

class _StaleDownloadPageController extends AnimeController {
  int _contextVersion = 1;

  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: BangumiMetadataRepository().fallbackHomeFeed(),
    offlineTasks: [
      _task.copyWith(
        status: MediaDownloadTaskStatus.completed,
        localPath: r'C:\Anime\episode-1.mp4',
      ),
    ],
  );

  @override
  int get accountContextVersion => _contextVersion;

  @override
  bool isAccountContextCurrent(int version) => version == _contextVersion;

  @override
  Future<bool> addHistory(
    AnimeSubject subject,
    AnimeEpisode? episode, {
    int? expectedAccountContextVersion,
  }) async {
    _contextVersion++;
    return true;
  }
}

final _task = MediaDownloadTask(
  id: 'task-1',
  subject: _subject,
  episode: _episode,
  createdAt: DateTime.utc(2026, 7, 18),
  updatedAt: DateTime.utc(2026, 7, 18),
  status: MediaDownloadTaskStatus.downloading,
  providerName: 'Direct MP4',
  format: 'MP4',
  url: 'https://cdn.example/video.mp4',
  downloadedBytes: 512 * 1024,
  totalBytes: 1024 * 1024,
  message: '正在通过 Direct MP4 下载',
);

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
