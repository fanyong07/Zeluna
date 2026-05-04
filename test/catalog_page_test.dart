import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(find.text('今日推荐'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('画廊'), findsNothing);
    expect(find.text('孤独摇滚！'), findsWidgets);
  });

  testWidgets('schedule button opens weekly schedule page', (tester) async {
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

    expect(find.text('周期表'), findsOneWidget);
    expect(find.text('周日'), findsOneWidget);
    await tester.drag(find.text('周日'), const Offset(-720, 0));
    await tester.pumpAndSettle();
    expect(find.text('周六'), findsOneWidget);
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

    await tester.tap(find.text('发现').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('来自最近更新、推荐和索引的综合元数据'), findsOneWidget);
    expect(find.text('孤独摇滚！'), findsWidgets);

    await tester.tap(find.text('剧集').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('按 TV / WEB / OVA / ONA'), findsOneWidget);
    expect(find.text('孤独摇滚！'), findsWidgets);

    await tester.tap(find.text('电影').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('按剧场版 / Movie / 电影标签筛选'), findsOneWidget);
    expect(find.text('剧场版测试片'), findsWidgets);
  });

  testWidgets('profile menu pages are reachable', (tester) async {
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

    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('观看记录').first);
    await tester.pumpAndSettle();

    expect(find.text('还没有观看记录'), findsOneWidget);
  });

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

    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放速度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();

    expect(_FakeAnimeController.lastSettings.speed, 1.5);

    if (!kReleaseMode) {
      await tester.scrollUntilVisible(
        find.text('影视资料源'),
        360,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('影视资料源'));
      await tester.pumpAndSettle();

      expect(find.text('影视资料源：TVMaze'), findsOneWidget);
      expect(find.text('启用影视资料源'), findsOneWidget);
    }
  });
}

class _FakeAnimeController extends AnimeController {
  static PlaybackSettings lastSettings = const PlaybackSettings();
  static ExternalServiceSettings lastServices = const ExternalServiceSettings();

  @override
  Future<AnimeState> build() async {
    return AnimeState(
      homeFeed: _feed,
      settings: lastSettings,
      services: lastServices,
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
  Future<List<AnimeSubject>> categorySubjects(String name) async {
    return const [_subject];
  }

  @override
  Future<List<AnimeSubject>> tagSubjects(String name) async {
    return const [_subject];
  }

  @override
  Future<List<AnimeSubject>> discoverSubjects() async {
    return const [_subject, _movieSubject];
  }

  @override
  Future<List<AnimeSubject>> seriesSubjects() async {
    return const [_subject];
  }

  @override
  Future<List<AnimeSubject>> movieSubjects() async {
    return const [_movieSubject];
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
}

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

const _movieSubject = AnimeSubject(
  id: 2,
  title: '剧场版测试片',
  originalTitle: 'Test Movie',
  summary: '用于测试电影元数据入口。',
  coverUrl: null,
  bannerUrl: null,
  date: '2024-03-01',
  platform: 'Movie',
  language: '日语',
  region: '日本',
  status: '剧场版',
  categories: [
    AnimeCategory(name: '动画'),
    AnimeCategory(name: '剧场版'),
  ],
  tags: [AnimeTag(name: '剧场版', count: 80)],
  totalEpisodes: 1,
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
