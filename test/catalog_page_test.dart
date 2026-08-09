import 'dart:async';

import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/catalog/catalog_controller.dart';
import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/sources/external_source_adapters.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/shared_ui/poster_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _internalMetadataProviderNames = [
  'Bangumi',
  'AniList',
  'Jikan',
  'Kitsu',
  'Cinemeta',
  'TVMaze',
  'Wikidata',
  'Wikimedia',
  'Archive',
  'PeerTube',
  'MyAnimeList',
];

void _expectInternalMetadataProvidersHidden() {
  for (final provider in _internalMetadataProviderNames) {
    expect(
      find.textContaining(provider, findRichText: true),
      findsNothing,
      reason: '$provider should stay hidden from public-facing copy',
    );
  }
}

void main() {
  testWidgets('home shows AniCh style tabs and profile entry', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('最近更新'), findsWidgets);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('索引'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('画廊'), findsNothing);
    expect(find.text('孤独摇滚！'), findsWidgets);
  });

  testWidgets('home recommendation can be dismissed as not interested', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    _FakeAnimeController.lastNotInterested = null;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    const menuKey = ValueKey('recommendation-menu-wikidata:2875');
    final menu = find.byKey(menuKey);
    expect(menu, findsOneWidget);
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('不感兴趣'));
    await tester.pumpAndSettle();

    expect(_FakeAnimeController.lastNotInterested?.id, _movieSubject.id);
    expect(find.byKey(menuKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pure chart mode hides inactive not-interested actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(
            _PersonalizationDisabledAnimeController.new,
          ),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('recommendation-menu-wikidata:2875')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('rotate-home-recommendations')),
      findsOneWidget,
    );
  });

  testWidgets('home rotates recommendations from the local candidate pool', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    _FakeAnimeController.rotateCalls = 0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    final rotate = find.byKey(const ValueKey('rotate-home-recommendations'));
    expect(rotate, findsOneWidget);
    await tester.ensureVisible(rotate);
    await tester.tap(rotate);
    await tester.pump();

    expect(_FakeAnimeController.rotateCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled Chinese preference shows the anime original title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    _FakeAnimeController.lastServices = const ExternalServiceSettings(
      preferBangumiChinese: false,
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      _FakeAnimeController.lastServices = const ExternalServiceSettings();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    expect(find.text('ぼっち・ざ・ろっく！'), findsOneWidget);
  });

  testWidgets('home search stays editable and submits in Android landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2048, 1152);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    final searchField = find.byType(TextField);
    final editable = find.descendant(
      of: searchField,
      matching: find.byType(EditableText),
    );
    expect(searchField, findsOneWidget);
    expect(editable, findsOneWidget);
    expect(tester.getSize(editable).width, greaterThan(240));

    await tester.tap(searchField);
    await tester.pump();
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byKey(const ValueKey('appSearchSubmit')), findsOneWidget);

    await tester.enterText(searchField, 'Inception');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.byType(SearchPage), findsOneWidget);
  });

  testWidgets('home hero carousel can slide and open detail', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    expect(find.text('孤独摇滚！'), findsWidgets);
    expect(find.text('Inception'), findsWidgets);

    await tester.drag(find.byType(PageView).first, const Offset(-620, 0));
    await tester.pumpAndSettle();

    expect(find.text('Inception'), findsWidgets);

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();

    expect(find.text('立即播放'), findsOneWidget);
    expect(find.text('Inception'), findsWidgets);
  });

  testWidgets('home hero starts with the feed-selected subject', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(
            _FeedSelectedHeroAnimeController.new,
          ),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();

    final detail = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(detail.subject.id, _subject.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule selects today and weekday taps stay in sync', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('周期表'));
    await tester.pumpAndSettle();

    expect(find.text('周期表'), findsWidgets);
    expect(find.text('周日'), findsOneWidget);

    final todayIndex = DateTime.now().weekday % 7;
    final targetIndex = todayIndex == 1 ? 2 : 1;
    final swipeIndex = targetIndex + 1;
    expect(find.byKey(ValueKey('schedule-result-$todayIndex')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('schedule-day-$targetIndex')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(ValueKey('schedule-result-$targetIndex')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Semantics>(find.byKey(ValueKey('schedule-day-$targetIndex')))
          .properties
          .selected,
      isTrue,
    );

    await tester.drag(find.byType(TabBarView), const Offset(-720, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('schedule-result-$swipeIndex')), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(find.byKey(ValueKey('schedule-day-$swipeIndex')))
          .properties
          .selected,
      isTrue,
    );

    await tester.drag(find.text('周日'), const Offset(-720, 0));
    await tester.pumpAndSettle();
    expect(find.text('周六'), findsOneWidget);
  });

  testWidgets('schedule subjects still open their detail page', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('周期表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-day-0')));
    await tester.pumpAndSettle();

    final sundayResult = find.byKey(const ValueKey('schedule-result-0'));
    await tester.tap(
      find.descendant(of: sundayResult, matching: find.byType(PosterCard)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DetailPage), findsOneWidget);
  });

  testWidgets('category and tag tiles open result lists', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动画(2)').last);
    await tester.pumpAndSettle();

    expect(find.text('分类：动画'), findsOneWidget);
    expect(find.text('孤独摇滚！'), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TV(1)').last);
    await tester.pumpAndSettle();

    expect(find.text('标签：TV'), findsOneWidget);
  });

  testWidgets('side navigation opens metadata pages', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('番剧').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('近期热门番剧与中文资料'), findsNothing);
    _expectInternalMetadataProvidersHidden();
    expect(find.text('孤独摇滚！'), findsWidgets);
    expect(find.text('Breaking Bad'), findsNothing);
    expect(find.text('Inception'), findsNothing);

    await tester.tap(find.text('剧集').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('近期热门剧集与中文资料'), findsNothing);
    expect(find.textContaining('收录 '), findsNothing);
    expect(find.textContaining('中文资料 '), findsNothing);
    expect(find.textContaining('均可尝试规则查源'), findsNothing);
    _expectInternalMetadataProvidersHidden();
    expect(find.text('Breaking Bad'), findsWidgets);

    await tester.tap(find.text('韩剧').last);
    await tester.pumpAndSettle();
    expect(find.text('The Glory'), findsWidgets);
    expect(find.text('本地化韩剧'), findsWidgets);
    expect(find.text('Breaking Bad'), findsNothing);

    await tester.tap(find.text('英剧').last);
    await tester.pumpAndSettle();
    expect(find.text('本地化英剧'), findsWidgets);
    expect(find.text('本地化韩剧'), findsNothing);

    await tester.tap(find.text('日剧').last);
    await tester.pumpAndSettle();
    expect(find.text('本地化日剧'), findsWidgets);
    expect(find.text('本地化英剧'), findsNothing);

    await tester.tap(find.text('美剧').last);
    await tester.pumpAndSettle();
    expect(find.text('本地化美剧'), findsWidgets);
    await tester.tap(find.text('英语').last);
    await tester.pumpAndSettle();
    expect(find.text('本地化美剧'), findsWidgets);

    await tester.tap(find.text('电影').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('热门电影与开放影片'), findsNothing);
    expect(find.textContaining('可直接播放 '), findsNothing);
    _expectInternalMetadataProvidersHidden();
    expect(find.text('Inception'), findsWidgets);
    expect(find.text('剧场版测试片'), findsNothing);
    expect(find.text('公版测试短片'), findsWidgets);
    expect(find.text('本地化电影'), findsWidgets);
    expect(find.text('可播放'), findsWidgets);
    expect(find.text('规则查源'), findsNothing);
    expect(find.text('2013年'), findsOneWidget);

    await tester.tap(find.text('电影').last);
    await tester.pumpAndSettle();
    expect(find.text('本地化电影'), findsWidgets);

    await tester.tap(find.widgetWithText(FilterChip, '可播放'));
    await tester.pumpAndSettle();
    expect(find.text('公版测试短片'), findsWidgets);
    expect(find.text('Inception'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, '全部').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('科幻').last);
    await tester.pumpAndSettle();
    expect(find.text('Inception'), findsWidgets);
    expect(find.text('The Godfather'), findsNothing);
  });

  testWidgets('metadata refresh waits for the controller to be ready', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    _DelayedMetadataController.reset();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_DelayedMetadataController.new),
        ],
        child: const MaterialApp(
          home: MetadataHubPage(kind: MetadataHubKind.anime),
        ),
      ),
    );
    await tester.pump();

    expect(_DelayedMetadataController.earlyDiscoveryCalls, 0);

    _DelayedMetadataController.completeBuild();
    await tester.pumpAndSettle();

    expect(_DelayedMetadataController.earlyDiscoveryCalls, 0);
    expect(_DelayedMetadataController.refreshDiscoveryCalls, 1);
    expect(find.text('2026 测试番剧'), findsWidgets);
  });

  testWidgets('detail hides internal provider metadata', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const MaterialApp(
          home: DetailPage(subject: _playableMovieSubject),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('开放许可媒体，可直接播放'), findsWidgets);
    _expectInternalMetadataProvidersHidden();
  });

  testWidgets('detail does not write history before the player has a frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    _HistoryTrackingAnimeController.addHistoryCalls = 0;

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const DetailPage(subject: _playableMovieSubject),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('测试播放页'))),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(
            _HistoryTrackingAnimeController.new,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();

    expect(find.text('测试播放页'), findsOneWidget);
    expect(_HistoryTrackingAnimeController.addHistoryCalls, 0);
  });

  testWidgets('detail hands a prefetched verified line directly to player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    PlaySessionRequest? capturedRequest;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const DetailPage(subject: _subject),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) {
            capturedRequest = state.extra as PlaySessionRequest;
            return const Scaffold(body: Center(child: Text('测试播放页')));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(
            _PrefetchedLineAnimeController.new,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即播放'));
    await tester.pumpAndSettle();

    expect(find.text('测试播放页'), findsOneWidget);
    expect(capturedRequest?.initialLine?.id, _prefetchedLine.id);
    expect(capturedRequest?.resumePosition, const Duration(minutes: 2));
  });

  testWidgets('profile history preview expands in place', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('观看记录').first);
    await tester.pumpAndSettle();

    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('全部历史 ›'), findsOneWidget);

    await tester.tap(find.text('全部历史 ›'));
    await tester.pumpAndSettle();

    expect(find.text('收起历史'), findsOneWidget);
    expect(find.text('第7集'), findsOneWidget);
  });

  testWidgets('side history opens standalone playable history page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HistoryPage()),
        GoRoute(
          path: '/player',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('测试播放页'))),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.text('历史记录'), findsWidgets);
    expect(find.text('全部历史'), findsOneWidget);
    expect(find.text('个人中心'), findsNothing);
    expect(find.textContaining('第1集'), findsWidgets);

    await tester.tap(find.textContaining('第1集').last);
    await tester.pumpAndSettle();

    expect(find.text('测试播放页'), findsOneWidget);
  });

  testWidgets(
    'history does not open player after the account context changes',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HistoryPage()),
          GoRoute(
            path: '/player',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('不应打开的播放页'))),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(
              _StaleAfterDetailAnimeController.new,
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('第1集').last);
      await tester.pumpAndSettle();

      expect(find.text('不应打开的播放页'), findsNothing);
      expect(find.byType(HistoryPage), findsOneWidget);
    },
  );

  testWidgets('top back on root navigation falls back instead of blanking', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('个人中心'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('个人中心'), findsNothing);
  });

  testWidgets('settings navigation opens consolidated playback entries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsWidgets);
    expect(find.text('下载管理'), findsOneWidget);
    expect(find.text('播放规则'), findsNothing);
    expect(find.text('自定义仓库'), findsNothing);
    expect(find.text('外部源目录'), findsNothing);
    expect(find.text('弹幕设置'), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('在线服务'), findsOneWidget);

    await tester.ensureVisible(find.text('播放设置'));
    await tester.tap(find.text('播放设置'));
    await tester.pumpAndSettle();
    expect(find.text('播放速度'), findsOneWidget);
  });

  testWidgets('search separates M3U live channels and external BT resources', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const MaterialApp(home: SearchPage(keyword: '测试')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('影视与资料'), findsOneWidget);
    expect(find.text('直播频道'), findsOneWidget);
    expect(find.text('测试直播频道'), findsWidgets);

    await tester.drag(
      find.byType(CustomScrollView).last,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(find.text('BT / 磁力资源'), findsOneWidget);
    expect(find.text('测试字幕组资源'), findsOneWidget);

    final openButton = find.widgetWithText(FilledButton, '外部客户端打开');
    await tester.ensureVisible(openButton);
    await tester.tap(openButton);
    await tester.pumpAndSettle();
    expect(find.text('交给外部 BT 客户端？'), findsOneWidget);
    expect(find.textContaining('暴露你的公网 IP'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'rule plugin pages separate anime series and movie repositories',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      _FakeAnimeController.lastRulePlugins = const RulePluginRepository()
          .defaultState();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_FakeAnimeController.new),
          ],
          child: const AnimeApp(),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('扩展来源').first);
      await tester.pumpAndSettle();

      expect(find.text('扩展来源'), findsWidgets);
      expect(find.text('扩展播放来源'), findsOneWidget);
      expect(find.text('自动来源包'), findsOneWidget);
      expect(find.text('测试 TVBox'), findsOneWidget);
      expect(find.text('提供 2 条可执行播放规则'), findsOneWidget);
      expect(find.text('番剧规则'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ruleGroupRefresh:anime')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ruleGroupToggle:anime')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ruleGroupRefresh:series')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ruleGroupToggle:movie')),
        findsOneWidget,
      );
      final expandAnimeRules = find.byTooltip('展开番剧规则');
      expect(expandAnimeRules, findsOneWidget);
      await tester.ensureVisible(expandAnimeRules);
      await tester.tap(expandAnimeRules);
      await tester.pumpAndSettle();
      expect(find.byTooltip('收起番剧规则'), findsOneWidget);
      expect(find.text('全部启用'), findsOneWidget);
      expect(find.text('全部关闭'), findsOneWidget);
      final executableRule = find.byKey(
        const ValueKey('installedRule:kazumi:enlie'),
      );
      final webViewRule = find.byKey(
        const ValueKey('installedRule:kazumi:omofun03'),
      );
      expect(
        find.descendant(of: executableRule, matching: find.text('可执行')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: webViewRule, matching: find.text('需 WebView')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('ruleToggle:kazumi:enlie')),
            )
            .onChanged,
        isNotNull,
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('ruleToggle:kazumi:omofun03')),
            )
            .onChanged,
        isNull,
      );

      await tester.tap(find.byTooltip('添加规则'));
      await tester.pumpAndSettle();
      expect(find.text('粘贴 GitHub 仓库或 raw JSON'), findsOneWidget);
      expect(find.text('新建规则'), findsOneWidget);
      await tester.tap(find.text('从来源合集导入'));
      await tester.pumpAndSettle();

      expect(find.text('来源合集'), findsWidgets);
      expect(find.text('omofun03'), findsOneWidget);
      expect(find.text('内置番剧规则'), findsOneWidget);
      expect(find.textContaining('已内置 22 条规则目录'), findsOneWidget);
      expect(find.text('批量安装'), findsOneWidget);
      expect(find.text('自定义仓库'), findsOneWidget);
      expect(find.text('粘贴仓库地址'), findsOneWidget);

      final pasteRepositoryButton = find.widgetWithText(
        OutlinedButton,
        '粘贴仓库地址',
      );
      await tester.ensureVisible(pasteRepositoryButton);
      await tester.tap(pasteRepositoryButton);
      await tester.pumpAndSettle();
      expect(find.text('添加自定义仓库'), findsOneWidget);
      expect(find.text('扫描 / 预览'), findsOneWidget);
      expect(find.textContaining('配置字段会按原样保留'), findsOneWidget);
      expect(find.textContaining('出于安全考虑'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('扩展来源'), findsWidgets);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pumpAndSettle();

      expect(find.text('更新规则'), findsOneWidget);
      expect(find.text('删除规则'), findsOneWidget);
      expect(find.text('omofun03'), findsWidgets);

      await tester.tap(find.text('更新规则'));
      await tester.pumpAndSettle();
      expect(find.text('删除规则'), findsNothing);

      await tester.tap(find.text('打开来源合集'));
      await tester.pumpAndSettle();

      expect(find.text('来源合集'), findsWidgets);
      expect(find.text('omofun03'), findsOneWidget);
      expect(find.text('韩剧看看'), findsNothing);
      expect(find.text('电影先生'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('ruleRepositorySegment:series')),
      );
      await tester.pumpAndSettle();
      expect(find.text('韩剧看看'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ruleCard:tvbox:meijutt')),
          matching: find.text('缺执行器'),
        ),
        findsOneWidget,
      );
      expect(find.text('电影先生'), findsNothing);
      expect(find.text('omofun03'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('ruleRepositorySegment:movie')),
      );
      await tester.pumpAndSettle();
      expect(find.text('电影先生'), findsOneWidget);
      expect(find.text('电影港'), findsOneWidget);
      expect(find.text('韩剧看看'), findsNothing);
    },
    // 旧规则管理页面已从统一后端架构中移除。
    skip: true,
  );

  testWidgets('external source route opens the source catalog', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    _FakeAnimeController.lastSourceToggle = null;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AnimeApp)),
    );
    container.read(routerProvider).go('/profile/sources');
    await tester.pumpAndSettle();

    expect(find.text('播放规则插件'), findsNothing);
    expect(find.text('自动规则包'), findsNothing);
    expect(find.text('测试 TVBox'), findsOneWidget);
    expect(find.text('已登记外部资源'), findsOneWidget);
    expect(find.text('测试直播'), findsOneWidget);

    final sourceSwitch = find.byKey(const ValueKey('sourceToggle:source:m3u'));
    expect(sourceSwitch, findsOneWidget);
    expect(tester.widget<Switch>(sourceSwitch).value, isFalse);
    await tester.tap(sourceSwitch);
    await tester.pumpAndSettle();

    expect(_FakeAnimeController.lastSourceToggle, ('source:m3u', true));
    expect(tester.widget<Switch>(sourceSwitch).value, isTrue);
  }, skip: true); // 旧外部源目录已从统一后端架构中移除。

  testWidgets('playback settings rows are actionable', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放设置').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('播放速度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放速度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();

    expect(_FakeAnimeController.lastSettings.speed, 1.5);
  });

  testWidgets('recommended catalog cards can be downranked without hiding', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    _FakeAnimeController.lastNotInterested = null;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const MaterialApp(
          home: MetadataHubPage(kind: MetadataHubKind.anime),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const menuKey = ValueKey('recommendation-menu-bangumi:1');
    expect(find.byKey(menuKey), findsOneWidget);
    await tester.ensureVisible(find.byKey(menuKey));
    await tester.tap(find.byKey(menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不感兴趣'));
    await tester.pumpAndSettle();

    expect(_FakeAnimeController.lastNotInterested?.id, _subject.id);
    expect(find.byKey(menuKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all metadata hubs use responsive sort controls without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final width in const [430.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 900);
        for (final kind in MetadataHubKind.values) {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                animeControllerProvider.overrideWith(_FakeAnimeController.new),
              ],
              child: MaterialApp(home: MetadataHubPage(kind: kind)),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          expect(
            find.byKey(const ValueKey('catalog-sort-dropdown')),
            width < 760 ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const ValueKey('catalog-sort-segmented')),
            width < 760 ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets('desktop catalog sorting survives local filters', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    _FakeAnimeController.lastCatalogSort = null;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const MaterialApp(
          home: MetadataHubPage(kind: MetadataHubKind.movie),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final sortControl = find.byKey(const ValueKey('catalog-sort-segmented'));
    await tester.tap(
      find.descendant(of: sortControl, matching: find.text('高分')),
    );
    await tester.pumpAndSettle();
    expect(_FakeAnimeController.lastCatalogSort, CatalogSortMode.topRated);

    await tester.tap(find.widgetWithText(FilterChip, '科幻'));
    await tester.pumpAndSettle();

    final segmented = tester.widget<SegmentedButton<CatalogSortMode>>(
      sortControl,
    );
    expect(segmented.selected, {CatalogSortMode.topRated});
    expect(_FakeAnimeController.lastCatalogSort, CatalogSortMode.topRated);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile catalog sorting uses a dropdown', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    _FakeAnimeController.lastCatalogSort = null;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const MaterialApp(
          home: MetadataHubPage(kind: MetadataHubKind.anime),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('catalog-sort-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新').last);
    await tester.pumpAndSettle();

    expect(_FakeAnimeController.lastCatalogSort, CatalogSortMode.latest);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile metadata filters stay collapsed until requested', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_FakeAnimeController.new),
        ],
        child: const MaterialApp(
          home: MetadataHubPage(kind: MetadataHubKind.movie),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('mobileMetadataFilters')), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);

    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();

    expect(find.byType(FilterChip), findsWidgets);
    expect(find.byKey(const ValueKey('mobileFilter-年份')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakeAnimeController extends AnimeController {
  static PlaybackSettings lastSettings = const PlaybackSettings();
  static ExternalServiceSettings lastServices = const ExternalServiceSettings();
  static (String, bool)? lastSourceToggle;
  static CatalogSortMode? lastCatalogSort;
  static AnimeSubject? lastNotInterested;
  static int rotateCalls = 0;
  static RulePluginState lastRulePlugins = const RulePluginRepository()
      .defaultState();

  @override
  Future<AnimeState> build() async {
    return AnimeState(
      homeFeed: _feed,
      history: _historyEntries,
      settings: lastSettings,
      services: lastServices,
      rulePlugins: lastRulePlugins,
      sourceCatalog: _sourceCatalog,
    );
  }

  @override
  Future<void> updateSettings(PlaybackSettings settings) async {
    lastSettings = settings;
    state = AsyncData(
      (state.value ?? const AnimeState(homeFeed: _feed)).copyWith(
        settings: settings,
      ),
    );
  }

  @override
  Future<void> updateServices(ExternalServiceSettings settings) async {
    lastServices = settings;
    state = AsyncData(
      (state.value ?? const AnimeState(homeFeed: _feed)).copyWith(
        services: settings,
      ),
    );
  }

  @override
  Future<void> toggleVideoSource(String id, bool enabled) async {
    lastSourceToggle = (id, enabled);
    final current = state.value ?? const AnimeState(homeFeed: _feed);
    final toggled = current.sourceCatalog.toggleSource(id, enabled);
    final activePlaybackRuleCount = toggled.sources
        .where((source) => source.enabled)
        .fold<int>(
          0,
          (count, source) => count + toggled.playbackRuleCountFor(source.id),
        );
    state = AsyncData(
      current.copyWith(
        sourceCatalog: toggled.copyWith(
          activePlaybackRuleCount: activePlaybackRuleCount,
        ),
      ),
    );
  }

  @override
  Future<RuleImportResult> importRuleRepositoryText(String text) async {
    final importedRule = RulePlugin(
      id: 'custom:test',
      name: '用户测试规则',
      version: '1.0',
      source: RuleSourceKind.custom,
      contentType: RuleContentType.anime,
      engine: 'native',
      updatedAt: _testRuleDate,
      qualityScore: 60,
      tags: ['用户导入'],
      baseUrl: 'https://example.com',
      searchUrl: 'https://example.com/search?wd=@keyword',
      searchable: true,
      quickSearch: true,
      filterable: false,
      unsupportedReason: '测试规则不解析',
      note: '测试导入',
    );
    final current = state.value ?? const AnimeState(homeFeed: _feed);
    final nextRules = [...current.rulePlugins.customRules, importedRule];
    lastRulePlugins = current.rulePlugins.copyWith(
      installedIds: {...current.rulePlugins.installedIds, importedRule.id},
      customRules: nextRules,
      repositories: [
        RuleRepositoryRecord(
          id: 'clipboard:test',
          name: '剪贴板仓库',
          url: '',
          importedAt: _testRuleDate,
          ruleCount: 1,
        ),
      ],
    );
    state = AsyncData(current.copyWith(rulePlugins: lastRulePlugins));
    return const RuleImportResult(
      repositoryName: '剪贴板仓库',
      ruleCount: 1,
      installedCount: 1,
    );
  }

  @override
  Future<RuleImportResult> importRuleRepositoryUrl(String url) async {
    final importedRule = RulePlugin(
      id: 'custom:creamycake',
      name: 'CreamyCake 测试规则',
      version: '1.0',
      source: RuleSourceKind.custom,
      contentType: RuleContentType.anime,
      engine: 'animeko-web-selector',
      updatedAt: _testRuleDate,
      qualityScore: 80,
      tags: ['Animeko', 'CSS'],
      baseUrl: 'https://example.com',
      searchUrl: 'https://example.com/search?wd={keyword}',
      searchable: true,
      quickSearch: true,
      filterable: false,
      groupId: 'repo:test',
      priority: 0,
      animeko: const AnimekoWebSelectorConfig(
        searchUrl: 'https://example.com/search?wd={keyword}',
        subjectFormatId: 'a',
        channelFormatId: 'index-grouped',
        matchVideoUrl: r'(?<v>https?:\/\/.+\.(m3u8|mp4))',
      ),
      note: '测试 URL 导入',
    );
    final current = state.value ?? const AnimeState(homeFeed: _feed);
    lastRulePlugins = current.rulePlugins.copyWith(
      installedIds: {...current.rulePlugins.installedIds, importedRule.id},
      enabledIds: current.rulePlugins.enabledIds,
      customRules: [...current.rulePlugins.customRules, importedRule],
      repositories: [
        RuleRepositoryRecord(
          id: 'url:test',
          name: 'CreamyCake CSS',
          url: url,
          importedAt: _testRuleDate,
          ruleCount: 37,
        ),
      ],
    );
    state = AsyncData(current.copyWith(rulePlugins: lastRulePlugins));
    return const RuleImportResult(
      repositoryName: 'CreamyCake CSS',
      ruleCount: 37,
      installedCount: 37,
    );
  }

  @override
  Future<List<AnimeSubject>> categorySubjects(String name) async {
    return const [_subject];
  }

  @override
  Future<List<AnimeSubject>> tagSubjects(String name) async {
    return const [_subject];
  }

  @override
  Future<List<AnimeSubject>> search(String keyword) async {
    return const [_subject, _liveSubject];
  }

  @override
  Future<SourceAdapterBatch<TorrentResource>> searchTorrentResources(
    String keyword,
  ) async {
    return SourceAdapterBatch<TorrentResource>(
      items: [
        TorrentResource(
          id: 'torrent:test',
          sourceId: 'torrent:fixture',
          sourceName: '测试 BT 源',
          title: '测试字幕组资源',
          category: '动画',
          sizeLabel: '1.2 GB',
          seeders: 12,
          magnetUri: Uri.parse(
            'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
          ),
          infoHash: '0123456789abcdef0123456789abcdef01234567',
        ),
      ],
    );
  }

  @override
  Future<List<AnimeSubject>> discoverSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) async {
    lastCatalogSort = sort;
    return const [_subject, _seriesSubject, _movieSubject];
  }

  @override
  Future<List<AnimeSubject>> seriesSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) async {
    lastCatalogSort = sort;
    return const [
      _seriesSubject,
      _koreanSeriesSubject,
      _localizedUsSeriesSubject,
      _localizedUkSeriesSubject,
      _localizedKoreanSeriesSubject,
      _localizedJapaneseSeriesSubject,
    ];
  }

  @override
  Future<List<AnimeSubject>> movieSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) async {
    lastCatalogSort = sort;
    return const [
      _movieSubject,
      _playableMovieSubject,
      _movieDramaSubject,
      _localizedMovieSubject,
    ];
  }

  @override
  Future<void> markRecommendationNotInterested(AnimeSubject subject) async {
    lastNotInterested = subject;
  }

  @override
  void rotateRecommendations() {
    rotateCalls++;
  }

  @override
  Future<Map<int, List<AnimeSubject>>> weeklySchedule() async {
    return const {
      0: [_subject],
      1: [],
      2: [],
      3: [],
      4: [],
      5: [],
      6: [_subject],
    };
  }

  @override
  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    final episodes = [
      for (var i = 1; i <= 12; i++)
        AnimeEpisode(
          id: subject.id * 1000 + i,
          subjectId: subject.id,
          number: i,
          title: '',
          airdate: '2022-10-${(7 + i).toString().padLeft(2, '0')}',
          duration: '24:00',
          description: '',
          thumbnailUrl: null,
        ),
    ];
    return AnimeDetailBundle(
      subject: subject,
      episodes: episodes,
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }

  @override
  Future<bool> addHistory(
    AnimeSubject subject,
    AnimeEpisode? episode, {
    int? expectedAccountContextVersion,
  }) async {
    final current = state.value ?? const AnimeState(homeFeed: _feed);
    state = AsyncData(
      current.copyWith(
        history: [
          LibraryEntry(
            subject: subject,
            episode: episode,
            updatedAt: _testRuleDate,
            note: episode == null ? '打开详情' : '播放到 ${episode.displayTitle}',
          ),
          ...current.history.where((item) => item.subject.id != subject.id),
        ],
      ),
    );
    return true;
  }
}

class _PersonalizationDisabledAnimeController extends _FakeAnimeController {
  @override
  Future<AnimeState> build() async => (await super.build()).copyWith(
    homePreferences: const HomePreferences(personalizedRecommendations: false),
  );
}

class _PrefetchedLineAnimeController extends _FakeAnimeController {
  @override
  PlaybackLine? prefetchedLineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    Duration minValidity = const Duration(seconds: 60),
  }) {
    return _prefetchedLine;
  }
}

class _FeedSelectedHeroAnimeController extends _FakeAnimeController {
  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: AnimeHomeFeed(
      hero: _subject,
      recent: const [_subject],
      recommended: [
        AnimeSubject.fromJson({
          ..._movieSubject.toJson(),
          'bannerUrl': 'banner-art',
        }),
      ],
      index: const [_subject, _movieSubject],
      categories: const [],
      tags: const [],
    ),
  );
}

class _DelayedMetadataController extends AnimeController {
  static late Completer<AnimeState> _buildCompleter;
  static bool _ready = false;
  static int earlyDiscoveryCalls = 0;
  static int refreshDiscoveryCalls = 0;

  static void reset() {
    _buildCompleter = Completer<AnimeState>();
    _ready = false;
    earlyDiscoveryCalls = 0;
    refreshDiscoveryCalls = 0;
  }

  static void completeBuild() {
    _buildCompleter.complete(const AnimeState(homeFeed: _feed));
  }

  @override
  Future<AnimeState> build() async {
    final value = await _buildCompleter.future;
    _ready = true;
    return value;
  }

  @override
  Future<List<AnimeSubject>> discoverSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) async {
    if (!_ready) {
      earlyDiscoveryCalls++;
      throw StateError('controller is not ready');
    }
    if (waitForRefresh) {
      refreshDiscoveryCalls++;
      return const [_futureAnimeSubject];
    }
    return const [_subject];
  }
}

