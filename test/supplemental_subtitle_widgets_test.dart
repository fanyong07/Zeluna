import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/danmaku_overlay.dart';
import 'package:anime/src/player/subtitles/subtitle_document.dart';
import 'package:anime/src/player/subtitles/subtitle_overlay.dart';
import 'package:anime/src/player/subtitles/subtitle_panel.dart';
import 'package:anime/src/player/subtitles/subtitle_repository.dart';
import 'package:anime/src/player/subtitles/subtitle_store.dart';
import 'package:anime/src/player/subtitles/supplemental_subtitle_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const subject = AnimeSubject(
  id: 100,
  title: '字幕演示作品',
  originalTitle: 'Subtitle Demo',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-01-01',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '',
  categories: [],
  tags: [],
  totalEpisodes: 2,
);
AnimeEpisode episode(int n) => AnimeEpisode(
  id: n,
  subjectId: 100,
  number: n,
  title: '',
  airdate: null,
  duration: '',
  description: '',
);
Uint8List srt(String text) =>
    Uint8List.fromList(utf8.encode('1\n00:00:01,000 --> 00:00:05,000\n$text'));

Future<SupplementalSubtitleController> controller({
  bool withDocument = false,
}) async {
  final c = SupplementalSubtitleController(SubtitleStore());
  c.bind(
    subject: subject.identityKey,
    episode: episode(1).identityKey(subjectKey: subject.identityKey),
    line: 'line-a',
    originalLanguage: 'ja',
  );
  if (withDocument) {
    await c.selectDocument(
      parseSubtitle(srt('今日は、いい天気ですね。'), 'Demo 01.srt', 'ja'),
      expectedGeneration: c.generation,
    );
  }
  return c;
}

