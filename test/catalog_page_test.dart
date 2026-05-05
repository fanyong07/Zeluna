import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

    expect(find.text('立即观看'), findsOneWidget);
    expect(find.text('Inception'), findsWidgets);
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

    expect(find.text('周期表'), findsWidgets);
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

    await tester.tap(find.text('番剧').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('来自 Bangumi / AniList 的番剧元数据'), findsOneWidget);
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

    await tester.tap(find.byTooltip('我的'));
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

    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(find.text('个人中心'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('今日推荐'), findsOneWidget);
    expect(find.text('个人中心'), findsNothing);
  });

  testWidgets('settings navigation opens settings hub with resource entries', (
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
    expect(find.text('规则管理'), findsOneWidget);
    expect(find.text('视频源'), findsWidgets);
    expect(find.text('弹幕设置'), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);

    await tester.ensureVisible(find.text('播放设置'));
    await tester.tap(find.text('播放设置'));
    await tester.pumpAndSettle();
    expect(find.text('播放速度'), findsOneWidget);
  });

  testWidgets(
    'rule plugin pages separate anime series and movie repositories',
    (tester) async {
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
      await tester.tap(find.text('规则管理').first);
      await tester.pumpAndSettle();

      expect(find.text('规则管理'), findsWidgets);
      expect(find.text('播放规则插件'), findsOneWidget);
      expect(find.text('番剧规则'), findsOneWidget);

      await tester.tap(find.byTooltip('添加规则'));
      await tester.pumpAndSettle();
      expect(find.text('导入仓库 URL'), findsOneWidget);
      expect(find.text('新建规则'), findsOneWidget);
      await tester.tap(find.text('从规则仓库导入'));
      await tester.pumpAndSettle();

      expect(find.text('规则仓库'), findsWidgets);
      expect(find.text('omofun03'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('规则管理'), findsWidgets);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pumpAndSettle();

      expect(find.text('更新规则'), findsOneWidget);
      expect(find.text('删除规则'), findsOneWidget);
      expect(find.text('omofun03'), findsWidgets);

      await tester.tap(find.text('更新规则'));
      await tester.pumpAndSettle();
      expect(find.text('删除规则'), findsNothing);

      await tester.tap(find.text('打开规则仓库'));
      await tester.pumpAndSettle();

      expect(find.text('规则仓库'), findsWidgets);
      expect(find.text('omofun03'), findsOneWidget);
      expect(find.text('韩剧看看'), findsNothing);
      expect(find.text('电影先生'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('ruleRepositoryRail:series')));
      await tester.pumpAndSettle();
      expect(find.text('韩剧看看'), findsOneWidget);
      expect(find.text('电影先生'), findsNothing);
      expect(find.text('omofun03'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('ruleRepositoryRail:movie')));
      await tester.pumpAndSettle();
      expect(find.text('电影先生'), findsOneWidget);
      expect(find.text('电影港'), findsOneWidget);
      expect(find.text('韩剧看看'), findsNothing);
    },
  );

  testWidgets('source management page lists catalog and saves toggles', (
    tester,
  ) async {
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

    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频源').first);
    await tester.pumpAndSettle();

    expect(find.text('视频源管理'), findsWidgets);
    expect(find.text('已导入视频源'), findsOneWidget);
    expect(find.text('测试 TVBox'), findsOneWidget);
    expect(find.text('测试直播'), findsOneWidget);
    expect(find.text('未检测'), findsWidgets);

    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(2));
    await tester.tap(switches.first);
    await tester.pumpAndSettle();

    expect(_FakeAnimeController.lastSourceToggle, ('source:tvbox', false));
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
    await tester.ensureVisible(find.text('播放速度'));
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
  static (String, bool)? lastSourceToggle;
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
    state = AsyncData(
      current.copyWith(
        sourceCatalog: current.sourceCatalog.toggleSource(id, enabled),
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
  Future<void> addHistory(AnimeSubject subject, AnimeEpisode? episode) async {
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
  }
}

final _testRuleDate = DateTime(2026, 5, 5);

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
    ),
];

const _sourceCatalog = SourceCatalogState(
  version: 1,
  totalSources: 2,
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
