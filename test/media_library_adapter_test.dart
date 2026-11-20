import 'dart:async';
import 'dart:convert';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/local_route_ranker.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/player/playback_line_display.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/sources/media_library_adapter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'Emby prefers TMDB identity and opens an original stream without persisting headers on the line',
    () async {
      http.Client createClient() => MockClient((request) async {
        expect(request.url.path, '/emby/Items');
        expect(request.url.queryParameters['AnyProviderIdEquals'], 'tmdb.42');
        expect(request.url.queryParameters['Fields'], contains('ProviderIds'));
        expect(request.url.queryParameters['IncludeItemTypes'], 'Movie');
        expect(request.headers['x-emby-token'], 'fixture-emby');
        expect(request.followRedirects, isFalse);
        return _items([
          {
            'Id': 'wrong-film',
            'Type': 'Movie',
            'ProviderIds': {'Tmdb': '43'},
          },
          {
            'Id': 'right-film',
            'Type': 'Movie',
            'ProviderIds': {'Tmdb': '42'},
          },
        ]);
      });
      final initial = MediaLibraryAdapter(createClient: createClient);
      await _add(
        initial,
        kind: MediaLibraryKind.emby,
        endpoint: 'https://nas.local/emby',
      );
      // A separately constructed adapter should restore saved libraries locally.
      final adapter = MediaLibraryAdapter(createClient: createClient);
      final line = await adapter.lookup(_movie(), _episode()).single;
      expect(
        line.url,
        'https://nas.local/emby/Videos/right-film/stream?static=true',
      );
      expect(line.headers, isEmpty);
      expect(line.quality, '原画');
      expect(line.id, isNot(contains('fixture-emby')));
      expect(line.clientVerified, isFalse); // Matching isn't decoding.
      expect(playbackLineCanStartImmediately(line), isTrue);
      expect(
        LocalRouteRanker.instance.cleanlinessTierOf(line),
        RouteCleanlinessTier.clean,
      );
      expect(LocalRouteRanker.canRace(line), isFalse);
      final open = adapter.playbackRequestFor(line);
      expect(open.origin, Uri.parse('https://nas.local/emby/'));
      expect(open.headers, {'X-Emby-Token': 'fixture-emby'});
      expect(
        await adapter.removeLibrary((await adapter.libraries())!.single.id),
        isTrue,
      );
      expect(() => adapter.playbackRequestFor(line), throwsStateError);
      expect(await MediaLibraryAdapter().libraries(), isEmpty);
    },
  );

  test(
    'Jellyfin checks ProviderIds and plays the exact season and episode, not the global episode number',
    () async {
      final requests = <String>[];
      final adapter = MediaLibraryAdapter(
        createClient: () => MockClient((request) async {
          requests.add(request.url.path);
          expect(
            request.headers['authorization'],
            contains('Token="fixture-jellyfin"'),
          );
          if (request.url.path.endsWith('/Items')) {
            expect(request.url.queryParameters['IncludeItemTypes'], 'Series');
            expect(request.url.queryParameters['AnyProviderIdEquals'], isNull);
            if (request.url.queryParameters.containsKey('SearchTerm')) {
              return _items([
                {
                  'Id': 'same-title',
                  'Type': 'Series',
                  'Name': 'Sample Series',
                  'ProviderIds': {'Tmdb': '111'},
                },
              ]);
            }
            expect(request.url.queryParameters['HasTmdbId'], 'true');
            return _items([
              {
                'Id': 'real-show',
                'Type': 'Series',
                'Name': 'Localized title',
                'ProviderIds': {'tmdb': '68'},
              },
            ]);
          }
          expect(request.url.path, '/jellyfin/Shows/real-show/Episodes');
          expect(request.url.queryParameters['Season'], '2');
          return _items([
            {
              'Id': 'wrong-season',
              'Type': 'Episode',
              'ParentIndexNumber': 1,
              'IndexNumber': 3,
            },
            {
              'Id': 'wrong-episode',
              'Type': 'Episode',
              'ParentIndexNumber': 2,
              'IndexNumber': 14,
            },
            {
              'Id': 'episode-file',
              'Type': 'Episode',
              'ParentIndexNumber': 2,
              'IndexNumber': 3,
            },
          ]);
        }),
      );
      await _add(
        adapter,
        kind: MediaLibraryKind.jellyfin,
        endpoint: 'https://nas.local/jellyfin',
      );
      final line = await adapter
          .lookup(
            _subject('Sample Series', source: 'tmdb:series:68'),
            _episode(number: 14, season: 2, seasonEpisode: 3),
          )
          .single;
      expect(requests, [
        '/jellyfin/Items',
        '/jellyfin/Items',
        '/jellyfin/Shows/real-show/Episodes',
      ]);
      expect(
        line.url,
        'https://nas.local/jellyfin/Videos/episode-file/stream?static=true',
      );
    },
  );

  test(
    'Bangumi can find a server series by its original title without a TMDB ID',
    () async {
      final adapter = MediaLibraryAdapter(
        createClient: () => MockClient((request) async {
          if (request.url.path.endsWith('/Items')) {
            return _items([
              {
                'Id': 'misleading',
                'Type': 'Series',
                'Name': 'Sample Anime: The Movie',
              },
              {
                'Id': 'anime',
                'Type': 'Series',
                'Name': '示例番剧',
                'OriginalTitle': 'Sample Anime',
              },
            ]);
          }
          expect(request.url.path, '/Shows/anime/Episodes');
          expect(request.url.queryParameters['Season'], '1');
          return _items([
            {
              'Id': 'bangumi-ep',
              'Type': 'Episode',
              'IndexNumber': 2,
              'ParentIndexNumber': 1,
            },
          ]);
        }),
      );
      await _add(
        adapter,
        kind: MediaLibraryKind.jellyfin,
        endpoint: 'https://nas.local/',
      );
      final line = await adapter
          .lookup(
            _subject('Sample Anime', source: 'bangumi'),
            _episode(number: 2),
          )
          .single;
      expect(
        line.url,
        'https://nas.local/Videos/bangumi-ep/stream?static=true',
      );
    },
  );

  test(
    'WebDAV caches its nested listing and matches a Bangumi season and a movie by year',
    () async {
      var now = DateTime(2026);
      final urls = <Uri>[];
      final adapter = MediaLibraryAdapter(
        now: () => now,
        createClient: () => MockClient((request) async {
          urls.add(request.url);
          expect(request.method, 'PROPFIND');
          expect(request.headers['depth'], '1');
          expect(
            request.headers['authorization'],
            'Basic ${base64Encode(utf8.encode('viewer:fixture-webdav'))}',
          );
          expect(request.followRedirects, isFalse);
          return switch (request.url.path) {
            '/dav/Library/' => _dav([
              _davEntry('/dav/Library/', directory: true),
              _davEntry('/dav/Library/Series/', directory: true),
              _davEntry('/dav/Library/Sample.Film.1999.mp4'),
              _davEntry('/dav/Library/Sample.Film.2024.2160p.mp4'),
              _davEntry('/dav/Library/mp4'),
              _davEntry(
                'https://outside.invalid/dav/Library/ToSkip/',
                directory: true,
              ),
              _davEntry('/dav/Other/ToSkip/', directory: true),
            ]),
            '/dav/Library/Series/' => _dav([
              _davEntry('/dav/Library/Series/Example.Anime.S01E03.mkv'),
              _davEntry(
                '/dav/Library/Series/${Uri.encodeComponent('示例动画.S02E03.2160p.mkv')}',
              ),
            ]),
            _ => throw StateError('Unexpected listing'),
          };
        }),
      );
      await _add(
        adapter,
        kind: MediaLibraryKind.webdav,
        endpoint: 'https://nas.local/dav/Library',
      );
      final subject = _subject(
        '示例动画 第2季',
        source: 'bangumi',
        originalTitle: 'Example Anime Season 2',
      );
      final matches = await Future.wait([
        adapter.lookup(subject, _episode(number: 3)).single,
        adapter.lookup(_movie(), _episode()).single,
      ]);
      expect(
        Uri.parse(matches.first.url!).pathSegments.last,
        '示例动画.S02E03.2160p.mkv',
      );
      expect(matches.first.format, 'MKV');
      expect(
        matches.last.url,
        'https://nas.local/dav/Library/Sample.Film.2024.2160p.mp4',
      );
      expect(matches.last.headers, isEmpty);
      expect(
        adapter.playbackRequestFor(matches.first).headers['Authorization'],
        startsWith('Basic '),
      );
      expect(urls.map((uri) => uri.path), [
        '/dav/Library/',
        '/dav/Library/Series/',
      ]);
      now = now.add(const Duration(minutes: 11));
      expect(await adapter.lookup(_movie(), _episode()).toList(), hasLength(1));
      expect(urls, hasLength(4));
      expect(
        await adapter.lookup(_movie(), _episode(), forceRefresh: true).toList(),
        hasLength(1),
      );
      expect(urls, hasLength(6));
    },
  );

  test(
    'auth failures and off-origin redirects do not block another configured library',
    () async {
      final calls = <String>[];
      final slow = Completer<http.Response>();
      final adapter = MediaLibraryAdapter(
        createClient: () => MockClient((request) async {
          calls.add(request.url.host);
          expect(request.followRedirects, isFalse);
          return switch (request.url.host) {
            'denied.local' => slow.future,
            'redirect.local' => http.Response(
              '',
              302,
              headers: {'location': 'https://outside.invalid/Items'},
            ),
            'working.local' => _items([
              {
                'Id': 'movie',
                'Type': 'Movie',
                'ProviderIds': {'Tmdb': '42'},
              },
            ]),
            _ => throw StateError('Unexpected host'),
          };
        }),
      );
      for (final host in ['denied.local', 'redirect.local', 'working.local']) {
        await _add(
          adapter,
          kind: MediaLibraryKind.emby,
          endpoint: 'https://$host/',
        );
      }
      final live = StreamIterator(adapter.lookup(_movie(), _episode()));
      try {
        expect(await live.moveNext(), isTrue);
        expect(live.current.url, startsWith('https://working.local/'));
        expect(slow.isCompleted, isFalse);
      } finally {
        slow.complete(http.Response('', 401));
      }
      expect(await live.moveNext(), isFalse);
      await live.cancel();
      expect(
        calls,
        unorderedEquals(['denied.local', 'redirect.local', 'working.local']),
      );
    },
  );

  test('fails closed on bad endpoints or unavailable secure storage', () async {
    final readFailure = MediaLibraryAdapter(
      storage: const _FailingStorage(failReads: true),
      createClient: () => throw StateError('No request without credentials'),
    );
    final writeFailure = MediaLibraryAdapter(storage: const _FailingStorage());
    expect(await readFailure.libraries(), isNull);
    expect(await readFailure.lookup(_movie(), _episode()).toList(), isEmpty);
    expect(await _save(readFailure, endpoint: 'https://nas.local/'), isFalse);
    expect(await _save(writeFailure, endpoint: 'https://nas.local/'), isFalse);
    expect(await writeFailure.libraries(), isEmpty);
    for (final url in [
      'ftp://nas.local/',
      'https://viewer:fixture@nas.local/',
      'https://nas.local/?api_key=fixture',
    ]) {
      expect(() => _save(writeFailure, endpoint: url), throwsFormatException);
    }
  });

  test(
    'supports LAN HTTP Emby username/password auth, anonymous WebDAV, and testConnection',
    () async {
      final seenRequests = <http.Request>[];
      final adapter = MediaLibraryAdapter(
        createClient: () => MockClient((request) async {
          seenRequests.add(request);
          if (request.url.path == '/Users/AuthenticateByName') {
            expect(request.method, 'POST');
            expect(
              request.headers['x-emby-authorization'],
              contains('Client="Zeluna"'),
            );
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['Pw'] != 'pass123') return http.Response('', 401);
            return http.Response(
              jsonEncode({
                'AccessToken': 'issued-token-99',
                'User': {'Id': 'u42'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path == '/Users/u42/Items') {
            expect(request.headers['x-emby-token'], 'issued-token-99');
            return _items([
              {
                'Id': 'lan-movie',
                'Type': 'Movie',
                'ProviderIds': {'Tmdb': '42'},
              },
            ]);
          }
          if (request.method == 'PROPFIND' && request.url.path == '/dav/') {
            expect(request.headers['authorization'], isNull);
            return _dav([
              _davEntry('/dav/', directory: true),
              _davEntry('/dav/Sample.Film.2024.mkv'),
            ]);
          }
          return http.Response('', 404);
        }),
      );

      final auth = await adapter.authenticateApiUser(
        kind: MediaLibraryKind.emby,
        endpoint: 'http://192.168.1.10:8096',
        username: 'alice',
        password: 'pass123',
      );
      expect(auth.token, 'issued-token-99');
      expect(auth.userId, 'u42');

      expect(
        await adapter.saveLibrary(
          name: '家庭 Emby',
          kind: MediaLibraryKind.emby,
          endpoint: 'http://192.168.1.10:8096',
          secret: auth.token,
          userId: auth.userId,
        ),
        isTrue,
      );
      expect(
        await adapter.saveLibrary(
          name: '本地 Alist',
          kind: MediaLibraryKind.webdav,
          endpoint: 'http://127.0.0.1:5244/dav',
          username: '',
          secret: '',
        ),
        isTrue,
      );
      expect(
        await adapter.testConnection(
          kind: MediaLibraryKind.webdav,
          endpoint: 'http://127.0.0.1:5244/dav',
          secret: '',
        ),
        contains('成功'),
      );
      final lines = await adapter.lookup(_movie(), _episode()).toList();
      expect(lines, hasLength(2));
      expect(
        lines.map((l) => l.url),
        unorderedEquals([
          'http://192.168.1.10:8096/Videos/lan-movie/stream?static=true',
          'http://127.0.0.1:5244/dav/Sample.Film.2024.mkv',
        ]),
      );
      final davLine = lines.firstWhere((l) => l.url!.contains('127.0.0.1'));
      expect(adapter.playbackRequestFor(davLine).headers, isEmpty);
    },
  );

  test(
    'WebDAV matches folder-based Chinese/fansub anime, series, and movie layouts',
    () async {
      final adapter = MediaLibraryAdapter(
        createClient: () => MockClient((request) async {
          final path = Uri.decodeComponent(request.url.path);
          return switch (path) {
            '/dav/' => _dav([
              _davEntry('/dav/', directory: true),
              _davEntry('/dav/${Uri.encodeComponent('葬送的芙莉莲')}/', directory: true),
              _davEntry('/dav/${Uri.encodeComponent('庆余年')}/', directory: true),
              _davEntry('/dav/${Uri.encodeComponent('奥本海默 (2023)')}/', directory: true),
              _davEntry(
                '/dav/${Uri.encodeComponent('[LoliHouse] 葬送的芙莉莲 - 05 [1080p].mkv')}',
              ),
            ]),
            '/dav/葬送的芙莉莲/' => _dav([
              _davEntry('/dav/${Uri.encodeComponent('葬送的芙莉莲')}/Season%201/', directory: true),
            ]),
            '/dav/葬送的芙莉莲/Season 1/' => _dav([
              _davEntry('/dav/${Uri.encodeComponent('葬送的芙莉莲')}/Season%201/03.mkv'),
            ]),
            '/dav/庆余年/' => _dav([
              _davEntry('/dav/${Uri.encodeComponent('庆余年')}/S02/', directory: true),
            ]),
            '/dav/庆余年/S02/' => _dav([
              _davEntry('/dav/${Uri.encodeComponent('庆余年')}/S02/${Uri.encodeComponent('第04集.mp4')}'),
            ]),
            '/dav/奥本海默 (2023)/' => _dav([
              _davEntry('/dav/${Uri.encodeComponent('奥本海默 (2023)')}/Oppenheimer.trailer.mp4'),
              _davEntry('/dav/${Uri.encodeComponent('奥本海默 (2023)')}/Oppenheimer.2160p.mkv'),
            ]),
            _ => http.Response('', 404),
          };
        }),
      );
      await _add(
        adapter,
        kind: MediaLibraryKind.webdav,
        endpoint: 'http://192.168.1.2:5244/dav',
      );
      final frieren = _subject('葬送的芙莉莲', source: 'bangumi');
      final ep3 = await adapter.lookup(frieren, _episode(number: 3)).single;
      expect(Uri.decodeComponent(ep3.url!), endsWith('/Season 1/03.mkv'));
      final ep5 = await adapter.lookup(frieren, _episode(number: 5)).single;
      expect(Uri.decodeComponent(ep5.url!), contains('[LoliHouse] 葬送的芙莉莲 - 05'));

      final qyn = _subject('庆余年', source: 'tmdb:tv:99');
      final s2e4 = await adapter
          .lookup(qyn, _episode(number: 50, season: 2, seasonEpisode: 4))
          .single;
      expect(Uri.decodeComponent(s2e4.url!), endsWith('/S02/第04集.mp4'));

      final oppenheimer = AnimeSubject(
        id: 2,
        title: '奥本海默',
        originalTitle: 'Oppenheimer',
        source: 'tmdb:movie:872585',
        summary: '',
        coverUrl: null,
        bannerUrl: null,
        date: '2023-07-21',
        platform: '',
        language: '',
        region: '',
        status: '',
        categories: const [],
        tags: const [],
        totalEpisodes: 1,
      );
      final film = await adapter.lookup(oppenheimer, _episode()).single;
      expect(Uri.decodeComponent(film.url!), endsWith('Oppenheimer.2160p.mkv'));
    },
  );

  test(
    'discovery surfaces a private line in quick and full playback, but not offline download lookup',
    () async {
      var wires = 0;
      final adapter = MediaLibraryAdapter(
        createClient: () => MockClient((_) async {
          wires++;
          return _items([
            {
              'Id': 'movie',
              'Type': 'Movie',
              'ProviderIds': {'Tmdb': '42'},
            },
          ]);
        }),
      );
      await _add(
        adapter,
        kind: MediaLibraryKind.emby,
        endpoint: 'https://nas.local/',
      );
      final discovery = PlaybackDiscoveryController(
        backendRepository: (_) => null,
        ruleRepository: (_) => const EmptyPlaybackSourceRepository(),
        verifyLine:
            (
              line, {
              enrichMetadata = true,
              forceRefresh = false,
              cancellationToken,
            }) => throw StateError(
              'Private media must not use the public verifier',
            ),
        isContextCurrent: (_) => true,
        clearRuleRuntimeCaches: () {},
        mediaLibrary: adapter,
      );
      addTearDown(discovery.dispose);
      discovery.loadForAccount(
        accountId: null,
        contextVersion: 1,
        services: const ExternalServiceSettings(),
        ruleState: const RulePluginState(),
        history: const [],
      );
      final movie = _movie();
      final episode = _episode();
      final quick = (await discovery.linesForEpisode(movie, episode)).single;
      expect(quick, isA<MediaLibraryPlaybackLine>());
      expect(await discovery.verifyPlaybackLine(quick), same(quick));
      final full = await discovery
          .lineUpdatesForEpisode(movie, episode)
          .toList();
      expect(full.last.lines.single.id, quick.id);
      expect(full.last.lines.single.headers, isEmpty);
      expect(
        rankPlaybackLinesForStartup([
          const PlaybackLine(
            id: 'public',
            episodeId: 1,
            providerId: 'public',
            providerName: 'Public',
            title: 'Film',
            quality: 'HD',
            format: 'MP4',
            url: 'https://public.invalid/file.mp4',
            clientVerified: true,
            available: true,
          ),
          quick,
        ]).first,
        same(quick),
      );
      final before = wires;
      final downloadLines = await discovery.downloadLinesForEpisode(
        movie,
        episode,
      );
      expect(downloadLines.whereType<MediaLibraryPlaybackLine>(), isEmpty);
      expect(wires, before);
    },
  );
}

Future<void> _add(
  MediaLibraryAdapter adapter, {
  required MediaLibraryKind kind,
  required String endpoint,
}) async {
  expect(
    await adapter.saveLibrary(
      name: kind.label,
      kind: kind,
      endpoint: endpoint,
      username: 'viewer',
      secret: 'fixture-${kind.name}',
    ),
    isTrue,
  );
}

Future<bool> _save(MediaLibraryAdapter adapter, {required String endpoint}) =>
    adapter.saveLibrary(
      name: 'Emby fixture',
      kind: MediaLibraryKind.emby,
      endpoint: endpoint,
      secret: 'fixture-emby',
    );

http.Response _items(List<Map<String, Object>> items) => http.Response(
  jsonEncode({'Items': items}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

String _davEntry(String href, {bool directory = false}) =>
    '<D:response><D:href>$href</D:href><D:propstat><D:prop>'
    '<D:resourcetype>${directory ? '<D:collection/>' : ''}</D:resourcetype>'
    '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';

http.Response _dav(List<String> responses) => http.Response(
  '<D:multistatus xmlns:D="DAV:">${responses.join()}</D:multistatus>',
  207,
);

AnimeSubject _movie() => _subject('Sample Film', source: 'tmdb:movie:42');

AnimeSubject _subject(
  String title, {
  required String source,
  String? originalTitle,
}) => AnimeSubject(
  id: 1,
  title: title,
  originalTitle: originalTitle ?? title,
  source: source,
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2024-01-01',
  platform: '',
  language: '',
  region: '',
  status: '',
  categories: const [],
  tags: const [],
  totalEpisodes: 30,
);

AnimeEpisode _episode({int number = 1, int? season, int? seasonEpisode}) =>
    AnimeEpisode(
      id: number,
      subjectId: 1,
      number: number,
      title: '',
      airdate: null,
      duration: '',
      description: '',
      seasonNumber: season,
      seasonEpisodeNumber: seasonEpisode,
    );

class _FailingStorage extends FlutterSecureStorage {
  const _FailingStorage({this.failReads = false});

  final bool failReads;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failReads) throw StateError('Fixture secure storage unavailable');
    return super.read(key: key);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('Fixture secure storage unavailable');
  }
}
