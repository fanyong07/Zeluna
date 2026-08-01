import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../domain/subject_content_type.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../rules/rule_plugin_repository.dart';

const _maxRulesPerQuickLookup = 12;
const _maxRulesPerGroupPerLookup = 6;
const _quickLookupConcurrency = 4;
const _expandedLookupConcurrency = 6;
const _progressiveVerificationConcurrency = 4;
const _expandedRuleTimeout = Duration(seconds: 14);
const _expandedLookupTotalBudget = Duration(seconds: 24);
// A useful Animeko rule often needs one detail request plus one play-page
// request. The old 4.5/4.8 second edge repeatedly cancelled a nearly-finished
// rule and made the progressive scan start the same work again from scratch.
const _quickRuleTimeout = Duration(milliseconds: 6500);
const _quickLookupTotalBudget = Duration(milliseconds: 7000);
const _defaultProgressiveDiscoveryRuleTimeout = Duration(seconds: 10);
const _defaultProgressiveDiscoveryTimeSlice = Duration(seconds: 16);
const _defaultProgressiveVerificationTimeSlice = Duration(seconds: 24);
const _availableRuleCacheTtl = Duration(minutes: 3);
const _unavailableRuleCacheTtl = Duration(seconds: 20);
const _ruleHealthTtl = Duration(minutes: 30);
const _maxCachedRuleLookups = 256;
const _maxRuleHealthEntries = 128;

enum PlaybackLineLookupPhase { discovery, verification, complete }

class PlaybackLineLookupUpdate {
  const PlaybackLineLookupUpdate({
    required this.lines,
    required this.completedRules,
    required this.totalRules,
    required this.phase,
    this.timedOut = false,
    this.resolvedProviderId,
  });

  final List<PlaybackLine> lines;
  final int completedRules;
  final int totalRules;
  final PlaybackLineLookupPhase phase;
  final bool timedOut;
  final String? resolvedProviderId;

  bool get isComplete => phase == PlaybackLineLookupPhase.complete;
}

abstract class PlaybackSourceRepository {
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  });

  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  });

  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  });
}

class InternetArchivePlaybackSourceRepository {
  InternetArchivePlaybackSourceRepository({http.Client? client})
    : _client =
          client ??
          createNetworkHttpClient(
            NetworkRequestPolicy.forService(NetworkServiceKind.metadataApi),
          );

  final http.Client _client;

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) async {
    if (!subject.source.startsWith('archive:')) return const [];
    final identifier = subject.source.substring('archive:'.length).trim();
    if (identifier.isEmpty) return const [];
    final response = await _client
        .get(
          Uri.parse(
            'https://archive.org/metadata/${Uri.encodeComponent(identifier)}',
          ),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final files = decoded is Map ? decoded['files'] : null;
    if (files is! List) return const [];
    final metadata = decoded is Map && decoded['metadata'] is Map
        ? decoded['metadata'] as Map
        : const {};
    if (!_archiveRightsAllowed(metadata)) return const [];
    final candidates =
        files.whereType<Map>().where((item) {
          final name = item['name']?.toString().toLowerCase() ?? '';
          final format = item['format']?.toString().toLowerCase() ?? '';
          final size = int.tryParse(item['size']?.toString() ?? '') ?? 0;
          final excluded = _containsAny(name, const [
            '_thumb',
            'thumbnail',
            'sample',
            'preview',
            'trailer',
          ]);
          return !excluded &&
              size > 1024 * 1024 &&
              (name.endsWith('.mp4') ||
                  name.endsWith('.webm') ||
                  format.contains('mpeg4') ||
                  format.contains('h.264'));
        }).toList()..sort((a, b) {
          return _archiveFileScore(b).compareTo(_archiveFileScore(a));
        });
    final lines = await Future.wait(
      candidates.take(8).map((item) async {
        final name = item['name']?.toString() ?? '';
        final size = int.tryParse(item['size']?.toString() ?? '');
        final url =
            'https://archive.org/download/${Uri.encodeComponent(identifier)}/${Uri.encodeComponent(name)}';
        if (!await _probeVideo(Uri.parse(url))) return null;
        return PlaybackLine(
          id: 'archive:$identifier:$name',
          episodeId: episode.id,
          providerId: 'internet_archive',
          providerName: 'Internet Archive',
          title: name,
          quality: _archiveQuality(name),
          format: name.toLowerCase().endsWith('.webm') ? 'WebM' : 'MP4',
          url: url,
          sizeLabel: size == null
              ? null
              : '${(size / 1024 / 1024).toStringAsFixed(1)} MB',
          available: true,
          message: 'Internet Archive 已验证公开媒体文件',
        );
      }),
    );
    return lines.whereType<PlaybackLine>().take(6).toList(growable: false);
  }

  Future<bool> _probeVideo(Uri uri) async {
    try {
      final request = http.Request('GET', uri)
        ..headers['Range'] = 'bytes=0-1023';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 && response.statusCode != 206) {
        return false;
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final typeLooksPlayable =
          contentType.startsWith('video/') ||
          contentType.contains('octet-stream') ||
          contentType.contains('mp4') ||
          contentType.contains('webm');
      if (!typeLooksPlayable) return false;
      await response.stream.take(1).drain<void>();
      return true;
    } catch (_) {
      return false;
    }
  }
}

