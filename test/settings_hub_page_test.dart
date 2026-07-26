import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
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
