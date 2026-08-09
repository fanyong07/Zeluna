import 'dart:async';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
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

  final warmupInvalidationCases =
      <
        ({
          String name,
          void Function(PlaybackDiscoveryController controller) invalidate,
        })
      >[
        (
          name: 'remember-line cache clear',
          invalidate: (controller) => controller.clearCaches(),
        ),
        (
          name: 'backend configuration change',
          invalidate: (controller) => controller.applyServices(
            const ExternalServiceSettings(
              playbackBackendEnabled: true,
              playbackBackendEndpoint: 'https://backend-2.example',
            ),
            contextVersion: 1,
          ),
        ),
        (
          name: 'rule configuration change',
          invalidate: (controller) => controller.applyRuleState(
            const RulePluginState(installedIds: <String>{'rule:new'}),
            contextVersion: 1,
          ),
        ),
        (
          name: 'controller dispose',
          invalidate: (controller) => controller.dispose(),
        ),
      ];
  for (final invalidationCase in warmupInvalidationCases) {
    test(
      '${invalidationCase.name} rejects an in-flight warmup result',
      () async {
        final verification = Completer<void>();
        var verifyCalls = 0;
        RulePlaybackCancellationToken? verificationToken;
        final nextEpisode = _episodeFor(2);
        final controller = _controller(
          backend: _FakePlaybackRepository(
            load: (_, episode, {required expandAll, cancellationToken}) async =>
                <PlaybackLine>[
                  _line(
                    'late-warmup',
                    episodeId: episode.id,
                    serverVerified: true,
                  ),
                ],
          ),
          activeVersion: () => 1,
          verify:
              (
                line, {
                enrichMetadata = true,
                forceRefresh = false,
                cancellationToken,
              }) async {
                verifyCalls++;
                verificationToken = cancellationToken;
                await verification.future;
                return _verified(line);
              },
        );
        addTearDown(() {
          if (!verification.isCompleted) verification.complete();
          controller.dispose();
        });
        _load(controller, accountId: 'account-a', contextVersion: 1);
        final prefetch = controller.prefetchPlaybackForEpisode(
          _subject,
          nextEpisode,
        );
        await _waitUntil(() => verifyCalls == 1);

        invalidationCase.invalidate(controller);
        expect(verificationToken?.isCancelled, isTrue);
        verification.complete();
        await prefetch;

        expect(controller.cachedWarmupEntries, 0);
      },
    );
  }

  test('caller cancellation rejects an in-flight warmup result', () async {
    final verification = Completer<void>();
    var verifyCalls = 0;
    RulePlaybackCancellationToken? verificationToken;
    final nextEpisode = _episodeFor(2);
    final controller = _controller(
      backend: _FakePlaybackRepository(
        load: (_, episode, {required expandAll, cancellationToken}) async =>
            <PlaybackLine>[
              _line(
                'cancelled-warmup',
                episodeId: episode.id,
                serverVerified: true,
              ),
            ],
      ),
      activeVersion: () => 1,
      verify:
          (
            line, {
            enrichMetadata = true,
            forceRefresh = false,
            cancellationToken,
          }) async {
            verifyCalls++;
            verificationToken = cancellationToken;
            await verification.future;
            return _verified(line);
          },
    );
    addTearDown(() {
      if (!verification.isCompleted) verification.complete();
      controller.dispose();
    });
    _load(controller, accountId: 'account-a', contextVersion: 1);
    final token = RulePlaybackCancellationToken();
    final prefetch = controller.prefetchPlaybackForEpisode(
      _subject,
      nextEpisode,
      cancellationToken: token,
    );
    await _waitUntil(() => verifyCalls == 1);

    token.cancel();
    expect(verificationToken?.isCancelled, isTrue);
    verification.complete();
    await prefetch;

    expect(controller.cachedWarmupEntries, 0);
  });

  test(
    'next-episode prefetch deduplicates and verifies at most two preferred candidates',
    () async {
      final nextEpisode = _episodeFor(2);
      var backendCalls = 0;
      var verifyCalls = 0;
      var inFlight = 0;
      var maxInFlight = 0;
      final requestedEpisodes = <int>[];
      final backend = _FakePlaybackRepository(
        load:
            (subject, episode, {required expandAll, cancellationToken}) async {
              backendCalls++;
              requestedEpisodes.add(episode.id);
              return <PlaybackLine>[
                _line(
                  'fallback',
                  provider: 'zeluna:fallback',
                  episodeId: nextEpisode.id,
                  serverVerified: true,
                ),
                _line(
                  'preferred',
                  provider: 'rule:preferred',
                  episodeId: nextEpisode.id,
                  serverVerified: true,
                ),
                _line(
                  'third',
                  provider: 'zeluna:third',
                  episodeId: nextEpisode.id,
                  serverVerified: true,
                ),
              ];
            },
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
              inFlight++;
              maxInFlight = maxInFlight < inFlight ? inFlight : maxInFlight;
              await Future<void>.delayed(const Duration(milliseconds: 10));
              inFlight--;
              return _verified(line);
            },
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      await Future.wait([
        controller.prefetchPlaybackForEpisode(
          _subject,
          nextEpisode,
          preferredProviderId: 'rule:preferred',
        ),
        controller.prefetchPlaybackForEpisode(
          _subject,
          nextEpisode,
          preferredProviderId: 'rule:preferred',
        ),
      ]);

      expect(backendCalls, 1);
      expect(requestedEpisodes, [nextEpisode.id]);
      expect(verifyCalls, 2);
      expect(maxInFlight, lessThanOrEqualTo(2));
      final bundle = controller.prefetchedWarmupBundleForEpisode(
        _subject,
        nextEpisode,
      );
      expect(
        bundle?.episodeIdentity,
        nextEpisode.identityKey(subjectKey: _subject.identityKey),
      );
      expect(bundle?.primary.providerId, 'rule:preferred');
      expect(bundle?.fallback?.providerId, 'zeluna:fallback');
      expect(bundle?.allLines, hasLength(2));
      expect(controller.cachedWarmupEntries, 1);
      expect(
        controller
            .prefetchedLineForEpisode(
              _subject,
              nextEpisode,
              preferredProviderId: 'rule:preferred',
            )
            ?.providerId,
        'rule:preferred',
      );
    },
  );

  test(
    'direct and offline subjects do not start next-episode prefetch',
    () async {
      var backendCalls = 0;
      final backend = _FakePlaybackRepository(
        load: (_, episode, {required expandAll, cancellationToken}) async {
          backendCalls++;
          return <PlaybackLine>[_line('unexpected', episodeId: episode.id)];
        },
      );
      final controller = _controller(backend: backend, activeVersion: () => 1);
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      for (final source in ['direct', 'offline']) {
        final subject = _subject.copyWith(source: source);
        await controller.prefetchPlaybackForEpisode(subject, _episodeFor(2));
      }

      expect(backendCalls, 0);
    },
  );

  test('account switch cancels a late next-episode prefetch write', () async {
    var activeVersion = 1;
    final verification = Completer<void>();
    var verifyCalls = 0;
    final nextEpisode = _episodeFor(2);
    final controller = _controller(
      backend: _FakePlaybackRepository(
        load: (_, episode, {required expandAll, cancellationToken}) async => [
          _line('next-account-a', episodeId: episode.id, serverVerified: true),
        ],
      ),
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
    final oldPrefetch = controller.prefetchPlaybackForEpisode(
      _subject,
      nextEpisode,
    );
    await _waitUntil(() => verifyCalls == 1);

    activeVersion = 2;
    _load(controller, accountId: 'account-b', contextVersion: 2);
    verification.complete();
    await oldPrefetch;

    expect(controller.prefetchedLineForEpisode(_subject, nextEpisode), isNull);
    expect(
      controller.prefetchedWarmupBundleForEpisode(_subject, nextEpisode),
      isNull,
    );
    expect(controller.cachedWarmupEntries, 0);
  });

  test(
    'forced next-episode refresh replaces a cancelled in-flight result',
    () async {
      final oldVerification = Completer<void>();
      var backendCalls = 0;
      final nextEpisode = _episodeFor(2);
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, episode, {required expandAll, cancellationToken}) async {
            backendCalls++;
            return <PlaybackLine>[
              _line(
                backendCalls == 1 ? 'old' : 'new',
                episodeId: episode.id,
                serverVerified: true,
              ),
            ];
          },
        ),
        activeVersion: () => 1,
        verify:
            (
              line, {
              enrichMetadata = true,
              forceRefresh = false,
              cancellationToken,
            }) async {
              if (line.id == 'old') await oldVerification.future;
              return _verified(line);
            },
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);
      final oldPrefetch = controller.prefetchPlaybackForEpisode(
        _subject,
        nextEpisode,
      );
      await _waitUntil(() => backendCalls == 1);
      final freshPrefetch = controller.prefetchPlaybackForEpisode(
        _subject,
        nextEpisode,
        forceRefresh: true,
      );
      expect(controller.cachedWarmupEntries, 0);
      await freshPrefetch;
      oldVerification.complete();
      await oldPrefetch;

      expect(backendCalls, 2);
      expect(
        controller.prefetchedLineForEpisode(_subject, nextEpisode)?.id,
        'new',
      );
      expect(
        controller
            .prefetchedWarmupBundleForEpisode(_subject, nextEpisode)
            ?.primary
            .id,
        'new',
      );
    },
  );

  test(
    'forced next-episode refresh hides a previously cached bundle',
    () async {
      final forcedResult = Completer<List<PlaybackLine>>();
      var backendCalls = 0;
      final nextEpisode = _episodeFor(2);
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, episode, {required expandAll, cancellationToken}) {
            backendCalls++;
            if (backendCalls == 1) {
              return Future<List<PlaybackLine>>.value(<PlaybackLine>[
                _line(
                  'cached-old',
                  episodeId: episode.id,
                  serverVerified: true,
                ),
              ]);
            }
            return forcedResult.future;
          },
        ),
        activeVersion: () => 1,
        verify:
            (
              line, {
              enrichMetadata = true,
              forceRefresh = false,
              cancellationToken,
            }) async => _verified(line),
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      await controller.prefetchPlaybackForEpisode(_subject, nextEpisode);
      expect(
        controller
            .prefetchedWarmupBundleForEpisode(_subject, nextEpisode)
            ?.primary
            .id,
        'cached-old',
      );

      final forced = controller.prefetchPlaybackForEpisode(
        _subject,
        nextEpisode,
        forceRefresh: true,
      );
      await _waitUntil(() => backendCalls == 2);

      expect(
        controller.prefetchedWarmupBundleForEpisode(_subject, nextEpisode),
        isNull,
      );

      forcedResult.complete(<PlaybackLine>[
        _line('forced-fresh', episodeId: nextEpisode.id, serverVerified: true),
      ]);
      await forced;

      expect(
        controller
            .prefetchedWarmupBundleForEpisode(_subject, nextEpisode)
            ?.primary
            .id,
        'forced-fresh',
      );
      expect(backendCalls, 2);
    },
  );

  test(
    'forced backend lookup owns the cache after an older result arrives late',
    () async {
      final oldResult = Completer<List<PlaybackLine>>();
      RulePlaybackCancellationToken? oldOperationToken;
      var backendCalls = 0;
      final backend = _FakePlaybackRepository(
        load: (_, episode, {required expandAll, cancellationToken}) {
          backendCalls++;
          if (backendCalls == 1) {
            oldOperationToken = cancellationToken;
            return oldResult.future;
          }
          return Future<List<PlaybackLine>>.value(<PlaybackLine>[
            _line('forced-fresh', episodeId: episode.id, serverVerified: true),
          ]);
        },
      );
      final controller = _controller(backend: backend, activeVersion: () => 1);
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      final oldLookup = controller.linesForEpisodeMode(_subject, _episode);
      await _waitUntil(() => backendCalls == 1 && oldOperationToken != null);
      final fresh = await controller.linesForEpisodeMode(
        _subject,
        _episode,
        forceRefresh: true,
      );
      oldResult.complete(<PlaybackLine>[
        _line('late-old', serverVerified: true),
      ]);
      final old = await oldLookup;
      final cached = await controller.linesForEpisodeMode(_subject, _episode);

      expect(oldOperationToken!.isCancelled, isTrue);
      expect(old, isEmpty);
      expect(fresh.single.id, 'forced-fresh');
      expect(cached.single.id, 'forced-fresh');
      expect(backendCalls, 2);
    },
  );

  test(
    'ordinary backend lookup joins an in-flight force refresh instead of stale cache',
    () async {
      final forcedResult = Completer<List<PlaybackLine>>();
      var backendCalls = 0;
      final backend = _FakePlaybackRepository(
        load: (_, episode, {required expandAll, cancellationToken}) {
          backendCalls++;
          if (backendCalls == 1) {
            return Future<List<PlaybackLine>>.value(<PlaybackLine>[
              _line('cached-old', episodeId: episode.id, serverVerified: true),
            ]);
          }
          return forcedResult.future;
        },
      );
      final controller = _controller(backend: backend, activeVersion: () => 1);
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      final initial = await controller.linesForEpisodeMode(_subject, _episode);
      expect(initial.single.id, 'cached-old');
      expect(controller.cachedBackendEntries, 1);

      final forced = controller.linesForEpisodeMode(
        _subject,
        _episode,
        forceRefresh: true,
      );
      await _waitUntil(() => backendCalls == 2);
      expect(controller.cachedBackendEntries, 0);

      var ordinaryCompleted = false;
      final ordinary = controller
          .linesForEpisodeMode(_subject, _episode)
          .whenComplete(() => ordinaryCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(ordinaryCompleted, isFalse);
      expect(backendCalls, 2);

      forcedResult.complete(<PlaybackLine>[
        _line('forced-fresh', serverVerified: true),
      ]);

      expect((await forced).single.id, 'forced-fresh');
      expect((await ordinary).single.id, 'forced-fresh');
      expect(
        (await controller.linesForEpisodeMode(_subject, _episode)).single.id,
        'forced-fresh',
      );
      expect(backendCalls, 2);
    },
  );

  test(
    'interactive lookup starts fast preferred work before slow backend hedge',
    () async {
      final backendResult = Completer<List<PlaybackLine>>();
      var backendStarted = false;
      final rule = _FakePreferredPlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => const [],
        loadPreferred:
            (
              _,
              _, {
              required preferredProviderId,
              required expandAll,
              cancellationToken,
            }) async {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              return <PlaybackLine>[
                _line(
                  'preferred-fast',
                  provider: preferredProviderId,
                  serverVerified: true,
                ),
              ];
            },
      );
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) {
            backendStarted = true;
            return backendResult.future;
          },
        ),
        rule: rule,
        activeVersion: () => 1,
        interactivePreferredHeadStart: const Duration(milliseconds: 80),
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );

      final lines = await controller.linesForEpisodeMode(
        _subject,
        _episode,
        preferredProviderId: 'rule:preferred',
      );
      backendResult.complete(const <PlaybackLine>[]);

      expect(lines.single.providerId, 'rule:preferred');
      expect(backendStarted, isFalse);
    },
  );

  test(
    'interactive lookup returns verified fallback after preferred head start',
    () async {
      final preferredStarted = Completer<void>();
      final preferredCancelled = Completer<void>();
      final rule = _FakePreferredPlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => const [],
        loadPreferred:
            (
              _,
              _, {
              required preferredProviderId,
              required expandAll,
              cancellationToken,
            }) {
              if (!preferredStarted.isCompleted) preferredStarted.complete();
              final pending = Completer<List<PlaybackLine>>();
              cancellationToken?.register(() {
                if (!preferredCancelled.isCompleted) {
                  preferredCancelled.complete();
                }
                if (!pending.isCompleted) pending.complete(const []);
              });
              return pending.future;
            },
      );
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async => [
            _line(
              'verified-fallback',
              provider: 'zeluna:fallback',
              serverVerified: true,
            ),
          ],
        ),
        rule: rule,
        activeVersion: () => 1,
        interactivePreferredHeadStart: const Duration(milliseconds: 60),
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );
      final stopwatch = Stopwatch()..start();

      final lines = await controller.linesForEpisodeMode(
        _subject,
        _episode,
        preferredProviderId: 'rule:preferred',
      );
      stopwatch.stop();
      await preferredStarted.future;
      await preferredCancelled.future;

      expect(lines.single.id, 'verified-fallback');
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 40)),
      );
    },
  );

  test(
    'missing preferred provider does not restart an empty backend lookup',
    () async {
      var backendCalls = 0;
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async {
            backendCalls++;
            return const <PlaybackLine>[];
          },
        ),
        activeVersion: () => 1,
        interactivePreferredHeadStart: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      final lines = await controller.linesForEpisodeMode(
        _subject,
        _episode,
        preferredProviderId: 'missing:provider',
      );

      expect(lines, isEmpty);
      expect(backendCalls, 1);
    },
  );

  test(
    'invalid or stale fallback cannot end the preferred head start',
    () async {
      final preferredResult = Completer<List<PlaybackLine>>();
      final rule = _FakePreferredPlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => const [],
        loadPreferred:
            (
              _,
              _, {
              required preferredProviderId,
              required expandAll,
              cancellationToken,
            }) => preferredResult.future,
      );
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async => [
            _line('unverified-fallback', provider: 'zeluna:unverified'),
            _line(
              'malformed-fallback',
              provider: 'zeluna:malformed',
              serverVerified: true,
              url: 'file:///private/video.m3u8',
            ),
            _line(
              'expired-fallback',
              provider: 'zeluna:expired',
              serverVerified: true,
              expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
            ),
          ],
        ),
        rule: rule,
        activeVersion: () => 1,
        interactivePreferredHeadStart: const Duration(milliseconds: 30),
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );
      var completed = false;

      final lookup = controller
          .linesForEpisodeMode(
            _subject,
            _episode,
            preferredProviderId: 'rule:preferred',
          )
          .whenComplete(() => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(completed, isFalse);
      preferredResult.complete(<PlaybackLine>[
        _line(
          'verified-preferred',
          provider: 'rule:preferred',
          serverVerified: true,
        ),
      ]);

      expect((await lookup).first.id, 'verified-preferred');
    },
  );

  test(
    'warmup without provider memory returns at most two verified fresh HTTP lines',
    () async {
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async => [
            _line(
              'server-primary',
              provider: 'zeluna:server',
              serverVerified: true,
            ),
            _line(
              'client-primary',
              provider: 'zeluna:client',
              clientVerified: true,
            ),
            _line(
              'third-valid',
              provider: 'zeluna:third',
              serverVerified: true,
            ),
            _line('unverified', provider: 'zeluna:unverified'),
            _line(
              'non-http',
              provider: 'zeluna:local',
              serverVerified: true,
              url: 'file:///private/video.m3u8',
            ),
            _line(
              'expired',
              provider: 'zeluna:expired',
              serverVerified: true,
              expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
            ),
          ],
        ),
        activeVersion: () => 1,
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);

      final lines = await controller.linesForEpisodeMode(
        _subject,
        _episode,
        lookupIntent: PlaybackLookupIntent.warmup,
      );

      expect(lines, hasLength(2));
      expect(lines.first.id, 'client-primary');
      expect(lines.map((line) => line.id), contains('server-primary'));
      expect(
        lines,
        everyElement(
          isA<PlaybackLine>()
              .having((line) => line.available, 'available', isTrue)
              .having(
                (line) => line.serverVerified || line.clientVerified,
                'verified',
                isTrue,
              )
              .having(
                (line) => Uri.parse(line.url!).scheme,
                'HTTP scheme',
                anyOf('http', 'https'),
              ),
        ),
      );
    },
  );

  test(
    'warmup waits for preferred and returns one available fallback',
    () async {
      final rule = _FakePreferredPlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => const [],
        loadPreferred:
            (
              _,
              _, {
              required preferredProviderId,
              required expandAll,
              cancellationToken,
            }) async {
              await Future<void>.delayed(const Duration(milliseconds: 80));
              return <PlaybackLine>[
                _line(
                  'preferred-warmup',
                  provider: preferredProviderId,
                  serverVerified: true,
                ),
              ];
            },
      );
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async => [
            _line(
              'fallback-warmup',
              provider: 'zeluna:fallback',
              serverVerified: true,
            ),
          ],
        ),
        rule: rule,
        activeVersion: () => 1,
        interactivePreferredHeadStart: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );
      final stopwatch = Stopwatch()..start();

      final lines = await controller.linesForEpisodeMode(
        _subject,
        _episode,
        forceRefresh: true,
        preferredProviderId: 'rule:preferred',
        lookupIntent: PlaybackLookupIntent.warmup,
      );
      stopwatch.stop();

      expect(lines.map((line) => line.providerId), [
        'rule:preferred',
        'zeluna:fallback',
      ]);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 60)),
      );
      expect(rule.preferredForceRefreshCalls, <bool>[true]);
      expect(rule.fallbackForceRefreshCalls, <bool>[true]);
    },
  );

  test('caller cancellation reaches the backend repository lookup', () async {
    RulePlaybackCancellationToken? receivedToken;
    final backendStarted = Completer<void>();
    final backendCancelled = Completer<void>();
    final backend = _FakePlaybackRepository(
      load: (_, _, {required expandAll, cancellationToken}) {
        receivedToken = cancellationToken;
        if (!backendStarted.isCompleted) backendStarted.complete();
        final pending = Completer<List<PlaybackLine>>();
        cancellationToken?.register(() {
          if (!backendCancelled.isCompleted) backendCancelled.complete();
        });
        return pending.future;
      },
    );
    final controller = _controller(backend: backend, activeVersion: () => 1);
    addTearDown(controller.dispose);
    _load(controller, accountId: 'account-a', contextVersion: 1);
    final token = RulePlaybackCancellationToken();

    final lookup = controller.linesForEpisodeMode(
      _subject,
      _episode,
      cancellationToken: token,
    );
    await backendStarted.future;
    expect(identical(receivedToken, token), isFalse);
    token.cancel();

    expect(await lookup, isEmpty);
    await backendCancelled.future;
  });

  test(
    'one caller cancellation does not abort a shared backend lookup',
    () async {
      var backendCalls = 0;
      RulePlaybackCancellationToken? operationToken;
      final backendResult = Completer<List<PlaybackLine>>();
      final backend = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) {
          backendCalls++;
          operationToken = cancellationToken;
          return backendResult.future;
        },
      );
      final controller = _controller(backend: backend, activeVersion: () => 1);
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);
      final tokenA = RulePlaybackCancellationToken();
      final tokenB = RulePlaybackCancellationToken();

      final lookupA = controller.linesForEpisodeMode(
        _subject,
        _episode,
        cancellationToken: tokenA,
      );
      final lookupB = controller.linesForEpisodeMode(
        _subject,
        _episode,
        cancellationToken: tokenB,
      );
      await _waitUntil(() => backendCalls == 1 && operationToken != null);
      tokenA.cancel();

      expect(await lookupA, isEmpty);
      expect(operationToken!.isCancelled, isFalse);
      backendResult.complete(<PlaybackLine>[
        _line('shared-result', serverVerified: true),
      ]);

      expect((await lookupB).single.id, 'shared-result');
      expect(backendCalls, 1);
    },
  );

  test(
    'the last shared backend subscriber cancels the owned operation',
    () async {
      var backendCalls = 0;
      RulePlaybackCancellationToken? operationToken;
      final backendResult = Completer<List<PlaybackLine>>();
      final backend = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) {
          backendCalls++;
          operationToken = cancellationToken;
          return backendResult.future;
        },
      );
      final controller = _controller(backend: backend, activeVersion: () => 1);
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);
      final tokenA = RulePlaybackCancellationToken();
      final tokenB = RulePlaybackCancellationToken();

      final lookupA = controller.linesForEpisodeMode(
        _subject,
        _episode,
        cancellationToken: tokenA,
      );
      final lookupB = controller.linesForEpisodeMode(
        _subject,
        _episode,
        cancellationToken: tokenB,
      );
      await _waitUntil(() => backendCalls == 1 && operationToken != null);
      tokenA.cancel();
      expect(await lookupA, isEmpty);
      expect(operationToken!.isCancelled, isFalse);

      tokenB.cancel();
      expect(await lookupB, isEmpty);
      await _waitUntil(() => operationToken!.isCancelled);
      expect(operationToken!.isCancelled, isTrue);
      expect(backendCalls, 1);
      backendResult.complete(const <PlaybackLine>[]);
    },
  );

  test(
    'rules-only warmup keeps verified preferred and fallback independent',
    () async {
      final preferredResult = Completer<List<PlaybackLine>>();
      final fallbackStarted = Completer<void>();
      final rule = _FakePreferredPlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => const [],
        loadPreferred:
            (
              _,
              _, {
              required preferredProviderId,
              required expandAll,
              cancellationToken,
            }) => preferredResult.future,
        loadFallback:
            (_, _, {required excludedProviderId, cancellationToken}) async {
              if (!fallbackStarted.isCompleted) fallbackStarted.complete();
              return <PlaybackLine>[
                _line(
                  'rules-fallback',
                  provider: 'rule:fallback',
                  serverVerified: true,
                ),
              ];
            },
      );
      final controller = _controller(
        backend: _FakePlaybackRepository.empty(),
        rule: rule,
        activeVersion: () => 1,
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );
      var completed = false;

      final lookup = controller
          .linesForEpisodeMode(
            _subject,
            _episode,
            preferredProviderId: 'rule:preferred',
            lookupIntent: PlaybackLookupIntent.warmup,
          )
          .whenComplete(() => completed = true);
      await fallbackStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      preferredResult.complete(<PlaybackLine>[
        _line(
          'rules-preferred',
          provider: 'rule:preferred',
          serverVerified: true,
        ),
      ]);

      expect((await lookup).map((line) => line.providerId), [
        'rule:preferred',
        'rule:fallback',
      ]);
    },
  );

  test(
    'built-in provider memory is not hidden by an empty custom rule list',
    () async {
      const inventory = RulePluginRepository();
      final state = inventory.defaultState();
      final preferredProviderId = inventory
          .playbackRulesFor(state, RuleContentType.anime)
          .first
          .id;
      final fallbackProviderId = inventory
          .playbackRulesFor(state, RuleContentType.anime)
          .last
          .id;
      final nextEpisode = _episodeFor(2);
      var preferredCalls = 0;
      var fallbackCalls = 0;
      final rule = _FakePreferredPlaybackRepository(
        supportedProviderIds: <String>{preferredProviderId},
        load: (_, _, {required expandAll, cancellationToken}) async => const [],
        loadPreferred:
            (
              _,
              _, {
              required preferredProviderId,
              required expandAll,
              cancellationToken,
            }) async {
              preferredCalls++;
              return <PlaybackLine>[
                _line(
                  'built-in-preferred',
                  provider: preferredProviderId,
                  serverVerified: true,
                ),
              ];
            },
        loadFallback:
            (_, _, {required excludedProviderId, cancellationToken}) async {
              fallbackCalls++;
              return <PlaybackLine>[
                _line(
                  'built-in-fallback',
                  provider: fallbackProviderId,
                  clientVerified: true,
                  episodeId: nextEpisode.id,
                ),
              ];
            },
      );
      final controller = _controller(
        backend: _FakePlaybackRepository.empty(),
        rule: rule,
        activeVersion: () => 1,
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: state,
      );

      expect(state.customRules, isEmpty);
      final lines = await controller.linesForEpisodeMode(
        _subject,
        _episode,
        preferredProviderId: preferredProviderId,
      );

      expect(preferredCalls, 1);
      expect(lines.single.providerId, preferredProviderId);

      final noMemoryWarmup = await controller.linesForEpisodeMode(
        _subject,
        nextEpisode,
        lookupIntent: PlaybackLookupIntent.warmup,
      );
      expect(fallbackCalls, 1);
      expect(noMemoryWarmup.single.providerId, fallbackProviderId);
    },
  );
}