class EmptyPlaybackSourceRepository implements PlaybackSourceRepository {
  const EmptyPlaybackSourceRepository();

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    return linesForEpisodeMode(
      subject,
      episode,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    return [
      PlaybackLine(
        id: 'placeholder:${subject.id}:${episode.id}',
        episodeId: episode.id,
        providerId: 'custom',
        providerName: '暂无来源',
        title: '${subject.title} - 第${episode.number}集',
        quality: '暂无',
        format: '视频',
        available: false,
        message: '暂时没有可用的播放地址。',
      ),
    ];
  }

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    final lines = await linesForEpisodeMode(
      subject,
      episode,
      expandAll: true,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken?.isCancelled ?? false) return;
    yield PlaybackLineLookupUpdate(
      lines: lines,
      completedRules: 1,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.complete,
    );
  }
}

class RulePlaybackSourceRepository implements PlaybackSourceRepository {
  RulePlaybackSourceRepository({
    required RulePluginRepository repository,
    required RulePluginState ruleState,
    RulePlaybackResolver? resolver,
    Duration quickLookupBudget = _quickLookupTotalBudget,
    Duration progressiveDiscoveryTimeSlice =
        _defaultProgressiveDiscoveryTimeSlice,
    Duration progressiveVerificationTimeSlice =
        _defaultProgressiveVerificationTimeSlice,
    Duration progressiveDiscoveryRuleTimeout =
        _defaultProgressiveDiscoveryRuleTimeout,
    Duration progressiveVerificationRuleTimeout = _expandedRuleTimeout,
    String cacheNamespace = 'shared',
  }) : assert(progressiveDiscoveryTimeSlice > Duration.zero),
       assert(progressiveVerificationTimeSlice > Duration.zero),
       assert(progressiveDiscoveryRuleTimeout > Duration.zero),
       assert(progressiveVerificationRuleTimeout > Duration.zero),
       _repository = repository,
       _ruleState = ruleState,
       _resolver = resolver ?? _sharedResolver,
       _quickLookupBudget = quickLookupBudget,
       _progressiveDiscoveryTimeSlice = progressiveDiscoveryTimeSlice,
       _progressiveVerificationTimeSlice = progressiveVerificationTimeSlice,
       _progressiveDiscoveryRuleTimeout = progressiveDiscoveryRuleTimeout,
       _progressiveVerificationRuleTimeout = progressiveVerificationRuleTimeout,
       _cacheNamespace = cacheNamespace;

  final RulePluginRepository _repository;
  final RulePluginState _ruleState;
  final RulePlaybackResolver _resolver;
  final Duration _quickLookupBudget;
  final Duration _progressiveDiscoveryTimeSlice;
  final Duration _progressiveVerificationTimeSlice;
  final Duration _progressiveDiscoveryRuleTimeout;
  final Duration _progressiveVerificationRuleTimeout;
  final String _cacheNamespace;

  static final RulePlaybackResolver _sharedResolver = RulePlaybackResolver();
  static final LinkedHashMap<String, _CachedRuleLookup> _ruleLookupCache =
      LinkedHashMap<String, _CachedRuleLookup>();
  static final Map<String, Future<List<PlaybackLine>>> _inFlightRuleLookups =
      <String, Future<List<PlaybackLine>>>{};
  static final LinkedHashMap<String, _RuleHealth> _ruleHealth =
      LinkedHashMap<String, _RuleHealth>();
  static int _runtimeCacheGeneration = 0;

  static void clearRuntimeCaches() {
    _runtimeCacheGeneration++;
    _ruleLookupCache.clear();
    _inFlightRuleLookups.clear();
    _ruleHealth.clear();
  }

