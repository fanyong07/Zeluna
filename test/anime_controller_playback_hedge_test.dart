import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime/src/data/anime_controller.dart';
import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:anime/src/data/bangumi_metadata_repository.dart';
import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/sources/source_catalog_models.dart';
import 'package:anime/src/sources/source_catalog_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_cloud_account_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(RulePlaybackSourceRepository.clearRuntimeCaches);
  tearDown(RulePlaybackSourceRepository.clearRuntimeCaches);

  test(
    'a fast empty backend starts rule fallback without wasting the hedge',
    () async {
      final harness = await _PlaybackHarness.create(
        playbackResponse: (_) async => http.Response('[]', 200),
        ruleId: 'test:fast-empty-fallback',
      );
      addTearDown(harness.dispose);

      final stopwatch = Stopwatch()..start();
      final lines = await harness.controller.linesForEpisodeMode(
        _subject,
        _episode,
      );
      stopwatch.stop();

      expect(lines.where((line) => line.available), hasLength(1));
      expect(lines.first.providerId, 'test:fast-empty-fallback');
      expect(harness.quickPlaybackRequests, 1);
      expect(harness.resolver.readyCalls, 1);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 700)),
        reason:
            'an already-empty backend should not consume the 900 ms head start',
      );
    },
  );

  test('a ready rule line wins after the slow backend head start', () async {
    final backendResponse = Completer<http.Response>();
    final harness = await _PlaybackHarness.create(
      playbackResponse: (_) => backendResponse.future,
      ruleId: 'test:slow-backend-fallback',
    );
    addTearDown(() async {
      if (!backendResponse.isCompleted) {
        backendResponse.complete(http.Response('[]', 200));
      }
      await harness.dispose();
    });

    final stopwatch = Stopwatch()..start();
    final lines = await harness.controller.linesForEpisodeMode(
      _subject,
      _episode,
    );
    stopwatch.stop();

    expect(lines.where((line) => line.available), hasLength(1));
    expect(lines.first.providerId, 'test:slow-backend-fallback');
    expect(harness.resolver.readyCalls, 1);
    expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 700)));
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'the six-second backend timeout must not hold a ready rule line',
    );
  });

  test(
    'a verified backend response is cached and exposed to the detail page',
    () async {
      final harness = await _PlaybackHarness.create(
        playbackResponse: (_) async => http.Response(
          jsonEncode([
            {
              'url': 'https://cdn.example/video.m3u8',
              'source': 'maccms:test',
              'title': '第1集',
              'format': 'hls',
              'status': 'server_verified',
              'available': true,
              'cached': true,
            },
          ]),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
        ruleId: 'test:unused-fallback',
      );
      addTearDown(harness.dispose);

      final first = await harness.controller.linesForEpisodeMode(
        _subject,
        _episode,
      );
      final prefetched = harness.controller.prefetchedLineForEpisode(
        _subject,
        _episode,
      );
      final second = await harness.controller.linesForEpisodeMode(
        _subject,
        _episode,
      );

      expect(first.single.serverVerified, isTrue);
      expect(prefetched?.id, first.single.id);
      expect(second.single.id, first.single.id);
      expect(harness.quickPlaybackRequests, 1);
      expect(harness.resolver.calls, 0);
    },
  );

  test(
    'a client-verified prefetch is reused without probing the media twice',
    () async {
      final harness = await _PlaybackHarness.create(
        playbackResponse: (_) async => http.Response(
          jsonEncode([
            {
              'url': 'https://cdn.example/candidate.m3u8',
              'source': 'maccms:test',
              'title': 'Episode 1',
              'format': 'hls',
              'status': 'client_probe_required',
              'available': false,
              'cached': false,
              'cache_state': 'cold',
            },
          ]),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
        ruleId: 'test:slower-fallback',
      );
      addTearDown(harness.dispose);

      final first = await harness.controller.linesForEpisodeMode(
        _subject,
        _episode,
      );
      final prefetched = harness.controller.prefetchedLineForEpisode(
        _subject,
        _episode,
      );
      final second = await harness.controller.linesForEpisodeMode(
        _subject,
        _episode,
      );

      expect(first.single.clientVerified, isTrue);
      expect(first.single.available, isTrue);
      expect(prefetched?.id, first.single.id);
      expect(prefetched?.clientVerified, isTrue);
      expect(second.single.id, first.single.id);
      expect(harness.quickPlaybackRequests, 1);
      expect(harness.resolver.verifyCalls, 1);
      expect(harness.resolver.forceRefreshValues, [isFalse]);
    },
  );

  test('startup ranking keeps tail-moov MP4 behind streamable lines', () {
    final ranked = rankPlaybackLinesForStartup([
      _startupLine('tail', PlaybackStartupProfile.mp4TailMoov, latencyMs: 5),
      _startupLine('unknown', PlaybackStartupProfile.unknown, latencyMs: 10),
      _startupLine('hls', PlaybackStartupProfile.hls, latencyMs: 30),
      _startupLine('fast', PlaybackStartupProfile.mp4FastStart, latencyMs: 80),
    ]);

    expect(ranked.map((line) => line.id), ['fast', 'hls', 'unknown', 'tail']);
  });

  test('startup ranking keeps input order when every score is equal', () {
    final ranked = rankPlaybackLinesForStartup([
      _startupLine('first', PlaybackStartupProfile.hls, latencyMs: 80),
      _startupLine('second', PlaybackStartupProfile.hls, latencyMs: 80),
      _startupLine('third', PlaybackStartupProfile.hls, latencyMs: 80),
    ]);

    expect(ranked.map((line) => line.id), ['first', 'second', 'third']);
  });

  test(
    'a cancelled backend lookup cannot populate the prefetch cache',
    () async {
      final backendResponse = Completer<http.Response>();
      final harness = await _PlaybackHarness.create(
        playbackResponse: (_) => backendResponse.future,
        ruleId: 'test:cancelled-backend-fallback',
      );
      addTearDown(() async {
        if (!backendResponse.isCompleted) {
          backendResponse.complete(http.Response('[]', 200));
        }
        await harness.dispose();
      });
      final cancellationToken = RulePlaybackCancellationToken();
      final cancelledLookup = harness.controller.linesForEpisodeMode(
        _subject,
        _episode,
        cancellationToken: cancellationToken,
      );
      await _waitUntil(() => harness.quickPlaybackRequests == 1);

      cancellationToken.cancel();
      backendResponse.complete(
        http.Response(
          jsonEncode([
            {
              'url': 'https://cdn.example/cancelled.m3u8',
              'source': 'maccms:test',
              'format': 'hls',
              'status': 'server_verified',
              'available': true,
            },
          ]),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      expect(await cancelledLookup, isEmpty);
      expect(
        harness.controller.prefetchedLineForEpisode(_subject, _episode),
        isNull,
      );
      final retry = await harness.controller.linesForEpisodeMode(
        _subject,
        _episode,
      );
      expect(retry.single.url, 'https://cdn.example/cancelled.m3u8');
      expect(harness.quickPlaybackRequests, 2);
    },
  );

  test(
    'detail prefetch probes three quick lines once and caches the best startup',
    () async {
      const tailUrl = 'https://tail.example/video.mp4';
      const hlsUrl = 'https://hls.example/video.m3u8';
      const fastUrl = 'https://fast.example/video.mp4';
      final harness = await _PlaybackHarness.create(
        playbackResponse: (_) async => http.Response(
          jsonEncode([
            {
              'url': tailUrl,
              'source': 'crawler:tail',
              'title': 'Tail MP4',
              'format': 'mp4',
              'status': 'server_verified',
              'available': true,
            },
            {
              'url': hlsUrl,
              'source': 'crawler:hls',
              'title': 'HLS',
              'format': 'hls',
              'status': 'server_verified',
              'available': true,
            },
            {
              'url': fastUrl,
              'source': 'crawler:fast',
              'title': 'Fast MP4',
              'format': 'mp4',
              'status': 'server_verified',
              'available': true,
            },
          ]),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
        ruleId: 'test:unused-prefetch-fallback',
        probeResults: const {
          tailUrl: (
            latency: Duration(milliseconds: 10),
            startupProfile: PlaybackStartupProfile.mp4TailMoov,
          ),
          hlsUrl: (
            latency: Duration(milliseconds: 20),
            startupProfile: PlaybackStartupProfile.hls,
          ),
          fastUrl: (
            latency: Duration(milliseconds: 40),
            startupProfile: PlaybackStartupProfile.mp4FastStart,
          ),
        },
      );
      addTearDown(harness.dispose);

      final detail = await harness.controller.detail(_subject);
      await _waitUntil(() {
        return harness.controller
                .prefetchedLineForEpisode(detail.subject, detail.episodes.first)
                ?.startupProfile ==
            PlaybackStartupProfile.mp4FastStart;
      });
      final prefetched = harness.controller.prefetchedLineForEpisode(
        detail.subject,
        detail.episodes.first,
      );

      expect(prefetched?.url, fastUrl);
      expect(prefetched?.clientVerified, isTrue);
      expect(harness.quickPlaybackRequests, 1);
      expect(harness.resolver.verifyCalls, 3);
      expect(harness.resolver.maxConcurrentVerifications, 3);
    },
  );

  test('an account switch blocks an old prefetch from writing back', () async {
    const oldUrl = 'https://old-account.example/video.m3u8';
    final verificationGate = Completer<void>();
    final harness = await _PlaybackHarness.create(
      playbackResponse: (_) async => http.Response(
        jsonEncode([
          {
            'url': oldUrl,
            'source': 'crawler:old-account',
            'title': 'Old account line',
            'format': 'hls',
            'status': 'server_verified',
            'available': true,
          },
        ]),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ),
      ruleId: 'test:unused-account-fallback',
      verificationGate: verificationGate.future,
    );
    addTearDown(() async {
      if (!verificationGate.isCompleted) verificationGate.complete();
      await harness.dispose();
    });

    final detail = await harness.controller.detail(_subject);
    await _waitUntil(() => harness.resolver.verifyCalls == 1);
    await harness.controller.registerAccount(
      email: 'prefetch-switch@example.com',
      nickname: 'Prefetch switch',
      password: 'test-pass',
    );
    verificationGate.complete();
    await _waitUntil(() => harness.resolver.activeVerifications == 0);

    expect(
      harness.controller.prefetchedLineForEpisode(
        detail.subject,
        detail.episodes.first,
      ),
      isNull,
    );
  });
}

class _PlaybackHarness {
  _PlaybackHarness({
    required this.root,
    required this.container,
    required this.client,
    required this.controller,
    required this.resolver,
    required int Function() requestCount,
  }) : _requestCount = requestCount;

  final Directory root;
  final ProviderContainer container;
  final http.Client client;
  final AnimeController controller;
  final _ReadyRuleResolver resolver;
  final int Function() _requestCount;

  int get quickPlaybackRequests => _requestCount();

  static Future<_PlaybackHarness> create({
    required FutureOr<http.Response> Function(http.Request request)
    playbackResponse,
    required String ruleId,
    Map<String, ({Duration latency, String startupProfile})> probeResults =
        const {},
    Future<void>? verificationGate,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'anime-controller-playback-hedge-',
    );
    Hive.init(root.path);
    final settings = await Hive.openBox<dynamic>('anime.settings.v2');
    final rule = _rule(ruleId);
    await settings.put('services', _services.toJson());
    await settings.put(
      'rulePlugins',
      RulePluginState(
        installedIds: {rule.id},
        enabledIds: {rule.id},
        approvedPermissionDigests: {
          rule.id: rule.effectiveManifest.permissionDigest,
        },
        customRules: [rule],
      ).toJson(),
    );
    await settings.close();

    var quickPlaybackRequests = 0;
    final client = MockClient((request) async {
      if (request.url.pathSegments.contains('quick-playback')) {
        quickPlaybackRequests++;
        return playbackResponse(request);
      }
      return http.Response('{}', 200);
    });
    final resolver = _ReadyRuleResolver(
      ruleId,
      probeResults: probeResults,
      verificationGate: verificationGate,
    );
    final container = ProviderContainer(
      overrides: [
        cloudAccountServiceProvider.overrideWithValue(
          FakeCloudAccountService(),
        ),
        bangumiCredentialStoreProvider.overrideWithValue(
          BangumiCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        tmdbCredentialStoreProvider.overrideWithValue(
          TmdbCredentialStore(backend: _MemoryCredentialBackend()),
        ),
        sourceCatalogRepositoryProvider.overrideWithValue(
          const _EmptySourceCatalogRepository(),
        ),
        bangumiMetadataRepositoryProvider.overrideWithValue(
          _PlaybackDetailMetadataRepository(),
        ),
        rulePlaybackResolverProvider.overrideWithValue(resolver),
        zelunaBackendHttpClientProvider.overrideWithValue(client),
      ],
    );
    await container.read(animeControllerProvider.future);
    return _PlaybackHarness(
      root: root,
      container: container,
      client: client,
      controller: container.read(animeControllerProvider.notifier),
      resolver: resolver,
      requestCount: () => quickPlaybackRequests,
    );
  }

  Future<void> dispose() async {
    container.dispose();
    client.close();
    await Hive.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _ReadyRuleResolver extends RulePlaybackResolver {
  _ReadyRuleResolver(
    this.readyRuleId, {
    this.probeResults = const {},
    this.verificationGate,
  });

  final String readyRuleId;
  final Map<String, ({Duration latency, String startupProfile})> probeResults;
  final Future<void>? verificationGate;
  int calls = 0;
  int readyCalls = 0;
  int verifyCalls = 0;
  int _activeVerifications = 0;
  int maxConcurrentVerifications = 0;
  final List<bool> forceRefreshValues = <bool>[];

  int get activeVerifications => _activeVerifications;

  @override
  Future<PlaybackLine> verifyPlaybackLine({
    required PlaybackLine line,
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    verifyCalls++;
    forceRefreshValues.add(forceRefresh);
    _activeVerifications++;
    if (_activeVerifications > maxConcurrentVerifications) {
      maxConcurrentVerifications = _activeVerifications;
    }
    final probeResult = probeResults[line.url];
    final latency = probeResult?.latency ?? const Duration(milliseconds: 5);
    try {
      final gate = verificationGate;
      if (gate == null) {
        await Future<void>.delayed(latency);
      } else {
        await gate;
      }
    } finally {
      _activeVerifications--;
    }
    return PlaybackLine(
      id: line.id,
      episodeId: line.episodeId,
      providerId: line.providerId,
      providerName: line.providerName,
      title: line.title,
      quality: line.quality,
      format: line.format,
      url: line.url,
      headers: line.headers,
      latency: latency,
      sizeLabel: line.sizeLabel,
      sizeBytes: line.sizeBytes,
      sizeEstimated: line.sizeEstimated,
      videoWidth: line.videoWidth,
      videoHeight: line.videoHeight,
      bitrate: line.bitrate,
      codecs: line.codecs,
      isLive: line.isLive,
      adaptive: line.adaptive,
      publicHttpOnly: line.publicHttpOnly,
      serverVerified: line.serverVerified,
      requiresClientProbe: false,
      clientVerified: true,
      startupProfile: probeResult?.startupProfile ?? line.startupProfile,
      cacheState: line.cacheState,
      sourceErrorCategory: line.sourceErrorCategory,
      expiresAt: line.expiresAt,
      available: true,
      message: line.message,
    );
  }

  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (rule.id != readyRuleId) return const [];
    readyCalls++;
    return [
      PlaybackLine(
        id: '${rule.id}:${episode.id}',
        episodeId: episode.id,
        providerId: rule.id,
        providerName: rule.name,
        title: episode.displayTitle,
        quality: '1080P',
        format: 'hls',
        url: 'https://fallback.example/video.m3u8',
        available: true,
      ),
    ];
  }
}

class _MemoryCredentialBackend
    implements BangumiCredentialBackend, TmdbCredentialBackend {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _EmptySourceCatalogRepository extends SourceCatalogRepository {
  const _EmptySourceCatalogRepository();

  @override
  Future<SourceCatalogState> loadCatalog({
    Map<String, bool> enabledOverrides = const {},
  }) async => const SourceCatalogState();
}

class _PlaybackDetailMetadataRepository extends BangumiMetadataRepository {
  _PlaybackDetailMetadataRepository()
    : super(client: MockClient((_) async => http.Response('not found', 404)));

  @override
  Future<AnimeDetailBundle> detail(
    int subjectId, {
    AnimeSubject? fallbackSubject,
  }) async => const AnimeDetailBundle(
    subject: _subject,
    episodes: [_episode],
    characters: [],
    staff: [],
    recommendations: [],
  );
}

PlaybackLine _startupLine(
  String id,
  String startupProfile, {
  required int latencyMs,
}) {
  return PlaybackLine(
    id: id,
    episodeId: _episode.id,
    providerId: 'zeluna:site:$id',
    providerName: id,
    title: id,
    quality: '',
    format: startupProfile == PlaybackStartupProfile.hls ? 'hls' : 'mp4',
    url: 'https://$id.example/video',
    latency: Duration(milliseconds: latencyMs),
    clientVerified: true,
    startupProfile: startupProfile,
    available: true,
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for playback prefetch.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

RulePlugin _rule(String id) => RulePlugin(
  id: id,
  name: id,
  version: '1.0.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'aikanbot-api',
  updatedAt: DateTime.utc(2026, 8, 1),
  qualityScore: 100,
  tags: const ['test'],
  baseUrl: 'https://rule.example',
  searchUrl: 'https://rule.example/search?keyword={keyword}',
  searchable: true,
  quickSearch: true,
  filterable: false,
  priority: -10000,
);

const _services = ExternalServiceSettings(
  mediaMetadataEnabled: false,
  tmdbEnabled: false,
  cinemetaEnabled: false,
  peerTubeEnabled: false,
  wikimediaCommonsEnabled: false,
  anilistEnabled: false,
  jikanEnabled: false,
  kitsuEnabled: false,
  bangumiEnabled: false,
  publicCollectionSyncEnabled: false,
  bilibiliSubtitleEnabled: false,
  dandanplayDanmakuEnabled: false,
  bilibiliDanmakuEnabled: false,
  playbackBackendEnabled: true,
  playbackBackendEndpoint: 'https://backend.example',
);

const _subject = AnimeSubject(
  id: 400602,
  title: '葬送的芙莉莲',
  originalTitle: 'Sousou no Frieren',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2023-09-29',
  platform: 'TV',
  language: '日语',
  region: '日本',
  status: '完结',
  categories: [],
  tags: [],
  totalEpisodes: 28,
  source: 'bangumi',
);

const _episode = AnimeEpisode(
  id: 400602001,
  subjectId: 400602,
  number: 1,
  title: '第1集',
  airdate: '2023-09-29',
  duration: '24:00',
  description: '',
);
