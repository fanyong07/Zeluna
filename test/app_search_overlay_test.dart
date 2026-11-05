import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/catalog/catalog_page.dart';
import 'package:anime/src/catalog/catalog_controller.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/search_history_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/shared_ui/app_chrome.dart';
import 'package:anime/src/sources/external_source_adapters.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (platform, kind, width, index) in [
    (TargetPlatform.windows, PointerDeviceKind.mouse, 1440.0, 0),
    (TargetPlatform.windows, PointerDeviceKind.mouse, 826.0, 5),
    (TargetPlatform.android, PointerDeviceKind.touch, 390.0, 0),
    (TargetPlatform.android, PointerDeviceKind.mouse, 390.0, 5),
  ]) {
    testWidgets(
      'suggestion survives pointer down and opens exactly once: $platform $kind $width row $index',
      (tester) async {
        final picked = <AnimeSubject>[];
        final searches = <String>[];
        final history = _MemoryHistory();
        await _mount(
          tester,
          AppChrome(
            active: ChromeDestination.home,
            onSearch: searches.add,
            onOpenSuggestion: picked.add,
            child: const SizedBox.expand(),
          ),
          width: width,
          history: history,
        );
        await _suggest(tester);
        final row = _suggestion(_subjects[index].title);
        expect(row.hitTestable(), findsOneWidget);
        final gesture = await tester.startGesture(
          tester.getCenter(row),
          kind: kind,
        );
        // Real desktop down/up events can be delivered in different frames.
        // A single tester.tap() misses a focus-driven overlay disposal here.
        await tester.pump(const Duration(milliseconds: 80));
        expect(_field(tester).focusNode!.hasFocus, isTrue);
        expect(row, findsOneWidget);
        expect(picked, isEmpty);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(picked, [_subjects[index]]);
        expect(searches, isEmpty);
        expect(history.added, [_subjects[index].title]);
        expect(find.byIcon(Icons.north_east_rounded), findsNothing);
        expect(_field(tester).focusNode!.hasFocus, isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets('suggestion without a detail callback still submits its title', (
    tester,
  ) async {
    final searches = <String>[];
    await _mount(
      tester,
      AppChrome(
        active: ChromeDestination.home,
        onSearch: searches.add,
        child: const SizedBox.expand(),
      ),
    );
    await _suggest(tester);
    await _mouseClick(tester, _suggestion(_subjects[1].title));
    expect(searches, [_subjects[1].title]);
    expect(find.byIcon(Icons.north_east_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history pick survives mouse down and submits exactly once', (
    tester,
  ) async {
    final searches = <String>[];
    final history = _MemoryHistory(['白箱', '命运石之门']);
    await _mount(
      tester,
      AppChrome(
        active: ChromeDestination.home,
        onSearch: searches.add,
        child: const SizedBox.expand(),
      ),
      history: history,
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    await _mouseClick(tester, find.text('白箱'));
    expect(searches, ['白箱']);
    expect(history.added, ['白箱']);
    expect(find.text('搜索历史'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history delete stays inside the field group without submitting',
    (tester) async {
      final searches = <String>[];
      final history = _MemoryHistory(['白箱', '命运石之门']);
      await _mount(
        tester,
        AppChrome(
          active: ChromeDestination.home,
          onSearch: searches.add,
          child: const SizedBox.expand(),
        ),
        history: history,
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await _mouseClick(tester, find.byTooltip('删除').first);
      expect(searches, isEmpty);
      expect(history.removed, ['白箱']);
      expect(find.text('白箱'), findsNothing);
      expect(find.text('命运石之门'), findsOneWidget);
      expect(_field(tester).focusNode!.hasFocus, isTrue);
      await _mouseClick(tester, find.byTooltip('删除'));
      expect(find.text('搜索历史'), findsNothing);
      expect(_field(tester).focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a real outside click closes suggestions without opening a title',
    (tester) async {
      final picked = <AnimeSubject>[];
      await _mount(
        tester,
        AppChrome(
          active: ChromeDestination.home,
          onSearch: (_) {},
          onOpenSuggestion: picked.add,
          child: const ColoredBox(
            key: ValueKey('search-outside'),
            color: Colors.black,
            child: SizedBox.expand(),
          ),
        ),
      );
      await _suggest(tester);
      await _mouseClick(tester, find.byKey(const ValueKey('search-outside')));
      expect(_field(tester).focusNode!.hasFocus, isFalse);
      expect(find.byIcon(Icons.north_east_rounded), findsNothing);
      expect(picked, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keyboard submit still trims and submits the query once', (
    tester,
  ) async {
    final searches = <String>[];
    final history = _MemoryHistory();
    await _mount(
      tester,
      AppChrome(
        active: ChromeDestination.home,
        onSearch: searches.add,
        child: const SizedBox.expand(),
      ),
      history: history,
    );
    await tester.enterText(find.byType(TextField), '  白箱  ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(searches, ['白箱']);
    expect(history.added, ['白箱']);
    expect(_field(tester).focusNode!.hasFocus, isFalse);
    expect(find.byIcon(Icons.north_east_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search arrow submits a focused query on a real mouse click', (
    tester,
  ) async {
    final searches = <String>[];
    final history = _MemoryHistory();
    await _mount(
      tester,
      AppChrome(
        active: ChromeDestination.home,
        onSearch: searches.add,
        child: const SizedBox.expand(),
      ),
      history: history,
    );
    await _suggest(tester);
    await _mouseClick(tester, find.byKey(const ValueKey('appSearchSubmit')));
    expect(searches, ['S']);
    expect(history.added, ['S']);
    expect(_field(tester).focusNode!.hasFocus, isFalse);
    expect(find.byIcon(Icons.north_east_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (label, page) in <(String, Widget)>[
    ('home', const CatalogPage()),
    ('catalog', const MetadataHubPage(kind: MetadataHubKind.anime)),
    ('search results', const SearchPage(keyword: 'old keyword')),
  ]) {
    testWidgets('$label suggestion opens the exact detail and back returns', (
      tester,
    ) async {
      final controller = _SearchController();
      final observer = _PushObserver();
      final history = _MemoryHistory();
      await _mount(
        tester,
        page,
        width: 826,
        controller: controller,
        observer: observer,
        history: history,
      );
      await _suggest(tester);
      final searchCalls = List<String>.of(controller.searches);
      await _mouseClick(tester, _suggestion('白箱'));
      expect(find.byType(DetailPage), findsOneWidget);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).subject,
        _subjects[1],
      );
      expect(controller.details, [_subjects[1]]);
      expect(
        controller.searches,
        searchCalls,
        reason: 'Picking a subject opens detail, not a second keyword search.',
      );
      expect(observer.pushes, 2, reason: 'Root plus exactly one detail route.');
      expect(history.added, ['白箱']);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsNothing);
      expect(find.byType(page.runtimeType), findsOneWidget);
      expect(find.byIcon(Icons.north_east_rounded), findsNothing);
      expect(_field(tester).focusNode!.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  double width = 1440,
  _MemoryHistory? history,
  _SearchController? controller,
  _PushObserver? observer,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final searchController = controller ?? _SearchController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeControllerProvider.overrideWith(() => searchController),
        searchHistoryStoreProvider.overrideWithValue(
          history ?? _MemoryHistory(),
        ),
      ],
      child: MaterialApp(
        theme: AnimeTheme.dark(),
        navigatorObservers: [?observer],
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));

Finder _suggestion(String title) => find.descendant(
  of: find.ancestor(
    of: find.byIcon(Icons.north_east_rounded),
    matching: find.byType(InkWell),
  ),
  matching: find.text(title),
);

Future<void> _suggest(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'S');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  expect(find.byIcon(Icons.north_east_rounded), findsNWidgets(6));
}

Future<void> _mouseClick(WidgetTester tester, Finder target) async {
  expect(target.hitTestable(), findsOneWidget);
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 80));
  await gesture.up();
  await tester.pumpAndSettle();
}

class _MemoryHistory extends SearchHistoryStore {
  _MemoryHistory([this.terms = const []]);
  List<String> terms;
  final added = <String>[];
  final removed = <String>[];

  @override
  Future<List<String>> load(String accountId) async => List.of(terms);

  @override
  Future<List<String>> add(String accountId, String term) async {
    added.add(term);
    terms = [term, ...terms.where((value) => value != term)];
    return terms;
  }

  @override
  Future<List<String>> remove(String accountId, String term) async {
    removed.add(term);
    terms = terms.where((value) => value != term).toList();
    return terms;
  }
}

class _PushObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

class _SearchController extends AnimeController {
  final searches = <String>[];
  final details = <AnimeSubject>[];

  @override
  Future<AnimeState> build() async => const AnimeState(homeFeed: _feed);

  @override
  Future<List<AnimeSubject>> search(String keyword) async {
    searches.add(keyword);
    return _subjects;
  }

  @override
  Future<List<AnimeSubject>> discoverSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) async => _subjects;

  @override
  Future<AnimeDetailBundle> detail(AnimeSubject subject) async {
    details.add(subject);
    return AnimeDetailBundle(
      subject: subject,
      episodes: const [],
      characters: const [],
      staff: const [],
      recommendations: const [],
    );
  }

  @override
  Future<SourceAdapterBatch<TorrentResource>> searchTorrentResources(
    String keyword,
  ) async => const SourceAdapterBatch(items: []);
}

final _subjects = List<AnimeSubject>.unmodifiable([
  for (final (index, title) in [
    '命运石之门',
    '白箱',
    '间谍过家家',
    '宋飞正传',
    '神探夏洛克',
    '邪恶力量',
  ].indexed)
    AnimeSubject(
      id: index + 1,
      title: title,
      originalTitle: 'S$index',
      summary: 'Search suggestion regression fixture.',
      coverUrl: null,
      bannerUrl: null,
      date: '2024-01-01',
      platform: 'TV',
      language: '日语',
      region: '日本',
      status: '已完结',
      categories: const [AnimeCategory(name: '动画')],
      tags: const [],
      totalEpisodes: 12,
    ),
]);
const _feed = AnimeHomeFeed(
  hero: _homeSubject,
  recent: [_homeSubject],
  recommended: [_homeSubject],
  index: [_homeSubject],
  categories: [],
  tags: [],
);
const _homeSubject = AnimeSubject(
  id: 99,
  title: 'Home fixture',
  originalTitle: '',
  summary: '',
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