class _HistoryTrackingAnimeController extends _FakeAnimeController {
  static int addHistoryCalls = 0;

  @override
  PlaybackLine? prefetchedLineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    Duration minValidity = const Duration(seconds: 60),
  }) => null;

  @override
  Future<bool> addHistory(
    AnimeSubject subject,
    AnimeEpisode? episode, {
    int? expectedAccountContextVersion,
  }) async {
    addHistoryCalls++;
    return false;
  }
}

class _StaleAfterDetailAnimeController extends _FakeAnimeController {
  int _contextVersion = 1;

  @override
  int get accountContextVersion => _contextVersion;

  @override
  bool isAccountContextCurrent(int version) => version == _contextVersion;

  @override
  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    _contextVersion++;
    return super.detail(subject);
  }
}

final _testRuleDate = DateTime(2026, 5, 5);

const _prefetchedLine = PlaybackLine(
  id: 'prefetched-line',
  episodeId: 1001,
  providerId: 'zeluna:site:test',
  providerName: '在线服务 · test',
  title: '预取线路',
  quality: '1080P',
  format: 'hls',
  url: 'https://cdn.example/video.m3u8',
  serverVerified: true,
  available: true,
);

const _futureAnimeSubject = AnimeSubject(
  id: 2026,
  title: '2026 测试番剧',
  originalTitle: 'Future Anime',
  summary: '用于验证首启后台刷新。',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-07-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '连载中',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 12,
);