PlaybackDiscoveryController _controller({
  required _FakePlaybackRepository backend,
  required int Function() activeVersion,
  PlaybackSourceRepository? rule,
  PlaybackLineVerifier? verify,
  Duration interactivePreferredHeadStart = const Duration(milliseconds: 750),
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
  interactivePreferredHeadStart: interactivePreferredHeadStart,
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

class _FakePlaybackRepository implements PlaybackSourceRepository {
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

final class _FakePreferredPlaybackRepository extends _FakePlaybackRepository
    implements
        PreferredPlaybackSourceRepository,
        ProviderAwarePlaybackSourceRepository {
  _FakePreferredPlaybackRepository({
    required super.load,
    required this.loadPreferred,
    this.loadFallback,
    this.supportedProviderIds,
  });

  final Future<List<PlaybackLine>> Function(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required String preferredProviderId,
    required bool expandAll,
    RulePlaybackCancellationToken? cancellationToken,
  })
  loadPreferred;
  final Future<List<PlaybackLine>> Function(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required String excludedProviderId,
    RulePlaybackCancellationToken? cancellationToken,
  })?
  loadFallback;
  final Set<String>? supportedProviderIds;
  final List<bool> preferredForceRefreshCalls = <bool>[];
  final List<bool> fallbackForceRefreshCalls = <bool>[];

  @override
  bool canResolveProvider(AnimeSubject subject, {required String providerId}) =>
      supportedProviderIds?.contains(providerId) ??
      providerId.trim().isNotEmpty;

  @override
  Future<List<PlaybackLine>> linesForEpisodeWithPreferredProvider(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required String preferredProviderId,
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) => loadPreferred(
    subject,
    episode,
    preferredProviderId: preferredProviderId,
    expandAll: expandAll,
    cancellationToken: cancellationToken,
  );

  @override
  Future<List<PlaybackLine>> verifiedLinesForProvider(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required String providerId,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    preferredForceRefreshCalls.add(forceRefresh);
    return loadPreferred(
      subject,
      episode,
      preferredProviderId: providerId,
      expandAll: false,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Future<List<PlaybackLine>> verifiedFallbackLinesExcludingProvider(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required String excludedProviderId,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    fallbackForceRefreshCalls.add(forceRefresh);
    final fallback = loadFallback;
    if (fallback != null) {
      return fallback(
        subject,
        episode,
        excludedProviderId: excludedProviderId,
        cancellationToken: cancellationToken,
      );
    }
    return load(
      subject,
      episode,
      expandAll: false,
      cancellationToken: cancellationToken,
    );
  }
}

PlaybackLine _line(
  String id, {
  String provider = 'zeluna:test',
  bool available = true,
  bool serverVerified = false,
  bool clientVerified = false,
  int? episodeId,
  String? url,
  DateTime? expiresAt,
}) => PlaybackLine(
  id: id,
  episodeId: episodeId ?? _episode.id,
  providerId: provider,
  providerName: provider,
  title: id,
  quality: '1080P',
  format: 'hls',
  url: url ?? 'https://$id.example/video.m3u8',
  serverVerified: serverVerified,
  clientVerified: clientVerified,
  expiresAt: expiresAt,
  available: available,
);

AnimeEpisode _episodeFor(int number) => AnimeEpisode(
  id: 400602000 + number,
  subjectId: _subject.id,
  number: number,
  title: 'Episode $number',
  airdate: '2026-08-02',
  duration: '24:00',
  description: '',
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
  id: 'rule:preferred',
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
