import 'dart:async';

import 'package:anime/src/data/playback_source_repository.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/playback/playback_discovery_controller.dart';
import 'package:anime/src/rules/rule_models.dart';
import 'package:anime/src/rules/rule_playback_resolver.dart';
import 'package:anime/src/rules/rule_plugin_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('REVIEW-SPEC-001 rule-state retirement', () {
    for (final available in [true, false]) {
      test(
        'retires ${available ? 'positive' : 'negative'} cache before reset',
        () async {
          final rule = _rule.copyWith(
            id: 'fixture:review-cache',
            engine: 'tvbox-json-api',
          );
          final enabled = _enabledReviewRules([rule]);
          final disabled = enabled.copyWith(enabledIds: {});
          var resolutions = 0;
          final resolver = _ReviewRuleResolver(
            (rule, episode) async => [
              _line(
                'resolution-${++resolutions}',
                provider: rule.id,
                available: available,
              ),
            ],
          );
          final repository = RulePlaybackSourceRepository(
            repository: RulePluginRepository(extraRules: [rule]),
            ruleState: enabled,
            resolver: resolver,
            cacheNamespace: 'review-state-$available',
          );
          Future<List<PlaybackLine>> lookup() => repository.linesForEpisodeMode(
            _subject,
            _episode,
            expandAll: true,
          );
          final resets = <Future<List<PlaybackLine>>>[];
          final controller = _controller(
            backend: _FakePlaybackRepository.empty(),
            rule: repository,
            activeVersion: () => 1,
            clearRuleRuntimeCaches: () => resets.add(lookup()),
          );
          addTearDown(controller.dispose);
          _load(
            controller,
            accountId: 'account-a',
            contextVersion: 1,
            ruleState: enabled,
          );
          expect((await resets.single).single.id, 'resolution-1');
          expect((await lookup()).single.id, 'resolution-1');
          controller.applyRuleState(disabled, contextVersion: 2);
          controller.applyRuleState(enabled, contextVersion: 1);
          controller.clearCaches();
          expect(resets, hasLength(1));
          expect((await lookup()).single.id, 'resolution-1');
          controller.applyRuleState(disabled, contextVersion: 1);
          expect((await resets.last).single.id, 'resolution-2');
          controller.applyRuleState(enabled, contextVersion: 1);
          expect((await resets.last).single.id, 'resolution-3');
          expect((await lookup()).single.id, 'resolution-3');
          expect(resets, hasLength(3));
        },
      );
    }

    for (final oldFirst in [true, false]) {
      test(
        'retired flight cannot populate active cache, oldFirst=$oldFirst',
        () async {
          final rule = _rule.copyWith(
            id: 'fixture:review-flight',
            engine: 'tvbox-json-api',
          );
          final enabled = _enabledReviewRules([rule]);
          final oldEntered = Completer<void>();
          final newEntered = Completer<void>();
          final oldResult = Completer<List<PlaybackLine>>();
          final newResult = Completer<List<PlaybackLine>>();
          var calls = 0;
          final resolver = _ReviewRuleResolver((rule, episode) {
            calls++;
            if (calls == 1) {
              oldEntered.complete();
              return oldResult.future;
            }
            if (calls == 2) {
              newEntered.complete();
              return newResult.future;
            }
            return Future.value([_line('unexpected-reparse')]);
          });
          final repository = RulePlaybackSourceRepository(
            repository: RulePluginRepository(extraRules: [rule]),
            ruleState: enabled,
            resolver: resolver,
            cacheNamespace: 'review-flight-$oldFirst',
          );
          final controller = _controller(
            backend: _FakePlaybackRepository.empty(),
            rule: repository,
            activeVersion: () => 1,
          );
          addTearDown(controller.dispose);
          _load(
            controller,
            accountId: 'account-a',
            contextVersion: 1,
            ruleState: enabled,
          );
          // Keep the public caller token and request context identical; old
          // completion must never supply the new lookup's result cache.
          final token = RulePlaybackCancellationToken();
          Future<List<PlaybackLine>> lookup() =>
              repository.verifiedLinesForProvider(
                _subject,
                _episode,
                providerId: rule.id,
                cancellationToken: token,
              );
          final oldLookup = lookup();
          addTearDown(() async {
            if (!oldResult.isCompleted) oldResult.complete([_line('old')]);
            if (!newResult.isCompleted) newResult.complete([_line('new')]);
            await oldLookup;
          });
          await oldEntered.future;
          controller.applyRuleState(
            enabled.copyWith(enabledIds: {}),
            contextVersion: 1,
          );
          controller.applyRuleState(enabled, contextVersion: 1);
          if (oldFirst) {
            oldResult.complete([
              _line('old', provider: rule.id, clientVerified: true),
            ]);
            await oldLookup;
          }
          final newLookup = lookup();
          await newEntered.future.timeout(const Duration(seconds: 1));
          newResult.complete([
            _line('new', provider: rule.id, clientVerified: true),
          ]);
          expect((await newLookup).single.id, 'new');
          if (!oldFirst) {
            oldResult.complete([
              _line('old', provider: rule.id, clientVerified: true),
            ]);
            await oldLookup;
          }
          expect((await lookup()).single.id, 'new');
          expect(calls, 2);
        },
      );
    }

    test('rule-state change retires failure health demotion', () async {
      final preferred = _rule.copyWith(
        id: 'fixture:review-health-a',
        engine: 'tvbox-json-api',
        baseUrl: 'https://health-a.example',
        priority: 1,
      );
      final fallback = _rule.copyWith(
        id: 'fixture:review-health-b',
        engine: 'tvbox-json-api',
        baseUrl: 'https://health-b.example',
        priority: 2,
      );
      final rules = [preferred, fallback];
      final state = _enabledReviewRules(rules);
      final order = <String>[];
      final resolver = _ReviewRuleResolver((rule, episode) async {
        order.add(rule.id);
        return [_line('failure', provider: rule.id, available: false)];
      });
      RulePlaybackSourceRepository repository(List<RulePlugin> selected) =>
          RulePlaybackSourceRepository(
            repository: RulePluginRepository(extraRules: selected),
            ruleState: _enabledReviewRules(selected),
            resolver: resolver,
            cacheNamespace: 'review-health',
          );
      final all = repository(rules);
      final controller = _controller(
        backend: _FakePlaybackRepository.empty(),
        rule: all,
        activeVersion: () => 1,
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: state,
      );
      final preferredOnly = repository([preferred]);
      for (final number in [1, 2]) {
        await preferredOnly.linesForEpisodeMode(
          _subject,
          _episodeFor(number),
          expandAll: true,
        );
      }
      order.clear();
      await all.linesForEpisodeMode(_subject, _episodeFor(3));
      expect(order, [
        fallback.id,
        preferred.id,
      ], reason: 'two failures demote the preferred rule');
      controller.applyRuleState(
        state.copyWith(enabledIds: {}),
        contextVersion: 1,
      );
      controller.applyRuleState(state, contextVersion: 1);
      order.clear();
      await all.linesForEpisodeMode(_subject, _episodeFor(4));
      expect(order, [
        preferred.id,
        fallback.id,
      ], reason: 'retirement restores configured priority');
    });
  });

  test(
    'CORE-003 discovery owns repository retirement before resolver reset',
    () async {
      final rule = _rule.copyWith(
        id: 'fixture:scope-cache',
        engine: 'tvbox-json-api',
      );
      final rules = RulePluginRepository(extraRules: [rule]);
      final state = RulePluginState(
        installedIds: {rule.id},
        enabledIds: {rule.id},
        customRules: [rule],
        approvedPermissionDigests: {
          rule.id: rule.effectiveManifest.permissionDigest,
        },
      );
      final resolver = _ScopeCacheResolver();
      final repository = RulePlaybackSourceRepository(
        repository: rules,
        ruleState: state,
        resolver: resolver,
        cacheNamespace: 'discovery-scope-retirement-fixture',
      );
      Future<List<PlaybackLine>> lookup() =>
          repository.linesForEpisodeMode(_subject, _episode, expandAll: true);
      RulePlaybackSourceRepository.clearRuntimeCaches();
      addTearDown(RulePlaybackSourceRepository.clearRuntimeCaches);
      expect((await lookup()).single.id, 'resolve-1');
      expect((await lookup()).single.id, 'resolve-1');

      var activeVersion = 1;
      final resetLookups = <Future<List<PlaybackLine>>>[];
      final controller = PlaybackDiscoveryController(
        backendRepository: (_) => _FakePlaybackRepository.empty(),
        ruleRepository: (_) => repository,
        verifyLine:
            (
              line, {
              enrichMetadata = true,
              forceRefresh = false,
              cancellationToken,
            }) async => line,
        isContextCurrent: (version) => version == activeVersion,
        clearRuleRuntimeCaches: () => resetLookups.add(lookup()),
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: state,
      );
      expect((await resetLookups.single).single.id, 'resolve-2');
      controller.clearCaches();
      expect((await lookup()).single.id, 'resolve-2');
      expect(resetLookups, hasLength(1));

      activeVersion = 2;
      _load(
        controller,
        accountId: 'account-b',
        contextVersion: 2,
        ruleState: state,
      );
      expect((await resetLookups.last).single.id, 'resolve-3');
      expect(resetLookups, hasLength(2));
      controller.dispose();
      expect((await resetLookups.last).single.id, 'resolve-4');
      controller.dispose();
      expect(resetLookups, hasLength(3));
      expect(resolver.calls, 4);
    },
  );

  group('REVIEW-SPEC-002 progressive route versions', () {
    const url = 'https://media.example/video.mp4?b=2&a=1';
    const headers = {'Referer': 'https://request.example/'};
    for (final hasRules in [false, true]) {
      for (final verifiedFirst in [false, true]) {
        for (final staleProbeSucceeds in [false, true]) {
          for (final rulesFirst in hasRules ? [false, true] : [false]) {
            test(
              'rules=$hasRules verifiedFirst=$verifiedFirst staleSuccess=$staleProbeSucceeds rulesFirst=$rulesFirst',
              () async {
                final candidate = _line(
                  'route',
                  url: url,
                  headers: headers,
                  available: false,
                  requiresClientProbe: true,
                  publicHttpOnly: true,
                );
                final verified = _line(
                  'route',
                  url: url,
                  headers: headers,
                  serverVerified: true,
                  latency: const Duration(milliseconds: 10),
                );
                final pending = _line(
                  'pending',
                  available: false,
                  requiresClientProbe: true,
                );
                final before = _line('before', clientVerified: true);
                final after = _line('after', clientVerified: true);
                final added = _line('full-only', clientVerified: true);
                final ruleLine = _line('rule-line', clientVerified: true);
                final fullEntered = Completer<void>();
                final releaseFull = Completer<void>();
                final probeEntered = Completer<void>();
                final releaseProbes = Completer<void>();
                final releaseRules = Completer<void>();
                final probePublished = Completer<void>();
                final rulePublished = Completer<void>();
                final snapshots = <List<PlaybackLine>>[];
                final probeIds = <String>[];
                final modes = <bool>[];
                final controller = _controller(
                  backend: _FakePlaybackRepository(
                    load:
                        (_, _, {required expandAll, cancellationToken}) async {
                          modes.add(expandAll);
                          if (!expandAll) {
                            return [
                              before,
                              verifiedFirst ? verified : candidate,
                              pending,
                              after,
                            ];
                          }
                          fullEntered.complete();
                          await releaseFull.future;
                          return [added, verifiedFirst ? candidate : verified];
                        },
                  ),
                  rule: _FakePlaybackRepository(
                    load:
                        (_, _, {required expandAll, cancellationToken}) async =>
                            [],
                    updates: (_, _, {cancellationToken}) async* {
                      await releaseRules.future;
                      yield PlaybackLineLookupUpdate(
                        lines: [ruleLine],
                        completedRules: 1,
                        totalRules: 1,
                        phase: PlaybackLineLookupPhase.complete,
                      );
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
                        probeIds.add(line.id);
                        if (line.id == 'pending') probeEntered.complete();
                        await releaseProbes.future;
                        final success =
                            line.id == 'pending' || staleProbeSucceeds;
                        return _line(
                          line.id,
                          provider: line.providerId,
                          url: line.url,
                          headers: line.headers,
                          publicHttpOnly: line.publicHttpOnly,
                          available: success,
                          clientVerified: success,
                        );
                      },
                );
                addTearDown(controller.dispose);
                _load(
                  controller,
                  accountId: 'account-a',
                  contextVersion: 1,
                  ruleState: hasRules ? _ruleState : const RulePluginState(),
                );
                final done = Completer<void>();
                final subscription = controller
                    .lineUpdatesForEpisode(_subject, _episode)
                    .listen(
                      (update) {
                        snapshots.add(update.lines);
                        if (update.lines.any(
                              (line) =>
                                  line.id == 'pending' && line.clientVerified,
                            ) &&
                            !probePublished.isCompleted) {
                          probePublished.complete();
                        }
                        if (update.lines.any(
                              (line) => line.id == ruleLine.id,
                            ) &&
                            !rulePublished.isCompleted) {
                          rulePublished.complete();
                        }
                      },
                      onError: done.completeError,
                      onDone: done.complete,
                    );
                addTearDown(() async {
                  if (!releaseFull.isCompleted) releaseFull.complete();
                  if (!releaseProbes.isCompleted) releaseProbes.complete();
                  if (!releaseRules.isCompleted) releaseRules.complete();
                  await subscription.cancel();
                });
                await fullEntered.future.timeout(const Duration(seconds: 3));
                expect(snapshots.single.map((line) => line.id), [
                  'before',
                  'route',
                  'pending',
                  'after',
                ]);
                releaseFull.complete();
                await probeEntered.future.timeout(const Duration(seconds: 3));
                if (hasRules && rulesFirst) {
                  releaseRules.complete();
                  await rulePublished.future.timeout(
                    const Duration(seconds: 3),
                  );
                }
                releaseProbes.complete();
                await probePublished.future.timeout(const Duration(seconds: 3));
                if (!releaseRules.isCompleted) releaseRules.complete();
                await done.future.timeout(const Duration(seconds: 3));
                final authoritative = snapshots.last;
                expect(authoritative.where((line) => line.id == 'route'), [
                  same(verified),
                ]);
                expect(
                  probeIds,
                  ['pending'],
                  reason:
                      'superseded candidate must not be probed, even if that probe could succeed',
                );
                expect(modes, [false, true]);
                expect(authoritative.map((line) => line.id), [
                  'before',
                  'route',
                  'pending',
                  'after',
                  'full-only',
                  if (hasRules) 'rule-line',
                ]);
                for (final snapshot in snapshots.skip(1)) {
                  expect(snapshot.where((line) => line.id == 'route'), [
                    same(verified),
                  ]);
                }
                expect(verified.url, url);
                expect(verified.headers, headers);
              },
            );
          }
        }
      }
    }

    for (final hasRules in [false, true]) {
      for (final distinct in ['headers', 'signed-url', 'provider', 'episode']) {
        test(
          'rules=$hasRules same ID keeps distinct $distinct request while its peer probe fails',
          () async {
            final candidate = _line(
              'shared-id',
              url: url,
              headers: headers,
              available: false,
              requiresClientProbe: true,
              publicHttpOnly: true,
            );
            final full = _line(
              'shared-id',
              url: distinct == 'signed-url'
                  ? 'https://media.example/video.mp4?a=1&b=2'
                  : url,
              headers: distinct == 'headers'
                  ? {'Referer': 'https://other.example/'}
                  : headers,
              provider: distinct == 'provider'
                  ? 'zeluna:other'
                  : candidate.providerId,
              episodeId: distinct == 'episode' ? _episode.id + 1 : _episode.id,
              serverVerified: true,
              latency: const Duration(milliseconds: 10),
            );
            final probeEntered = Completer<void>();
            final releaseProbe = Completer<void>();
            final controller = _controller(
              backend: _FakePlaybackRepository(
                load: (_, _, {required expandAll, cancellationToken}) async => [
                  expandAll ? full : candidate,
                ],
              ),
              rule: _FakePlaybackRepository.empty(),
              activeVersion: () => 1,
              verify:
                  (
                    line, {
                    enrichMetadata = true,
                    forceRefresh = false,
                    cancellationToken,
                  }) async {
                    expect(line, same(candidate));
                    probeEntered.complete();
                    await releaseProbe.future;
                    return candidate;
                  },
            );
            addTearDown(controller.dispose);
            _load(
              controller,
              accountId: 'account-a',
              contextVersion: 1,
              ruleState: hasRules ? _ruleState : const RulePluginState(),
            );
            final updates = controller
                .lineUpdatesForEpisode(_subject, _episode)
                .toList();
            addTearDown(() async {
              if (!releaseProbe.isCompleted) releaseProbe.complete();
              await updates;
            });
            await probeEntered.future.timeout(const Duration(seconds: 3));
            releaseProbe.complete();
            expect((await updates).last.lines, [same(candidate), same(full)]);
            expect(full.available, isTrue);
          },
        );
      }
    }
  });

  group('REVIEW-STD-002 ordinary request writeback', () {
    const url = 'https://media.example/video.mp4?b=2&a=1';
    const headers = {'Referer': 'https://request.example/'};
    for (final mode in ['full', 'warmup']) {
      for (final distinct in [
        'headers',
        'signed-url',
        'provider',
        'episode',
        'same-request',
      ]) {
        for (final probeSucceeds in [false, true]) {
          test('$mode $distinct probeSuccess=$probeSucceeds', () async {
            final warmup = mode == 'warmup';
            final hasPeer = distinct != 'same-request';
            // A single already-available route still awaits its real probe;
            // with a peer, only B is initially playable, so warmup cannot exit.
            final initiallyVerified = !hasPeer && !probeSucceeds;
            final candidate = _line(
              'shared-id',
              url: url,
              headers: headers,
              available: initiallyVerified,
              serverVerified: initiallyVerified,
              requiresClientProbe: true,
              publicHttpOnly: true,
            );
            final peer = _line(
              'shared-id',
              url: distinct == 'signed-url'
                  ? 'https://media.example/video.mp4?a=1&b=2'
                  : url,
              headers: distinct == 'headers'
                  ? {'Referer': 'https://other.example/'}
                  : headers,
              provider: distinct == 'provider'
                  ? 'zeluna:other'
                  : candidate.providerId,
              episodeId: distinct == 'episode' ? _episode.id + 1 : _episode.id,
              serverVerified: true,
              latency: const Duration(milliseconds: 10),
            );
            final probed = _line(
              candidate.id,
              provider: candidate.providerId,
              episodeId: candidate.episodeId,
              url: url,
              headers: headers,
              publicHttpOnly: true,
              available: probeSucceeds,
              clientVerified: probeSucceeds,
              latency: const Duration(milliseconds: 5),
            );
            final probeEntered = Completer<void>();
            final releaseProbe = Completer<void>();
            var backendCalls = 0;
            var probeCalls = 0;
            final controller = _controller(
              backend: _FakePlaybackRepository(
                load: (_, _, {required expandAll, cancellationToken}) async {
                  backendCalls++;
                  expect(expandAll, !warmup);
                  return [candidate, if (hasPeer) peer];
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
                    expect(line, same(candidate));
                    probeCalls++;
                    if (!probeEntered.isCompleted) probeEntered.complete();
                    await releaseProbe.future;
                    return probed;
                  },
            );
            addTearDown(controller.dispose);
            _load(controller, accountId: 'account-a', contextVersion: 1);
            Future<List<PlaybackLine>> lookup() =>
                controller.linesForEpisodeMode(
                  _subject,
                  _episode,
                  expandAll: !warmup,
                  lookupIntent: warmup
                      ? PlaybackLookupIntent.warmup
                      : PlaybackLookupIntent.interactive,
                );
            var returned = false;
            final first = lookup().then((lines) {
              returned = true;
              return lines;
            });
            addTearDown(() async {
              if (!releaseProbe.isCompleted) releaseProbe.complete();
              await first;
            });
            await probeEntered.future.timeout(const Duration(seconds: 3));
            expect(returned, isFalse, reason: 'must reach the probe writeback');
            releaseProbe.complete();
            final expected = [
              if (!warmup || probeSucceeds) same(probed),
              if (hasPeer) same(peer),
            ];
            final result = await first.timeout(const Duration(seconds: 3));
            expect(result, expected);
            expect(result.where((line) => line.available), [
              if (probeSucceeds) same(probed),
              if (hasPeer) same(peer),
            ]);
            // Read the same public lookup again: cached payload must retain B.
            // A warmup with no reusable line keeps its existing eviction policy.
            final evicted = warmup && !hasPeer && !probeSucceeds;
            expect(controller.cachedBackendEntries, evicted ? 0 : 1);
            expect(
              await lookup().timeout(const Duration(seconds: 3)),
              expected,
            );
            expect(backendCalls, evicted ? 2 : 1);
            // Full lookup retains its existing success-only cache-write policy;
            // warmup caches only reusable results. Do not broaden semantics.
            expect(probeCalls, evicted || (!warmup && !probeSucceeds) ? 2 : 1);
          });
        }
      }
    }
  });

  group('CORE-002 request equivalence', () {
    const url = 'https://media.example/video.m3u8?b=2&a=1';
    for (final name in ['Referer', 'Origin', 'Authorization', 'Cookie']) {
      test('retains distinct $name contexts and original IDs in order', () {
        final first = _line('first', url: url, headers: {name: 'fixture-a'});
        final second = _line('second', url: url, headers: {name: 'fixture-b'});
        final merged = mergePlaybackLines([first, second, first]);
        expect(merged, [first, second]);
        expect(merged.map((line) => line.id), ['first', 'second']);
      });
    }

    test('retains distinct trust constraints', () {
      final lines = [
        _line('unverified', url: url),
        _line('public-only', url: url, publicHttpOnly: true),
        _line('server-verified', url: url, serverVerified: true),
        _line('client-verified', url: url, clientVerified: true),
        _line('needs-probe', url: url, requiresClientProbe: true),
      ];
      expect(mergePlaybackLines(lines), lines);
    });

    test('equivalent headers upgrade in place without changing signed URL', () {
      final first = _line(
        'first',
        url: url,
        available: false,
        headers: {'Referer': 'https://example.com/', 'X-Test': 'yes'},
      );
      final other = _line('other');
      final upgraded = _line(
        'upgraded',
        url: url,
        headers: {'x-test': 'yes', 'referer': 'https://example.com/'},
      );
      final duplicate = _line(
        'duplicate',
        url: url,
        headers: {'X-TEST': 'yes', 'REFERER': 'https://example.com/'},
      );
      expect(mergePlaybackLines([first, other, upgraded, duplicate]), [
        upgraded,
        other,
      ]);
      expect(upgraded.url, url);
      expect(
        mergePlaybackLines([
          upgraded,
          _line('reordered', url: 'https://media.example/video.m3u8?a=1&b=2'),
        ]),
        hasLength(2),
      );
    });

    test('empty URLs retain provider and line placeholder identity', () {
      final first = _line('missing', url: '');
      final second = _line('missing', url: '', provider: 'other');
      final third = _line('another', url: '');
      expect(mergePlaybackLines([first, second, third, first]), [
        first,
        second,
        third,
      ]);
    });
  });

  test(
    'CORE-002 verification updates a route without duplicating its ID',
    () async {
      final candidate = _line(
        'candidate',
        available: false,
        requiresClientProbe: true,
      );
      final verified = _line('candidate', clientVerified: true);
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async => [
            candidate,
          ],
        ),
        activeVersion: () => 1,
        verify:
            (
              line, {
              enrichMetadata = true,
              forceRefresh = false,
              cancellationToken,
            }) async => verified,
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);
      expect(await controller.linesForEpisodeMode(_subject, _episode), [
        verified,
      ]);
    },
  );

  for (final mode in ['expanded', 'progressive', 'warmup']) {
    test('CORE-002 $mode retains distinct header variants', () async {
      final variants = [
        _line(
          'first-context',
          url: 'https://media.example/video.mp4',
          headers: {'Referer': 'https://first.example/'},
          clientVerified: true,
        ),
        _line(
          'second-context',
          url: 'https://media.example/video.mp4',
          headers: {'Referer': 'https://second.example/'},
          clientVerified: true,
        ),
      ];
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async =>
              variants,
        ),
        activeVersion: () => 1,
      );
      addTearDown(controller.dispose);
      _load(controller, accountId: 'account-a', contextVersion: 1);
      final List<PlaybackLine> lines;
      if (mode == 'progressive') {
        final updates = await controller
            .lineUpdatesForEpisode(_subject, _episode)
            .toList();
        lines = updates.last.lines;
      } else {
        lines = await controller.linesForEpisodeMode(
          _subject,
          _episode,
          expandAll: mode == 'expanded',
          lookupIntent: mode == 'warmup'
              ? PlaybackLookupIntent.warmup
              : PlaybackLookupIntent.interactive,
        );
      }
      expect(lines.map((line) => line.id), ['first-context', 'second-context']);
    });
  }

  for (final preferred in <String?>[null, 'zeluna:preferred']) {
    test(
      'expanded lookup retains all routes with preference $preferred',
      () async {
        final requestedModes = <bool>[];
        final backend = _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async {
            requestedModes.add(expandAll);
            if (preferred != null) {
              await Future<void>.delayed(const Duration(seconds: 7));
            }
            return List.generate(
              58,
              (i) => _line(
                'route-$i',
                provider: i == 0 ? 'zeluna:preferred' : 'zeluna:anich',
                available: i < 2,
                serverVerified: i < 2,
              ),
            );
          },
        );
        final controller = _controller(
          backend: backend,
          activeVersion: () => 1,
        );
        addTearDown(controller.dispose);
        _load(controller, accountId: 'account-a', contextVersion: 1);
        final lines = await controller.linesForEpisodeMode(
          _subject,
          _episode,
          expandAll: true,
          preferredProviderId: preferred,
        );
        expect(requestedModes, [true]);
        expect(
          lines.map((line) => line.id).toSet(),
          List.generate(58, (i) => 'route-$i').toSet(),
        );
      },
    );
  }

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
    'expanded lookup includes enabled rule lines when backend is already playable',
    () async {
      var ruleCalls = 0;
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async =>
              <PlaybackLine>[_line('backend-line', provider: 'zeluna:backend')],
        ),
        rule: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async {
            ruleCalls++;
            return <PlaybackLine>[
              _line('enabled-rule-line', provider: 'rule:enabled'),
            ];
          },
        ),
        activeVersion: () => 1,
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
        expandAll: true,
      );

      expect(ruleCalls, 1);
      expect(
        lines.map((line) => line.id),
        containsAll(<String>['backend-line', 'enabled-rule-line']),
      );
    },
  );

  test(
    'quick lookup still returns a playable backend line without waiting for rules',
    () async {
      var ruleCalls = 0;
      final controller = _controller(
        backend: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async =>
              <PlaybackLine>[_line('backend-line', provider: 'zeluna:backend')],
        ),
        rule: _FakePlaybackRepository(
          load: (_, _, {required expandAll, cancellationToken}) async {
            ruleCalls++;
            return <PlaybackLine>[
              _line('enabled-rule-line', provider: 'rule:enabled'),
            ];
          },
        ),
        activeVersion: () => 1,
      );
      addTearDown(controller.dispose);
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );

      final lines = await controller.linesForEpisodeMode(_subject, _episode);

      expect(ruleCalls, 0);
      expect(lines.map((line) => line.id), <String>['backend-line']);
    },
  );

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

  test(
    'enabled rule lookup publishes before slow backend verification completes',
    () async {
      final verification = Completer<void>();
      var verifyCalls = 0;
      var ruleStreamCalls = 0;
      final backend = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => [
          _line('slow-backend', available: false, serverVerified: true),
        ],
      );
      final rule = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => const [],
        updates: (_, _, {cancellationToken}) async* {
          ruleStreamCalls++;
          yield PlaybackLineLookupUpdate(
            lines: <PlaybackLine>[
              _line('enabled-rule-line', provider: 'rule:enabled'),
            ],
            completedRules: 1,
            totalRules: 1,
            phase: PlaybackLineLookupPhase.complete,
          );
        },
      );
      final controller = _controller(
        backend: backend,
        rule: rule,
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
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );
      final snapshots = <PlaybackLineLookupUpdate>[];
      final done = controller
          .lineUpdatesForEpisode(_subject, _episode)
          .forEach(snapshots.add);
      addTearDown(() async {
        if (!verification.isCompleted) verification.complete();
        await done;
        controller.dispose();
      });

      await _waitUntil(() => verifyCalls == 1);

      expect(ruleStreamCalls, 1);
      await _waitUntil(
        () => snapshots.any(
          (update) =>
              update.lines.any((line) => line.id == 'enabled-rule-line'),
        ),
      );
      expect(verification.isCompleted, isFalse);

      verification.complete();
      await done;
    },
  );

  test(
    'enabled rules publish before slow full backend discovery completes',
    () async {
      final expanded = Completer<List<PlaybackLine>>();
      var fullCalls = 0;
      final backend = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async {
          if (expandAll) {
            fullCalls++;
            return expanded.future;
          }
          return [_line('quick', clientVerified: true)];
        },
      );
      final rule = _FakePlaybackRepository(
        load: (_, _, {required expandAll, cancellationToken}) async => [],
        updates: (_, _, {cancellationToken}) async* {
          yield PlaybackLineLookupUpdate(
            lines: [
              _line(
                'early-rule',
                provider: 'rule:enabled',
                clientVerified: true,
              ),
            ],
            completedRules: 1,
            totalRules: 1,
            phase: PlaybackLineLookupPhase.complete,
          );
        },
      );
      final controller = _controller(
        backend: backend,
        rule: rule,
        activeVersion: () => 1,
      );
      _load(
        controller,
        accountId: 'account-a',
        contextVersion: 1,
        ruleState: _ruleState,
      );
      final snapshots = <PlaybackLineLookupUpdate>[];
      final done = controller
          .lineUpdatesForEpisode(_subject, _episode)
          .forEach(snapshots.add);
      addTearDown(() async {
        if (!expanded.isCompleted) expanded.complete([]);
        await done;
        controller.dispose();
      });
      await _waitUntil(() => fullCalls == 1);
      await _waitUntil(
        () => snapshots.any((u) => u.lines.any((l) => l.id == 'early-rule')),
      );
      expect(expanded.isCompleted, isFalse);
      expect(snapshots.last.phase, isNot(PlaybackLineLookupPhase.complete));
      expanded.complete([_line('full', clientVerified: true)]);
      await done;
      expect(
        snapshots.last.lines.map((l) => l.id),
        containsAll(['quick', 'full', 'early-rule']),
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

  group('REVIEW-SPEC-003 prefetch request writeback', () {
    for (final successFirst in [true, false]) {
      test('different Referer successFirst=$successFirst', () async {
        final episode = _episodeFor(2);
        const url = 'https://media.example/next.m3u8';
        const aHeaders = {'Referer': 'https://a.example/'};
        const bHeaders = {'Referer': 'https://b.example/'};
        final a = _line(
          'shared-id',
          episodeId: episode.id,
          url: url,
          headers: aHeaders,
          publicHttpOnly: true,
          serverVerified: true,
        );
        final b = _line(
          'shared-id',
          episodeId: episode.id,
          url: url,
          headers: bHeaders,
          publicHttpOnly: true,
          serverVerified: true,
        );
        final success = _line(
          a.id,
          episodeId: episode.id,
          url: url,
          headers: aHeaders,
          publicHttpOnly: true,
          serverVerified: true,
          clientVerified: true,
        );
        final failure = _line(
          b.id,
          episodeId: episode.id,
          url: url,
          headers: bHeaders,
          publicHttpOnly: true,
          available: false,
        );
        final entered = [Completer<void>(), Completer<void>()];
        final release = [Completer<PlaybackLine>(), Completer<PlaybackLine>()];
        final completed = [Completer<void>(), Completer<void>()];
        final requests = <PlaybackLine>[];
        final completionOrder = <int>[];
        var backendCalls = 0;
        final controller = _controller(
          backend: _FakePlaybackRepository(
            load:
                (_, requested, {required expandAll, cancellationToken}) async {
                  backendCalls++;
                  expect(requested, same(episode));
                  expect(expandAll, isFalse);
                  return [a, b];
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
                // Neither route requires the ordinary lookup's client probe.
                // Both callbacks must be the public prefetch's second round.
                expect(enrichMetadata, isFalse);
                expect(line.requiresClientProbe, isFalse);
                expect(line.clientVerified, isFalse);
                expect(line.serverVerified, isTrue);
                final index = identical(line, a) ? 0 : 1;
                expect(line, same(index == 0 ? a : b));
                requests.add(line);
                entered[index].complete();
                final result = await release[index].future;
                completionOrder.add(index);
                completed[index].complete();
                return result;
              },
        );
        addTearDown(controller.dispose);
        _load(controller, accountId: 'account-a', contextVersion: 1);
        var returned = false;
        final prefetch = controller
            .prefetchPlaybackForEpisode(_subject, episode)
            .then((_) => returned = true);
        addTearDown(() async {
          if (!release[0].isCompleted) release[0].complete(success);
          if (!release[1].isCompleted) release[1].complete(failure);
          await prefetch;
        });
        await Future.wait(
          entered.map((gate) => gate.future),
        ).timeout(const Duration(seconds: 3));
        expect(returned, isFalse);
        expect(requests, [same(a), same(b)]);
        expect(requests.map((line) => line.headers), [aHeaders, bHeaders]);
        expect(backendCalls, 1);
        expect(
          controller.prefetchedWarmupBundleForEpisode(_subject, episode),
          isNull,
        );

        final first = successFirst ? 0 : 1;
        final second = 1 - first;
        final results = [success, failure];
        release[first].complete(results[first]);
        await completed[first].future.timeout(const Duration(seconds: 3));
        // Drain the first probe's async-stream writeback before releasing peer.
        await Future<void>.delayed(Duration.zero);
        expect(completionOrder, [first]);
        expect(returned, isFalse);
        release[second].complete(results[second]);
        await prefetch.timeout(const Duration(seconds: 3));
        expect(completionOrder, [first, second]);
        expect(requests, hasLength(2));
        final bundle = controller.prefetchedWarmupBundleForEpisode(
          _subject,
          episode,
        );
        expect(bundle, isNotNull);
        expect(bundle!.primary, same(success));
        expect(bundle.primary.headers, aHeaders);
        expect(bundle.primary.available, isTrue);
        expect(bundle.primary.serverVerified, isTrue);
        expect(bundle.primary.clientVerified, isTrue);
        expect(bundle.primary.publicHttpOnly, isTrue);
        expect(bundle.primary.requiresClientProbe, isFalse);
        expect(bundle.allLines, [same(success)]);
        expect(controller.cachedWarmupEntries, 1);
      });
    }
  });

  group('REVIEW-SPEC-003 prefetch route versions', () {
    for (final verifiedFirst in [false, true]) {
      for (final staleSucceeds in [false, true]) {
        test(
          'verifiedFirst=$verifiedFirst staleSucceeds=$staleSucceeds',
          () async {
            final episode = _episodeFor(2);
            const headers = {'Referer': 'https://same-request.example/'};
            final obsolete = _line(
              'same-route',
              episodeId: episode.id,
              headers: headers,
              serverVerified: true,
              publicHttpOnly: true,
            );
            final current = _line(
              obsolete.id,
              episodeId: episode.id,
              headers: headers,
              serverVerified: true,
              clientVerified: true,
            );
            final inventory = verifiedFirst
                ? [current, obsolete]
                : [obsolete, current];
            // Route-version qualification must not relax generic trust dedupe.
            expect(mergePlaybackLines(inventory), inventory);
            final probes = <PlaybackLine>[];
            final controller = _controller(
              backend: _FakePlaybackRepository(
                load: (_, _, {required expandAll, cancellationToken}) async =>
                    inventory,
              ),
              activeVersion: () => 1,
              verify:
                  (
                    line, {
                    enrichMetadata = true,
                    forceRefresh = false,
                    cancellationToken,
                  }) async {
                    probes.add(line);
                    return _line(
                      line.id,
                      episodeId: episode.id,
                      headers: headers,
                      publicHttpOnly: true,
                      available: staleSucceeds,
                      clientVerified: staleSucceeds,
                    );
                  },
            );
            addTearDown(controller.dispose);
            _load(controller, accountId: 'account-a', contextVersion: 1);
            await controller
                .prefetchPlaybackForEpisode(_subject, episode)
                .timeout(const Duration(seconds: 3));
            expect(
              probes,
              isEmpty,
              reason:
                  'do not probe obsolete trust versions of a usable request',
            );
            final bundle = controller.prefetchedWarmupBundleForEpisode(
              _subject,
              episode,
            );
            expect(bundle?.primary, same(current));
            expect(bundle?.allLines, [same(current)]);
            expect(bundle?.primary.headers, headers);
            expect(bundle?.primary.clientVerified, isTrue);
            expect(bundle?.primary.publicHttpOnly, isFalse);
            expect(mergePlaybackLines(inventory), inventory);
          },
        );
      }
    }
  });

  group('REVIEW-SPEC-003 prefetch controls', () {
    for (final succeeds in [false, true]) {
      test('single request real probe succeeds=$succeeds', () async {
        final episode = _episodeFor(2);
        const headers = {'Referer': 'https://single.example/'};
        final candidate = _line(
          'single',
          episodeId: episode.id,
          headers: headers,
          serverVerified: true,
        );
        final result = _line(
          candidate.id,
          episodeId: episode.id,
          headers: headers,
          available: succeeds,
          serverVerified: succeeds,
          clientVerified: succeeds,
        );
        final entered = Completer<void>();
        final release = Completer<PlaybackLine>();
        var probeCalls = 0;
        final controller = _controller(
          backend: _FakePlaybackRepository(
            load: (_, _, {required expandAll, cancellationToken}) async => [
              candidate,
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
                expect(line, same(candidate));
                expect(line.requiresClientProbe, isFalse);
                probeCalls++;
                entered.complete();
                return release.future;
              },
        );
        addTearDown(controller.dispose);
        _load(controller, accountId: 'account-a', contextVersion: 1);
        var returned = false;
        final prefetch = controller
            .prefetchPlaybackForEpisode(_subject, episode)
            .then((_) => returned = true);
        addTearDown(() async {
          if (!release.isCompleted) release.complete(result);
          await prefetch;
        });
        await entered.future.timeout(const Duration(seconds: 3));
        expect(returned, isFalse);
        release.complete(result);
        await prefetch.timeout(const Duration(seconds: 3));
        expect(probeCalls, 1);
        final bundle = controller.prefetchedWarmupBundleForEpisode(
          _subject,
          episode,
        );
        if (succeeds) {
          expect(bundle?.primary, same(result));
          expect(bundle?.primary.headers, headers);
          expect(bundle?.allLines, [same(result)]);
        } else {
          expect(
            bundle,
            isNull,
            reason: 'a real failure must retire even an available route',
          );
        }
        expect(controller.cachedWarmupEntries, succeeds ? 1 : 0);
      });
    }

    for (final retirement in [
      'caller-cancel',
      'account-switch',
      'cache-epoch',
    ]) {
      test('$retirement rejects a late second-round probe', () async {
        final episode = _episodeFor(2);
        var version = 1;
        final token = RulePlaybackCancellationToken();
        final candidate = _line(
          'late',
          episodeId: episode.id,
          headers: {'Referer': 'https://late.example/'},
          serverVerified: true,
        );
        final result = _line(
          candidate.id,
          episodeId: candidate.episodeId,
          headers: candidate.headers,
          serverVerified: true,
          clientVerified: true,
        );
        final entered = Completer<void>();
        final release = Completer<PlaybackLine>();
        RulePlaybackCancellationToken? probeToken;
        var probeCalls = 0;
        final controller = _controller(
          backend: _FakePlaybackRepository(
            load: (_, _, {required expandAll, cancellationToken}) async => [
              candidate,
            ],
          ),
          activeVersion: () => version,
          verify:
              (
                line, {
                enrichMetadata = true,
                forceRefresh = false,
                cancellationToken,
              }) async {
                expect(line, same(candidate));
                expect(line.requiresClientProbe, isFalse);
                probeToken = cancellationToken;
                probeCalls++;
                entered.complete();
                return release.future;
              },
        );
        addTearDown(controller.dispose);
        _load(controller, accountId: 'account-a', contextVersion: version);
        var returned = false;
        final prefetch = controller
            .prefetchPlaybackForEpisode(
              _subject,
              episode,
              cancellationToken: token,
            )
            .then((_) => returned = true);
        addTearDown(() async {
          if (!release.isCompleted) release.complete(result);
          await prefetch;
        });
        await entered.future.timeout(const Duration(seconds: 3));
        expect(returned, isFalse);
        expect(probeToken, same(token));
        switch (retirement) {
          case 'caller-cancel':
            token.cancel();
          case 'account-switch':
            version = 2;
            _load(controller, accountId: 'account-b', contextVersion: version);
          case 'cache-epoch':
            controller.clearCaches();
        }
        expect(probeToken?.isCancelled, isTrue);
        release.complete(result);
        await prefetch.timeout(const Duration(seconds: 3));
        expect(probeCalls, 1);
        expect(
          controller.prefetchedWarmupBundleForEpisode(_subject, episode),
          isNull,
        );
        expect(controller.cachedWarmupEntries, 0);
        if (retirement == 'account-switch') {
          _load(controller, accountId: 'account-a', contextVersion: version);
          expect(
            controller.prefetchedWarmupBundleForEpisode(_subject, episode),
            isNull,
          );
        }
      });
    }
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
  void Function()? clearRuleRuntimeCaches,
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
  clearRuleRuntimeCaches: clearRuleRuntimeCaches ?? () {},
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
  _FakePlaybackRepository({required this.load, this.updates});

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
  final Stream<PlaybackLineLookupUpdate> Function(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  })?
  updates;
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
  }) =>
      updates?.call(subject, episode, cancellationToken: cancellationToken) ??
      const Stream<PlaybackLineLookupUpdate>.empty();
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
  bool publicHttpOnly = false,
  bool requiresClientProbe = false,
  Map<String, String> headers = const {},
  int? episodeId,
  String? url,
  DateTime? expiresAt,
  Duration? latency,
}) => PlaybackLine(
  id: id,
  episodeId: episodeId ?? _episode.id,
  providerId: provider,
  providerName: provider,
  title: id,
  quality: '1080P',
  format: 'hls',
  url: url ?? 'https://$id.example/video.m3u8',
  headers: headers,
  publicHttpOnly: publicHttpOnly,
  requiresClientProbe: requiresClientProbe,
  serverVerified: serverVerified,
  clientVerified: clientVerified,
  expiresAt: expiresAt,
  latency: latency,
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

class _ScopeCacheResolver extends RulePlaybackResolver {
  var calls = 0;

  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
    RulePlaybackCancellationToken? cancellationToken,
  }) async => [
    _line('resolve-${++calls}', provider: rule.id, clientVerified: true),
  ];
}

RulePluginState _enabledReviewRules(List<RulePlugin> rules) => RulePluginState(
  installedIds: {for (final rule in rules) rule.id},
  enabledIds: {for (final rule in rules) rule.id},
  customRules: rules,
  approvedPermissionDigests: {
    for (final rule in rules) rule.id: rule.effectiveManifest.permissionDigest,
  },
);

class _ReviewRuleResolver extends RulePlaybackResolver {
  _ReviewRuleResolver(this.load);
  final Future<List<PlaybackLine>> Function(RulePlugin, AnimeEpisode) load;
  @override
  Future<List<PlaybackLine>> resolveRule({
    required RulePlugin rule,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    bool verifyPlayable = true,
    RulePlaybackCancellationToken? cancellationToken,
  }) => load(rule, episode);
}
