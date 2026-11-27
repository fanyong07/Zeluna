import 'dart:async';
import 'dart:convert';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/library/following_update_tracker.dart';
import 'package:anime/src/profile/profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _today = DateTime(2026, 3, 7);
AnimeEpisode _ep(int number, [String? date]) => AnimeEpisode(
  id: 100 + number,
  subjectId: 1,
  number: number,
  title: '',
  airdate: date,
  duration: '',
  description: '',
);
AnimeSubject _subject(int id, {String source = 'bangumi'}) =>
    AnimeSubject.fromJson({
      'id': id,
      'title': '作品$id',
      'totalEpisodes': 12,
      'source': source,
    });
LibraryEntry _entry(int id, {int? ep, int pos = 0}) => LibraryEntry(
  subject: _subject(id),
  episode: ep == null ? null : _ep(ep),
  positionSeconds: pos,
  durationSeconds: 100,
  updatedAt: _today,
);
http.Response _json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

void main() {
  test(
    'aired dates include today and exclude future, unknown dates and specials',
    () {
      int aired(List<AnimeEpisode> eps) =>
          latestAiredEpisodeNumber(eps, now: _today, fallbackTotal: 12);
      expect(
        aired([
          _ep(4, '2026-03-08'),
          _ep(3, '2026-03-07'),
          _ep(2, '2026-03-06'),
          _ep(12),
          _ep(11, '2026-02-30'),
        ]),
        3,
      );
      expect(aired([_ep(1, '2026-03-08'), _ep(2)]), 0);
      expect(aired([_ep(0, '2025-03-08'), _ep(4), _ep(2, 'invalid')]), 4);
      expect(aired([]), 12);
      expect(latestAiredEpisodeNumber([_ep(-1)]), 0);
    },
  );

  test(
    'completed, partial, caught up and never watched use the same badge rules',
    () {
      final entry = _entry(1, ep: 2);
      FollowingUpdateStatus status(int ep, int pos, {int aired = 5}) =>
          computeFollowingUpdateStatus(
            followingEntry: entry,
            historyEntry: _entry(1, ep: ep, pos: pos),
            latestAiredEpisodeOverride: aired,
          );
      final done = status(3, 85);
      expect(
        (done.watchedEpisode, done.watchingEpisode, done.unwatchedCount),
        (3, null, 2),
      );
      expect(done.detailLabel, '更新至第 5 集 · 未看 2 集');
      expect(done.shortBadge, '未看 2 集');
      final partial = status(3, 84);
      expect(
        (
          partial.watchedEpisode,
          partial.watchingEpisode,
          partial.unwatchedCount,
        ),
        (2, 3, 3),
      );
      expect(status(3, 50, aired: 0).detailLabel, '看到第 3 集');
      final caught = status(5, 0);
      expect(
        (caught.detailLabel, caught.shortBadge, caught.hasUpdates),
        ('已追平 · 共 5 集', '已追平', false),
      );
      final fresh = computeFollowingUpdateStatus(followingEntry: _entry(1));
      expect(
        (fresh.watchedEpisode, fresh.watchingEpisode, fresh.unwatchedCount),
        (0, null, 12),
      );
      final unknown = computeFollowingUpdateStatus(
        followingEntry: entry,
        historyEntry: _entry(1),
        latestAiredEpisodeOverride: 0,
      );
      expect((unknown.shortBadge, unknown.detailLabel), (null, ''));
      expect(
        computeFollowingUpdateStatus(
          followingEntry: entry,
          latestAiredEpisodeOverride: 0,
        ).detailLabel,
        '已看到第 2 集',
      );
    },
  );

  test(
    'overlapping refreshes use three slots, coalesce, isolate errors and expire at 15 minutes',
    () async {
      var now = _today;
      var active = 0;
      var peak = 0;
      final calls = <int>[];
      final release = Completer<void>();
      final repo = BangumiMetadataRepository(
        client: MockClient((req) async {
          expect(req.url.host, 'api.bgm.tv');
          expect(req.url.path, '/v0/episodes');
          expect(req.url.queryParameters['type'], '0');
          final id = int.parse(req.url.queryParameters['subject_id']!);
          calls.add(id);
          active++;
          if (active > peak) peak = active;
          await release.future;
          active--;
          if (id == 4) return http.Response('', 503);
          return _json({
            'data': [
              {'ep': id, 'airdate': '2026-03-07'},
            ],
          });
        }),
      );
      final tracker = FollowingUpdateTracker(repo, clock: () => now);
      addTearDown(tracker.dispose);
      final first = tracker.refreshForSubjects([
        for (var i = 1; i <= 4; i++) _subject(i),
        _subject(0),
        _subject(25, source: 'local'),
      ]);
      final second = tracker.refreshForSubjects([
        _subject(1),
        _subject(5),
      ], force: true);
      await Future<void>.delayed(Duration.zero);
      expect(tracker.refreshing, true);
      expect(calls, [1, 2, 3]);
      release.complete();
      await Future.wait([first, second]);
      expect(peak, 3);
      expect(calls, [1, 2, 3, 4, 5]);
      expect(tracker.refreshing, false);
      expect(tracker.latestAiredFor('bangumi:4'), isNull);
      expect(tracker.latestAiredFor('bangumi:5'), 5);
      now = now.add(const Duration(minutes: 14));
      await tracker.refreshForSubjects([_subject(1), _subject(4)]);
      expect(calls.skip(5), [4]);
      await tracker.refreshForSubjects([_subject(2)], force: true);
      now = now.add(const Duration(minutes: 1));
      await tracker.refreshForSubjects([_subject(1), _subject(2)]);
      expect(calls.skip(6), [2, 1]);
    },
  );

  testWidgets(
    'following filters react to cached air dates, manual refresh and empty results',
    (tester) async {
      var aired = 4;
      final calls = <int>[];
      final repo = BangumiMetadataRepository(
        client: MockClient((req) async {
          final id = int.parse(req.url.queryParameters['subject_id']!);
          calls.add(id);
          return _json({
            'data': [
              {'ep': id == 1 ? aired : 2, 'airdate': '2000-01-01'},
            ],
          });
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_LibraryController.new),
            bangumiMetadataRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            home: LibraryPage(
              title: '追番列表',
              emptyTitle: '还没有追番',
              emptyMessage: '加入追番后查看',
              showFollowingUpdates: true,
              entriesOf: (s) => s.following,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, [1, 2]);
      expect(find.text('全部 (2)'), findsOneWidget);
      expect(find.text('有更新 (1)'), findsOneWidget);
      expect(find.text('更新至第 4 集 · 未看 2 集'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('followingFilterUpdated')));
      await tester.pumpAndSettle();
      expect(find.text('作品1'), findsOneWidget);
      expect(find.text('作品2'), findsNothing);
      aired = 2;
      await tester.tap(find.byTooltip('刷新更新'));
      await tester.pumpAndSettle();
      expect(calls, [1, 2, 1, 2]);
      expect(find.text('有更新 (0)'), findsOneWidget);
      expect(find.text('当前追番均已追平'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('followingFilterAll')));
      await tester.pumpAndSettle();
      expect(find.text('作品2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _LibraryController extends AnimeController {
  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: AnimeHomeFeed.fromJson({'hero': _subject(1).toJson()}),
    following: [_entry(1), _entry(2)],
    history: [_entry(1, ep: 2), _entry(2, ep: 2)],
  );
}
