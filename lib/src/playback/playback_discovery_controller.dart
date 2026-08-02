import 'dart:async';

import '../data/async_single_flight.dart';
import '../data/playback_prefetch_cache.dart';
import '../data/playback_source_repository.dart';
import '../data/zeluna_backend_playback_repository.dart';
import '../domain/anime_models.dart';
import '../rules/rule_models.dart';
import '../rules/rule_playback_resolver.dart';
import '../settings/settings_controller.dart';

typedef PlaybackBackendRepositoryFactory =
    PlaybackSourceRepository? Function(ExternalServiceSettings services);
typedef PlaybackRuleRepositoryFactory =
    PlaybackSourceRepository Function(RulePluginState ruleState);
typedef PlaybackLineVerifier =
    Future<PlaybackLine> Function(
      PlaybackLine line, {
      bool enrichMetadata,
      bool forceRefresh,
      RulePlaybackCancellationToken? cancellationToken,
    });
typedef PlaybackContextGuard = bool Function(int contextVersion);

/// Runs every supplied playback probe with a small concurrency window and
/// emits each result as soon as it finishes. This keeps a large route
/// inventory responsive without creating a request burst.
Stream<PlaybackLine> probePlaybackLinesProgressively(
  List<PlaybackLine> lines, {
  int maxConcurrent = 4,
  RulePlaybackCancellationToken? cancellationToken,
  required Future<PlaybackLine> Function(PlaybackLine line) verify,
}) async* {
  if (lines.isEmpty ||
      maxConcurrent <= 0 ||
      cancellationToken?.isCancelled == true) {
    return;
  }
  var nextIndex = 0;
  final pending = <int, Future<({int index, PlaybackLine line})>>{};

  void fillWindow() {
    while (nextIndex < lines.length &&
        pending.length < maxConcurrent &&
        cancellationToken?.isCancelled != true) {
      final index = nextIndex++;
      pending[index] = verify(
        lines[index],
      ).then((line) => (index: index, line: line));
    }
  }

  fillWindow();
  while (pending.isNotEmpty && cancellationToken?.isCancelled != true) {
    final completed = await Future.any(pending.values);
    pending.remove(completed.index);
    if (cancellationToken?.isCancelled == true) return;
    yield completed.line;
    fillWindow();
  }
}

Future<List<PlaybackLine>> probeSinglePlaybackBackupSequentially(
  Iterable<PlaybackLine> candidates, {
  int maxCandidates = 3,
  RulePlaybackCancellationToken? cancellationToken,
  required Future<PlaybackLine> Function(PlaybackLine line) verify,
}) async {
  if (maxCandidates <= 0 || cancellationToken?.isCancelled == true) {
    return const <PlaybackLine>[];
  }
  final checked = <PlaybackLine>[];
  for (final candidate in candidates.take(maxCandidates)) {
    if (cancellationToken?.isCancelled == true) break;
    final verified = await verify(candidate);
    checked.add(verified);
    if (verified.available) break;
  }
  return List<PlaybackLine>.unmodifiable(checked);
}

List<PlaybackLine> rankPlaybackLinesForStartup(Iterable<PlaybackLine> lines) {
  final indexed = lines.indexed.toList(growable: false);
  final sorted = [...indexed]
    ..sort((left, right) {
      final availability = _startupAvailabilityRank(
        left.$2,
      ).compareTo(_startupAvailabilityRank(right.$2));
      if (availability != 0) return availability;
      final profile = _startupProfileRank(
        left.$2,
      ).compareTo(_startupProfileRank(right.$2));
      if (profile != 0) return profile;
      final latency = (left.$2.latency ?? const Duration(days: 1)).compareTo(
        right.$2.latency ?? const Duration(days: 1),
      );
      if (latency != 0) return latency;
      return left.$1.compareTo(right.$1);
    });
  return List<PlaybackLine>.unmodifiable(sorted.map((entry) => entry.$2));
}

int _startupAvailabilityRank(PlaybackLine line) {
  if (line.available && line.clientVerified) return 0;
  if (line.available && line.serverVerified) return 1;
  if (line.available) return 2;
  if (line.requiresClientProbe) return 3;
  return 4;
}