  @override
  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    return linesForEpisodeMode(
      subject,
      episode,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) return const [];
    final type = _contentTypeFor(subject);
    final rules = _selectLookupRules(
      _repository.playbackRulesFor(_ruleState, type),
      expandAll: expandAll,
    );
    if (rules.isEmpty) {
      return const EmptyPlaybackSourceRepository().linesForEpisode(
        subject,
        episode,
        cancellationToken: cancellationToken,
      );
    }
    return expandAll
        ? _resolveExpandedRules(
            rules,
            subject,
            episode,
            cancellationToken: cancellationToken,
          )
        : _resolveQuickRules(
            rules,
            subject,
            episode,
            cancellationToken: cancellationToken,
          );
  }

  @override
  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    final sessionToken = cancellationToken ?? RulePlaybackCancellationToken();
    late final StreamController<PlaybackLineLookupUpdate> controller;
    var started = false;

    Future<void> run() async {
      try {
        final type = _contentTypeFor(subject);
        final enabledRules = _repository.playbackRulesFor(_ruleState, type);
        final allRules = _selectLookupRules(enabledRules, expandAll: true);
        if (allRules.isEmpty) {
          if (!sessionToken.isCancelled && !controller.isClosed) {
            controller.add(
              const PlaybackLineLookupUpdate(
                lines: <PlaybackLine>[],
                completedRules: 0,
                totalRules: 0,
                phase: PlaybackLineLookupPhase.complete,
              ),
            );
          }
          return;
        }

        final quickRules = _selectLookupRules(enabledRules, expandAll: false);
        final quickRuleIds = quickRules.map((rule) => rule.id).toSet();
        final orderedRules = <RulePlugin>[
          ...quickRules,
          ...allRules.where((rule) => !quickRuleIds.contains(rule.id)),
        ];
        final inventory = <String, PlaybackLine>{};

        final discovery = await _runProgressivePhase(
          controller: controller,
          sessionToken: sessionToken,
          rules: orderedRules,
          subject: subject,
          episode: episode,
          inventory: inventory,
          verifyPlayable: false,
          concurrency: _expandedLookupConcurrency,
          timeSlice: _progressiveDiscoveryTimeSlice,
          ruleTimeout: _progressiveDiscoveryRuleTimeout,
          phase: PlaybackLineLookupPhase.discovery,
        );
        if (sessionToken.isCancelled ||
            controller.isClosed ||
            !discovery.isComplete) {
          return;
        }

        final verificationRules = orderedRules
            .where((rule) => discovery.availableProviderIds.contains(rule.id))
            .toList(growable: false);
        var timedOut = discovery.timedOut;
        if (verificationRules.isNotEmpty) {
          final verification = await _runProgressivePhase(
            controller: controller,
            sessionToken: sessionToken,
            rules: verificationRules,
            subject: subject,
            episode: episode,
            inventory: inventory,
            verifyPlayable: true,
            concurrency: _progressiveVerificationConcurrency,
            timeSlice: _progressiveVerificationTimeSlice,
            ruleTimeout: _progressiveVerificationRuleTimeout,
            phase: PlaybackLineLookupPhase.verification,
          );
          if (sessionToken.isCancelled ||
              controller.isClosed ||
              !verification.isComplete) {
            return;
          }
          timedOut |= verification.timedOut;
        }
        if (sessionToken.isCancelled || controller.isClosed) return;
        controller.add(
          PlaybackLineLookupUpdate(
            lines: List<PlaybackLine>.unmodifiable(inventory.values),
            completedRules: orderedRules.length,
            totalRules: orderedRules.length,
            phase: PlaybackLineLookupPhase.complete,
            timedOut: timedOut,
          ),
        );
      } catch (error, stackTrace) {
        if (!sessionToken.isCancelled && !controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }

    controller = StreamController<PlaybackLineLookupUpdate>(
      onListen: () {
        if (started) return;
        started = true;
        unawaited(run());
      },
      onCancel: sessionToken.cancel,
    );
    return controller.stream;
  }

  Future<_ProgressivePhaseResult> _runProgressivePhase({
    required StreamController<PlaybackLineLookupUpdate> controller,
    required RulePlaybackCancellationToken sessionToken,
    required List<RulePlugin> rules,
    required AnimeSubject subject,
    required AnimeEpisode episode,
    required Map<String, PlaybackLine> inventory,
    required bool verifyPlayable,
    required int concurrency,
    required Duration timeSlice,
    required Duration ruleTimeout,
    required PlaybackLineLookupPhase phase,
  }) async {
    if (rules.isEmpty || sessionToken.isCancelled) {
      return const _ProgressivePhaseResult();
    }
    final phaseToken = RulePlaybackCancellationToken();
    final unlinkPhase = sessionToken.register(phaseToken.cancel);
    final pending = <int, Future<_RuleResolution>>{};
    final sliceStopwatch = Stopwatch()..start();
    final availableProviderIds = <String>{};
    var nextRuleIndex = 0;
    var completedRules = 0;
    var timedOut = false;

    void fillLookupSlots() {
      while (!phaseToken.isCancelled &&
          pending.length < concurrency &&
          nextRuleIndex < rules.length) {
        final index = nextRuleIndex++;
        pending[index] = _resolveRuleForProgressiveLookup(
          index,
          rules[index],
          subject,
          episode,
          verifyPlayable: verifyPlayable,
          timeout: ruleTimeout,
          cancellationToken: phaseToken,
        );
      }
    }

    try {
      fillLookupSlots();
      while (pending.isNotEmpty && !phaseToken.isCancelled) {
        final remaining = timeSlice - sliceStopwatch.elapsed;
        if (remaining <= Duration.zero) {
          sliceStopwatch.reset();
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        final resolution = await _nextProgressiveResolution(
          pending.values,
          timeout: remaining,
          cancellationToken: phaseToken,
        );
        if (resolution == null) {
          if (phaseToken.isCancelled) break;
          sliceStopwatch.reset();
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        pending.remove(resolution.index);
        completedRules++;
        timedOut |= resolution.timedOut;
        final rule = rules[resolution.index];
        inventory.removeWhere((_, line) => line.providerId == rule.id);
        if (resolution.lines.isNotEmpty) {
          for (final line in resolution.lines) {
            inventory[line.id] = line;
          }
        }
        if (resolution.lines.any((line) => line.available)) {
          availableProviderIds.add(rule.id);
        }
        if (!sessionToken.isCancelled && !controller.isClosed) {
          controller.add(
            PlaybackLineLookupUpdate(
              lines: List<PlaybackLine>.unmodifiable(inventory.values),
              completedRules: completedRules,
              totalRules: rules.length,
              phase: phase,
              timedOut: resolution.timedOut,
              resolvedProviderId: rule.id,
            ),
          );
        }
        fillLookupSlots();
      }
      return _ProgressivePhaseResult(
        completedRules: completedRules,
        totalRules: rules.length,
        timedOut: timedOut,
        availableProviderIds: Set<String>.unmodifiable(availableProviderIds),
      );
    } finally {
      sliceStopwatch.stop();
      phaseToken.cancel();
      unlinkPhase();
    }
  }

  Future<_RuleResolution> _resolveRuleForProgressiveLookup(
    int index,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
    required Duration timeout,
    required RulePlaybackCancellationToken cancellationToken,
  }) async {
    final ruleToken = RulePlaybackCancellationToken();
    final unlinkRule = cancellationToken.register(ruleToken.cancel);
    try {
      var timedOut = false;
      final lines =
          await _resolveRuleCached(
            rule,
            subject,
            episode,
            verifyPlayable: verifyPlayable,
            cancellationToken: ruleToken,
          ).timeout(
            timeout,
            onTimeout: () {
              timedOut = true;
              ruleToken.cancel();
              return <PlaybackLine>[
                _timedOutPlaybackLine(
                  rule: rule,
                  subject: subject,
                  episode: episode,
                  verifyPlayable: verifyPlayable,
                ),
              ];
            },
          );
      return _RuleResolution(index, lines, timedOut: timedOut);
    } finally {
      unlinkRule();
    }
  }

  Future<List<PlaybackLine>> _resolveQuickRules(
    List<RulePlugin> rules,
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final quickToken = RulePlaybackCancellationToken();
    final unlinkQuick = cancellationToken?.register(quickToken.cancel);
    final pending = <int, Future<_RuleResolution>>{};
    final completed = <int, List<PlaybackLine>>{};
    final budgetStopwatch = Stopwatch()..start();
    var nextRuleIndex = 0;
    var foundAvailableLine = false;

    void fillLookupSlots() {
      while (!quickToken.isCancelled &&
          !foundAvailableLine &&
          budgetStopwatch.elapsed < _quickLookupBudget &&
          pending.length < _quickLookupConcurrency &&
          nextRuleIndex < rules.length) {
        final index = nextRuleIndex++;
        pending[index] = _resolveRuleForQuickLookup(
          index,
          rules[index],
          subject,
          episode,
          cancellationToken: quickToken,
        );
      }
    }

    try {
      fillLookupSlots();
      while (pending.isNotEmpty) {
        if (quickToken.isCancelled) break;
        final budgetRemaining = _quickLookupBudget - budgetStopwatch.elapsed;
        if (budgetRemaining <= Duration.zero) break;

        final resolution = await _nextResolution(
          pending.values,
          timeout: budgetRemaining,
        );
        if (resolution == null) break;
        pending.remove(resolution.index);
        completed[resolution.index] = resolution.lines;

        if (!foundAvailableLine &&
            resolution.lines.any((line) => line.available)) {
          foundAvailableLine = true;
          break;
        }
        fillLookupSlots();
      }
    } finally {
      budgetStopwatch.stop();
      quickToken.cancel();
      unlinkQuick?.call();
    }
    final orderedIndexes = completed.keys.toList()..sort();
    return [for (final index in orderedIndexes) ...completed[index]!];
  }

  Future<_RuleResolution> _resolveRuleForQuickLookup(
    int index,
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final ruleToken = RulePlaybackCancellationToken();
    final unlinkRule = cancellationToken?.register(ruleToken.cancel);
    try {
      final lines =
          await _resolveRuleCached(
            rule,
            subject,
            episode,
            verifyPlayable: false,
            cancellationToken: ruleToken,
          ).timeout(
            _quickRuleTimeout,
            onTimeout: () {
              ruleToken.cancel();
              return const <PlaybackLine>[];
            },
          );
      return _RuleResolution(index, lines);
    } finally {
      unlinkRule?.call();
    }
  }

  Future<_RuleResolution?> _nextResolution(
    Iterable<Future<_RuleResolution>> pending, {
    Duration? timeout,
  }) async {
    try {
      final next = Future.any(pending);
      return timeout == null ? await next : await next.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<_RuleResolution?> _nextProgressiveResolution(
    Iterable<Future<_RuleResolution>> pending, {
    required Duration timeout,
    required RulePlaybackCancellationToken cancellationToken,
  }) async {
    if (cancellationToken.isCancelled) return null;
    final cancelled = Completer<_RuleResolution?>();
    final unlinkCancellation = cancellationToken.register(() {
      if (!cancelled.isCompleted) cancelled.complete(null);
    });
    try {
      return await Future.any<_RuleResolution?>([
        Future.any<_RuleResolution>(pending),
        cancelled.future,
      ]).timeout(timeout, onTimeout: () => null);
    } finally {
      unlinkCancellation();
    }
  }

  Future<List<PlaybackLine>> _resolveExpandedRules(
    List<RulePlugin> rules,
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final operationToken = RulePlaybackCancellationToken();
    final unlinkOperation = cancellationToken?.register(operationToken.cancel);
    final resolved = List<List<PlaybackLine>?>.filled(rules.length, null);
    var nextRuleIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (operationToken.isCancelled) return;
        final index = nextRuleIndex++;
        if (index >= rules.length) return;
        try {
          resolved[index] = await _resolveRuleCached(
            rules[index],
            subject,
            episode,
            verifyPlayable: true,
            cancellationToken: operationToken,
          ).timeout(_expandedRuleTimeout);
        } on TimeoutException {
          resolved[index] = const <PlaybackLine>[];
        }
      }
    }

    final workerCount = rules.length < _expandedLookupConcurrency
        ? rules.length
        : _expandedLookupConcurrency;
    final workers = Future.wait(List.generate(workerCount, (_) => worker()));
    try {
      final completed = await Future.any<bool>([
        workers.then((_) => true),
        Future<bool>.delayed(_expandedLookupTotalBudget, () => false),
      ]);
      if (!completed) {
        operationToken.cancel();
        try {
          await workers.timeout(const Duration(milliseconds: 800));
        } on TimeoutException {
          // Closing the owned HTTP clients stops active network work. A custom
          // client used by tests may not be abortable, so do not block the UI.
        }
      }
    } finally {
      unlinkOperation?.call();
    }
    if (cancellationToken?.isCancelled ?? false) return const [];
    return [for (final lines in resolved) ...?lines];
  }

  Future<List<PlaybackLine>> _resolveRuleCached(
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    if (cancellationToken?.isCancelled ?? false) {
      return Future.value(const <PlaybackLine>[]);
    }
    if (_ruleContainsPrivateCredentials(rule)) {
      return _resolver
          .resolveRule(
            rule: rule,
            subject: subject,
            episode: episode,
            verifyPlayable: verifyPlayable,
            cancellationToken: cancellationToken,
          )
          .catchError((Object _) => const <PlaybackLine>[]);
    }
    final cacheGeneration = _runtimeCacheGeneration;
    final now = DateTime.now();
    final cacheKey = _ruleLookupCacheKey(
      rule,
      subject,
      episode,
      verifyPlayable: verifyPlayable,
    );
    final successfulCacheKey = _successfulRuleLookupCacheKey(
      rule,
      subject,
      episode,
      verifyPlayable: verifyPlayable,
    );
    for (final key in <String>[successfulCacheKey, cacheKey]) {
      final cached = _ruleLookupCache.remove(key);
      if (cached != null && cached.expiresAt.isAfter(now)) {
        _ruleLookupCache[key] = cached;
        return Future.value(cached.lines);
      }
    }

    final inFlightKey = cancellationToken == null
        ? cacheKey
        : '$cacheKey|token:${identityHashCode(cancellationToken)}';
    final inFlight = _inFlightRuleLookups[inFlightKey];
    if (inFlight != null) return inFlight;

    final stopwatch = Stopwatch()..start();
    late final Future<List<PlaybackLine>> lookup;
    lookup = _resolver
        .resolveRule(
          rule: rule,
          subject: subject,
          episode: episode,
          verifyPlayable: verifyPlayable,
          cancellationToken: cancellationToken,
        )
        .then((lines) {
          stopwatch.stop();
          final immutableLines = List<PlaybackLine>.unmodifiable(
            _withFallbackLatency(lines, stopwatch.elapsed),
          );
          if (cacheGeneration != _runtimeCacheGeneration ||
              (cancellationToken?.isCancelled ?? false)) {
            return immutableLines;
          }
          final available = immutableLines.any((line) => line.available);
          _rememberRuleHealth(rule, available, stopwatch.elapsed);
          _storeCachedRuleLookup(
            cacheKey,
            immutableLines,
            DateTime.now().add(
              available ? _availableRuleCacheTtl : _unavailableRuleCacheTtl,
            ),
          );
          if (available && successfulCacheKey != cacheKey) {
            _storeCachedRuleLookup(
              successfulCacheKey,
              immutableLines,
              DateTime.now().add(_availableRuleCacheTtl),
            );
          }
          return immutableLines;
        })
        .catchError((Object _) => const <PlaybackLine>[])
        .whenComplete(() {
          if (identical(_inFlightRuleLookups[inFlightKey], lookup)) {
            _inFlightRuleLookups.remove(inFlightKey);
          }
        });
    _inFlightRuleLookups[inFlightKey] = lookup;
    return lookup;
  }

  void _storeCachedRuleLookup(
    String key,
    List<PlaybackLine> lines,
    DateTime expiresAt,
  ) {
    _ruleLookupCache.remove(key);
    _ruleLookupCache[key] = _CachedRuleLookup(lines, expiresAt);
    while (_ruleLookupCache.length > _maxCachedRuleLookups) {
      _ruleLookupCache.remove(_ruleLookupCache.keys.first);
    }
  }

  void _rememberRuleHealth(RulePlugin rule, bool available, Duration latency) {
    final key = _ruleHealthKey(rule);
    final previous = _ruleHealth.remove(key);
    _ruleHealth[key] = available
        ? _RuleHealth(
            lastSuccessAt: DateTime.now(),
            latency: latency,
            consecutiveFailures: 0,
          )
        : _RuleHealth(
            lastSuccessAt: previous?.lastSuccessAt,
            lastFailureAt: DateTime.now(),
            latency: previous?.latency,
            consecutiveFailures: (previous?.consecutiveFailures ?? 0) + 1,
          );
    while (_ruleHealth.length > _maxRuleHealthEntries) {
      _ruleHealth.remove(_ruleHealth.keys.first);
    }
  }

  List<RulePlugin> _selectLookupRules(
    List<RulePlugin> rules, {
    required bool expandAll,
  }) {
    if (rules.isEmpty) return const [];
    final validRules = rules.where(_isValidLookupRule).toList();
    final sorted = [...validRules]
      ..sort((a, b) {
        if (!expandAll) {
          final quickSearch = _quickSearchRank(
            a,
          ).compareTo(_quickSearchRank(b));
          if (quickSearch != 0) return quickSearch;
          final health = _ruleHealthRank(a).compareTo(_ruleHealthRank(b));
          if (health != 0) return health;
          final latency = _knownLatency(a).compareTo(_knownLatency(b));
          if (latency != 0) return latency;
        }
        final priority = a.priority.compareTo(b.priority);
        if (priority != 0) return priority;
        final quality = b.qualityScore.compareTo(a.qualityScore);
        if (quality != 0) return quality;
        return a.name.compareTo(b.name);
      });
    if (expandAll) return sorted;

    final grouped = <String, List<RulePlugin>>{};
    for (final rule in sorted) {
      final groupId = rule.groupId.trim();
      final key = groupId.isEmpty ? 'rule:${rule.id}' : 'group:$groupId';
      grouped.putIfAbsent(key, () => <RulePlugin>[]).add(rule);
    }
    final groupedCount = <String, int>{};
    final selected = <RulePlugin>[];
    var groupOffset = 0;
    var madeProgress = true;
    while (selected.length < _maxRulesPerQuickLookup && madeProgress) {
      madeProgress = false;
      for (final entry in grouped.entries) {
        final groupId = entry.key;
        final groupRules = entry.value;
        if (groupOffset >= groupRules.length) continue;
        final count = groupedCount[groupId] ?? 0;
        if (count >= _maxRulesPerGroupPerLookup) continue;
        selected.add(groupRules[groupOffset]);
        groupedCount[groupId] = count + 1;
        madeProgress = true;
        if (selected.length >= _maxRulesPerQuickLookup) break;
      }
      groupOffset++;
    }
    return selected;
  }

  bool _isValidLookupRule(RulePlugin rule) {
    final endpoint = Uri.tryParse(rule.baseUrl.trim());
    return endpoint != null && endpoint.hasScheme && endpoint.host.isNotEmpty;
  }

  int _quickSearchRank(RulePlugin rule) => rule.quickSearch ? 0 : 1;

  int _ruleHealthRank(RulePlugin rule) {
    final health = _activeRuleHealth(rule);
    if (health == null) return 1;
    if (health.consecutiveFailures >= 2 &&
        health.lastFailureAt != null &&
        (health.lastSuccessAt == null ||
            health.lastFailureAt!.isAfter(health.lastSuccessAt!))) {
      return 2;
    }
    if (health.lastSuccessAt != null) return 0;
    return 1;
  }

  int _knownLatency(RulePlugin rule) {
    return _activeRuleHealth(rule)?.latency?.inMilliseconds ?? 1 << 30;
  }

  _RuleHealth? _activeRuleHealth(RulePlugin rule) {
    final key = _ruleHealthKey(rule);
    final health = _ruleHealth[key];
    if (health == null) return null;
    final successAt = health.lastSuccessAt;
    final failureAt = health.lastFailureAt;
    final latest = successAt == null
        ? failureAt
        : failureAt == null || successAt.isAfter(failureAt)
        ? successAt
        : failureAt;
    if (latest == null || DateTime.now().difference(latest) > _ruleHealthTtl) {
      _ruleHealth.remove(key);
      return null;
    }
    return health;
  }

  String _ruleLookupCacheKey(
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) {
    final verification = verifyPlayable ? 'verified' : 'unverified';
    return '$_cacheNamespace|${identityHashCode(_resolver)}|$verification|'
        '${_ruleConfigDigest(rule)}|${rule.id}|${rule.version}|'
        '${rule.updatedAt.microsecondsSinceEpoch}|${rule.engine}|'
        '${rule.baseUrl}|${rule.searchUrl}|${subject.source}|${subject.id}|'
        '${subject.title}|${subject.originalTitle}|${episode.id}|'
        '${episode.number}|${episode.title}';
  }

  String _ruleHealthKey(RulePlugin rule) {
    return '$_cacheNamespace|${_ruleConfigDigest(rule)}|'
        '${rule.contentType.name}|${rule.id}|${rule.version}|'
        '${rule.updatedAt.microsecondsSinceEpoch}';
  }

  String _successfulRuleLookupCacheKey(
    RulePlugin rule,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool verifyPlayable,
  }) {
    final verification = verifyPlayable ? 'verified' : 'unverified';
    return '$_cacheNamespace|${identityHashCode(_resolver)}|$verification|'
        'successful|${_ruleConfigDigest(rule)}|${rule.id}|${rule.version}|'
        '${rule.updatedAt.microsecondsSinceEpoch}|${rule.engine}|'
        '${rule.baseUrl}|${rule.searchUrl}|${subject.source}|${subject.id}|'
        '${episode.id}|${episode.number}';
  }

  RuleContentType _contentTypeFor(AnimeSubject subject) {
    return switch (subjectContentTypeOf(subject)) {
      SubjectContentType.anime => RuleContentType.anime,
      SubjectContentType.series => RuleContentType.series,
      SubjectContentType.movie => RuleContentType.movie,
    };
  }
}