const _subject = AnimeSubject(
  id: 1,
  title: '孤独摇滚！',
  originalTitle: 'ぼっち・ざ・ろっく！',
  summary: '怕生少女加入乐队的故事。',
  coverUrl: null,
  bannerUrl: null,
  date: '2022-10-08',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '全12集',
  categories: [
    AnimeCategory(name: '动画'),
    AnimeCategory(name: '音乐'),
  ],
  tags: [AnimeTag(name: '音乐', count: 100)],
  totalEpisodes: 12,
);

const _liveSubject = AnimeSubject(
  id: 99001,
  title: '测试直播频道',
  originalTitle: '测试直播频道',
  summary: '来自测试直播源的频道。',
  coverUrl: null,
  bannerUrl: null,
  date: null,
  platform: '直播',
  language: '未知',
  region: '未知',
  status: '直播',
  categories: [AnimeCategory(name: '直播')],
  tags: [AnimeTag(name: 'M3U')],
  totalEpisodes: 1,
  source: 'm3u-channel:source:m3u:fixture',
);

const _movieSubject = AnimeSubject(
  id: 2875,
  title: 'Inception',
  originalTitle: 'Inception',
  summary: '一名盗梦者接受在他人潜意识中植入想法的任务。',
  coverUrl: null,
  bannerUrl: null,
  date: '2010-07-08',
  platform: 'Movie',
  language: 'English',
  region: 'United States',
  status: '电影',
  categories: [
    AnimeCategory(name: '电影'),
    AnimeCategory(name: 'Science fiction'),
    AnimeCategory(name: 'Action'),
  ],
  tags: [
    AnimeTag(name: 'Wikidata'),
    AnimeTag(name: 'IMDb'),
  ],
  totalEpisodes: 1,
  source: 'wikidata',
);