int _startupProfileRank(PlaybackLine line) {
  switch (line.startupProfile) {
    case PlaybackStartupProfile.mp4FastStart:
      return 0;
    case PlaybackStartupProfile.hls:
      return 1;
    case PlaybackStartupProfile.mp4TailMoov:
      return 3;
  }
  final format = line.format.trim().toLowerCase();
  if (format == 'hls' ||
      format == 'dash' ||
      format.contains('m3u8') ||
      format.contains('mpeg-dash')) {
    return 1;
  }
  return 2;
}

/// Owns playback-route loading, merging, progressive verification,
/// cancellation, short-lived backend caching, and detail-page prefetch.
final class PlaybackDiscoveryController {
  PlaybackDiscoveryController({
    required PlaybackBackendRepositoryFactory backendRepository,
    required PlaybackRuleRepositoryFactory ruleRepository,
    required PlaybackLineVerifier verifyLine,
    required PlaybackContextGuard isContextCurrent,
    required void Function() clearRuleRuntimeCaches,
    DateTime Function()? now,
  }) : _backendRepository = backendRepository,
       _ruleRepository = ruleRepository,
       _verifyLine = verifyLine,
       _isContextCurrent = isContextCurrent,
       _clearRuleRuntimeCaches = clearRuleRuntimeCaches,
       _backendCache = PlaybackPrefetchCache(now: now);

  final PlaybackBackendRepositoryFactory _backendRepository;
  final PlaybackRuleRepositoryFactory _ruleRepository;
  final PlaybackLineVerifier _verifyLine;
  final PlaybackContextGuard _isContextCurrent;
  final void Function() _clearRuleRuntimeCaches;
  final PlaybackPrefetchCache _backendCache;
  final AsyncSingleFlight<String, List<PlaybackLine>> _backendLookups =
      AsyncSingleFlight<String, List<PlaybackLine>>();
  final Map<String, Future<void>> _prefetches = <String, Future<void>>{};
  final Map<String, RulePlaybackCancellationToken> _prefetchTokens =
      <String, RulePlaybackCancellationToken>{};

  String? _accountId;
  var _contextVersion = 0;
  var _scopeEpoch = 0;
  var _loaded = false;
  var _disposed = false;
  ExternalServiceSettings _services = const ExternalServiceSettings();
  RulePluginState _ruleState = const RulePluginState();
  List<LibraryEntry> _history = const <LibraryEntry>[];

  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;
  int get cachedBackendEntries => _backendCache.length;

  void loadForAccount({
    required String? accountId,
    required int contextVersion,
    required ExternalServiceSettings services,
    required RulePluginState ruleState,
    required List<LibraryEntry> history,
  }) {
    _ensureNotDisposed();
    _invalidateScope();
    _accountId = accountId;
    _contextVersion = contextVersion;
    _services = services;
    _ruleState = ruleState;
    _history = List<LibraryEntry>.unmodifiable(history);
    _loaded = true;
  }

  void applyServices(
    ExternalServiceSettings services, {
    required int contextVersion,
  }) {
    final scope = _scope();
    if (scope.contextVersion != contextVersion) return;
    final changed =
        _servicesSignature(_services) != _servicesSignature(services);
    _services = services;
    if (!changed) return;
    _invalidateAsyncWork();
  }

  void applyRuleState(
    RulePluginState ruleState, {
    required int contextVersion,
  }) {
    final scope = _scope();
    if (scope.contextVersion != contextVersion) return;
    if (identical(_ruleState, ruleState)) return;
    _ruleState = ruleState;
    _invalidateAsyncWork();
    _clearRuleRuntimeCaches();
  }

  void updateHistory(
    List<LibraryEntry> history, {
    required int contextVersion,
  }) {
    final scope = _scope();
    if (scope.contextVersion != contextVersion) return;
    _history = List<LibraryEntry>.unmodifiable(history);
  }

