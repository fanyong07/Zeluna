import 'dart:convert';

import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/catalog/catalog_controller.dart';
import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/zeluna_backend_catalog_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/subject_content_type.dart';
import 'package:anime/src/shared_ui/app_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('switching home sub-tabs keeps 首页 active in bottom navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_HomeSubTabController.new),
        ],
        child: MaterialApp(theme: AnimeTheme.dark(), home: const CatalogPage()),
      ),
    );
    await tester.pumpAndSettle();

    ChromeDestination activeDestination() {
      final chrome = tester.widget<AppChrome>(find.byType(AppChrome));
      return chrome.active;
    }

    expect(activeDestination(), ChromeDestination.home);

    for (final tabLabel in const ['最近更新', '推荐', '索引', '分类', '标签']) {
      await tester.tap(find.text(tabLabel).first);
      await tester.pumpAndSettle();
      expect(
        activeDestination(),
        ChromeDestination.home,
        reason:
            'Home sub-tab "$tabLabel" must not switch bottom nav away from 首页',
      );
    }
  });

  test(
    'ZelunaBackendCatalogRepository filters noise and populates both categories and rich tags',
    () async {
      final client = MockClient((request) async {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([
              {
                'stable_id': 'bangumi:876',
                'title': 'CLANNAD 〜AFTER STORY〜',
                'original_title': 'CLANNAD 〜AFTER STORY〜',
                'cover_url': 'https://img.example/clannad.jpg',
                'banner_url': 'https://img.example/clannad-banner.jpg',
                'language': 'ja',
                'region': '日本',
                'genres': [
                  'CLANNAD 〜AFTER STORY〜',
                  '京阿尼',
                  '催泪',
                  '治愈',
                  'TV',
                  '2008年10月',
                  '2008',
                  '~After-Story~',
                  '游戏改',
                ],
                'rating': 9.1,
              },
              {
                'stable_id': 'bangumi:1428',
                'title': '钢之炼金术师',
                'cover_url': 'https://img.example/fma.jpg',
                'language': 'ja',
                'region': '日本',
                'genres': [
                  '钢之炼金术师',
                  'BONES',
                  '热血',
                  '漫画改',
                  'TV',
                  '2009年4月',
                  '战斗',
                  'FA',
                ],
                'rating': 8.9,
              },
            ]),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(client.close);

      final repo = ZelunaBackendCatalogRepository(
        baseUrl: 'https://backend.example',
        client: client,
      );
      final anime = await repo.home(SubjectContentType.anime);

      expect(anime, hasLength(2));
      expect(
        anime.first.categories.map((c) => c.name),
        containsAll(['催泪', '治愈']),
      );
      expect(
        anime.first.categories.map((c) => c.name),
        isNot(contains('2008年10月')),
      );
      expect(
        anime.first.tags.map((t) => t.name),
        containsAll(['京阿尼', '催泪', '治愈', 'TV', '游戏改', '日漫']),
      );
      expect(
        anime.first.tags.map((t) => t.name),
        isNot(contains('~After-Story~')),
      );
      expect(
        anime.last.tags.map((t) => t.name),
        containsAll(['BONES', '热血', '漫画改', '战斗', 'TV', '日漫']),
      );
      expect(anime.last.tags.map((t) => t.name), isNot(contains('FA')));
    },
  );

  test(
    'CatalogController aggregates real counts and covers for categories and tags across all media types',
    () async {
      final storage = _MemoryCatalogStorage();
      final animeList = [
        _subject(
          1,
          '葬送的芙莉莲',
          source: 'bangumi',
          cover: 'https://img.example/frieren.jpg',
          categories: const ['奇幻', '冒险'],
          tags: const ['奇幻', '冒险', '漫画改', 'TV', '日漫', 'MADHOUSE'],
        ),
        _subject(
          2,
          '迷宫饭',
          source: 'bangumi',
          cover: 'https://img.example/dungeon.jpg',
          categories: const ['奇幻', '美食'],
          tags: const ['奇幻', '美食', '漫画改', 'TV', '日漫', 'TRIGGER'],
        ),
      ];
      final seriesList = [
        _subject(
          3,
          '指环王：力量之戒',
          source: 'tmdb:series:3',
          cover: 'https://img.example/lotr.jpg',
          categories: const ['奇幻', '剧情'],
          tags: const ['奇幻', '剧情', '美剧'],
        ),
      ];
      final movieList = [
        _subject(
          4,
          '流浪地球2',
          source: 'tmdb:movie:4',
          cover: 'https://img.example/earth.jpg',
          categories: const ['科幻', '剧情'],
          tags: const ['科幻', '剧情', '华语电影'],
        ),
      ];

      final controller = CatalogController(
        storage: storage,
        publishSnapshot: (_) {},
        search: (_, _) async => const [],
        loadHome: (type, _) async => switch (type) {
          SubjectContentType.anime => animeList,
          SubjectContentType.series => seriesList,
          SubjectContentType.movie => movieList,
        },
        loadDetail: (subject, _) async => AnimeDetailBundle(
          subject: subject,
          episodes: const [],
          characters: const [],
          staff: const [],
          recommendations: const [],
        ),
        enrichDetail: (bundle, _) async => bundle,
        prefetchPlayback: (_, _) {},
        fallbackSeries: const [],
        fallbackMovies: const [],
      );
      addTearDown(controller.dispose);

      await controller.loadForAccount(
        accountId: 'acc',
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        fallbackHomeFeed: _fallbackFeed,
      );
      await controller.refreshHome();

      final feed = controller.snapshot.homeFeed;
      final fantasy = feed.categories.singleWhere((c) => c.name == '奇幻');
      expect(fantasy.count, 3);
      expect(fantasy.imageUrl, isNotNull);
      expect(fantasy.imageUrl, isNotEmpty);

      final drama = feed.categories.singleWhere((c) => c.name == '剧情');
      expect(drama.count, 2);
      expect(drama.imageUrl, isNotNull);
      expect(
        drama.imageUrl,
        isNot(fantasy.imageUrl),
        reason:
            'Distinct categories should pick distinct covers when available',
      );

      expect(feed.tags.length, greaterThanOrEqualTo(8));
      final mangaAdapted = feed.tags.singleWhere((t) => t.name == '漫画改');
      expect(mangaAdapted.count, 2);
      expect(mangaAdapted.imageUrl, isNotEmpty);

      final fantasySubjects = await controller.categorySubjects('奇幻');
      expect(fantasySubjects, hasLength(3));
      final dramaTagSubjects = await controller.tagSubjects('剧情');
      expect(dramaTagSubjects, hasLength(2));
    },
  );
}

AnimeSubject _subject(
  int id,
  String title, {
  required String source,
  required String? cover,
  required List<String> categories,
  required List<String> tags,
}) => AnimeSubject(
  id: id,
  title: title,
  originalTitle: title,
  summary: '简介',
  coverUrl: cover,
  bannerUrl: cover,
  date: '2025-01-01',
  platform: source.startsWith('tmdb:movie') ? '电影' : 'TV',
  language: 'ja',
  region: '日本',
  status: '已完结',
  categories: [for (final c in categories) AnimeCategory(name: c)],
  tags: [for (final t in tags) AnimeTag(name: t)],
  totalEpisodes: 12,
  ratingScore: 8.8,
  source: source,
);

final _fallbackFeed = AnimeHomeFeed(
  hero: _subject(
    999,
    '默认作品',
    source: 'bangumi',
    cover: null,
    categories: const ['动画'],
    tags: const ['TV'],
  ),
  recent: const [],
  recommended: const [],
  index: const [],
  categories: const [AnimeCategory(name: '动画', count: 1)],
  tags: const [AnimeTag(name: 'TV', count: 1)],
);

class _MemoryCatalogStorage implements CatalogStorage {
  final Map<String, Object?> _values = {};

  @override
  Object? get(String key) => _values[key];

  @override
  Future<void> put(String key, Object? value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class _HomeSubTabController extends AnimeController {
  @override
  Future<AnimeState> build() async => AnimeState(homeFeed: _fallbackFeed);

  @override
  Future<List<AnimeSubject>> categorySubjects(String name) async => const [];

  @override
  Future<List<AnimeSubject>> tagSubjects(String name) async => const [];
}
