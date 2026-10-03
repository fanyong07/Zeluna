import 'dart:convert';

import 'package:anime/src/data/zeluna_backend_playback_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:anime/src/player/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _subject = AnimeSubject(
  id: 1,
  title: '测试作品',
  originalTitle: '',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2023',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '完结',
  categories: [AnimeCategory(name: '动画')],
  tags: [],
  totalEpisodes: 12,
);
const _episode = AnimeEpisode(
  id: 101,
  subjectId: 1,
  number: 1,
  title: '第1集',
  airdate: null,
  duration: '',
  description: '',
);
String _inventoryId(int i) =>
    'registered:${i.toRadixString(16).padLeft(24, '0')}';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'local action is capability-gated and one per source ($width)',
      (tester) async {
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var localQueries = 0;
        var selections = 0;
        PlaybackLine line(String id, bool supported, String inventoryId) =>
            PlaybackLine(
              id: id,
              episodeId: 101,
              providerId: 'maccms:$inventoryId',
              providerName: '测试采集',
              sourceInventoryId: inventoryId,
              clientQuerySupported: supported,
              url: supported ? 'https://cdn.example/$id.mp4' : null,
              queryLocation: 'local',
              queried: true,
              title: id,
              quality: '',
              format: '',
              available: false,
              diagnosticStatus: PlaybackDiscoveryStatus.routeUnavailable,
            );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: PlaybackSourcePanel(
                selected: null,
                lines: [
                  line('first', true, _inventoryId(1)),
                  line('second', true, _inventoryId(1)),
                  line('unsupported', false, _inventoryId(2)),
                ],
                failedLineIds: const {},
                scanning: false,
                completedRules: 0,
                totalRules: 0,
                onSelected: (_) => selections++,
                onPickLocal: () async {},
                onOpenNetwork: (_, _) async {},
                onSearch: () async {},
                onQueryLocally: (_) async => localQueries++,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('本机重查（本集）'), findsOneWidget);
        await tester.tap(find.text('本机重查（本集）'));
        await tester.pump();
        expect(localQueries, 1);
        expect(selections, 0);
        expect(find.text('搜索与解析：本机网络'), findsNWidgets(3));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'all 118 registered sources are visible and disabled rows cannot be selected ($width)',
      (tester) async {
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final lines = List.generate(
          118,
          (i) => PlaybackLine(
            id: 'inventory-$i',
            episodeId: 101,
            providerId: 'source-$i',
            providerName: '来源$i',
            sourceName: '来源$i',
            sourceInventoryId: _inventoryId(i),
            title: '来源$i',
            quality: '',
            format: '',
            diagnosticStatus: i < 80
                ? PlaybackDiscoveryStatus.candidateUnadmitted
                : PlaybackDiscoveryStatus.sourceDisabled,
            queried: false,
            available: false,
            message: i < 80 ? '候选源尚未接入生产查询' : '此源当前未启用',
          ),
        );
        var selections = 0;
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
                totalRules: 0,
                onSelected: (_) => selections++,
                onPickLocal: () async {},
                onOpenNetwork: (_, _) async {},
                onSearch: () async {},
              ),
            ),
          ),
        );
        expect(find.text('来源状态：共 118 个来源，已检查 0 个'), findsOneWidget);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(find.text('该来源仅为候选，尚未接入查询；本集没有播放验证结果。'), findsNWidgets(80));
        for (var i = 0; i < 118; i++) {
          expect(find.byKey(ValueKey('inventory-$i')), findsOneWidget);
        }
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('inventory-117')),
          600,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 60,
        );
        await tester.pumpAndSettle();
        final lastRow = find.byKey(const ValueKey('inventory-117'));
        final lastRect = tester.getRect(lastRow);
        expect(lastRect.overlaps(Rect.fromLTWH(0, 0, width, 760)), isTrue);
        expect(lastRect.center.dy, inInclusiveRange(0, 760));
        await tester.tap(lastRow);
        await tester.pumpAndSettle();
        expect(selections, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    '58 routes from one registered adapter remain visible but count as one source',
    () {
      final lines = List.generate(
        58,
        (i) => PlaybackLine(
          id: 'route-$i',
          episodeId: 101,
          providerId: 'route-$i',
          providerName: '路线$i',
          sourceName: '路线$i',
          sourceInventoryId: _inventoryId(1),
          title: '第1集',
          quality: '1080P',
          format: 'HLS',
          url: 'https://cdn.example/$i.m3u8',
          available: i == 0,
          diagnosticStatus: i == 0
              ? PlaybackDiscoveryStatus.serverVerified
              : PlaybackDiscoveryStatus.routeUnavailable,
          queried: true,
          matched: true,
        ),
      );
      final summary = summarizePlaybackSourceDiagnostics(lines);
      expect(summary.totalSources, 1);
      expect(summary.queriedSources, 1);
      expect(summary.playableSources, 1);
      final groups = groupPlaybackLinesForDiagnostics(lines);
      expect([...groups.primary, ...groups.other], hasLength(58));
      final preserved = preservePlaybackLineProbeMetadata(
        incoming: lines.first,
        previous: lines.first,
      );
      expect(preserved.sourceInventoryId, _inventoryId(1));
    },
  );

  for (final expandAll in [false, true]) {
    test(
      'quick/full roster preserves 118 identities without playback promotion ($expandAll)',
      () async {
        final repository = ZelunaBackendPlaybackRepository(
          baseUrl: 'https://backend.example.com',
          client: MockClient((request) async {
            expect(
              request.url.path,
              expandAll
                  ? '/api/v3/playback/bangumi:1'
                  : '/api/v3/quick-playback/bangumi:1',
            );
            return http.Response(
              jsonEncode(
                List.generate(
                  118,
                  (i) => {
                    'inventory_source_id': _inventoryId(i),
                    'source_inventory_entry': true,
                    'source': 'candidate:${i < 2 ? '同名来源' : '来源$i'}',
                    'title': '来源$i',
                    'url': '',
                    'available': false,
                    'diagnostic_status': i < 80
                        ? 'candidate_unadmitted'
                        : i < 85
                        ? 'compatibility_inactive'
                        : 'source_disabled',
                    'queried': false,
                  },
                ),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        addTearDown(repository.dispose);
        final lines = await repository.linesForEpisodeMode(
          _subject,
          _episode,
          expandAll: expandAll,
        );
        expect(lines, hasLength(118));
        final summary = summarizePlaybackSourceDiagnostics(lines);
        expect(summary.totalSources, 118);
        expect(summary.queriedSources, 0);
        expect(summary.matchedSources, 0);
        expect(summary.playableSources, 0);
        expect(lines.first.diagnosticStatus, 'candidate_unadmitted');
        final groups = groupPlaybackLinesForDiagnostics(lines);
        expect([...groups.primary, ...groups.other], hasLength(118));
        expect(
          lines.every(
            (line) =>
                !line.available &&
                !line.requiresClientProbe &&
                !line.serverVerified,
          ),
          isTrue,
        );
      },
    );
  }

  test(
    'malformed inventory marker cannot authorize playback or claim a query',
    () async {
      final repository = ZelunaBackendPlaybackRepository(
        baseUrl: 'https://backend.example.com',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {
                'inventory_source_id': _inventoryId(1),
                'source_inventory_entry': true,
                'source': 'candidate:候选',
                'url': 'https://cdn.example.com/bogus.mp4',
                'available': true,
                'status': 'server_verified',
                'diagnostic_status': 'server_verified',
                'queried': true,
                'matched': true,
                'headers': {'Authorization': 'fixture-not-a-credential'},
              },
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      addTearDown(repository.dispose);
      final line = (await repository.linesForEpisode(
        _subject,
        _episode,
      )).single;
      expect(line.available, isFalse);
      expect(line.serverVerified, isFalse);
      expect(line.url, isNull);
      expect(line.headers, isEmpty);
      expect(line.queried, isFalse);
      expect(summarizePlaybackSourceDiagnostics([line]).matchedSources, 0);
    },
  );
}
