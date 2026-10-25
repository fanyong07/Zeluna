import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/catalog/catalog_controller.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:anime/src/shared_ui/app_chrome.dart';
import 'package:anime/src/shared_ui/poster_card.dart';
import 'package:anime/src/sources/external_source_adapters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monochrome themes have pure backgrounds and contrasting controls', () {
    for (final dark in [true, false]) {
      final theme = dark ? AnimeTheme.dark() : AnimeTheme.light();
      final scheme = theme.colorScheme;
      expect(theme.scaffoldBackgroundColor, dark ? Colors.black : Colors.white);
      expect(scheme.primary, dark ? Colors.white : Colors.black);
      expect(scheme.onPrimary, dark ? Colors.black : Colors.white);
      for (final color in [
        scheme.primary,
        scheme.secondary,
        scheme.tertiary,
        scheme.surface,
        scheme.surfaceContainer,
        scheme.onSurface,
        scheme.onSurfaceVariant,
        scheme.outline,
        scheme.error,
      ]) {
        expect(color.r, color.g);
        expect(color.g, color.b);
      }
      const selected = {WidgetState.selected};
      expect(theme.switchTheme.thumbColor!.resolve(selected), scheme.onPrimary);
      expect(theme.switchTheme.trackColor!.resolve(selected), scheme.primary);
      expect(
        theme.checkboxTheme.checkColor!.resolve(selected),
        scheme.onPrimary,
      );
    }
  });

  for (final dark in [true, false]) {
    for (final size in [
      const Size(320, 740),
      const Size(430, 932),
      const Size(834, 640),
      const Size(1440, 900),
    ]) {
      testWidgets(
        'home $size dark=$dark keeps controls separate from content',
        (tester) async {
          await _mount(tester, const CatalogPage(), size, dark: dark);
          expect(tester.takeException(), isNull);
          final controls = find.byKey(const ValueKey('homeCarouselControls'));
          final details = find.widgetWithText(AccentButton, '查看详情').first;
          expect(
            tester.getTopLeft(controls).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(details).dy),
          );
          expect(find.text('本季热门与近期更新'), findsNothing);
          // No duplicate sidebar repeating the same recommendations.
          expect(find.byType(CompactSubjectRow), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('large phone text does not overflow the home hero', (
    tester,
  ) async {
    await _mount(tester, const CatalogPage(), const Size(320, 740), scale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'catalogue exposes posters on first screen and keeps optional filters reachable',
    (tester) async {
      await _mount(
        tester,
        const MetadataHubPage(kind: MetadataHubKind.anime),
        const Size(1440, 900),
      );
      expect(
        tester.getTopLeft(find.byType(PosterCard).first).dy,
        lessThan(460),
      );
      expect(find.text('日语'), findsNothing);
      await tester.tap(find.text('更多筛选'));
      await tester.pumpAndSettle();
      expect(find.text('日语'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, '日语'));
      await tester.pumpAndSettle();
      expect(find.byType(PosterCard), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 740),
    const Size(430, 932),
    const Size(1440, 900),
  ]) {
    testWidgets('detail $size has one description and reachable actions', (
      tester,
    ) async {
      await _mount(tester, const DetailPage(subject: _subject), size);
      expect(find.text(_subject.summary), findsOneWidget);
      expect(find.text('大家都在看'), findsNothing);
      expect(find.text('下载').hitTestable(), findsWidgets);
      expect(
        find.widgetWithText(FilledButton, '立即播放').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('detail large phone text preserves its action layout', (
    tester,
  ) async {
    await _mount(
      tester,
      const DetailPage(subject: _subject),
      const Size(320, 740),
      scale: 1.5,
    );
    final download = find.widgetWithText(OutlinedButton, '下载');
    expect(tester.getSize(download).height, greaterThanOrEqualTo(44));
    expect(
      find.ancestor(of: download, matching: find.byType(FittedBox)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('library $size uses the common navigation shell', (
      tester,
    ) async {
      await _mount(
        tester,
        LibraryPage(
          title: '全部收藏',
          emptyTitle: '暂无收藏',
          emptyMessage: '先收藏一部作品',
          entriesOf: (s) => s.favorites,
        ),
        size,
      );
      expect(find.byType(AppChrome), findsOneWidget);
      expect(find.text('2 部作品'), findsOneWidget);
      expect(
        find.text('返回'),
        findsNothing,
        reason: 'no extra floating return button',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'search query can change in place without losing the results view',
    (tester) async {
      await _mount(
        tester,
        const SearchPage(keyword: '初始片名'),
        const Size(1440, 900),
      );
      await tester.enterText(find.byType(TextField), '修改后的片名');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(_ReviewController.lastSearch, '修改后的片名');
      expect(find.byType(SearchPage), findsOneWidget);
      expect(find.byType(PosterCard), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget child,
  Size size, {
  bool dark = true,
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [animeControllerProvider.overrideWith(_ReviewController.new)],
      child: MaterialApp(
        theme: dark ? AnimeTheme.dark() : AnimeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

class _ReviewController extends AnimeController {
  static String lastSearch = '';
  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: _feed,
    favorites: [
      LibraryEntry(subject: _subject, updatedAt: DateTime(2026, 10, 4)),
      LibraryEntry(subject: _second, updatedAt: DateTime(2026, 10, 4)),
    ],
  );
  @override
  Future<List<AnimeSubject>> discoverSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) async => [_subject, _second];
  @override
  Future<CatalogPageResult> queryCatalog(
    CatalogQuery query, {
    String? cursor,
  }) async => CatalogPageResult(
    subjects: [_subject, _second].where(query.matches).toList(),
  );
  @override
  Future<AnimeDetailBundle> detail(AnimeSubject subject) async =>
      AnimeDetailBundle(
        subject: subject,
        episodes: [
          AnimeEpisode(
            id: 1,
            subjectId: subject.id,
            number: 1,
            title: '冒险开始',
            airdate: null,
            duration: '24:00',
            description: '',
          ),
        ],
        characters: const [],
        staff: const [],
        recommendations: const [],
      );
  @override
  Future<List<AnimeSubject>> search(String keyword) async {
    lastSearch = keyword;
    return [_subject];
  }

  @override
  Future<SourceAdapterBatch<TorrentResource>> searchTorrentResources(
    String keyword,
  ) async => const SourceAdapterBatch(items: []);
}

const _subject = AnimeSubject(
  id: 1,
  title: '葬送的芙莉莲',
  originalTitle: 'Frieren',
  summary: '只展示一次的作品简介。',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-09-29',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '已完结',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 28,
);
const _second = AnimeSubject(
  id: 2,
  title: '有一个很长标题的作品用于布局验证',
  originalTitle: '',
  summary: '第二部作品。',
  coverUrl: null,
  bannerUrl: null,
  date: '2024-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '已完结',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 12,
);
const _feed = AnimeHomeFeed(
  hero: _subject,
  recent: [_subject, _second],
  recommended: [_subject, _second],
  index: [_subject, _second],
  categories: [],
  tags: [],
);