const _seriesSubject = AnimeSubject(
  id: 169,
  title: 'Breaking Bad',
  originalTitle: 'Breaking Bad',
  summary: '一位化学教师在绝境中走向犯罪世界。',
  coverUrl: null,
  bannerUrl: null,
  date: '2008-01-20',
  platform: 'Scripted',
  language: 'English',
  region: 'United States',
  status: 'Ended',
  categories: [
    AnimeCategory(name: 'Drama'),
    AnimeCategory(name: 'Crime'),
  ],
  tags: [AnimeTag(name: 'TVMaze')],
  totalEpisodes: 62,
  source: 'tvmaze',
);

const _koreanSeriesSubject = AnimeSubject(
  id: 57841,
  title: 'The Glory',
  originalTitle: '더 글로리',
  summary: '一名女性围绕校园暴力展开漫长复仇。',
  coverUrl: null,
  bannerUrl: null,
  date: '2022-12-30',
  platform: 'Scripted',
  language: 'Korean',
  region: 'South Korea',
  status: 'Ended',
  categories: [
    AnimeCategory(name: 'Drama'),
    AnimeCategory(name: 'Thriller'),
  ],
  tags: [AnimeTag(name: 'TVMaze')],
  totalEpisodes: 16,
  source: 'tvmaze',
);

