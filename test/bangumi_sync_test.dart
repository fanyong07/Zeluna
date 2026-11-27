import 'dart:async';
import 'dart:convert';

import 'package:anime/src/core/identity/stable_identity.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/library/bangumi_sync_service.dart';
import 'package:anime/src/settings/bangumi_sync_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _credential = BangumiAccessCredential(
  token: 'mock-personal-token-for-offline-tests',
);
http.Response _json(Object value) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), 200);
Map<String, Object> _watching(int id, int watched) => {
  'ep_status': watched,
  'updated_at': '2026-03-07T13:10:00Z',
  'subject': {'id': id, 'name_cn': '作品$id', 'eps': 12},
};
BangumiMetadataRepository _repo(
  MockClientHandler handler, {
  Future<void> Function(BangumiAccessCredential)? reject,
}) => BangumiMetadataRepository(
  client: MockClient(handler),
  accessCredentialProvider: () async => _credential,
  onAccessTokenRejected: reject,
);
AnimeSubject _subject(int id) =>
    AnimeSubject.fromJson({'id': id, 'title': '作品$id'});
AnimeEpisode _ep(int id, int number, {int subject = 1}) => AnimeEpisode(
  id: id,
  number: number,
  subjectId: subject,
  title: '',
  airdate: null,
  duration: '',
  description: '',
);
LibraryEntry _entry(int id, {AnimeEpisode? ep, int pos = 0}) => LibraryEntry(
  subject: _subject(id),
  episode: ep,
  positionSeconds: pos,
  durationSeconds: 100,
  updatedAt: DateTime(2026),
);

