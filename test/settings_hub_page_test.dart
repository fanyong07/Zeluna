import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:anime/src/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings hub does not expose API configuration entries', (
    tester,
  ) async {
    await _setViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const SettingsHubPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('影视资料与 API'), findsNothing);
    expect(find.text('番剧资料与 API'), findsNothing);
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('弹幕显示'), findsOneWidget);
    expect(find.text('弹幕来源'), findsOneWidget);
    expect(find.text('Zeluna + 2 个'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy API settings routes return to the settings hub', (
    tester,
  ) async {
    await _setViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AnimeApp)),
    );
    final router = container.read(routerProvider);

    for (final route in const [
      '/settings/services/media',
      '/settings/services/anime',
    ]) {
      router.go(route);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHubPage), findsOneWidget);
      expect(find.byType(ServiceSettingsPage), findsNothing);
      expect(find.text('影视资料与 API'), findsNothing);
      expect(find.text('番剧资料与 API'), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('danmaku sources are reachable from the settings hub', (
    tester,
  ) async {
    await _setViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AnimeApp)),
    );
    container.read(routerProvider).go('/settings');
    await tester.pumpAndSettle();

    await tester.tap(find.text('弹幕来源'));
    await tester.pumpAndSettle();

    expect(find.text('弹幕源：Zeluna / 弹弹play / Bilibili / 自建弹幕库'), findsOneWidget);
    expect(find.textContaining('游客可读取，登录后可发送'), findsOneWidget);
    expect(find.text('启用弹弹play弹幕'), findsOneWidget);
    expect(find.text('启用 Bilibili 弹幕'), findsOneWidget);
    expect(find.text('启用自建弹幕库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('self-hosted HTTP requires a visible warning confirmation', (
    tester,
  ) async {
    await _setViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(
            _SelfHostedSettingsController.new,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const ServiceSettingsPage(kind: 'playback'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('自托管 HTTP（不安全） · http://192.168.1.20'), findsNWidgets(2));
    expect(find.text('允许不安全 HTTP'), findsOneWidget);
    final toggle = find.byKey(const ValueKey('setting_switch_允许不安全 HTTP'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('允许不安全 HTTP？'), findsOneWidget);
    expect(find.textContaining('不会向它发送你的云账号登录凭据'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ServiceSettingsPage)),
    );
    final controller =
        container.read(animeControllerProvider.notifier)
            as _SelfHostedSettingsController;
    expect(controller.updated, isNull);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('confirm_insecure_playback_backend')),
    );
    await tester.pumpAndSettle();
    expect(controller.updated?.allowInsecurePlaybackBackend, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home settings persist the recommendation switch and expose reset',
    (tester) async {
      await _setViewport(tester);
      var reset = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_HomeSettingsController.new),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: HomeSettingsPage(
              onResetRecommendationPreferences: () async => reset = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('个性化推荐'), findsOneWidget);
      final toggle = find.byKey(const ValueKey('setting_switch_个性化推荐'));
      await tester.tap(toggle);
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeSettingsPage)),
      );
      final controller =
          container.read(animeControllerProvider.notifier)
              as _HomeSettingsController;
      expect(controller.updated?.personalizedRecommendations, isFalse);

      final resetAction = find.byKey(
        const ValueKey('reset_recommendation_preferences'),
      );
      await tester.ensureVisible(resetAction);
      await tester.tap(resetAction);
      await tester.pumpAndSettle();
      expect(find.text('重置推荐偏好？'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('confirm_reset_recommendation_preferences')),
      );
      await tester.pumpAndSettle();
      expect(reset, isTrue);
      expect(find.text('推荐偏好已重置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home settings route delegates recommendation reset', (
    tester,
  ) async {
    await _setViewport(tester);
    _HomeSettingsController.resetCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_HomeSettingsController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AnimeApp)),
    );
    container.read(routerProvider).go('/profile/home-settings');
    await tester.pumpAndSettle();

    final resetAction = find.byKey(
      const ValueKey('reset_recommendation_preferences'),
    );
    await tester.ensureVisible(resetAction);
    await tester.tap(resetAction);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('confirm_reset_recommendation_preferences')),
    );
    await tester.pumpAndSettle();

    expect(_HomeSettingsController.resetCalls, 1);
    expect(find.text('推荐偏好已重置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setViewport(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.reset);
}

class _FakeAnimeController extends AnimeController {
  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);
}

class _SelfHostedSettingsController extends AnimeController {
  ExternalServiceSettings? updated;

  @override
  Future<AnimeState> build() async => const AnimeState(
    homeFeed: _feed,
    services: ExternalServiceSettings(
      playbackBackendEnabled: false,
      playbackBackendEndpoint: 'http://192.168.1.20',
      playbackBackendSelfHosted: true,
      allowInsecurePlaybackBackend: false,
    ),
  );

  @override
  Future<void> updateServices(ExternalServiceSettings settings) async {
    updated = settings;
  }
}

class _HomeSettingsController extends AnimeController {
  static int resetCalls = 0;
  HomePreferences? updated;

  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);

  @override
  Future<void> updateHomePreferences(HomePreferences preferences) async {
    updated = preferences;
  }

  @override
  Future<void> resetRecommendationPreferences() async {
    resetCalls++;
  }
}

const _subject = AnimeSubject(
  id: 1,
  title: '测试番剧',
  originalTitle: 'Test Anime',
  summary: '设置页测试数据。',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '中文',
  region: '中国',
  status: '连载',
  categories: [],
  tags: [],
  totalEpisodes: 12,
);

const _feed = AnimeHomeFeed(
  hero: _subject,
  recent: [_subject],
  recommended: [_subject],
  index: [_subject],
  categories: [],
  tags: [],
);
