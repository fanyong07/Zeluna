import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/media_download_task.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/downloads/batch_download_sheet.dart';
import 'package:anime/src/downloads/download_network_guard.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final metered in [false, true]) {
    testWidgets(
      'remaining excludes watched, cached and active; metered=$metered',
      (tester) async {
        final controller = _Downloads();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              animeControllerProvider.overrideWith(() => controller),
              unmeteredNetworkCheckerProvider.overrideWithValue(
                () async => !metered,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    final ready = ref.watch(animeControllerProvider).hasValue;
                    return TextButton(
                      onPressed: ready
                          ? () => showBatchDownloadSheet(
                              context,
                              ref,
                              bundle: _bundle,
                              historyEntry: LibraryEntry(
                                subject: _subject,
                                updatedAt: DateTime.utc(2026),
                                episode: _episodes.first,
                              ),
                            )
                          : null,
                      child: const Text('打开'),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选未缓存'));
        await tester.pump();
        expect(find.text('已选 3 集'), findsOneWidget);
        await tester.tap(find.text('清空选择'));
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('batchDownloadConfirm')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('batchDownloadRemainingUnwatched')),
        );
        await tester.pumpAndSettle();
        expect(find.text('已选 2 集'), findsOneWidget);
        expect(find.textContaining('SP1'), findsNothing);
        final confirm = find.byKey(const ValueKey('batchDownloadConfirm'));
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        if (metered) {
          expect(find.text('当前不是 Wi-Fi 网络'), findsOneWidget);
          expect(controller.calls, isEmpty);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(controller.calls, isEmpty);
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          await tester.tap(find.text('仅本次使用流量下载'));
          await tester.pumpAndSettle();
        }
        expect(controller.calls, [2, 5]);
        expect(find.text('已加入 2 集到下载队列'), findsOneWidget);
      },
    );
  }
  testWidgets('management switch writes the shared setting', (tester) async {
    final controller = _Downloads();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [animeControllerProvider.overrideWith(() => controller)],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pump();
    final key = find.byKey(const ValueKey('wifiOnlyDownloadSwitch'));
    expect(tester.widget<SwitchListTile>(key).value, isTrue);
    await tester.tap(key);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(key).value, isFalse);
  });
  testWidgets(
    'Android bridge reads metering and falls back for older installs',
    (tester) async {
      const ch = MethodChannel('app.anime.anime/network-status');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ch, (call) async {
        expect(call.method, 'isUnmetered');
        return false;
      });
      expect(await isUnmeteredNetwork(channel: ch), isFalse);
      addTearDown(() => messenger.setMockMethodCallHandler(ch, null));
      messenger.setMockMethodCallHandler(
        ch,
        (_) async => throw MissingPluginException(),
      );
      expect(await isUnmeteredNetwork(channel: ch), isTrue);
      messenger.setMockMethodCallHandler(
        ch,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect(await isUnmeteredNetwork(channel: ch), isTrue);
    },
  );
}

class _Downloads extends AnimeController {
  final calls = <int>[];
  @override
  Future<void> updateMisc(MiscSettings settings) async {
    state = AsyncData(state.requireValue.copyWith(misc: settings));
  }

  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: BangumiMetadataRepository().fallbackHomeFeed(),
    offlineTasks: [
      for (final n in [3, 4])
        MediaDownloadTask(
          id: 'task$n',
          subject: _subject,
          episode: _episodes[n - 1],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          status: n == 3
              ? MediaDownloadTaskStatus.completed
              : MediaDownloadTaskStatus.downloading,
          localPath: n == 3 ? 'cached.mp4' : null,
        ),
    ],
  );
  @override
  Future<String> queueOffline(
    AnimeSubject subject,
    AnimeEpisode? episode,
  ) async {
    calls.add(episode!.number);
    return '已加入下载队列';
  }
}

final _episodes = List.generate(
  7,
  (i) => AnimeEpisode(
    id: 100 + i,
    subjectId: 1,
    number: i + 1,
    title: switch (i) {
      5 => '预告',
      6 => 'SP1',
      _ => '',
    },
    airdate: null,
    duration: '',
    description: '',
  ),
);
final _bundle = AnimeDetailBundle(
  subject: _subject,
  episodes: _episodes,
  characters: const [],
  staff: const [],
  recommendations: const [],
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