String _ruleConfigDigest(RulePlugin rule) {
  try {
    return sha256.convert(utf8.encode(jsonEncode(rule.toJson()))).toString();
  } catch (_) {
    return identityHashCode(rule).toRadixString(16);
  }
}

bool _ruleContainsPrivateCredentials(RulePlugin rule) {
  if (rule.requiresPrivateAuth ||
      (rule.animeko?.cookies.trim().isNotEmpty ?? false)) {
    return true;
  }
  if (rule.requestHeaders.entries.any(
    (entry) => _looksSensitiveName(entry.key) && entry.value.trim().isNotEmpty,
  )) {
    return true;
  }
  return _containsSensitiveConfig(rule.rawConfig);
}

bool _containsSensitiveConfig(Object? value, [String key = '']) {
  if (value is Map) {
    return value.entries.any(
      (entry) => _containsSensitiveConfig(entry.value, entry.key.toString()),
    );
  }
  if (value is Iterable) {
    return value.any((item) => _containsSensitiveConfig(item, key));
  }
  return _looksSensitiveName(key) &&
      value?.toString().trim().isNotEmpty == true;
}

bool _looksSensitiveName(String name) {
  final normalized = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return normalized.contains('auth') ||
      normalized.contains('cookie') ||
      normalized.contains('credential') ||
      normalized.contains('password') ||
      normalized.contains('session') ||
      normalized.contains('signature') ||
      normalized.contains('secret') ||
      normalized.contains('token') ||
      normalized == 'apikey' ||
      normalized == 'accesskey';
}

