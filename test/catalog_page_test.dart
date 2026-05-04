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
    expect(find.textContaining('接入 TVMaze 影视剧元数据'), findsOneWidget);
    expect(find.text('Breaking Bad'), findsWidgets);

    await tester.tap(find.text('韩剧').last);
    await tester.pumpAndSettle();
    expect(find.text('The Glory'), findsWidgets);
    expect(find.text('Breaking Bad'), findsNothing);

    await tester.tap(find.text('电影').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('接入 Wikidata 电影元数据'), findsOneWidget);
    expect(find.text('Inception'), findsWidgets);
    expect(find.text('剧场版测试片'), findsNothing);

    await tester.tap(find.text('科幻').last);
    await tester.pumpAndSettle();
    expect(find.text('Inception'), findsWidgets);
    expect(find.text('The Godfather'), findsNothing);
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
    return const [_subject, _seriesSubject, _movieSubject];
  }

  @override
  Future<List<AnimeSubject>> seriesSubjects() async {
    return const [_seriesSubject, _koreanSeriesSubject];
  }

  @override
  Future<List<AnimeSubject>> movieSubjects() async {
    return const [_movieSubject, _movieDramaSubject];
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