  Future<List<PlaybackLine>> linesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) => linesForEpisodeMode(
    subject,
    episode,
    cancellationToken: cancellationToken,
  );

  Future<PlaybackLine> verifyPlaybackLine(
    PlaybackLine line, {
    bool enrichMetadata = true,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final scope = _scope();
    final verified = await _verifyLine(
      line,
      enrichMetadata: enrichMetadata,
      forceRefresh: forceRefresh,
      cancellationToken: cancellationToken,
    );
    return _isCurrent(scope) && cancellationToken?.isCancelled != true
        ? verified
        : line;
  }

  Future<List<PlaybackLine>> linesForEpisodeMode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final scope = _scope();
    if (cancellationToken?.isCancelled ?? false) return const [];
    var backendLines = const <PlaybackLine>[];
    var probedBackendLines = const <PlaybackLine>[];
    var ruleLines = const <PlaybackLine>[];

    bool isCurrentRequest() =>
        _isCurrent(scope) && !(cancellationToken?.isCancelled ?? false);
    bool hasPlayableLine(Iterable<PlaybackLine> lines) => lines.any(
      (line) => line.available && (line.url?.trim().isNotEmpty ?? false),
    );
    Future<({String kind, List<PlaybackLine> lines})> tagged(
      String kind,
      Future<List<PlaybackLine>> future,
    ) async => (kind: kind, lines: await future);

    final backendEvent = tagged(
      'backend',
      _backendLinesForEpisode(
        scope,
        subject,
        episode,
        cancellationToken: cancellationToken,
      ).timeout(
        const Duration(seconds: 6),
        onTimeout: () => const <PlaybackLine>[],
      ),
    );
    final firstEvent = await Future.any([
      backendEvent,
      Future<({String kind, List<PlaybackLine> lines})>.delayed(
        const Duration(milliseconds: 900),
        () => (kind: 'hedge', lines: const <PlaybackLine>[]),
      ),
    ]);
    if (!isCurrentRequest()) return const <PlaybackLine>[];

    final pending =
        <String, Future<({String kind, List<PlaybackLine> lines})>>{};

    void startRules() {
      pending.putIfAbsent(
        'rules',
        () => tagged(
          'rules',
          _ruleLinesForEpisode(
            scope,
            subject,
            episode,
            expandAll: expandAll,
            cancellationToken: cancellationToken,
          ),
        ),
      );
    }

    void startBackendCandidateProbe() {
      if (backendLines.isEmpty || pending.containsKey('probe')) return;
      pending['probe'] = tagged(
        'probe',
        _probeBackendClientCandidates(
          scope,
          backendLines,
          cancellationToken: cancellationToken,
        ).onError((_, _) => const <PlaybackLine>[]),
      );
    }

    if (firstEvent.kind == 'backend') {
      backendLines = firstEvent.lines;
      if (hasPlayableLine(backendLines)) {
        return mergePlaybackLines(backendLines);
      }
      startBackendCandidateProbe();
      startRules();
    } else {
      pending['backend'] = backendEvent;
      startRules();
    }

    while (pending.isNotEmpty) {
      final event = await Future.any(pending.values);
      pending.remove(event.kind);
      if (!isCurrentRequest()) return const <PlaybackLine>[];
      switch (event.kind) {
        case 'backend':
          backendLines = event.lines;
          startBackendCandidateProbe();
        case 'probe':
          probedBackendLines = event.lines;
          if (hasPlayableLine(probedBackendLines)) {
            _cacheBackendPlaybackLines(
              scope,
              subject,
              episode,
              mergePlaybackLines(<PlaybackLine>[
                ...backendLines,
                ...probedBackendLines,
              ]),
              expandAll: expandAll,
            );
          }
        case 'rules':
          ruleLines = event.lines;
      }
      final merged = mergePlaybackLines(<PlaybackLine>[
        ...backendLines,
        ...probedBackendLines,
        ...ruleLines,
      ]);
      if (hasPlayableLine(merged)) return merged;
    }

    return isCurrentRequest()
        ? mergePlaybackLines(<PlaybackLine>[
            ...backendLines,
            ...probedBackendLines,
            ...ruleLines,
          ])
        : const <PlaybackLine>[];
  }

  PlaybackLine? prefetchedLineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode,
  ) {
    final scope = _scope();
    final lookupKey = _backendPlaybackLookupKey(
      scope,
      _services,
      subject,
      episode,
    );
    if (lookupKey == null) return null;
    final lines = _backendCache.read(lookupKey);
    if (lines == null) return null;
    for (final line in lines) {
      if (line.available &&
          (line.serverVerified || line.clientVerified) &&
          (line.url?.trim().isNotEmpty ?? false)) {
        return line;
      }
    }
    return null;
  }

  Future<List<PlaybackLine>> prepareSingleBackupForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    required PlaybackLine currentLine,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final scope = _scope();
    final backendLines = await _backendLinesForEpisode(
      scope,
      subject,
      episode,
      expandAll: true,
      cancellationToken: cancellationToken,
    );
    if (!_isCurrent(scope) || cancellationToken?.isCancelled == true) {
      return const <PlaybackLine>[];
    }

    var checked = mergePlaybackLines(backendLines);
    final currentUrl = currentLine.url?.trim() ?? '';
    bool isCurrentLine(PlaybackLine line) {
      final url = line.url?.trim() ?? '';
      return line.id == currentLine.id ||
          (currentUrl.isNotEmpty && url == currentUrl);
    }

    if (checked.any((line) => line.available && !isCurrentLine(line))) {
      return checked;
    }
    final candidates = _backendLinesNeedingBackgroundProbe(
      checked,
    ).where((line) => line.requiresClientProbe && !isCurrentLine(line));
    final probed = await probeSinglePlaybackBackupSequentially(
      candidates,
      cancellationToken: cancellationToken,
      verify: (candidate) => verifyPlaybackLine(
        candidate,
        enrichMetadata: false,
        cancellationToken: cancellationToken,
      ),
    );
    if (!_isCurrent(scope) || cancellationToken?.isCancelled == true) {
      return const <PlaybackLine>[];
    }
    for (final verified in probed) {
      checked = replacePlaybackLine(checked, verified);
    }
    return checked;
  }

  Stream<PlaybackLineLookupUpdate> lineUpdatesForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async* {
    final scope = _scope();
    final token = cancellationToken ?? RulePlaybackCancellationToken();
    final backendLines = await _backendLinesForEpisode(
      scope,
      subject,
      episode,
      cancellationToken: token,
    );
    if (!_isCurrent(scope) || token.isCancelled) return;
    var baseLines = mergePlaybackLines(backendLines);
    yield PlaybackLineLookupUpdate(
      lines: baseLines,
      completedRules: 0,
      totalRules: 1,
      phase: PlaybackLineLookupPhase.discovery,
    );
    final expandedBackendLines = await _backendLinesForEpisode(
      scope,
      subject,
      episode,
      expandAll: true,
      cancellationToken: token,
    );
    if (!_isCurrent(scope) || token.isCancelled) return;
    baseLines = mergePlaybackLines(<PlaybackLine>[
      ...baseLines,
      ...expandedBackendLines,
    ]);
    final backendProbeCandidates = _backendLinesNeedingBackgroundProbe(
      baseLines,
    );
    final backendProbeTotal = backendProbeCandidates.isEmpty
        ? 1
        : backendProbeCandidates.length;
    yield PlaybackLineLookupUpdate(
      lines: baseLines,
      completedRules: 0,
      totalRules: backendProbeTotal,
      phase: PlaybackLineLookupPhase.discovery,
    );
    var clientCheckedBaseLines = baseLines;
    var completedBackendProbes = 0;
    await for (final probedLine in probePlaybackLinesProgressively(
      backendProbeCandidates,
      maxConcurrent: 4,
      cancellationToken: token,
      verify: (line) => verifyPlaybackLine(
        line,
        enrichMetadata: false,
        cancellationToken: token,
      ),
    )) {
      if (!_isCurrent(scope) || token.isCancelled) return;
      clientCheckedBaseLines = replacePlaybackLine(
        clientCheckedBaseLines,
        probedLine,
      );
      completedBackendProbes++;
      yield PlaybackLineLookupUpdate(
        lines: clientCheckedBaseLines,
        completedRules: completedBackendProbes,
        totalRules: backendProbeTotal,
        phase: PlaybackLineLookupPhase.discovery,
      );
    }
    if (!_isCurrent(scope) || token.isCancelled) return;
    final ruleState = _ruleState;
    if (ruleState.customRules.isEmpty) {
      yield PlaybackLineLookupUpdate(
        lines: clientCheckedBaseLines,
        completedRules: backendProbeTotal,
        totalRules: backendProbeTotal,
        phase: PlaybackLineLookupPhase.complete,
      );
      return;
    }
    yield PlaybackLineLookupUpdate(
      lines: clientCheckedBaseLines,
      completedRules: backendProbeTotal,
      totalRules: backendProbeTotal,
      phase: PlaybackLineLookupPhase.discovery,
    );
    final repository = _ruleRepository(ruleState);
    await for (final update in repository.lineUpdatesForEpisode(
      subject,
      episode,
      cancellationToken: token,
    )) {
      if (!_isCurrent(scope) || token.isCancelled) return;
      yield PlaybackLineLookupUpdate(
        lines: mergePlaybackLines(<PlaybackLine>[
          ...clientCheckedBaseLines,
          ...update.lines,
        ]),
        completedRules: update.completedRules + backendProbeTotal,
        totalRules: update.totalRules + backendProbeTotal,
        phase: update.phase,
        timedOut: update.timedOut,
        resolvedProviderId: update.resolvedProviderId,
      );
    }
  }

  void prefetchPlayback(AnimeSubject subject, List<AnimeEpisode> episodes) {
    final scope = _scope();
    if (episodes.isEmpty || !_usesBackendPlayback(subject)) return;
    final historyEpisode = _history
        .where((item) => sameSubjectIdentity(item.subject, subject))
        .map((item) => item.episode)
        .whereType<AnimeEpisode>()
        .firstOrNull;
    final episode =
        historyEpisode != null &&
            episodes.any((item) => item.id == historyEpisode.id)
        ? historyEpisode
        : episodes.first;
    final key = <Object?>[
      scope.accountId,
      scope.contextVersion,
      scope.epoch,
      subject.source,
      subject.id,
      subject.title,
      episode.id,
      episode.number,
    ].join('|');
    if (_prefetches.containsKey(key)) return;

    final cancellationToken = RulePlaybackCancellationToken();
    late final Future<void> prefetch;
    prefetch =
        _prefetchAndRankPlayback(
          scope,
          subject,
          episode,
          cancellationToken: cancellationToken,
        ).onError((_, _) {}).whenComplete(() {
          if (identical(_prefetches[key], prefetch)) {
            _prefetches.remove(key);
            _prefetchTokens.remove(key);
          }
        });
    _prefetches[key] = prefetch;
    _prefetchTokens[key] = cancellationToken;
  }

  void clearCaches() => _invalidateAsyncWork();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    _invalidateScope();
  }

  Future<void> _prefetchAndRankPlayback(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required RulePlaybackCancellationToken cancellationToken,
  }) async {
    final lines = await linesForEpisode(
      subject,
      episode,
      cancellationToken: cancellationToken,
    );
    if (!_isCurrent(scope) || cancellationToken.isCancelled) return;
    var backendLines = lines
        .where((line) => line.providerId.startsWith('zeluna:'))
        .toList(growable: false);
    if (backendLines.isEmpty) return;

    final refreshThreshold = DateTime.now().add(const Duration(seconds: 15));
    final candidates = backendLines
        .where(
          (line) =>
              !line.clientVerified &&
              (line.serverVerified || line.requiresClientProbe) &&
              (line.url?.trim().isNotEmpty ?? false) &&
              (line.expiresAt == null ||
                  line.expiresAt!.isAfter(refreshThreshold)),
        )
        .take(3)
        .toList(growable: false);
    await for (final verified in probePlaybackLinesProgressively(
      candidates,
      maxConcurrent: 3,
      cancellationToken: cancellationToken,
      verify: (line) => verifyPlaybackLine(
        line,
        enrichMetadata: false,
        cancellationToken: cancellationToken,
      ),
    )) {
      if (!_isCurrent(scope) || cancellationToken.isCancelled) return;
      backendLines = replacePlaybackLine(backendLines, verified);
    }
    if (!_isCurrent(scope) || cancellationToken.isCancelled) return;
    _cacheBackendPlaybackLines(
      scope,
      subject,
      episode,
      rankPlaybackLinesForStartup(backendLines),
    );
  }

  Future<List<PlaybackLine>> _backendLinesForEpisode(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    if (!_isCurrent(scope) || cancellationToken?.isCancelled == true) {
      return Future.value(const <PlaybackLine>[]);
    }
    final services = _services;
    final lookupKey = _backendPlaybackLookupKey(
      scope,
      services,
      subject,
      episode,
      expandAll: expandAll,
    );
    if (lookupKey == null) return Future.value(const <PlaybackLine>[]);
    final cached = _backendCache.read(lookupKey);
    if (cached != null) return Future.value(cached);
    final pending = _backendLookups.run(lookupKey, () {
      final repository = _backendRepository(services);
      if (repository == null) return Future.value(const <PlaybackLine>[]);
      return repository
          .linesForEpisodeMode(subject, episode, expandAll: expandAll)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => const <PlaybackLine>[],
          )
          .onError((_, _) => const <PlaybackLine>[]);
    });
    return pending.then((lines) {
      if (!_isCurrent(scope) || cancellationToken?.isCancelled == true) {
        return const <PlaybackLine>[];
      }
      _backendCache.write(lookupKey, lines);
      return lines;
    });
  }

  Future<List<PlaybackLine>> _ruleLinesForEpisode(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (!_isCurrent(scope) || _ruleState.customRules.isEmpty) return const [];
    final ruleState = _ruleState;
    final lines = await _ruleRepository(ruleState)
        .linesForEpisodeMode(
          subject,
          episode,
          expandAll: expandAll,
          cancellationToken: cancellationToken,
        )
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () => const <PlaybackLine>[],
        )
        .onError((_, _) => const <PlaybackLine>[]);
    return _isCurrent(scope) && cancellationToken?.isCancelled != true
        ? lines
        : const <PlaybackLine>[];
  }

  Future<List<PlaybackLine>> _probeBackendClientCandidates(
    _PlaybackDiscoveryScope scope,
    List<PlaybackLine> lines, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final now = DateTime.now();
    final candidates = lines
        .where(
          (line) =>
              line.requiresClientProbe &&
              (line.url?.trim().isNotEmpty ?? false) &&
              (line.expiresAt == null ||
                  line.expiresAt!.isAfter(
                    now.add(const Duration(seconds: 15)),
                  )),
        )
        .take(4)
        .toList(growable: false);
    if (candidates.isEmpty || cancellationToken?.isCancelled == true) {
      return const <PlaybackLine>[];
    }
    final checked = <PlaybackLine>[];
    await for (final line in probePlaybackLinesProgressively(
      candidates,
      maxConcurrent: 4,
      cancellationToken: cancellationToken,
      verify: (line) => verifyPlaybackLine(
        line,
        enrichMetadata: false,
        cancellationToken: cancellationToken,
      ),
    )) {
      if (!_isCurrent(scope) || cancellationToken?.isCancelled == true) {
        return const <PlaybackLine>[];
      }
      checked.add(line);
      if (line.available) return <PlaybackLine>[line];
    }
    return checked;
  }

  String? _backendPlaybackLookupKey(
    _PlaybackDiscoveryScope scope,
    ExternalServiceSettings services,
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
  }) {
    final service = SettingsController.playbackBackendService(services);
    final endpoint = ZelunaBackendPlaybackRepository.normalizeBaseUrl(
      services.playbackBackendEndpoint,
      service: service,
      allowInsecureSelfHosted: services.allowInsecurePlaybackBackend,
    );
    if (!services.playbackBackendEnabled ||
        !_usesBackendPlayback(subject) ||
        endpoint == null) {
      return null;
    }
    return <Object?>[
      scope.accountId,
      scope.contextVersion,
      scope.epoch,
      endpoint,
      service.name,
      services.allowInsecurePlaybackBackend,
      subject.source,
      subject.id,
      episode.id,
      episode.number,
      expandAll,
    ].join('|');
  }

  void _cacheBackendPlaybackLines(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode,
    Iterable<PlaybackLine> lines, {
    bool expandAll = false,
  }) {
    if (!_isCurrent(scope)) return;
    final lookupKey = _backendPlaybackLookupKey(
      scope,
      _services,
      subject,
      episode,
      expandAll: expandAll,
    );
    if (lookupKey != null) _backendCache.write(lookupKey, lines);
  }

  List<PlaybackLine> _backendLinesNeedingBackgroundProbe(
    List<PlaybackLine> lines,
  ) {
    final refreshThreshold = DateTime.now().add(const Duration(seconds: 15));
    return lines
        .where(
          (line) =>
              (line.url?.trim().isNotEmpty ?? false) &&
              (line.requiresClientProbe ||
                  (line.serverVerified &&
                      !line.clientVerified &&
                      line.latency == null)) &&
              (line.expiresAt == null ||
                  line.expiresAt!.isAfter(refreshThreshold)),
        )
        .toList(growable: false);
  }

  void _invalidateScope() {
    _scopeEpoch++;
    _invalidateAsyncWork(incrementEpoch: false);
    _clearRuleRuntimeCaches();
  }

  void _invalidateAsyncWork({bool incrementEpoch = true}) {
    if (incrementEpoch) _scopeEpoch++;
    for (final token in _prefetchTokens.values) {
      token.cancel();
    }
    _prefetchTokens.clear();
    _prefetches.clear();
    _backendLookups.clear();
    _backendCache.clear();
  }

  _PlaybackDiscoveryScope _scope() {
    _ensureNotDisposed();
    if (!_loaded) throw StateError('Playback discovery is not configured.');
    return _PlaybackDiscoveryScope(
      accountId: _accountId,
      contextVersion: _contextVersion,
      epoch: _scopeEpoch,
    );
  }

  bool _isCurrent(_PlaybackDiscoveryScope scope) =>
      !_disposed &&
      _loaded &&
      scope.accountId == _accountId &&
      scope.contextVersion == _contextVersion &&
      scope.epoch == _scopeEpoch &&
      _isContextCurrent(scope.contextVersion);

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('Playback discovery is disposed.');
  }

  static bool _usesBackendPlayback(AnimeSubject subject) {
    final source = subject.source.toLowerCase();
    return source == 'bangumi' || source.startsWith('tmdb:');
  }

  static String _servicesSignature(ExternalServiceSettings services) =>
      <Object?>[
        services.playbackBackendEnabled,
        services.playbackBackendEndpoint.trim(),
        services.playbackBackendSelfHosted,
        services.allowInsecurePlaybackBackend,
      ].join('|');
}

