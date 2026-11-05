import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/domain/client_media_resolver.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:anime/src/player/ui/playback_line_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('latency thresholds retain semantic colors including selection', (
    tester,
  ) async {
    const cases = <int, PlaybackLineLatencyBand>{
      500: PlaybackLineLatencyBand.fast,
      501: PlaybackLineLatencyBand.moderate,
      1500: PlaybackLineLatencyBand.moderate,
      1501: PlaybackLineLatencyBand.slow,
    };
    for (final brightness in Brightness.values) {
      for (final entry in cases.entries) {
        final line = _line(latencyMs: entry.key);
        for (final selected in [false, true]) {
          await tester.pumpWidget(
            _host(
              PlaybackLineTile(line: line, selected: selected),
              brightness: brightness,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            _textColor(tester, 'line-latency-line'),
            PlaybackLineTileColors.latency(entry.value, brightness),
          );
          expect(
            _textColor(tester, 'line-size-line'),
            PlaybackLineTileColors.size(brightness),
          );
          expect(
            _textColor(tester, 'line-resolution-line'),
            PlaybackLineTileColors.resolution(brightness),
          );
          expect(
            _textColor(tester, 'line-url-line'),
            PlaybackLineTileColors.unknown(brightness),
          );
          expect(find.text('${entry.key}ms'), findsOneWidget);
          expect(find.text('约 50.0 MB'), findsOneWidget);
          expect(find.text('1920×1080'), findsOneWidget);
          expect(find.text('当前'), selected ? findsOneWidget : findsNothing);
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets(
    'unknown and invalid metrics are neutral gray without fake data',
    (tester) async {
      final line = _line(
        latencyMs: -1,
        sizeBytes: 0,
        sizeLabel: '30 MB',
        width: 0,
        height: -1,
        quality: 'unknown',
        format: 'auto',
      );
      await tester.pumpWidget(
        _host(PlaybackLineTile(line: line, selected: true)),
      );
      for (final metric in ['latency', 'size', 'resolution', 'format']) {
        expect(
          _textColor(tester, 'line-$metric-line'),
          PlaybackLineTileColors.unknown(Brightness.dark),
        );
      }
      expect(find.text('速度未知'), findsOneWidget);
      expect(find.text('大小未知'), findsOneWidget);
      expect(find.text('分辨率未知'), findsOneWidget);
      expect(find.text('格式未知'), findsOneWidget);
      expect(find.textContaining('30 MB'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real upstream names replace catalog prefixes in name and title',
    (tester) async {
      final line = _line(
        providerId: 'crawler.anich',
        providerName: 'AniCh · hb-10',
        sourceName: 'Animeko · hb-10',
        title: 'AniCh · hb-10',
      );
      await tester.pumpWidget(_host(PlaybackLineTile(line: line)));
      expect(find.text('hb-10'), findsOneWidget);
      expect(find.textContaining('AniCh'), findsNothing);
      expect(find.textContaining('Animeko'), findsNothing);
      expect(find.byKey(const ValueKey('line-title-line')), findsNothing);

      await tester.pumpWidget(
        _host(
          PlaybackLineTile(
            line: _line(
              providerId: 'crawler.kazumi',
              providerName: 'Kazumi · xfdmneo',
              sourceName: '',
              title: 'Kazumi · 第1集',
            ),
          ),
        ),
      );
      expect(find.text('稀饭动漫'), findsOneWidget);
      expect(find.text('第1集'), findsOneWidget);
      expect(find.textContaining('Kazumi'), findsNothing);

      await tester.pumpWidget(
        _host(
          PlaybackLineTile(
            line: _line(
              providerId: 'crawler.animeko',
              providerName: 'Animeko · dm-yhdm',
              title: '',
            ),
          ),
        ),
      );
      expect(find.text('樱花动漫'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('copy and full selectable URL do not select the route', (
    tester,
  ) async {
    final fullUrl =
        'https://cdn.example/video/${'long-segment-' * 30}'
        '/index.m3u8?token=unmodified%2Bvalue&expires=123456789';
    var selections = 0;
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      _host(
        PlaybackLineTile(
          line: _line(url: fullUrl),
          onTap: () => selections++,
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('line-url-line'))).data,
      fullUrl,
    );
    await tester.tap(find.byKey(const ValueKey('copy-line-url-line')));
    await tester.pump();
    expect(copied, [fullUrl]);
    expect(selections, 0);

    await tester.tap(find.byKey(const ValueKey('view-line-url-line')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('line-url-dialog-line')), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('line-full-url-line')),
          )
          .data,
      fullUrl,
    );
    await tester.tap(find.byKey(const ValueKey('copy-full-line-url-line')));
    await tester.pump();
    expect(copied, [fullUrl, fullUrl]);
    expect(selections, 0);
    await tester.tap(find.byKey(const ValueKey('close-line-url-line')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('line-name-line')));
    expect(selections, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed media candidate remains visible with URL and measured colors',
    (tester) async {
      await tester.pumpWidget(
        _host(
          PlaybackLineTile(
            line: _line(
              available: false,
              diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
              latencyMs: 266,
            ),
            runtimeFailed: true,
            selected: true,
          ),
        ),
      );
      expect(find.text('播放失败 · 可重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('line-url-line')), findsOneWidget);
      expect(find.byKey(const ValueKey('copy-line-url-line')), findsOneWidget);
      expect(
        _textColor(tester, 'line-latency-line'),
        PlaybackLineTileColors.latency(
          PlaybackLineLatencyBand.fast,
          Brightness.dark,
        ),
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('route-tap-line')))
            .onTap,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable source keeps curated diagnostics without a fake URL',
    (tester) async {
      final line = _line(
        available: false,
        url: '',
        diagnosticStatus: PlaybackDiscoveryStatus.searchMiss,
        title: '',
      );
      await tester.pumpWidget(_host(PlaybackLineTile(line: line)));
      expect(find.textContaining('未找到匹配'), findsOneWidget);
      expect(find.text(playbackSourceStateExplanation(line)), findsOneWidget);
      expect(find.byKey(const ValueKey('line-url-line')), findsNothing);
      expect(find.byKey(const ValueKey('copy-line-url-line')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending resolver is visibly pending rather than a video link', (
    tester,
  ) async {
    final descriptor = ClientMediaResolverDescriptor(
      pageUrl: Uri.parse('https://chapter.example/play/1.html'),
      referer: Uri.parse('https://chapter.example/'),
      ruleId: 'xfdmneo',
      ruleName: '稀饭动漫',
      userAgent: '',
      pageHosts: const ['chapter.example'],
      mediaHosts: const ['cdn.example'],
    );
    var selections = 0;
    await tester.pumpWidget(
      _host(
        PlaybackLineTile(
          line: _line(
            clientResolver: descriptor,
            available: false,
            requiresClientProbe: true,
            latencyMs: null,
            url: descriptor.pageUrl.toString(),
            diagnosticStatus: PlaybackDiscoveryStatus.clientResolverRequired,
          ),
          onTap: () => selections++,
        ),
      ),
    );
    expect(find.text('本机解析中'), findsOneWidget);
    expect(find.textContaining('尚未证明可播'), findsOneWidget);
    expect(find.textContaining('chapter.example'), findsNothing);
    expect(find.byKey(const ValueKey('copy-line-url-line')), findsNothing);
    expect(
      _textColor(tester, 'line-latency-line'),
      PlaybackLineTileColors.unknown(Brightness.dark),
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('route-tap-line')))
          .onTap,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('line-name-line')));
    expect(selections, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '320px and large text wrap metrics actions and long URL without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selections = 0;
      var localQueries = 0;
      final longUrl = 'https://cdn.example/${'unbroken' * 100}/master.m3u8';
      for (final compact in [false, true]) {
        await tester.pumpWidget(
          _host(
            PlaybackLineTile(
              line: _line(
                providerName: 'Kazumi · 稀饭动漫长站点名称测试手机线路显示',
                title: '官方字幕完整线路说明${'长文本' * 12}',
                url: longUrl,
                diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
                available: false,
              ),
              selected: true,
              runtimeFailed: true,
              index: 999,
              compact: compact,
              showLocalQuery: true,
              onTap: () => selections++,
              onQueryLocally: () => localQueries++,
            ),
            textScale: 2.4,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Wrap), findsAtLeastNWidgets(3));
        expect(tester.takeException(), isNull);
        final rowRect = tester.getRect(find.byType(PlaybackLineTile));
        expect(rowRect.width, lessThanOrEqualTo(320));
        await tester.ensureVisible(
          find.byKey(const ValueKey('local-query-line')),
        );
        await tester.tap(find.byKey(const ValueKey('local-query-line')));
        expect(localQueries, compact ? 2 : 1);
        expect(selections, 0);
        await tester.ensureVisible(
          find.byKey(const ValueKey('view-line-url-line')),
        );
        await tester.tap(find.byKey(const ValueKey('view-line-url-line')));
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('close-line-url-line')));
        await tester.pumpAndSettle();
        expect(selections, 0);
      }
    },
  );

  testWidgets(
    'metric semantics identify measurements without relying on color',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(PlaybackLineTile(line: _line(latencyMs: 266))),
      );
      expect(find.bySemanticsLabel(RegExp('延迟：266ms')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('视频大小：约 50.0 MB')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('分辨率：1920×1080')), findsOneWidget);
      semantics.dispose();
    },
  );
}

Color? _textColor(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).style?.color;

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness, useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

PlaybackLine _line({
  String providerId = 'crawler.kazumi',
  String providerName = 'Kazumi · xfdmneo',
  String sourceName = '',
  String title = '第1集',
  int? latencyMs,
  int? sizeBytes = 50 * 1024 * 1024,
  String? sizeLabel,
  int? width = 1920,
  int? height = 1080,
  String quality = '1080P',
  String format = 'HLS',
  String url = 'https://cdn.example/index.m3u8',
  bool available = true,
  bool requiresClientProbe = false,
  String diagnosticStatus = '',
  ClientMediaResolverDescriptor? clientResolver,
}) => PlaybackLine(
  id: 'line',
  episodeId: 1,
  providerId: providerId,
  providerName: providerName,
  sourceName: sourceName,
  title: title,
  quality: quality,
  format: format,
  url: url,
  clientResolver: clientResolver,
  latency: latencyMs == null ? null : Duration(milliseconds: latencyMs),
  sizeBytes: sizeBytes,
  sizeLabel: sizeLabel,
  sizeEstimated: true,
  videoWidth: width,
  videoHeight: height,
  available: available,
  requiresClientProbe: requiresClientProbe,
  diagnosticStatus: diagnosticStatus,
);
