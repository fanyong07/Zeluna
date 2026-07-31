import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('playback source panel modes perform real actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var localPickCount = 0;
    var searchCount = 0;
    String? openedUrl;
    Map<String, String>? openedHeaders;
    const line = PlaybackLine(
      id: 'line-1',
      episodeId: 1,
      providerId: 'provider-1',
      providerName: '风车',
      title: '正片',
      quality: '1080P',
      format: 'HLS',
      url: 'https://cdn.example.com/video/index.m3u8',
      available: true,
      latency: Duration(milliseconds: 36),
      videoWidth: 1920,
      videoHeight: 1080,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: PlaybackSourcePanel(
            selected: line,
            lines: const [line],
            failedLineIds: const {},
            scanning: false,
            completedRules: 5,
            totalRules: 5,
            onSelected: (_) {},
            onPickLocal: () async => localPickCount++,
            onOpenNetwork: (url, headers) async {
              openedUrl = url;
              openedHeaders = headers;
            },
            onSearch: () async => searchCount++,
          ),
        ),
      ),
    );

    expect(find.text('风车'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('36ms'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playbackSourceMode:本地')));
    await tester.pumpAndSettle();
    expect(find.text('选择视频文件'), findsOneWidget);
    await tester.tap(find.text('选择视频文件'));
    await tester.pumpAndSettle();
    expect(localPickCount, 1);

    await tester.tap(find.byKey(const ValueKey('playbackSourceMode:直链')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('lineNetworkUrl')),
      'https://media.example.com/live.m3u8',
    );
    await tester.enterText(
      find.byKey(const ValueKey('lineNetworkHeaders')),
      'Referer: https://media.example.com/',
    );
    await tester.tap(find.byKey(const ValueKey('lineNetworkPlay')));
    await tester.pumpAndSettle();
    expect(openedUrl, 'https://media.example.com/live.m3u8');
    expect(openedHeaders, {'Referer': 'https://media.example.com/'});

    await tester.tap(find.byKey(const ValueKey('playbackSourceMode:搜索')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索全部线路'));
    await tester.pumpAndSettle();
    expect(searchCount, 1);
    expect(find.text('风车'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
