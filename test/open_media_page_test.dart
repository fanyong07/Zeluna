import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/open_media_page.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';

void main() {
  testWidgets('picked Windows video reaches the player as local media', (
    tester,
  ) async {
    const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
      call,
    ) async {
      expect(call.method, 'custom');
      return [
        {
          'path': r'C:\Videos\episode #1 %.mp4',
          'name': 'episode #1 %.mp4',
          'size': 1024,
        },
      ];
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        null,
      );
    });
    PlaySessionRequest? request;
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const OpenMediaPage()),
        GoRoute(
          path: '/player',
          builder: (context, state) {
            request = state.extra! as PlaySessionRequest;
            return const Scaffold(body: Text('Player opened'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeControllerProvider.overrideWith(_OpenMediaController.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择本地文件'));
    await tester.pumpAndSettle();

    expect(request, isNotNull);
    final line = request!.initialLine!;
    expect(line.url, 'file:///C:/Videos/episode%20%231%20%25.mp4');
    expect(playbackLineCanStartImmediately(line), isTrue);
    var networkRequests = 0;
    final client = MockClient((_) async {
      networkRequests++;
      throw StateError('A picked local file must not need an HTTP probe');
    });
    addTearDown(client.close);
    final verified = await RulePlaybackResolver(
      client: client,
    ).verifyPlaybackLine(line: line);
    expect(verified.available, isTrue);
    expect(verified.url, line.url);
    expect(networkRequests, 0);
    expect(tester.takeException(), isNull);
  });
}

class _OpenMediaController extends AnimeController {
  @override
  Future<AnimeState> build() async =>
      AnimeState(homeFeed: BangumiMetadataRepository().fallbackHomeFeed());
}
