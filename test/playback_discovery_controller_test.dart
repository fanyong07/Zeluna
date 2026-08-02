import 'dart:async';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'old-account backend result cannot publish or populate the cache',
    () async {
      var activeVersion = 1;
      var calls = 0;
      final oldResult = Completer<List<PlaybackLine>>();
      final backend = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) {
          calls++;
          return calls == 1
              ? oldResult.future
              : Future.value(<PlaybackLine>[_line('new-account')]);
        },
      );
      final controller = _controller(
        backend: backend,
        activeVersion: () => activeVersion,
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      final oldLookup = controller.linesForEpisodeMode(_subject, _episode);
      await _waitUntil(() => calls == 1);
      activeVersion = 2;
      _load(controller, accountId: 'account-b', contextVersion: 2);
      oldResult.complete(<PlaybackLine>[_line('old-account')]);

      expect(await oldLookup, isEmpty);
      expect(controller.cachedBackendEntries, 0);
      final current = await controller.linesForEpisodeMode(_subject, _episode);
      expect(current.single.id, 'new-account');
      expect(
        calls,
        2,
        reason: 'the same episode must not reuse account A cache',
      );
    },
  );

  test('old-account rule result is rejected after a scope switch', () async {
    var activeVersion = 1;
    final ruleResult = Completer<List<PlaybackLine>>();
    var ruleCalls = 0;
    final controller = _controller(
      backend: _FakePlaybackRepository.empty(),
      rule: _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) {
          ruleCalls++;
          return ruleResult.future;
        },
      ),
      activeVersion: () => activeVersion,
    );
    addTearDown(controller.dispose);
    _load(
      controller,
      accountId: 'account-a',
      contextVersion: 1,
      ruleState: _ruleState,
    );

    final lookup = controller.linesForEpisodeMode(_subject, _episode);
    await _waitUntil(() => ruleCalls == 1);
    activeVersion = 2;
    _load(controller, accountId: 'account-b', contextVersion: 2);
    ruleResult.complete(<PlaybackLine>[_line('old-rule', provider: 'rule')]);

    expect(await lookup, isEmpty);
  });

  test(
    'cancellation suppresses a late progressive verification result',
    () async {
      final verification = Completer<void>();
      var verifyCalls = 0;
      final candidate = _line(
        'candidate',
        available: false,
        serverVerified: true,
      );
      final backend = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => [
          candidate,
        ],
      );
      final controller = _controller(
        backend: backend,
        activeVersion: () => 1,
        verify:
            (
              line, {
              enrichMetadata = true,
              forceRefresh = false,
              cancellationToken,
            }) async {
              verifyCalls++;
              await verification.future;
              return _verified(line);
            },
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);
      final token = RulePlaybackCancellationToken();
      final updates = controller
          .lineUpdatesForEpisode(_subject, _episode, cancellationToken: token)
          .toList();
      await _waitUntil(() => verifyCalls == 1);

      token.cancel();
      verification.complete();
      final snapshots = await updates;

      expect(snapshots, hasLength(2));
      expect(
        snapshots.every((update) => !update.lines.single.clientVerified),
        isTrue,
      );
    },
  );

  test(
    'progressive verification publishes in completion order then completes',
    () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      var verifyCalls = 0;
      final first = _line('first', available: false, serverVerified: true);
      final second = _line('second', available: false, serverVerified: true);
      final backend = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => [
          first,
          second,
        ],
      );
      final controller = _controller(
        backend: backend,
        activeVersion: () => 1,
        verify:
            (
              line, {
              enrichMetadata = true,
              forceRefresh = false,
              cancellationToken,
            }) async {
              verifyCalls++;
              await (line.id == 'first' ? firstGate.future : secondGate.future);
              return _verified(line);
            },
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);
      final snapshots = <PlaybackLineLookupUpdate>[];
      final done = controller
          .lineUpdatesForEpisode(_subject, _episode)
          .forEach(snapshots.add);
      await _waitUntil(() => verifyCalls == 2);

      secondGate.complete();
      await _waitUntil(
        () => snapshots.any(
          (update) => update.lines.any(
            (line) => line.id == 'second' && line.clientVerified,
          ),
        ),
      );
      firstGate.complete();
      await done;

      final verifiedSnapshots = snapshots
          .where((update) => update.lines.any((line) => line.clientVerified))
          .toList(growable: false);
      expect(
        verifiedSnapshots.first.lines
            .singleWhere((line) => line.id == 'second')
            .clientVerified,
        isTrue,
      );
      expect(
        verifiedSnapshots.first.lines
            .singleWhere((line) => line.id == 'first')
            .clientVerified,
        isFalse,
      );
      expect(
        verifiedSnapshots.last.lines.every((line) => line.clientVerified),
        isTrue,
      );
      expect(snapshots.last.phase, PlaybackLineLookupPhase.complete);
    },
  );

  test('account switch cancels a late detail prefetch write', () async {
    var activeVersion = 1;
    final verification = Completer<void>();
    var verifyCalls = 0;
    final backend = _FakePlaybackRepository(
      load: (_, _, {required expandAll, cancellationToken}) async => [
        _line('prefetch', serverVerified: true),
      ],
    );
    final controller = _controller(
      backend: backend,
      activeVersion: () => activeVersion,
      verify:
          (
            line, {
            enrichMetadata = true,
            forceRefresh = false,
            cancellationToken,
          }) async {
            verifyCalls++;
            await verification.future;
            return _verified(line);
          },
    );
    addTearDown(controller.dispose);
    _load(controller, accountId: 'account-a', contextVersion: 1);
    controller.prefetchPlayback(_subject, const <AnimeEpisode>[_episode]);
    await _waitUntil(() => verifyCalls == 1);

    activeVersion = 2;
    _load(controller, accountId: 'account-b', contextVersion: 2);
    verification.complete();
    await Future<void>.delayed(Duration.zero);

    expect(controller.prefetchedLineForEpisode(_subject, _episode), isNull);
    expect(controller.cachedBackendEntries, 0);
  });

  test('backend setting changes invalidate the scoped episode cache', () async {
    var calls = 0;
    final backend = _FakePlaybackRepository(
      load: (_, _, {required expandAll, cancellationToken}) async {
        calls++;
        return <PlaybackLine>[_line('backend-$calls', serverVerified: true)];
      },
    );
    final controller = _controller(backend: backend, activeVersion: () => 1);
    addTearDown(controller.dispose);
    _load(controller, accountId: 'account-a', contextVersion: 1);
    final first = await controller.linesForEpisodeMode(_subject, _episode);
    expect(first.single.id, 'backend-1');
    expect(controller.prefetchedLineForEpisode(_subject, _episode), isNotNull);

    controller.applyServices(
      const ExternalServiceSettings(
        playbackBackendEnabled: true,
        playbackBackendEndpoint: 'https://backend-2.example',
      ),
      contextVersion: 1,
    );

    expect(controller.prefetchedLineForEpisode(_subject, _episode), isNull);
    final second = await controller.linesForEpisodeMode(_subject, _episode);
    expect(second.single.id, 'backend-2');
    expect(calls, 2);
  });
}

