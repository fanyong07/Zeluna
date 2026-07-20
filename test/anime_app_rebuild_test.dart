import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unrelated anime state does not rebuild MaterialApp', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_RebuildController.new),
        ],
        child: const AnimeApp(),
      ),
    );
    await tester.pump();

    final materialApp = find.byType(MaterialApp);
    expect(materialApp, findsOneWidget);
    final beforeUnrelatedUpdate = tester.widget<MaterialApp>(materialApp);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AnimeApp)),
    );
    final controller =
        container.read(animeControllerProvider.notifier) as _RebuildController;

    controller.publishPlaybackChange();
    await tester.pump();

    final afterUnrelatedUpdate = tester.widget<MaterialApp>(materialApp);
    expect(identical(afterUnrelatedUpdate, beforeUnrelatedUpdate), isTrue);

    controller.publishAppearanceChange();
    await tester.pump();

    final afterAppearanceUpdate = tester.widget<MaterialApp>(materialApp);
    expect(identical(afterAppearanceUpdate, afterUnrelatedUpdate), isFalse);
  });
}

class _RebuildController extends AnimeController {
  @override
  Future<AnimeState> build() async =>
      AnimeState(homeFeed: BangumiMetadataRepository().fallbackHomeFeed());

  void publishPlaybackChange() {
    final current = state.value!;
    state = AsyncData(
      current.copyWith(settings: current.settings.copyWith(speed: 1.25)),
    );
  }

  void publishAppearanceChange() {
    final current = state.value!;
    state = AsyncData(
      current.copyWith(
        appearance: current.appearance.copyWith(compactMode: true),
      ),
    );
  }
}