const _localizedUsSeriesSubject = AnimeSubject(
  id: 57842,
  title: '本地化美剧',
  originalTitle: 'Localized US Series',
  summary: '地区与语言已经本地化。',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-01-01',
  platform: '剧集',
  language: '英语',
  region: '美国',
  status: '已完结',
  categories: [AnimeCategory(name: '剧情')],
  tags: [],
  totalEpisodes: 10,
  source: 'tvmaze:tt-local-us',
);

const _localizedUkSeriesSubject = AnimeSubject(
  id: 57843,
  title: '本地化英剧',
  originalTitle: 'Localized UK Series',
  summary: '地区与语言已经本地化。',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-01-01',
  platform: '剧集',
  language: '英语',
  region: '英国',
  status: '已完结',
  categories: [AnimeCategory(name: '剧情')],
  tags: [],
  totalEpisodes: 8,
  source: 'tvmaze:tt-local-uk',
);

const _localizedKoreanSeriesSubject = AnimeSubject(
  id: 57844,
  title: '本地化韩剧',
  originalTitle: 'Localized Korean Series',
  summary: '地区与语言已经本地化。',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-01-01',
  platform: '剧集',
  language: '韩语',
  region: '韩国',
  status: '已完结',
  categories: [AnimeCategory(name: '剧情')],
  tags: [],
  totalEpisodes: 16,
  source: 'tvmaze:tt-local-kr',
);