ProviderContainer _container(BangumiMetadataRepository repo) {
  final container = ProviderContainer(
    overrides: [
      animeControllerProvider.overrideWith(_TestLibrary.new),
      bangumiMetadataRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('misc opt-in round trips without changing legacy defaults', () {
    final old = MiscSettings.fromJson({'keepScreenOn': false});
    expect(old.bangumiAutoSyncProgress, false);
    final settings = old.copyWith(bangumiAutoSyncProgress: true);
    expect(
      MiscSettings.fromJson(settings.toJson()).bangumiAutoSyncProgress,
      true,
    );
    expect(
      settings.copyWith(wifiOnlyCache: false).bangumiAutoSyncProgress,
      true,
    );
    expect(settings.keepScreenOn, false);
  });

  test(
    'authenticated collection gets /me and follows page offsets, preserving subject and progress',
    () async {
      final paths = <String>[];
      final repository = _repo((req) async {
        paths.add(req.url.path);
        expect(req.url.origin, 'https://api.bgm.tv');
        expect(req.method, 'GET');
        expect(req.headers['authorization'], 'Bearer ${_credential.token}');
        if (req.url.path == '/v0/me') return _json({'username': 'sample'});
        final offset = paths.length - 2;
        expect(req.url.queryParameters, {
          'subject_type': '2',
          'type': '3',
          'limit': '1',
          'offset': '$offset',
        });
        return _json({
          'data': [_watching(offset + 1, offset + 3)],
          'total': 2,
        });
      });
      final items = await repository.fetchWatchingCollection(limit: 1);
      expect(paths, [
        '/v0/me',
        '/v0/users/sample/collections',
        '/v0/users/sample/collections',
      ]);
      expect(items.map((e) => e.subject.identityKey), [
        'bangumi:1',
        'bangumi:2',
      ]);
      expect(items.first.subject.title, '作品1');
      expect(items.first.subject.totalEpisodes, 12);
      expect(items.first.updatedAt, DateTime.utc(2026, 3, 7, 13, 10));
      expect(items.map((e) => e.watchedEpisodes), [3, 4]);
    },
  );

  for (final username in [null, 'sample']) {
    test(
      '401 on ${username == null ? '/me' : 'collection'} rejects the personal token without anonymous retry',
      () async {
        final paths = <String>[];
        final rejected = <String>[];
        final repo = _repo((req) async {
          paths.add(req.url.path);
          return http.Response('', 401);
        }, reject: (credential) async => rejected.add(credential.token));
        await expectLater(
          repo.fetchWatchingCollection(username: username),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Bangumi 令牌无效或已过期，请重新验证',
            ),
          ),
        );
        expect(
          await repo.markEpisodeWatched(subjectId: 1, episodeId: 72),
          false,
        );
        expect(paths, [
          username == null ? '/v0/me' : '/v0/users/sample/collections',
        ]);
        expect(rejected, [_credential.token]);
      },
    );
  }

  for (final status in [400, 404]) {
    test('$status follows once, then retries the same episode', () async {
      final calls = <(String, String, int)>[];
      final repo = _repo((req) async {
        expect(req.url.origin, 'https://api.bgm.tv');
        expect(req.headers['authorization'], 'Bearer ${_credential.token}');
        expect(req.headers['content-type'], contains('application/json'));
        calls.add((
          req.method,
          req.url.path,
          jsonDecode(req.body)['type'] as int,
        ));
        return http.Response('', calls.length == 1 ? status : 204);
      });
      expect(await repo.markEpisodeWatched(subjectId: 1, episodeId: 72), true);
      expect(calls, [
        ('PUT', '/v0/users/-/collections/-/episodes/72', 2),
        ('POST', '/v0/users/-/collections/1', 3),
        ('PUT', '/v0/users/-/collections/-/episodes/72', 2),
      ]);
    });
  }

  test(
    'rate limit, rejected token and network errors are non-throwing for writes',
    () async {
      var calls = 0;
      final limited = _repo((_) async {
        calls++;
        return http.Response('', 429, headers: {'retry-after': '30'});
      });
      for (var i = 0; i < 2; i++) {
        expect(
          await limited.markEpisodeWatched(subjectId: 1, episodeId: 88),
          false,
        );
      }
      expect(calls, 1);
      var rejected = 0;
      final denied = _repo(
        (req) async => http.Response('', req.method == 'PUT' ? 404 : 401),
        reject: (_) async => rejected++,
      );
      expect(
        await denied.markEpisodeWatched(subjectId: 1, episodeId: 88),
        false,
      );
      expect(rejected, 1);
      final offline = _repo((_) async => throw http.ClientException('offline'));
      expect(
        await offline.markEpisodeWatched(subjectId: 1, episodeId: 88),
        false,
      );
    },
  );

  test(
    'build-time metadata credentials alone never authorize private reads or writes',
    () async {
      final repo = BangumiMetadataRepository(
        publicMetadataToken: 'mock-public-token',
        client: MockClient((_) async => fail('no private request allowed')),
      );
      await expectLater(repo.fetchWatchingCollection(), throwsFormatException);
      expect(await repo.markEpisodeWatched(subjectId: 1, episodeId: 72), false);
      final invalid = _repo(
        (_) async => _json({
          'data': [
            {'ep_status': 5},
          ],
        }),
      );
      await expectLater(
        invalid.fetchWatchingCollection(username: 'sample'),
        throwsFormatException,
      );
    },
  );

  test(
    'outbound sync honors opt-in and identity, coalesces overlapping events, retries a failure',
    () async {
      final requests = <String>[];
      final release = Completer<void>();
      final container = _container(
        _repo((req) async {
          requests.add(req.url.path);
          await release.future;
          return http.Response('', requests.length == 1 ? 503 : 204);
        }),
      );
      await container.read(animeControllerProvider.future);
      final service = container.read(bangumiSyncServiceProvider);
      Future<bool> sync({
        bool enabled = true,
        AnimeSubject? subject,
        int id = 72,
      }) => service.syncEpisodeWatchedIfEnabled(
        enabled: enabled,
        subject: subject ?? _subject(1),
        episode: _ep(id, 4),
      );
      expect(await sync(enabled: false), false);
      expect(await sync(subject: _subject(1).copyWith(source: 'local')), false);
      expect(await sync(subject: _subject(0)), false);
      expect(await sync(id: -4), false);
      expect(requests, isEmpty);
      final first = sync();
      final overlap = sync();
      release.complete();
      expect(await Future.wait([first, overlap]), [false, false]);
      expect(await sync(), true);
      expect(await sync(), false);
      expect(requests, List.filled(2, '/v0/users/-/collections/-/episodes/72'));
    },
  );

  test(
    'catalogue-generated IDs resolve to official episode IDs; missing numbers never mark another episode',
    () async {
      final calls = <String>[];
      final container = _container(
        _repo((req) async {
          calls.add(req.url.path);
          if (req.method == 'GET') {
            return _json({
              'data': [
                {'id': 72, 'ep': 4},
              ],
            });
          }
          return http.Response('', 204);
        }),
      );
      await container.read(animeControllerProvider.future);
      final service = container.read(bangumiSyncServiceProvider);
      Future<bool> sync(int id, int number) =>
          service.syncEpisodeWatchedIfEnabled(
            enabled: true,
            subject: _subject(1),
            episode: _ep(id, number),
          );
      final localId = stableInt63(
        stableEpisodeKey(subjectKey: 'bangumi:1', normalizedNumber: 4),
      );
      expect(await sync(localId, 4), true);
      expect(await sync(72, 4), false);
      expect(await sync(1005, 5), false);
      expect(calls, [
        '/v0/episodes',
        '/v0/users/-/collections/-/episodes/72',
        '/v0/episodes',
      ]);
    },
  );

  test(
    'import is idempotent, completes a partial episode, and never rewinds local history',
    () async {
      final repo = _repo(
        (req) async => req.url.path == '/v0/me'
            ? _json({'username': 'sample'})
            : _json({
                'data': [
                  _watching(1, 4),
                  _watching(2, 8),
                  _watching(3, 3),
                  _watching(4, 0),
                ],
              }),
      );
      final container = _container(repo);
      await container.read(animeControllerProvider.future);
      final service = container.read(bangumiSyncServiceProvider);
      final imported = await service.importWatchingToLibrary();
      expect(
        (
          imported.totalFetched,
          imported.newlyFollowed,
          imported.progressUpdated,
        ),
        (4, 3, 2),
      );
      final state = container.read(animeControllerProvider).requireValue;
      expect(state.following.map((e) => e.subject.id).toSet(), {1, 2, 3, 4});
      final history = {
        for (final entry in state.history) entry.subject.id: entry,
      };
      expect((history[1]!.episode!.number, history[1]!.episode!.id), (4, -4));
      expect(
        (history[2]!.episode!.number, history[2]!.positionSeconds),
        (9, 43),
      );
      expect((history[3]!.episode!.id, history[3]!.positionSeconds), (93, 0));
      expect(history.containsKey(4), false);
      final again = await service.importWatchingToLibrary();
      expect((again.newlyFollowed, again.progressUpdated), (0, 0));
    },
  );

  testWidgets(
    'personal token binding, import summary, switch and clear are usable offline',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final calls = <String>[];
      final client = MockClient((req) async {
        expect(req.headers['authorization'], 'Bearer ${_credential.token}');
        calls.add(req.url.path);
        return req.url.path == '/v0/me'
            ? _json({'username': 'sample', 'id': 123})
            : _json({
                'data': [_watching(4, 3)],
              });
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(720, 1000);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeControllerProvider.overrideWith(_TestLibrary.new),
            bangumiMetadataHttpClientProvider.overrideWithValue(client),
            bangumiBuiltInAccessTokenProvider.overrideWithValue(
              'mock-build-time-token',
            ),
          ],
          child: const MaterialApp(home: BangumiSyncPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未绑定'), findsOneWidget);
      final input = find.byType(TextField);
      expect(tester.widget<TextField>(input).obscureText, true);
      await tester.enterText(input, _credential.token);
      await tester.tap(find.text('验证并保存'));
      await tester.pumpAndSettle();
      expect(find.text('已绑定：sample'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('bangumiImportWatchingButton')),
      );
      await tester.pumpAndSettle();
      expect(find.text('共读取 1 部在看，新增追番 1 部，更新进度 1 部'), findsOneWidget);
      final toggle = find.byKey(const ValueKey('bangumiAutoSyncSwitch'));
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, true);
      await tester.tap(find.text('清除令牌'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
      expect(find.text('未绑定'), findsOneWidget);
      expect(calls, ['/v0/me', '/v0/me', '/v0/users/sample/collections']);
      expect(tester.takeException(), isNull);
    },
  );
}

class _TestLibrary extends AnimeController {
  @override
  Future<AnimeState> build() async => AnimeState(
    homeFeed: AnimeHomeFeed.fromJson({'hero': _subject(1).toJson()}),
    following: [_entry(1)],
    history: [
      _entry(2, ep: _ep(92, 9, subject: 2), pos: 43),
      _entry(3, ep: _ep(93, 3, subject: 3), pos: 50),
    ],
  );
  @override
  Future<bool> toggleFollowing(AnimeSubject subject) async {
    final s = state.requireValue;
    expect(
      s.following.any((e) => sameSubjectIdentity(e.subject, subject)),
      false,
      reason: 'import must never toggle off a local follow',
    );
    state = AsyncData(
      s.copyWith(following: [...s.following, _entry(subject.id)]),
    );
    return true;
  }

  @override
  Future<bool> addHistory(
    AnimeSubject subject,
    AnimeEpisode? episode, {
    int? expectedAccountContextVersion,
  }) async {
    final s = state.requireValue;
    state = AsyncData(
      s.copyWith(
        history: [
          _entry(subject.id, ep: episode),
          ...s.history.where((e) => !sameSubjectIdentity(e.subject, subject)),
        ],
      ),
    );
    return true;
  }

  @override
  Future<void> updatePlaybackProgress(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required Duration position,
    required Duration duration,
    int? expectedAccountContextVersion,
  }) async {
    expect(position, duration);
    await addHistory(subject, episode);
  }

  @override
  Future<void> updateMisc(MiscSettings settings) async =>
      state = AsyncData(state.requireValue.copyWith(misc: settings));
}
