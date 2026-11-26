import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/danmaku_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/video/native_video_compatibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/generated_player_video.dart';
import 'support/isolated_player_environment.dart';

// Explicit opt-in: generated local video and isolated account/storage, but real
// anonymous danmaku GETs. Never sends comments, reads secrets or opens user stores.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const live = bool.fromEnvironment('ZELUNA_LIVE_DANMAKU');
  testWidgets(
    'Android landscape renders live dandanplay and switches episodes',
    (tester) async {
      await NativeVideoCompatibility.instance.initialize();
      MediaKit.ensureInitialized();
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      final directory = await Directory.systemTemp.createTemp(
        'zeluna-danmaku-android-',
      );
      final fixture = await LoopbackPlayerVideo.start(
        await writeGeneratedPlayerTestVideo(directory),
      );
      final account = _AndroidPlayerAccount(mediaBase: fixture.baseUri);
      const subject = AnimeSubject(
        id: -9001,
        title: '葬送的芙莉莲',
        originalTitle: 'Frieren',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: '2023-09-29',
        platform: 'TV',
        language: '日语',
        region: '日本',
        status: '',
        categories: [AnimeCategory(name: '动画')],
        tags: [],
        totalEpisodes: 28,
        source: 'integration',
      );
      final evidence = <String, Object?>{
        'live_danmaku': true,
        'media_transport': 'generated_loopback_http',
        'user_storage': 'isolated',
        'software_decode':
            NativeVideoCompatibility.instance.configuration.hwdec == 'no',
      };
      binding.reportData = evidence;
      addTearDown(() async {
        account.repository.close();
        await fixture.close();
        await SystemChrome.setPreferredOrientations([]);
      });
      Future<void> waitFor(bool Function() ready, String label) async {
        final end = DateTime.now().add(const Duration(seconds: 25));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: label);
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [animeControllerProvider.overrideWith(() => account)],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(),
            home: PlayerPage(
              request: PlaySessionRequest(
                subject: subject,
                episodes: const [playerTestEpisode, playerTestSecondEpisode],
                episode: playerTestEpisode,
                initialLine: account.lineFor(playerTestEpisode),
              ),
            ),
          ),
        ),
      );
      await waitFor(() => account.firstFrames > 0, 'native first frame');
      final video = tester.widget<Video>(find.byType(Video).first);
      await video.controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 10),
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('发送'), findsOneWidget);
      await tester.tap(find.byTooltip('全屏').hitTestable());
      await tester.pumpAndSettle();
      account.enableDanmaku();
      await waitFor(
        () =>
            (account.commentsByEpisode[playerTestEpisode.id]?.length ?? 0) > 0,
        'episode 1 real dandanplay loaded',
      );
      final texts = account.commentsByEpisode[playerTestEpisode.id]!
          .map((c) => c.text)
          .toSet();
      await waitFor(
        () => find
            .byWidgetPredicate((w) => w is Text && texts.contains(w.data))
            .evaluate()
            .isNotEmpty,
        'real remote comment painted on Android',
      );
      evidence['episode_1_count'] =
          account.commentsByEpisode[playerTestEpisode.id]!.length;
      evidence['episode_1_painted'] = true;

      Future<void> showControls() async {
        if (find.byTooltip('播放速度').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(tester.getCenter(find.byType(Video).first));
          await tester.pump(const Duration(milliseconds: 400));
          await waitFor(
            () => find.byTooltip('播放速度').hitTestable().evaluate().isNotEmpty,
            'tap reveals controls',
          );
        }
      }

      await showControls();
      await tester.tap(find.byTooltip('暂停').hitTestable());
      await tester.pump(const Duration(milliseconds: 400));
      final playBounds = tester.getRect(find.byTooltip('播放'));
      final inputBounds = tester.getRect(find.byType(TextField));
      final episodesBounds = tester.getRect(find.byTooltip('选集'));
      expect((inputBounds.center.dy - playBounds.center.dy).abs(), lessThan(2));
      expect(inputBounds.left, greaterThan(playBounds.right));
      expect(inputBounds.right, lessThan(episodesBounds.left));
      evidence['composer_inline'] = true;
      debugPrint('ANDROID_DANMAKU_SCREENSHOT_READY');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 8)),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('播放').hitTestable());
      await tester.pump(const Duration(milliseconds: 400));
      await showControls();
      await tester.tap(find.byTooltip('下一集').hitTestable());
      await waitFor(
        () =>
            (account.commentsByEpisode[playerTestSecondEpisode.id]?.length ??
                0) >
            0,
        'episode 2 automatically loads real danmaku',
      );
      final secondIds = account.commentsByEpisode[playerTestSecondEpisode.id]!
          .map((c) => c.id)
          .toSet();
      await waitFor(
        () => tester
            .widgetList<RemoteDanmakuOverlay>(find.byType(RemoteDanmakuOverlay))
            .any(
              (w) =>
                  w.comments.isNotEmpty &&
                  secondIds.contains(w.comments.first.id),
            ),
        'old episode timeline replaced',
      );
      evidence['episode_2_count'] = secondIds.length;
      await showControls();
      await tester.tap(find.byTooltip('播放速度').hitTestable());
      await tester.pump(const Duration(milliseconds: 150));
      debugPrint('ANDROID_MENU_SCREENSHOT_READY');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.text('1.25x'),
        findsWidgets,
        reason: 'menu remains open beyond chrome auto-hide deadline',
      );
      await tester.tap(find.text('1.25x').last);
      await tester.pumpAndSettle();
      await showControls();
      await tester.tap(find.byTooltip(RegExp(r'音量 \d+%，点击调节')).hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byTooltip('静音'), findsOneWidget);
      await tester.tapAt(const Offset(200, 100));
      await tester.pumpAndSettle();
      await showControls();
      await tester.enterText(find.byType(TextField), '本地验证草稿，不发送');
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.byType(TextField).hitTestable(),
        findsOneWidget,
        reason: 'typing keeps the composer visible beyond auto-hide',
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '本地验证草稿，不发送');
      field.controller!.clear();
      field.focusNode?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await tester.pump(const Duration(milliseconds: 400));
      await showControls();
      await tester.tap(find.byTooltip('选集').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('选集'), findsWidgets);
      expect(find.textContaining('Second generated video'), findsWidgets);
      evidence['controls_verified'] = [
        'speed',
        'touch_volume',
        'episode_panel',
        'composer_focus_without_sending',
      ];
      evidence['passed'] = true;
      evidence['observed_utc'] = DateTime.now().toUtc().toIso8601String();
      debugPrint('ANDROID_DANMAKU_RESULT ${jsonEncode(evidence)}');
      binding.reportData = evidence;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
    skip: !live,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _AndroidPlayerAccount extends IsolatedPlayerTestAccount {
  _AndroidPlayerAccount({required super.mediaBase});
  @override
  Future<void> updateSettings(PlaybackSettings settings) async {
    state = AsyncData(state.requireValue.copyWith(settings: settings));
  }

  final repository = DanmakuRepository();
  final commentsByEpisode = <int, List<DanmakuComment>>{};
  @override
  Future<DanmakuTimeline> danmakuTimelineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool forceRefresh = false,
  }) async {
    danmakuRequests.add(episode.id);
    final timeline = await repository.timelineForEpisode(
      subject,
      episode,
      const ExternalServiceSettings(
        bilibiliDanmakuEnabled: false,
        dandanplayDanmakuEnabled: true,
        customDanmakuEnabled: false,
      ),
      forceRefresh: forceRefresh,
    );
    commentsByEpisode[episode.id] = timeline.comments
        .where((c) => c.provider == '弹弹play')
        .toList();
    return timeline;
  }
}