const _localizedJapaneseSeriesSubject = AnimeSubject(
  id: 57845,
  title: '本地化日剧',
  originalTitle: 'Localized Japanese Series',
  summary: '地区与语言已经本地化。',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-01-01',
  platform: '剧集',
  language: '日语',
  region: '日本',
  status: '已完结',
  categories: [AnimeCategory(name: '剧情')],
  tags: [],
  totalEpisodes: 10,
  source: 'tvmaze:tt-local-jp',
);

const _movieDramaSubject = AnimeSubject(
  id: 47703,
  title: 'The Godfather',
  originalTitle: 'The Godfather',
  summary: '科里昂家族权力交接中的犯罪史诗。',
  coverUrl: null,
  bannerUrl: null,
  date: '1972-03-14',
  platform: 'Movie',
  language: 'English',
  region: 'United States',
  status: '电影',
  categories: [
    AnimeCategory(name: '电影'),
    AnimeCategory(name: 'Crime'),
    AnimeCategory(name: 'Drama'),
  ],
  tags: [
    AnimeTag(name: 'Wikidata'),
    AnimeTag(name: 'IMDb'),
  ],
  totalEpisodes: 1,
  source: 'wikidata',
);

const _localizedMovieSubject = AnimeSubject(
  id: 47704,
  title: '本地化电影',
  originalTitle: 'Localized Movie',
  summary: '平台、语言和地区已经本地化。',
  coverUrl: null,
  bannerUrl: null,
  date: '2024-01-01',
  platform: '电影',
  language: '英语',
  region: '美国',
  status: '电影',
  categories: [AnimeCategory(name: '电影')],
  tags: [],
  totalEpisodes: 1,
  source: 'custom-metadata',
);

