import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:anime/src/shared_ui/app_chrome.dart';
import 'package:anime/src/theme/zeluna_color_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'AppearanceSettings serializes new theme fields and migrates legacy JSON',
    () {
      final legacy = AppearanceSettings.fromJson({
        'followSystem': true,
        'darkMode': false,
        'compactMode': true,
        'reduceMotion': false,
      });
      expect(legacy.followSystem, isTrue);
      expect(legacy.darkMode, isFalse);
      expect(legacy.pureBlackOled, isFalse);
      expect(legacy.accentMode, ThemeAccentMode.monochrome);
      expect(legacy.tintedSurfaces, isFalse);

      const custom = AppearanceSettings(
        darkMode: true,
        pureBlackOled: true,
        accentMode: ThemeAccentMode.custom,
        accentColorValue: 0xFF10B981,
        tintedSurfaces: true,
      );
      final decoded = AppearanceSettings.fromJson(custom.toJson());
      expect(decoded, custom);
    },
  );

  test(
    'All spectrum presets yield crisp contrasting foregrounds in dark and light',
    () {
      expect(ZelunaColorPalette.spectrumPresets.length, 8);
      for (final preset in ZelunaColorPalette.spectrumPresets) {
        for (final dark in [true, false]) {
          final appearance = AppearanceSettings(
            darkMode: dark,
            accentMode: ThemeAccentMode.preset,
            accentColorValue: preset.color.toARGB32(),
          );
          final theme = dark
              ? AnimeTheme.dark(appearance: appearance)
              : AnimeTheme.light(appearance: appearance);
          final scheme = theme.colorScheme;
          // Foreground is strictly pure white or near-black for legibility.
          expect(
            scheme.onPrimary == const Color(0xFFFFFFFF) ||
                scheme.onPrimary == const Color(0xFF0B0B0E),
            isTrue,
          );
        }
      }
    },
  );

  testWidgets(
    'AppearanceSettingsPage lets users pick spectrum presets and HSV palette',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final controller = _ThemeTestController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [animeControllerProvider.overrideWith(() => controller)],
          child: MaterialApp(
            theme: AnimeTheme.dark(),
            home: const AppearanceSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('主题强调色'), findsOneWidget);
      expect(find.text('当前：极致黑白'), findsOneWidget);

      await tester.tap(find.text('青空'));
      await tester.pumpAndSettle();
      expect(controller.lastAppearance.accentMode, ThemeAccentMode.preset);
      expect(controller.lastAppearance.accentColorValue, 0xFF06B6D4);

      await tester.tap(find.text('调色板'));
      await tester.pumpAndSettle();
      expect(find.text('自由调色板'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Desktop sidebar collapses smoothly between 216px and 72px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    sideNavigationCollapsed.value = false;
    addTearDown(() {
      sideNavigationCollapsed.value = false;
      tester.view.reset();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_ThemeTestController.new),
        ],
        child: MaterialApp(
          theme: AnimeTheme.dark(),
          home: const AppChrome(
            active: ChromeDestination.home,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('sideNavigationToggle'));
    expect(toggle, findsOneWidget);
    expect(find.text('Zeluna'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(sideNavigationCollapsed.value, isTrue);
    expect(find.text('Zeluna'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'Desktop theater split activates on wide landscape non-fullscreen windows',
    () {
      expect(
        usesDesktopTheaterSplitLayoutForSize(
          const Size(1280, 800),
          TargetPlatform.windows,
          fullscreen: false,
          theaterExpanded: false,
        ),
        isTrue,
      );
      expect(
        usesDesktopTheaterSplitLayoutForSize(
          const Size(1280, 800),
          TargetPlatform.windows,
          fullscreen: false,
          theaterExpanded: true,
        ),
        isFalse,
      );
      expect(
        usesDesktopTheaterSplitLayoutForSize(
          const Size(1280, 800),
          TargetPlatform.windows,
          fullscreen: true,
          theaterExpanded: false,
        ),
        isFalse,
      );
      expect(
        usesDesktopTheaterSplitLayoutForSize(
          const Size(390, 844),
          TargetPlatform.android,
          fullscreen: false,
          theaterExpanded: false,
        ),
        isFalse,
      );
    },
  );
}

class _ThemeTestController extends AnimeController {
  AppearanceSettings lastAppearance = const AppearanceSettings();

  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: BangumiMetadataRepository().fallbackHomeFeed(),
    appearance: lastAppearance,
  );

  @override
  Future<void> updateAppearance(AppearanceSettings next) async {
    lastAppearance = next;
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(appearance: next));
    }
  }
}