PlaybackDiscoveryController _controller({
  required _FakePlaybackRepository backend,
  required int Function() activeVersion,
  _FakePlaybackRepository? rule,
  PlaybackLineVerifier? verify,
}) => PlaybackDiscoveryController(
  backendRepository: (_) => backend,
  ruleRepository: (_) => rule ?? _FakePlaybackRepository.empty(),
  verifyLine:
      verify ??
      (
        line, {
        enrichMetadata = true,
        forceRefresh = false,
        cancellationToken,
      }) async => line,
  isContextCurrent: (version) => version == activeVersion(),
  clearRuleRuntimeCaches: () {},
);

void _load(
  PlaybackDiscoveryController controller, {
  required String accountId,
  required int contextVersion,
  RulePluginState ruleState = const RulePluginState(),
}) => controller.loadForAccount(
  accountId: accountId,
  contextVersion: contextVersion,
  services: _services,
  ruleState: ruleState,
  history: const <LibraryEntry>[],
);

final class _FakePlaybackRepository implements PlaybackSourceRepository {
  _FakePlaybackRepository({required this.load});

  factory _FakePlaybackRepository.empty() => _FakePlaybackRepository(
    load: (_, _, {required expandAll, cancellationToken}) async => const [],
  );

  final Future<List<PlaybackLine>> Function(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool expandAll,
    RulePlaybackCancellationToken? cancellationToken,
  })
  load;
  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => load(
    subject,
    episode,
    expandAll: false,
    cancellationToken: cancellationToken,
  );

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) => load(
    subject,
    episode,
    expandAll: expandAll,
    cancellationToken: cancellationToken,
  );

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => const Stream<PlaybackLineLookupUpdate>.empty();
}

PlaybackLine _line(
  String id, {
  String provider = 'zeluna:test',
  bool available = true,
  bool serverVerified = false,
}) => PlaybackLine(
  id: id,
  episodeId: _episode.id,
  providerId: provider,
  providerName: provider,
  title: id,
  quality: '1080P',
  format: 'hls',
  url: 'https://$id.example/video.m3u8',
  serverVerified: serverVerified,
  available: available,
);

PlaybackLine _verified(PlaybackLine line) => PlaybackLine(
  id: line.id,
  episodeId: line.episodeId,
  providerId: line.providerId,
  providerName: line.providerName,
  title: line.title,
  quality: line.quality,
  format: line.format,
  url: line.url,
  serverVerified: line.serverVerified,
  clientVerified: true,
  latency: const Duration(milliseconds: 5),
  available: true,
);

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for state.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final _ruleState = RulePluginState(customRules: [_rule]);
final _rule = RulePlugin(
  id: 'test:rule',
  name: 'Test rule',
  version: '1.0.0',
  source: RuleSourceKind.custom,
  contentType: RuleContentType.anime,
  engine: 'test',
  updatedAt: DateTime.utc(2026, 8, 2),
  qualityScore: 100,
  tags: const <String>[],
  baseUrl: 'https://rule.example',
  searchUrl: 'https://rule.example/search?q={keyword}',
  searchable: true,
  quickSearch: true,
  filterable: false,
);

const _services = ExternalServiceSettings(
  playbackBackendEnabled: true,
  playbackBackendEndpoint: 'https://backend.example',
);

const _subject = AnimeSubject(
  id: 400602,
  title: 'Test subject',
  originalTitle: 'Test subject',
  summary: '',
  coverUrl: null,
  bannerUrl: null,
  date: '2026-08-02',
  platform: 'TV',
  language: 'ja',
  region: 'JP',
  status: 'airing',
  categories: [],
  tags: [],
  totalEpisodes: 1,
  source: 'bangumi',
);

const _episode = AnimeEpisode(
  id: 400602001,
  subjectId: 400602,
  number: 1,
  title: 'Episode 1',
  airdate: '2026-08-02',
  duration: '24:00',
  description: '',
);