List<PlaybackLine> _withFallbackLatency(
  List<PlaybackLine> lines,
  Duration lookupLatency,
) {
  return lines
      .map(
        (line) => line.available && line.latency == null
            ? PlaybackLine(
                id: line.id,
                episodeId: line.episodeId,
                providerId: line.providerId,
                providerName: line.providerName,
                title: line.title,
                quality: line.quality,
                format: line.format,
                url: line.url,
                headers: line.headers,
                latency: lookupLatency,
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
                requiresClientProbe: line.requiresClientProbe,
                clientVerified: line.clientVerified,
                startupProfile: line.startupProfile,
                cacheState: line.cacheState,
                sourceErrorCategory: line.sourceErrorCategory,
                expiresAt: line.expiresAt,
                available: line.available,
                message: line.message,
              )
            : line,
      )
      .toList(growable: false);
}

PlaybackLine _timedOutPlaybackLine({
  required RulePlugin rule,
  required AnimeSubject subject,
  required AnimeEpisode episode,
  required bool verifyPlayable,
}) {
  final stage = verifyPlayable ? 'verification' : 'discovery';
  return PlaybackLine(
    id: 'timeout:$stage:${rule.id}:${episode.id}',
    episodeId: episode.id,
    providerId: rule.id,
    providerName: rule.name,
    title: '${subject.title} · 第${episode.number}集',
    quality: '超时',
    format: '--',
    available: false,
    message: verifyPlayable ? '线路验证超时，已暂时标记为不可用。' : '线路检索超时，请稍后重试。',
  );
}

