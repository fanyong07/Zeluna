import 'dart:io';

import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/app/desktop_window.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:anime/src/player/ui/playback_line_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Real platform rendering of the production route widgets. The records below
/// are deterministic UI fixtures, not upstream playback or latency evidence.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native platform presents flat colored route inventory', (
    tester,
  ) async {
    await initializeDesktopWindow();
    final lines = List<PlaybackLine>.generate(77, (index) {
      return PlaybackLine(
        id: 'presentation-$index',
        episodeId: 1,
        providerId: index == 1 ? 'crawler.animeko' : 'crawler.anich',
        providerName: index == 1 ? 'xifan-dongman' : 'hb-$index',
        sourceName: index == 1 ? '稀饭动漫' : 'hb-$index',
        title: '第1集 · 官方简中',
        quality: '1080P',
        format: 'HLS',
        url: 'https://media.example/fixture/$index/index.m3u8?token=ui-only',
        available: index != 76,
        clientVerified: index != 76,
        diagnosticStatus: index == 76
            ? PlaybackDiscoveryStatus.routeUnavailable
            : PlaybackDiscoveryStatus.serverVerified,
        latency: Duration(
          milliseconds: index == 0
              ? 126
              : index == 1
              ? 860
              : 1680,
        ),
        sizeBytes: 956 * 1024 * 1024,
        sizeEstimated: true,
        videoWidth: 1920,
        videoHeight: 1080,
      );
    });
    var selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AnimeTheme.dark(),
        home: Scaffold(
          body: SafeArea(
            child: PlaybackSourcePanel(
              selected: lines.first,
              lines: lines,
              failedLineIds: const {},
              scanning: false,
              completedRules: 1,
              totalRules: 1,
              onSelected: (_) => selections++,
              onPickLocal: () async {},
              onOpenNetwork: (_, _) async {},
              onSearch: () async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackLineTile), findsNWidgets(77));
    expect(find.text('hb-0'), findsOneWidget);
    expect(find.textContaining('Animeko'), findsNothing);
    expect(find.textContaining('Kazumi'), findsNothing);
    expect(find.textContaining('AniCh'), findsNothing);
    final latency = tester.widget<Text>(
      find.byKey(const ValueKey('line-latency-presentation-0')),
    );
    final size = tester.widget<Text>(
      find.byKey(const ValueKey('line-size-presentation-0')),
    );
    final resolution = tester.widget<Text>(
      find.byKey(const ValueKey('line-resolution-presentation-0')),
    );
    expect(latency.style?.color, isNot(size.style?.color));
    expect(size.style?.color, isNot(resolution.style?.color));
    await tester.tap(
      find.byKey(const ValueKey('view-line-url-presentation-0')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(selections, 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    Scrollable.of(
      tester.element(find.byKey(const ValueKey('presentation-76'))),
    ).position.jumpTo(
      Scrollable.of(
        tester.element(find.byKey(const ValueKey('presentation-76'))),
      ).position.maxScrollExtent,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('presentation-76')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        theme: AnimeTheme.dark(),
        home: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                const Text('线路展示验证 · 示例数据'),
                PortraitPlaybackLineList(
                  lines: lines,
                  selectedLineId: lines.first.id,
                  failedLineIds: const {},
                  onSelected: (_) => selections++,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('hb-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugPrint(
      'ROUTE_PRESENTATION_VERIFIED platform=${Platform.operatingSystem} routes=77 colors=distinct labels=real url=complete fixtures=true',
    );
    const holdSeconds = int.fromEnvironment('ZELUNA_NATIVE_QA_HOLD_SECONDS');
    if (holdSeconds > 0) {
      debugPrint('ADAPTER_QA_VISIBLE {"provider":"presentation-fixture"}');
      await tester.pump(Duration(seconds: holdSeconds));
    }
    binding.reportData = <String, Object?>{
      'platform': Platform.operatingSystem,
      'route_count': 77,
      'production_widgets': true,
      'upstream_playback_evidence': false,
      'metadata_fixture': true,
      'colors_distinct': true,
      'complete_url_dialog': true,
      'failed_route_retained': true,
    };
  });
}