List<PlaybackLine> mergePlaybackLines(Iterable<PlaybackLine> lines) {
  final merged = <PlaybackLine>[];
  final indexes = <String, int>{};
  for (final line in lines) {
    final url = line.url ?? '';
    final key = url.isNotEmpty ? url : '${line.providerId}:${line.id}';
    final previousIndex = indexes[key];
    if (previousIndex == null) {
      indexes[key] = merged.length;
      merged.add(line);
    } else if (!merged[previousIndex].available && line.available) {
      merged[previousIndex] = line;
    }
  }
  return List<PlaybackLine>.unmodifiable(merged);
}

List<PlaybackLine> replacePlaybackLine(
  Iterable<PlaybackLine> lines,
  PlaybackLine replacement,
) {
  var replaced = false;
  final result = <PlaybackLine>[];
  for (final line in lines) {
    if (line.id == replacement.id) {
      if (!replaced) result.add(replacement);
      replaced = true;
    } else {
      result.add(line);
    }
  }
  if (!replaced) result.add(replacement);
  return List<PlaybackLine>.unmodifiable(result);
}

final class _PlaybackDiscoveryScope {
  const _PlaybackDiscoveryScope({
    required this.accountId,
    required this.contextVersion,
    required this.epoch,
  });

  final String? accountId;
  final int contextVersion;
  final int epoch;
}