class _ProgressivePhaseResult {
  const _ProgressivePhaseResult({
    this.completedRules = 0,
    this.totalRules = 0,
    this.timedOut = false,
    this.availableProviderIds = const <String>{},
  });

  final int completedRules;
  final int totalRules;
  final bool timedOut;
  final Set<String> availableProviderIds;

  bool get isComplete => completedRules == totalRules;
}

class _RuleResolution {
  const _RuleResolution(this.index, this.lines, {this.timedOut = false});

  final int index;
  final List<PlaybackLine> lines;
  final bool timedOut;
}

class _CachedRuleLookup {
  const _CachedRuleLookup(this.lines, this.expiresAt);

  final List<PlaybackLine> lines;
  final DateTime expiresAt;
}

class _RuleHealth {
  const _RuleHealth({
    this.lastSuccessAt,
    this.lastFailureAt,
    this.latency,
    required this.consecutiveFailures,
  });

  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final Duration? latency;
  final int consecutiveFailures;
}

bool _containsAny(String text, List<String> patterns) {
  return patterns.any(text.contains);
}

String _archiveQuality(String name) {
  final lower = name.toLowerCase();
  final match = RegExp(r'(2160|1440|1080|720|480)p').firstMatch(lower);
  return match?.group(0)?.toUpperCase() ?? '公开原片';
}

bool _archiveRightsAllowed(Map metadata) {
  final license = [
    metadata['licenseurl'],
    metadata['rights'],
    metadata['usage'],
  ].whereType<Object>().map((item) => item.toString()).join(' ').toLowerCase();
  if (_containsAny(license, const [
    'creativecommons.org',
    'public domain',
    'cc0',
    'cc by',
  ])) {
    return true;
  }
  final collection = metadata['collection'];
  final collections = collection is List
      ? collection.map((item) => item.toString().toLowerCase())
      : [collection?.toString().toLowerCase() ?? ''];
  return collections.any(
    (item) => _containsAny(item, const [
      'feature_films',
      'prelinger',
      'classic_tv',
      'animationandcartoons',
    ]),
  );
}

int _archiveFileScore(Map item) {
  final name = item['name']?.toString().toLowerCase() ?? '';
  final format = item['format']?.toString().toLowerCase() ?? '';
  var score = 0;
  if (name.endsWith('.mp4')) score += 20;
  if (format.contains('h.264') || format.contains('mpeg4')) score += 12;
  if (RegExp(r'(2160|1440|1080|720)p').hasMatch(name)) score += 8;
  if (item['source']?.toString() == 'derivative') score += 2;
  return score;
}
