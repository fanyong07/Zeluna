import 'dart:async';
import 'dart:io';

import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'runtime bundle keeps active branding and omits unused originals',
    (tester) async {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest.listAssets();
      expect(assets, contains('assets/brand/anime_logo_app_icon.png'));
      for (final original in [
        'assets/brand/anime_logo_app_icon_192.png',
        'assets/brand/anime_logo_app_icon_512.png',
        'assets/brand/anime_logo_mark.png',
        'assets/brand/anime_logo_mark_512.png',
        'assets/brand/splash/zeluna_android_splash.png',
      ]) {
        expect(assets, isNot(contains(original)));
        expect(
          File(original).existsSync(),
          isTrue,
          reason: 'preserve design originals',
        );
      }
      expect(assets, contains('assets/fonts/NotoSansSC-400.ttf'));
      expect(assets, contains('assets/fonts/NotoSansSC-600.ttf'));
      expect(assets, contains('assets/fonts/NotoSerifSC-SemiBold.ttf'));
    },
  );

  testWidgets('Zeluna is the visible Flutter application brand', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_BrandTestController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();
    await tester.pump();

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.title, 'Zeluna');
    expect(find.text('Zeluna'), findsOneWidget);
    expect(find.text('ANIME'), findsNothing);
  });

  test('platform display names and Windows binary use Zeluna', () {
    const visibleBrandFiles = {
      'android/app/src/main/AndroidManifest.xml': 'android:label="Zeluna"',
      'web/index.html': '<title>Zeluna</title>',
      'web/manifest.json': '"short_name": "Zeluna"',
      'ios/Runner/Info.plist': '<string>Zeluna</string>',
      'macos/Runner/Configs/AppInfo.xcconfig': 'PRODUCT_NAME = Zeluna',
      'windows/runner/main.cpp': 'window.Create(L"Zeluna"',
      'windows/runner/Runner.rc': '"ProductName", "Zeluna"',
      'linux/runner/my_application.cc':
          'gtk_window_set_title(window, "Zeluna")',
    };
    for (final entry in visibleBrandFiles.entries) {
      expect(
        File(entry.key).readAsStringSync(),
        contains(entry.value),
        reason: '${entry.key} should expose the Zeluna brand',
      );
    }

    expect(
      File('lib/src/profile/profile_page.dart').readAsStringSync(),
      contains("info?.appName ?? 'Zeluna'"),
    );

    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains(RegExp(r'^name: anime$', multiLine: true)),
    );
    expect(
      File('android/app/build.gradle.kts').readAsStringSync(),
      contains('applicationId = "app.anime.anime"'),
    );
    expect(
      File('windows/CMakeLists.txt').readAsStringSync(),
      allOf(
        contains('project(Zeluna LANGUAGES CXX)'),
        contains('set(BINARY_NAME "Zeluna")'),
      ),
    );
    expect(
      File('windows/runner/Runner.rc').readAsStringSync(),
      contains('"OriginalFilename", "Zeluna.exe"'),
    );
    expect(
      File('linux/CMakeLists.txt').readAsStringSync(),
      contains('set(APPLICATION_ID "app.anime.anime")'),
    );
  });

  testWidgets('startup loading state is plain without artwork', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_LoadingBrandTestController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('zeluna-startup-background')),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
    final startup = tester.widget<Scaffold>(
      find.descendant(
        of: find.byType(ZelunaStartupView),
        matching: find.byType(Scaffold),
      ),
    );
    expect(startup.backgroundColor, const Color(0xFF14181D));
  });
}

class _BrandTestController extends AnimeController {
  @override
  Future<AnimeState> build() async =>
      AnimeState(homeFeed: BangumiMetadataRepository().fallbackHomeFeed());
}

class _LoadingBrandTestController extends AnimeController {
  final Completer<AnimeState> _state = Completer<AnimeState>();

  @override
  Future<AnimeState> build() => _state.future;
}
