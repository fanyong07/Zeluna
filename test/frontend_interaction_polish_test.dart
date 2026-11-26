import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/catalog/catalog_controller.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/search_history_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/shared_ui/app_chrome.dart';
import 'package:anime/src/shared_ui/app_interactions.dart';
import 'package:anime/src/shared_ui/poster_card.dart';
import 'package:anime/src/theme/accent_color_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ZelunaScrollBehavior allows mouse dragging horizontal lists', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const ZelunaScrollBehavior(),
        home: Scaffold(
          body: SizedBox(
            height: 120,
            child: ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              itemCount: 20,
              itemBuilder: (_, index) =>
                  SizedBox(width: 160, child: Text('Item $index')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
    final gesture = await tester.startGesture(
      const Offset(400, 60),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-220, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(100));
  });

  testWidgets(
    'HorizontalScrollStrip shows desktop hover arrow and scrolls on click',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(900, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AnimeTheme.dark(),
          scrollBehavior: const ZelunaScrollBehavior(),
          home: Scaffold(
            body: SizedBox(
              height: 120,
              child: HorizontalScrollStrip(
                controller: controller,
                builder: (context, scrollController) => ListView.builder(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: 16,
                  itemBuilder: (_, index) =>
                      SizedBox(width: 180, child: Text('Card $index')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('向右滚动'), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(200, 60));
      await tester.pumpAndSettle();

      expect(find.byTooltip('向右滚动'), findsOneWidget);
      await tester.tap(find.byTooltip('向右滚动'));
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(150));
      expect(find.byTooltip('向左滚动'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'StatefulShellRoute preserves Home scroll offset across tab switches and scrolls to top on reselect',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final fakeController = _InteractionFakeController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(() => fakeController),
          ],
          child: const AnimeApp(),
        ),
      );
      await tester.pumpAndSettle();

      final homeScrollable = find
          .descendant(
            of: find.byType(CustomScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      final scrollState = tester.state<ScrollableState>(homeScrollable);
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -450),
      );
      await tester.pumpAndSettle();
      final savedOffset = scrollState.position.pixels;
      expect(savedOffset, greaterThan(150));

      // Switch to Anime tab and back to Home.
      await tester.tap(find.text('番剧').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();

      expect(scrollState.position.pixels, closeTo(savedOffset, 1.0));

      // Re-tap active Home tab to smoothly scroll back to top.
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();

      expect(scrollState.position.pixels, closeTo(0.0, 1.0));
    },
  );

  testWidgets('Home pull-to-refresh triggers refreshHome on controller', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final fakeController = _InteractionFakeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [animeControllerProvider.overrideWith(() => fakeController)],
        child: const AnimeApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(fakeController.refreshHomeCalls, 0);
    await tester.fling(
      find.byType(CustomScrollView).first,
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    expect(fakeController.refreshHomeCalls, greaterThanOrEqualTo(1));
  });

  test(
    'isInsidePlayerVideoGestureZone scales proportionally for portrait video',
    () {
      // Portrait ~220px video leaves a generous central gesture zone.
      expect(isInsidePlayerVideoGestureZone(110, 220), isTrue);
      expect(isInsidePlayerVideoGestureZone(60, 220), isTrue);
      expect(isInsidePlayerVideoGestureZone(150, 220), isTrue);
      expect(isInsidePlayerVideoGestureZone(10, 220), isFalse);
      expect(isInsidePlayerVideoGestureZone(210, 220), isFalse);

      // Full-size 720px landscape preserves 72px top and 132px bottom guard bands.
      expect(isInsidePlayerVideoGestureZone(71, 720), isFalse);
      expect(isInsidePlayerVideoGestureZone(72, 720), isTrue);
      expect(isInsidePlayerVideoGestureZone(588, 720), isTrue);
      expect(isInsidePlayerVideoGestureZone(589, 720), isFalse);
    },
  );

  testWidgets(
    'portrait mobile horizontal drag works at 220px height and commits seek once on release',
    (tester) async {
      tester.view.physicalSize = const Size(390, 220);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final seekCalls = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerGestureSurface(
              volume: 100,
              mobileGesturesEnabled: true,
              position: const Duration(minutes: 4),
              duration: const Duration(minutes: 10),
              onSeek: (pos) async => seekCalls.add(pos),
              onVolumeChanged: (_) {},
              onTap: () {},
              onDoubleTapLeft: () async {},
              onDoubleTapCenter: () async {},
              onDoubleTapRight: () async {},
              onLongPressStart: () {},
              onLongPressEnd: () {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(160, 110));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();

      // While dragging, only preview HUD updates; no seek storm is fired.
      expect(seekCalls, isEmpty);
      expect(find.textContaining('/'), findsWidgets);

      await gesture.up();
      await tester.pump();

      // Exactly one seek commit happens when the finger lifts.
      expect(seekCalls, hasLength(1));
      expect(seekCalls.single, greaterThan(const Duration(minutes: 4)));
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'desktop PlayerGestureSurface maps click to play/pause, double-click to fullscreen, and wheel to volume',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var desktopClicks = 0;
      var desktopDoubleClicks = 0;
      var mobileTaps = 0;
      final volumeUpdates = <double>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerGestureSurface(
              volume: 100,
              mobileGesturesEnabled: false,
              onDesktopClick: () async => desktopClicks++,
              onDesktopDoubleClick: () async => desktopDoubleClicks++,
              onVolumeChanged: volumeUpdates.add,
              onTap: () => mobileTaps++,
              onDoubleTapLeft: () async {},
              onDoubleTapCenter: () async {},
              onDoubleTapRight: () async {},
              onLongPressStart: () {},
              onLongPressEnd: () {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pump();

      final surface = find.byKey(const ValueKey('playerGestureSurface'));
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 350));
      expect(desktopClicks, 1);
      expect(desktopDoubleClicks, 0);
      expect(mobileTaps, 0);

      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 350));
      expect(desktopDoubleClicks, 1);

      // Mouse wheel up increases volume by 5 and reveals HUD.
      tester.binding.handlePointerEvent(
        const PointerScrollEvent(
          position: Offset(480, 270),
          scrollDelta: Offset(0, -120),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
      expect(volumeUpdates, [105.0]);
      expect(find.textContaining('音量'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets('PosterCard provides press-down scale and foreground ink layer', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AnimeTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 260,
              child: PosterCard(subject: _subjects.first, onTap: () => taps++),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('posterCardInk')), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PosterCard)),
    );
    await tester.pump();
    final pressedScale = tester.widget<AnimatedScale>(
      find.descendant(
        of: find.byType(PosterCard),
        matching: find.byType(AnimatedScale),
      ),
    );
    expect(pressedScale.scale, closeTo(0.97, 0.001));

    await gesture.up();
    await tester.pumpAndSettle();
    final releasedScale = tester.widget<AnimatedScale>(
      find.descendant(
        of: find.byType(PosterCard),
        matching: find.byType(AnimatedScale),
      ),
    );
    expect(releasedScale.scale, closeTo(1.0, 0.001));
    expect(taps, 1);
  });

  testWidgets(
    'ZelunaAccentColorPicker swatches expose click cursors and button semantics',
    (tester) async {
      AppearanceSettings? changed;
      await tester.pumpWidget(
        MaterialApp(
          theme: AnimeTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ZelunaAccentColorPicker(
                settings: const AppearanceSettings(),
                onChanged: (next) => changed = next,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final clickRegions = tester
          .widgetList<MouseRegion>(find.byType(MouseRegion))
          .where((region) => region.cursor == SystemMouseCursors.click);
      expect(clickRegions.length, greaterThanOrEqualTo(9));

      await tester.tap(find.text('青空'));
      await tester.pumpAndSettle();
      expect(changed, isNotNull);
    },
  );

  testWidgets(
    'Desktop search shortcuts focus search with slash and Ctrl+K and unfocus with Escape',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(
              _InteractionFakeController.new,
            ),
            searchHistoryStoreProvider.overrideWithValue(_EmptyHistoryStore()),
          ],
          child: MaterialApp(
            theme: AnimeTheme.dark(),
            home: AppChrome(
              active: ChromeDestination.home,
              onSearch: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      TextField field() => tester.widget<TextField>(find.byType(TextField));
      expect(field().focusNode!.hasFocus, isFalse);

      // Press '/' to focus search.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(field().focusNode!.hasFocus, isTrue);

      // Press Escape to dismiss focus.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field().focusNode!.hasFocus, isFalse);

      // Press Ctrl+K to focus search again.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(field().focusNode!.hasFocus, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _EmptyHistoryStore extends SearchHistoryStore {
  @override
  Future<List<String>> load(String accountId) async => const [];
}

class _InteractionFakeController extends AnimeController {
  int refreshHomeCalls = 0;

  @override
  Future<AnimeState> build() async => AnimeState(homeFeed: _feed);

  @override
  Future<void> refreshHome() async {
    refreshHomeCalls++;
  }

  @override
  Future<List<AnimeSubject>> discoverSubjects({
    bool waitForRefresh = false,
    CatalogSortMode sort = CatalogSortMode.recommended,
  }) async => _subjects;
}

final _subjects = List<AnimeSubject>.generate(
  18,
  (index) => AnimeSubject(
    id: index + 1,
    title: '测试作品 ${index + 1}',
    originalTitle: 'Test Subject ${index + 1}',
    summary: '交互回归测试条目。',
    coverUrl: null,
    bannerUrl: null,
    date: '2026-01-01',
    platform: 'TV',
    language: '日语',
    region: '日本',
    status: '连载中',
    categories: const [AnimeCategory(name: '动画')],
    tags: const [],
    totalEpisodes: 12,
  ),
);

final _feed = AnimeHomeFeed(
  hero: _subjects.first,
  recent: _subjects,
  recommended: _subjects,
  index: _subjects,
  categories: const [],
  tags: const [],
);
