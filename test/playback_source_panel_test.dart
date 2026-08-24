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

  testWidgets(
    'source panel shows truthful summary and folds background states',
    (tester) async {
      tester.view.physicalSize = const Size(430, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const verified = PlaybackLine(
        id: 'verified',
        episodeId: 1,
        providerId: 'aggregate.maccms',
        providerName: '在线服务 · iKun',
        sourceName: 'iKun',
        title: '线路1',
        quality: '1080P',
        format: 'HLS',
        url: 'https://cdn.example.com/verified.m3u8',
        diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
        queried: true,
        matched: true,
        available: true,
      );
      const lines = [
        verified,
        PlaybackLine(
          id: 'route',
          episodeId: 1,
          providerId: 'crawler.route',
          providerName: '在线服务 · 线路失败源',
          sourceName: '线路失败源',
          title: '线路失败源',
          quality: '',
          format: '',
          diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
          queried: true,
          matched: true,
          available: false,
          message: '已匹配作品，但当前线路验证失败',
        ),
        PlaybackLine(
          id: 'miss',
          episodeId: 1,
          providerId: 'crawler.miss',
          providerName: '在线服务 · 无结果源',
          sourceName: '无结果源',
          title: '无结果源',
          quality: '',
          format: '',
          diagnosticStatus: PlaybackDiscoveryStatus.searchMiss,
          queried: true,
          matched: false,
          available: false,
          message: '当前站点没有匹配到这部作品',
        ),
        PlaybackLine(
          id: 'pending',
          episodeId: 1,
          providerId: 'crawler.pending',
          providerName: '在线服务 · 未查询源',
          sourceName: '未查询源',
          title: '未查询源',
          quality: '',
          format: '',
          diagnosticStatus: PlaybackDiscoveryStatus.notQueried,
          queried: false,
          matched: false,
          available: false,
          message: '本轮未查询该来源',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: PlaybackSourcePanel(
              selected: verified,
              lines: lines,
              failedLineIds: const {},
              scanning: false,
              completedRules: 1,
              totalRules: 1,
              onSelected: (_) {},
              onPickLocal: () async {},
              onOpenNetwork: (_, _) async {},
              onSearch: () async {},
            ),
          ),
        ),
      );

      expect(find.text('4 来源 · 3 已查 · 2 匹配 · 1 可播'), findsOneWidget);
      expect(find.text('在线服务 · iKun'), findsOneWidget);
      expect(find.text('在线服务 · 线路失败源'), findsOneWidget);
      expect(find.text('其它来源（2）'), findsOneWidget);
      expect(find.text('在线服务 · 无结果源'), findsNothing);
      expect(find.text('在线服务 · 未查询源'), findsNothing);

      await tester.tap(find.text('其它来源（2）'));
      await tester.pumpAndSettle();

      expect(find.text('在线服务 · 无结果源'), findsOneWidget);
      expect(find.text('在线服务 · 未查询源'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source panel renders one card and keeps the real source state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const verified = PlaybackLine(
      id: 'verified-modu',
      episodeId: 1,
      providerId: 'aggregate.maccms',
      providerName: '在线服务 · 魔都2',
      sourceName: '魔都2',
      title: '第1集',
      quality: '1080P',
      format: 'HLS',
      url: 'https://media.example/modu/index.m3u8',
      diagnosticStatus: PlaybackDiscoveryStatus.serverVerified,
      queried: true,
      matched: true,
      serverVerified: true,
      available: true,
    );
    const placeholder = PlaybackLine(
      id: 'placeholder-modu',
      episodeId: 1,
      providerId: 'aggregate.maccms',
      providerName: '在线服务 · 魔都2',
      sourceName: '魔都2',
      title: '魔都2',
      quality: '',
      format: '',
      diagnosticStatus: PlaybackDiscoveryStatus.searchMiss,
      queried: true,
      matched: false,
      available: false,
      message: '当前站点没有匹配到这部作品',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: PlaybackSourcePanel(
            selected: verified,
            lines: const [placeholder, verified],
            failedLineIds: const {},
            scanning: false,
            completedRules: 1,
            totalRules: 1,
            onSelected: (_) {},
            onPickLocal: () async {},
            onOpenNetwork: (_, _) async {},
            onSearch: () async {},
          ),
        ),
      ),
    );

    expect(find.text('1 来源 · 1 已查 · 1 匹配 · 1 可播'), findsOneWidget);
    expect(find.text('在线服务 · 魔都2'), findsOneWidget);
    expect(find.text('其它来源（1）'), findsNothing);
    expect(find.text('当前站点没有匹配到这部作品'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