const _playableMovieSubject = AnimeSubject(
  id: 70001,
  title: '公版测试短片',
  originalTitle: 'Public Domain Test Short',
  summary: '来自 Wikimedia Commons 的开放许可媒体，可直接播放。',
  coverUrl: null,
  bannerUrl: null,
  date: '2025-05-01',
  platform: 'Movie',
  language: 'English',
  region: 'Internet Archive',
  status: 'Internet Archive',
  categories: [AnimeCategory(name: '纪录片')],
  tags: [AnimeTag(name: 'Internet Archive')],
  totalEpisodes: 1,
  source: 'archive:public-domain-test-short',
);

const _feed = AnimeHomeFeed(
  hero: _subject,
  recent: [_subject],
  recommended: [_subject, _movieSubject],
  index: [_subject, _movieSubject],
  categories: [
    AnimeCategory(name: '动画', count: 2),
    AnimeCategory(name: '剧场版', count: 1),
  ],
  tags: [
    AnimeTag(name: 'TV', count: 1),
    AnimeTag(name: '剧场版', count: 1),
  ],
);

final _historyEntries = [
  for (var i = 1; i <= 7; i++)
    LibraryEntry(
      subject: _subject.copyWith(summary: '测试历史 $i'),
      episode: AnimeEpisode(
        id: 1000 + i,
        subjectId: _subject.id,
        number: i,
        title: '',
        airdate: '2022-10-${(7 + i).toString().padLeft(2, '0')}',
        duration: '24:00',
        description: '',
        thumbnailUrl: null,
      ),
      updatedAt: DateTime(2026, 5, 5, 12, i),
      note: '测试历史 $i',
      positionSeconds: i == 1 ? 120 : 0,
      durationSeconds: i == 1 ? 1440 : 0,
    ),
];

const _sourceCatalog = SourceCatalogState(
  version: 1,
  totalSources: 2,
  playbackRuleCounts: {'source:tvbox': 2, 'source:m3u': 0},
  availablePlaybackRuleCount: 2,
  activePlaybackRuleCount: 2,
  sources: [
    VideoSource(
      id: 'source:tvbox',
      name: '测试 TVBox',
      kind: VideoSourceKind.tvBox,
      importUrl: 'https://example.com/tvbox.json',
      baseUrl: 'https://example.com/tvbox.json',
      tags: ['TVBox', '动漫'],
      supportsSearch: true,
      usesNativePlayer: true,
      enabled: true,
      health: 'unknown',
      message: 'TVBox 配置，2 个可解析静态站点',
    ),
    VideoSource(
      id: 'source:m3u',
      name: '测试直播',
      kind: VideoSourceKind.liveM3u,
      importUrl: 'https://example.com/live.m3u',
      baseUrl: 'https://example.com/live.m3u',
      tags: ['直播', 'M3U'],
      usesNativePlayer: true,
      enabled: false,
      health: 'unknown',
      message: 'M3U 直播源，12 个频道',
    ),
  ],
);
