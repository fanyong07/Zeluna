import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'diagnostics export is opt-in and accessible in the source panel',
    (tester) async {
      var copies = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackSourcePanel(
              selected: null,
              lines: const [],
              failedLineIds: const {},
              scanning: false,
              completedRules: 0,
              totalRules: 0,
              onSelected: (_) {},
              onPickLocal: () async {},
              onOpenNetwork: (_, _) async {},
              onSearch: () async {},
              onCopyDiagnostics: () async {
                copies++;
              },
            ),
          ),
        ),
      );
      expect(copies, 0);
      await tester.tap(find.text('复制播放诊断'));
      await tester.pump();
      expect(copies, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'portrait inventory includes routes beyond four and unavailable rows',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lines = List.generate(
        58,
        (i) => PlaybackLine(
          id: 'route-$i',
          episodeId: 1,
          providerId: 'source',
          providerName: '来源',
          title: '线路$i',
          quality: '',
          format: 'HLS',
          url: 'https://cdn.example/$i.m3u8',
          available: i != 57,
          clientVerified: i != 57,
          diagnosticStatus: i == 57
              ? PlaybackDiscoveryStatus.routeUnavailable
              : '',
        ),
      );
      var selections = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PortraitPlaybackLineList(
              lines: lines,
              selectedLineId: null,
              failedLineIds: const {},
              onSelected: (_) => selections++,
            ),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('portrait-route-route-57')),
        250,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 80,
      );
      expect(find.textContaining('线路失败'), findsOneWidget);
      final disabledRow = find.byKey(const ValueKey('portrait-route-route-57'));
      expect(
        tester
            .widget<InkWell>(
              find.descendant(
                of: disabledRow,
                matching: find.byKey(const ValueKey('route-tap-route-57')),
              ),
            )
            .onTap,
        isNull,
      );
      expect(selections, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all 58 AniCh routes are listed on a narrow screen without expansion',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lines = List.generate(
        58,
        (i) => PlaybackLine(
          id: 'anich-$i',
          episodeId: 1,
          providerId: 'route-$i',
          providerName: 'route-$i',
          sourceName: 'route-$i',
          title: '第1集 官方字幕完整线路',
          quality: '1080P',
          format: 'HLS',
          url: 'https://cdn.example/$i.m3u8',
          available: false,
          diagnosticStatus: PlaybackDiscoveryStatus.clientProbeRequired,
          message: '服务器出口受限，等待客户端完成清单和首段验证',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PlaybackSourcePanel(
              selected: null,
              lines: lines,
              failedLineIds: const {},
              scanning: false,
              completedRules: 0,
              totalRules: 58,
              onSelected: (_) {},
              onPickLocal: () async {},
              onOpenNetwork: (_, _) async {},
              onSearch: () async {},
            ),
          ),
        ),
      );
      expect(find.text('共 58 条线路，0 条可以播放'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      for (var i = 0; i < 58; i++) {
        expect(find.byKey(ValueKey('anich-$i')), findsOneWidget);
      }
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('anich-57')),
        600,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      final lastRouteRect = tester.getRect(
        find.byKey(const ValueKey('anich-57')),
      );
      expect(
        lastRouteRect.overlaps(const Rect.fromLTWH(0, 0, 360, 760)),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
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
    'source panel shows every source including background states by default',
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

      expect(find.text('共 1 条线路，1 条可以播放 · 3 项待解析或暂无线路'), findsOneWidget);
      expect(find.text('iKun'), findsOneWidget);
      expect(find.text('线路失败源'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);

      expect(find.text('无结果源'), findsOneWidget);
      expect(find.text('未查询源'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source panel stretches short long selected and hovered rows to shared edges',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lines = [
        const PlaybackLine(
          id: 'short',
          episodeId: 1,
          providerId: 'route-short',
          providerName: 'hb-10',
          title: '第1集',
          quality: '',
          format: 'HLS',
          url: 'https://a.test/1.m3u8',
          available: true,
          latency: Duration(milliseconds: 9),
        ),
        PlaybackLine(
          id: 'long',
          episodeId: 1,
          providerId: 'route-long',
          providerName: '稀饭动漫',
          title: '第1集 · 官方字幕完整线路',
          quality: '',
          format: 'DASH',
          url: 'https://cdn.example/${'unbroken-' * 50}/master.m3u8',
          available: true,
          latency: const Duration(milliseconds: 123456),
          sizeBytes: 1234567890,
          videoWidth: 1920,
          videoHeight: 1080,
        ),
        const PlaybackLine(
          id: 'pending',
          episodeId: 1,
          providerId: 'route-pending',
          providerName: '待解析线路',
          title: '第1集',
          quality: '',
          format: '',
          available: false,
          diagnosticStatus: PlaybackDiscoveryStatus.clientResolverRequired,
        ),
      ];
      var selections = 0;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      for (final width in [320.0, 360.0, 1280.0]) {
        for (final scale in [1.0, 2.4]) {
          tester.view.physicalSize = Size(width, 2400);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: PlaybackSourcePanel(
                  selected: lines.first,
                  lines: lines,
                  failedLineIds: const {},
                  scanning: false,
                  completedRules: 3,
                  totalRules: 3,
                  onSelected: (_) => selections++,
                  onPickLocal: () async {},
                  onOpenNetwork: (_, _) async {},
                  onSearch: () async {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final contentLeft = tester
              .getRect(find.byKey(const ValueKey('line-content-short')))
              .left;
          for (final line in lines) {
            final id = line.id;
            final surfaceFinder = find.byKey(ValueKey('line-surface-$id'));
            final surface = tester.getRect(surfaceFinder);
            final gutter = tester.getRect(
              find.byKey(ValueKey('line-gutter-$id')),
            );
            final content = tester.getRect(
              find.byKey(ValueKey('line-content-$id')),
            );
            expect(surface.left, 12);
            expect(surface.right, width - 12);
            expect(gutter.left - surface.left, 12);
            expect(content.left, contentLeft);
            expect(content.left - gutter.right, 8);
            expect(surface.right - content.right, 12);
            for (final metric in ['latency', 'size', 'resolution', 'format']) {
              final shortMetric = tester.getRect(
                find.byKey(ValueKey('line-$metric-short')),
              );
              final metricRect = tester.getRect(
                find.byKey(ValueKey('line-$metric-$id')),
              );
              expect(metricRect.left, shortMetric.left);
              expect(metricRect.width, closeTo(shortMetric.width, 0.01));
            }
            await mouse.moveTo(surface.center);
            await tester.pumpAndSettle();
            expect(tester.getRect(surfaceFinder), surface);
          }
          expect(find.text('本机重查（本集）'), findsNothing);
          expect(
            tester
                .widget<InkWell>(
                  find.byKey(const ValueKey('route-tap-pending')),
                )
                .onTap,
            isNull,
          );
          expect(selections, 0);
          expect(tester.takeException(), isNull);
        }
      }
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

    expect(find.text('共 1 条线路，1 条可以播放'), findsOneWidget);
    expect(find.text('魔都2'), findsOneWidget);
    expect(find.text('其它来源（1）'), findsNothing);
    expect(find.text('当前站点没有匹配到这部作品'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