Widget panel(
  SupplementalSubtitleController c, {
  double width = 430,
  double scale = 1,
  http.Client? httpClient,
  Future<List<SubtitleImportFile>> Function()? pickFiles,
}) => MaterialApp(
  theme: ThemeData.dark(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: width,
        child: SupplementalSubtitlePanel(
          controller: c,
          subject: subject,
          episode: episode(1),
          episodes: [episode(1), episode(2)],
          pickFiles: pickFiles,
          createRepository: () => SubtitleRepository(
            const ExternalServiceSettings(),
            client:
                httpClient ??
                MockClient(
                  (_) async => http.Response(
                    jsonEncode({
                      'status': 'provider_unavailable',
                      'message': '来源不可用，请导入字幕',
                      'candidates': [],
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8',
                    },
                  ),
                ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'enabling captions fetches the unique server library file without import',
    (tester) async {
      final c = await controller();
      addTearDown(c.dispose);
      var searches = 0;
      var downloads = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/search')) {
          searches++;
          return http.Response(
            jsonEncode({
              'status': 'found',
              'message': '已找到服务器内置字幕',
              'candidates': [
                {
                  'id': '0123456789abcdef0123456789abcdef',
                  'provider': 'library',
                  'entry_id': subject.identityKey,
                  'file_name': 'original.ja.srt',
                  'language': 'ja',
                  'auto_match': true,
                  'reasons': ['已核对作品和分集'],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        downloads++;
        return http.Response.bytes(srt('服务器原文'), 200);
      });
      await tester.pumpWidget(panel(c, httpClient: client));
      await tester.tap(find.text('显示外挂字幕'));
      await tester.pumpAndSettle();
      expect(searches, 1);
      expect(downloads, 1);
      expect(c.textAt(const Duration(seconds: 2)), '服务器原文');
      expect(
        c.store.documentFor(c.episodeKey, 'ja')?.fileName,
        'original.ja.srt',
      );
      await tester.tap(find.text('显示外挂字幕'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示外挂字幕'));
      await tester.pumpAndSettle();
      expect(downloads, 1, reason: 're-enabling uses the local file cache');
    },
  );
  testWidgets(
    'panel supports 220px landscape and portrait with enlarged text',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      final c = await controller(withDocument: true);
      addTearDown(c.dispose);
      for (final size in [
        const Size(568, 320),
        const Size(430, 900),
        const Size(1280, 720),
      ]) {
        tester.view.physicalSize = size;
        for (final scale in [1.0, 1.6]) {
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: panel(
                c,
                width: size.width > size.height ? 220 : size.width,
                scale: scale,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$size scale $scale');
          expect(find.text('保留片源字幕，只补原文'), findsOneWidget);
        }
      }
    },
  );
  testWidgets(
    'single import and unavailable online search keep native subtitle intact',
    (tester) async {
      final c = await controller();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        panel(
          c,
          pickFiles: () async => [SubtitleImportFile('01.srt', srt('Hello'))],
        ),
      );
      await tester.tap(find.text('导入字幕'));
      await tester.pumpAndSettle();
      expect(c.document?.fileName, '01.srt');
      expect(c.enabled, isTrue);
      await tester.tap(find.text('查找内置日语'));
      await tester.pumpAndSettle();
      expect(find.text('来源不可用，请导入字幕'), findsOneWidget);
      expect(c.document?.fileName, '01.srt');
      await tester.tap(find.text('当前片源已有双语'));
      await tester.pumpAndSettle();
      expect(c.bilingual, isTrue);
      expect(c.visible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'batch import requires confirmation and binds each episode independently',
    (tester) async {
      final c = await controller();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        panel(
          c,
          pickFiles: () async => [
            SubtitleImportFile('Demo 01.srt', srt('first')),
            SubtitleImportFile('Demo 02.srt', srt('second')),
          ],
        ),
      );
      await tester.tap(find.text('导入字幕'));
      await tester.pumpAndSettle();
      expect(c.document, isNull);
      await tester.scrollUntilVisible(find.text('确认并保存分集字幕'), 200);
      await tester.tap(find.text('确认并保存分集字幕'));
      await tester.pumpAndSettle();
      expect(c.textAt(const Duration(seconds: 2)), 'first');
      expect(
        c.store
            .documentFor(
              episode(2).identityKey(subjectKey: subject.identityKey),
              'ja',
            )
            ?.cues
            .single
            .text,
        'second',
      );
    },
  );
  testWidgets(
    'overlay leaves existing Chinese visible and danmaku outside its band',
    (tester) async {
      final c = await controller(withDocument: true);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: Text('片源原有中文字幕'),
                ),
                SupplementalSubtitleOverlay(
                  controller: c,
                  position: const Duration(seconds: 2),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('片源原有中文字幕'), findsOneWidget);
      expect(find.text('今日は、いい天気ですね。'), findsOneWidget);
      final band = supplementalSubtitleBounds(
        const Size(800, 600),
        c,
        TextScaler.noScaling,
        text: 'original',
      );
      expect(
        danmakuDisplayBounds(
          const Size(800, 600),
          1,
          excludedArea: band,
        ).overlaps(band),
        isFalse,
      );
      await c.setBilingual(true);
      await tester.pump();
      expect(find.text('片源原有中文字幕'), findsOneWidget);
      expect(find.text('今日は、いい天気ですね。'), findsNothing);
    },
  );
  testWidgets('render subtitle surfaces for visual review', (tester) async {
    if (!const bool.fromEnvironment('SUBTITLE_SCREENSHOTS')) return;
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-400.ttf'));
    await loader.load();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    final c = await controller(withDocument: true);
    addTearDown(c.dispose);
    for (final size in [
      const Size(1280, 720),
      const Size(430, 900),
      const Size(568, 320),
    ]) {
      tester.view.physicalSize = size;
      final boundaryKey = GlobalKey();
      final overlayKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansSC',
            ),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundaryKey,
              child: Row(
                children: [
                  if (size.width > 600)
                    Expanded(
                      child: ColoredBox(
                        color: const Color(0xFF17232A),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const Center(
                              child: Icon(
                                Icons.movie_outlined,
                                size: 110,
                                color: Color(0xFF3F535D),
                              ),
                            ),
                            const Positioned(
                              left: 0,
                              right: 0,
                              bottom: 64,
                              child: Text(
                                '片源原有中文字幕保持不变',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 24),
                              ),
                            ),
                            SupplementalSubtitleOverlay(
                              key: overlayKey,
                              controller: c,
                              position: const Duration(seconds: 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SizedBox(
                    width: size.width > 600 ? 400 : size.width,
                    child: SupplementalSubtitlePanel(
                      controller: c,
                      subject: subject,
                      episode: episode(1),
                      episodes: [episode(1), episode(2)],
                      createRepository: () => SubtitleRepository(
                        const ExternalServiceSettings(
                          playbackBackendEnabled: false,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('artifacts/subtitle-qa');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/subtitles-${size.width.round()}x${size.height.round()}.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
