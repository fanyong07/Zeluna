import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/shared_ui/app_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop navigation keeps settings on the same baseline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_ChromeTestController.new),
        ],
        child: const MaterialApp(
          home: AppChrome(
            active: ChromeDestination.home,
            showSearch: false,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();

    final homeIcon = find.byIcon(Icons.home_rounded);
    final settingsIcon = find.byIcon(Icons.settings_outlined);
    expect(homeIcon, findsOneWidget);
    expect(settingsIcon, findsOneWidget);
    expect(
      tester.getCenter(settingsIcon).dx,
      closeTo(tester.getCenter(homeIcon).dx, 0.01),
    );
    expect(
      tester.getTopLeft(find.text('设置')).dx,
      closeTo(tester.getTopLeft(find.text('首页')).dx, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('extra-wide chrome keeps a single profile entry', (tester) async {
    tester.view.physicalSize = const Size(2048, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_ChromeTestController.new),
        ],
        child: const MaterialApp(
          home: AppChrome(
            active: ChromeDestination.home,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('我的'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.person_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact home action shares the top row with theme toggle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_ChromeTestController.new),
        ],
        child: const MaterialApp(
          home: AppChrome(
            active: ChromeDestination.home,
            compactAction: AppIconButton(
              icon: Icons.calendar_month_outlined,
              tooltip: '周期表',
            ),
            trailing: SizedBox(key: ValueKey<String>('desktop-home-toolbar')),
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();

    final schedule = find.byIcon(Icons.calendar_month_outlined);
    final theme = find.byIcon(Icons.dark_mode_rounded);
    expect(schedule, findsOneWidget);
    expect(theme, findsOneWidget);
    expect(
      tester.getCenter(schedule).dy,
      closeTo(tester.getCenter(theme).dy, 0.01),
    );
    expect(
      find.byKey(const ValueKey<String>('desktop-home-toolbar')),
      findsNothing,
    );
  });

  testWidgets('compact chrome can remove the standalone refresh row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_ChromeTestController.new),
        ],
        child: const MaterialApp(
          home: AppChrome(
            active: ChromeDestination.anime,
            showCompactTrailing: false,
            trailing: Icon(Icons.refresh_rounded),
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _ChromeTestController extends AnimeController {
  @override
  Future<AnimeState> build() async =>
      AnimeState(homeFeed: BangumiMetadataRepository().fallbackHomeFeed());
}
