import 'dart:async';

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

enum PlaybackLookupIntent { interactive, warmup }

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
    Duration interactivePreferredHeadStart = const Duration(milliseconds: 750),
  }) : assert(interactivePreferredHeadStart.inMicroseconds > 0),
       _backendRepository = backendRepository,
       _ruleRepository = ruleRepository,
       _verifyLine = verifyLine,
       _isContextCurrent = isContextCurrent,
       _clearRuleRuntimeCaches = clearRuleRuntimeCaches,
       _now = now ?? DateTime.now,
       _interactivePreferredHeadStart = interactivePreferredHeadStart,
       _backendCache = PlaybackPrefetchCache(now: now),
       _episodeWarmupCache = NextEpisodeWarmupCache(
         ttl: const Duration(minutes: 45),
         maxEntries: 8,
         now: now,
       );

  final PlaybackBackendRepositoryFactory _backendRepository;
  final PlaybackRuleRepositoryFactory _ruleRepository;
  final PlaybackLineVerifier _verifyLine;
  final PlaybackContextGuard _isContextCurrent;
  final void Function() _clearRuleRuntimeCaches;
  final DateTime Function() _now;
  final Duration _interactivePreferredHeadStart;
  final PlaybackPrefetchCache _backendCache;
  final NextEpisodeWarmupCache _episodeWarmupCache;
  final Map<String, _BackendLookupOperation> _backendLookups =
      <String, _BackendLookupOperation>{};
  final Map<String, Future<void>> _prefetches = <String, Future<void>>{};
  final Map<String, RulePlaybackCancellationToken> _prefetchTokens =
      <String, RulePlaybackCancellationToken>{};
  final Set<RulePlaybackCancellationToken> _activeLookupTokens =
      <RulePlaybackCancellationToken>{};

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
  int get cachedWarmupEntries => _episodeWarmupCache.length;

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
    bool forceRefresh = false,
    String? preferredProviderId,
    RulePlaybackCancellationToken? cancellationToken,
    PlaybackLookupIntent lookupIntent = PlaybackLookupIntent.interactive,
  }) => linesForEpisodeMode(
    subject,
    episode,
    forceRefresh: forceRefresh,
    preferredProviderId: preferredProviderId,
    cancellationToken: cancellationToken,
    lookupIntent: lookupIntent,
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
    bool forceRefresh = false,
    String? preferredProviderId,
    RulePlaybackCancellationToken? cancellationToken,
    PlaybackLookupIntent lookupIntent = PlaybackLookupIntent.interactive,
  }) async {
    final scope = _scope();
    if (cancellationToken?.isCancelled ?? false) return const [];
    final preferred = preferredProviderId?.trim();
    if ((preferred == null || preferred.isEmpty) &&
        lookupIntent == PlaybackLookupIntent.interactive) {
      return _linesForEpisodeWithoutPreference(
        scope,
        subject,
        episode,
        expandAll: expandAll,
        forceRefresh: forceRefresh,
        cancellationToken: cancellationToken,
      );
    }
    return _linesForEpisodeWithPreference(
      scope,
      subject,
      episode,
      expandAll: expandAll,
      forceRefresh: forceRefresh,
      preferredProviderId: preferred,
      lookupIntent: lookupIntent,
      cancellationToken: cancellationToken,
    );
  }

  Future<List<PlaybackLine>> _linesForEpisodeWithoutPreference(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool expandAll,
    required bool forceRefresh,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final lookupWorkToken = RulePlaybackCancellationToken();
    _activeLookupTokens.add(lookupWorkToken);
    final unlinkLookupWork = cancellationToken?.register(
      lookupWorkToken.cancel,
    );
    final cancelled = Completer<({String kind, List<PlaybackLine> lines})>();
    final unlinkCancellation = lookupWorkToken.register(() {
      if (!cancelled.isCompleted) {
        cancelled.complete((kind: 'cancelled', lines: const <PlaybackLine>[]));
      }
    });
    var lookupWorkStopped = false;
    var backendLines = const <PlaybackLine>[];
    var probedBackendLines = const <PlaybackLine>[];
    var ruleLines = const <PlaybackLine>[];

    List<PlaybackLine> finish(List<PlaybackLine> lines) {
      if (!lookupWorkStopped) {
        lookupWorkStopped = true;
        _activeLookupTokens.remove(lookupWorkToken);
        lookupWorkToken.cancel();
        unlinkCancellation();
        unlinkLookupWork?.call();
      }
      return lines;
    }

    bool isCurrentRequest() =>
        _isCurrent(scope) && !(cancellationToken?.isCancelled ?? false);
    bool hasPlayableLine(Iterable<PlaybackLine> lines) => lines.any(
      (line) => line.available && (line.url?.trim().isNotEmpty ?? false),
    );
    List<PlaybackLine> currentLines() {
      return mergePlaybackLines(<PlaybackLine>[
        ...backendLines,
        ...probedBackendLines,
        ...ruleLines,
      ]);
    }

    Future<({String kind, List<PlaybackLine> lines})> tagged(
      String kind,
      Future<List<PlaybackLine>> future,
    ) async {
      try {
        return (kind: kind, lines: await future);
      } catch (_) {
        return (kind: kind, lines: const <PlaybackLine>[]);
      }
    }

    final backendEvent = tagged(
      'backend',
      _backendLinesForEpisode(
        scope,
        subject,
        episode,
        forceRefresh: forceRefresh,
        cancellationToken: lookupWorkToken,
      ).timeout(
        const Duration(seconds: 6),
        onTimeout: () => const <PlaybackLine>[],
      ),
    );
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
            cancellationToken: lookupWorkToken,
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
          cancellationToken: lookupWorkToken,
        ).onError((_, _) => const <PlaybackLine>[]),
      );
    }

    try {
      final firstEvent = await Future.any([
        backendEvent,
        Future<({String kind, List<PlaybackLine> lines})>.delayed(
          const Duration(milliseconds: 900),
          () => (kind: 'hedge', lines: const <PlaybackLine>[]),
        ),
        cancelled.future,
      ]);
      if (!isCurrentRequest() || firstEvent.kind == 'cancelled') {
        return finish(const <PlaybackLine>[]);
      }
      if (firstEvent.kind == 'backend') {
        backendLines = firstEvent.lines;
        final merged = currentLines();
        if (hasPlayableLine(merged)) return finish(merged);
        startBackendCandidateProbe();
        startRules();
      } else {
        pending['backend'] = backendEvent;
        startRules();
      }

      while (pending.isNotEmpty) {
        final event = await Future.any([...pending.values, cancelled.future]);
        if (event.kind == 'cancelled') return finish(const <PlaybackLine>[]);
        pending.remove(event.kind);
        if (!isCurrentRequest()) return finish(const <PlaybackLine>[]);
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
        final merged = currentLines();
        if (hasPlayableLine(merged)) return finish(merged);
      }

      return finish(
        isCurrentRequest() ? currentLines() : const <PlaybackLine>[],
      );
    } finally {
      finish(const <PlaybackLine>[]);
    }
  }

  Future<List<PlaybackLine>> _linesForEpisodeWithPreference(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool expandAll,
    required bool forceRefresh,
    required String? preferredProviderId,
    required PlaybackLookupIntent lookupIntent,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final workToken = RulePlaybackCancellationToken();
    _activeLookupTokens.add(workToken);
    final unlinkCaller = cancellationToken?.register(workToken.cancel);
    final cancelled = Completer<({String kind, List<PlaybackLine> lines})>();
    final unlinkCancellation = workToken.register(() {
      if (!cancelled.isCompleted) {
        cancelled.complete((kind: 'cancelled', lines: const <PlaybackLine>[]));
      }
    });
    var stopped = false;
    var preferredHeadStartElapsed = lookupIntent == PlaybackLookupIntent.warmup;
    var fallbackWorkStarted = false;
    var backendStarted = false;
    var backendLines = const <PlaybackLine>[];
    var probedBackendLines = const <PlaybackLine>[];
    var preferredRuleLines = const <PlaybackLine>[];
    var fallbackRuleLines = const <PlaybackLine>[];
    var genericRuleLines = const <PlaybackLine>[];

    List<PlaybackLine> finish(List<PlaybackLine> lines) {
      if (!stopped) {
        stopped = true;
        _activeLookupTokens.remove(workToken);
        workToken.cancel();
        unlinkCancellation();
        unlinkCaller?.call();
      }
      return lines;
    }

    bool isCurrentRequest() =>
        _isCurrent(scope) && !(cancellationToken?.isCancelled ?? false);
    Future<({String kind, List<PlaybackLine> lines})> tagged(
      String kind,
      Future<List<PlaybackLine>> future,
    ) async {
      try {
        return (kind: kind, lines: await future);
      } catch (_) {
        return (kind: kind, lines: const <PlaybackLine>[]);
      }
    }

    Future<List<PlaybackLine>> guardedRuleLookup(
      FutureOr<List<PlaybackLine>> Function() start,
    ) => Future<List<PlaybackLine>>.sync(start)
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () => const <PlaybackLine>[],
        )
        .onError((_, _) => const <PlaybackLine>[]);

    final pending =
        <String, Future<({String kind, List<PlaybackLine> lines})>>{};
    final hasPreferredSignal = preferredProviderId?.isNotEmpty == true;
    PlaybackSourceRepository? ruleRepository;
    if (_mayHaveRuleProviders(_ruleState)) {
      try {
        ruleRepository = _ruleRepository(_ruleState);
      } catch (_) {
        ruleRepository = null;
      }
    }
    final providerAware =
        ruleRepository is ProviderAwarePlaybackSourceRepository
        ? ruleRepository as ProviderAwarePlaybackSourceRepository
        : null;
    ProviderAwarePlaybackSourceRepository? preferredRuleRepository;
    if (hasPreferredSignal && providerAware != null) {
      try {
        if (providerAware.canResolveProvider(
          subject,
          providerId: preferredProviderId!,
        )) {
          preferredRuleRepository = providerAware;
        }
      } catch (_) {
        preferredRuleRepository = null;
      }
    }
    final hasRuleProvider = preferredRuleRepository != null;

    void startBackend() {
      if (backendStarted) return;
      backendStarted = true;
      pending.putIfAbsent(
        'backend',
        () => tagged(
          'backend',
          _backendLinesForEpisode(
            scope,
            subject,
            episode,
            expandAll: expandAll,
            forceRefresh: forceRefresh,
            cancellationToken: workToken,
          ).timeout(
            const Duration(seconds: 6),
            onTimeout: () => const <PlaybackLine>[],
          ),
        ),
      );
    }

    void startPreferredRule() {
      final preferredRepository = preferredRuleRepository;
      final preferred = preferredProviderId;
      if (preferredRepository == null || preferred == null) return;
      pending.putIfAbsent(
        'preferred-rule',
        () => tagged(
          'preferred-rule',
          guardedRuleLookup(
            () => preferredRepository.verifiedLinesForProvider(
              subject,
              episode,
              providerId: preferred,
              forceRefresh: forceRefresh,
              cancellationToken: workToken,
            ),
          ),
        ),
      );
    }

    void startFallbackRules() {
      if (ruleRepository == null) return;
      pending.putIfAbsent(
        'fallback-rules',
        () => tagged(
          'fallback-rules',
          guardedRuleLookup(
            () => providerAware == null
                ? _ruleLinesForEpisode(
                    scope,
                    subject,
                    episode,
                    expandAll: expandAll,
                    cancellationToken: workToken,
                  )
                : providerAware.verifiedFallbackLinesExcludingProvider(
                    subject,
                    episode,
                    excludedProviderId: preferredProviderId ?? '',
                    forceRefresh: forceRefresh,
                    cancellationToken: workToken,
                  ),
          ),
        ),
      );
    }

    void startFallbackWork() {
      if (fallbackWorkStarted) return;
      fallbackWorkStarted = true;
      startBackend();
      startFallbackRules();
    }

    void startBackendCandidateProbe() {
      if (backendLines.isEmpty || pending.containsKey('probe')) return;
      pending['probe'] = tagged(
        'probe',
        _probeBackendClientCandidates(
          scope,
          backendLines,
          maxCandidates: 2,
          cancellationToken: workToken,
        ).onError((_, _) => const <PlaybackLine>[]),
      );
    }

    List<PlaybackLine> currentVerifiedLines() {
      final minExpiry = _now().add(const Duration(seconds: 15));
      final merged = mergePlaybackLines(<PlaybackLine>[
        ...preferredRuleLines,
        ...fallbackRuleLines,
        ...genericRuleLines,
        ...probedBackendLines,
        ...backendLines,
      ]).where((line) => _isVerifiedLookupLine(line, minExpiry)).toList();
      if (!hasPreferredSignal) {
        return List<PlaybackLine>.unmodifiable(
          rankPlaybackLinesForStartup(merged).take(2),
        );
      }
      final preferred = rankPlaybackLinesForStartup(
        merged.where((line) => line.providerId == preferredProviderId),
      );
      final fallbacks = rankPlaybackLinesForStartup(
        merged.where((line) => line.providerId != preferredProviderId),
      );
      return List<PlaybackLine>.unmodifiable(<PlaybackLine>[
        ...preferred.take(1),
        ...fallbacks.take(1),
      ]);
    }

    bool shouldReturn(List<PlaybackLine> lines) {
      if (!hasPreferredSignal) return lines.length >= 2;
      final hasPreferred = lines.any(
        (line) => line.providerId == preferredProviderId,
      );
      final hasFallback = lines.any(
        (line) => line.providerId != preferredProviderId,
      );
      if (lookupIntent == PlaybackLookupIntent.warmup) {
        return hasPreferred && hasFallback;
      }
      return hasPreferred || (preferredHeadStartElapsed && hasFallback);
    }

    try {
      if (lookupIntent == PlaybackLookupIntent.warmup) {
        startPreferredRule();
        startFallbackWork();
      } else {
        startPreferredRule();
        if (!hasRuleProvider) startBackend();
        pending['preferred-head-start'] = tagged(
          'preferred-head-start',
          Future<List<PlaybackLine>>.delayed(
            _interactivePreferredHeadStart,
            () => const <PlaybackLine>[],
          ),
        );
      }

      while (pending.isNotEmpty) {
        final event = await Future.any([...pending.values, cancelled.future]);
        if (event.kind == 'cancelled' || !isCurrentRequest()) {
          return finish(const <PlaybackLine>[]);
        }
        pending.remove(event.kind);
        switch (event.kind) {
          case 'backend':
            backendLines = event.lines;
            startBackendCandidateProbe();
          case 'probe':
            probedBackendLines = event.lines;
            if (probedBackendLines.isNotEmpty) {
              var verifiedBackendLines = backendLines;
              for (final line in probedBackendLines) {
                verifiedBackendLines = replacePlaybackLine(
                  verifiedBackendLines,
                  line,
                );
              }
              _cacheBackendPlaybackLines(
                scope,
                subject,
                episode,
                verifiedBackendLines,
                expandAll: expandAll,
              );
            }
          case 'preferred-rule':
            preferredRuleLines = event.lines;
            if (preferredProviderId != null &&
                event.lines.every(
                  (line) => line.providerId != preferredProviderId,
                )) {
              preferredHeadStartElapsed = true;
              pending.remove('preferred-head-start');
              startFallbackWork();
            }
          case 'fallback-rules':
            if (providerAware == null) {
              genericRuleLines = event.lines;
            } else {
              fallbackRuleLines = event.lines;
            }
          case 'preferred-head-start':
            preferredHeadStartElapsed = true;
            startFallbackWork();
        }
        final lines = currentVerifiedLines();
        if (shouldReturn(lines)) return finish(lines);
      }

      return finish(
        isCurrentRequest() ? currentVerifiedLines() : const <PlaybackLine>[],
      );
    } finally {
      finish(const <PlaybackLine>[]);
    }
  }

  static bool _isVerifiedLookupLine(PlaybackLine line, DateTime minExpiry) {
    if (!line.available || (!line.serverVerified && !line.clientVerified)) {
      return false;
    }
    final url = Uri.tryParse(line.url?.trim() ?? '');
    if (url == null ||
        (url.scheme != 'http' && url.scheme != 'https') ||
        url.host.isEmpty) {
      return false;
    }
    final expiresAt = line.expiresAt;
    return expiresAt == null || expiresAt.isAfter(minExpiry);
  }

  PlaybackLine? prefetchedLineForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    Duration minValidity = const Duration(seconds: 60),
  }) {
    final scope = _scope();
    final prefetched = _episodeWarmupCache.read(
      _episodePrefetchKey(scope, subject, episode),
      minValidity: minValidity,
    );
    final cached = <PlaybackLine>[
      if (prefetched != null) ...prefetched.allLines,
    ];
    final lookupKey = _backendPlaybackLookupKey(
      scope,
      _services,
      subject,
      episode,
    );
    if (lookupKey != null) {
      final backend = _backendCache.read(lookupKey, minValidity: minValidity);
      if (backend != null) cached.addAll(backend);
    }
    final unique = <String, PlaybackLine>{
      for (final line in cached) line.id: line,
    };
    final lines = <PlaybackLine>[...unique.values];
    final preferred = preferredProviderId?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      lines.sort((a, b) {
        final aPreferred = a.providerId == preferred;
        final bPreferred = b.providerId == preferred;
        if (aPreferred == bPreferred) return 0;
        return aPreferred ? -1 : 1;
      });
    }
    for (final line in lines) {
      if (line.available &&
          (line.serverVerified || line.clientVerified) &&
          (line.url?.trim().isNotEmpty ?? false)) {
        return line;
      }
    }
    return null;
  }

  NextEpisodeWarmupBundle? prefetchedWarmupBundleForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    Duration minValidity = const Duration(seconds: 60),
  }) {
    final scope = _scope();
    return _episodeWarmupCache.read(
      _episodePrefetchKey(scope, subject, episode),
      minValidity: minValidity,
    );
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
    if (!_mayHaveRuleProviders(ruleState)) {
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
    _startPrefetch(
      scope,
      subject,
      episode,
      cacheEpisode: false,
      preferredProviderId: null,
      forceRefresh: false,
    );
  }

  Future<void> prefetchPlaybackForEpisode(
    AnimeSubject subject,
    AnimeEpisode episode, {
    String? preferredProviderId,
    bool forceRefresh = false,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    final scope = _scope();
    if (cancellationToken?.isCancelled == true ||
        !_isPrefetchableSubject(subject)) {
      return;
    }
    final key = _prefetchJobKey(scope, subject, episode, episodeCache: true);
    if (forceRefresh) {
      _prefetchTokens[key]?.cancel();
      _prefetches.remove(key);
      _prefetchTokens.remove(key);
      _episodeWarmupCache.remove(_episodePrefetchKey(scope, subject, episode));
    }
    final existing = _prefetches[key];
    if (existing != null) {
      await existing;
      return;
    }
    final token = cancellationToken ?? RulePlaybackCancellationToken();
    _prefetchTokens[key] = token;
    late final Future<void> prefetch;
    prefetch =
        _prefetchAndRankPlayback(
          scope,
          subject,
          episode,
          cancellationToken: token,
          cacheEpisode: true,
          preferredProviderId: preferredProviderId,
          forceRefresh: forceRefresh,
        ).whenComplete(() {
          if (identical(_prefetches[key], prefetch)) {
            _prefetches.remove(key);
            _prefetchTokens.remove(key);
          }
        });
    _prefetches[key] = prefetch;
    await prefetch;
  }

  void _startPrefetch(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    required bool cacheEpisode,
    required String? preferredProviderId,
    required bool forceRefresh,
  }) {
    final key = _prefetchJobKey(
      scope,
      subject,
      episode,
      episodeCache: cacheEpisode,
    );
    if (_prefetches.containsKey(key)) return;
    final token = RulePlaybackCancellationToken();
    late final Future<void> prefetch;
    prefetch =
        _prefetchAndRankPlayback(
          scope,
          subject,
          episode,
          cancellationToken: token,
          cacheEpisode: cacheEpisode,
          preferredProviderId: preferredProviderId,
          forceRefresh: forceRefresh,
        ).onError((_, _) {}).whenComplete(() {
          if (identical(_prefetches[key], prefetch)) {
            _prefetches.remove(key);
            _prefetchTokens.remove(key);
          }
        });
    _prefetches[key] = prefetch;
    _prefetchTokens[key] = token;
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
    required bool cacheEpisode,
    required String? preferredProviderId,
    required bool forceRefresh,
  }) async {
    final lines = await linesForEpisode(
      subject,
      episode,
      forceRefresh: forceRefresh,
      preferredProviderId: preferredProviderId,
      cancellationToken: cancellationToken,
      lookupIntent: PlaybackLookupIntent.warmup,
    );
    if (!_isCurrent(scope) || cancellationToken.isCancelled) return;
    final preferred = preferredProviderId?.trim();
    var candidates = cacheEpisode
        ? lines.toList(growable: true)
        : lines
              .where((line) => line.providerId.startsWith('zeluna:'))
              .toList(growable: true);
    if (candidates.isEmpty) return;
    if (preferred != null && preferred.isNotEmpty) {
      candidates.sort((a, b) {
        final aPreferred = a.providerId == preferred;
        final bPreferred = b.providerId == preferred;
        if (aPreferred == bPreferred) return 0;
        return aPreferred ? -1 : 1;
      });
    }

    final refreshThreshold = _now().add(const Duration(seconds: 15));
    final probeCandidates = candidates
        .where(
          (line) =>
              !line.clientVerified &&
              (line.serverVerified || line.requiresClientProbe) &&
              (line.url?.trim().isNotEmpty ?? false) &&
              (line.expiresAt == null ||
                  line.expiresAt!.isAfter(refreshThreshold)),
        )
        .take(cacheEpisode ? 2 : 3)
        .toList(growable: false);
    await for (final verified in probePlaybackLinesProgressively(
      probeCandidates,
      maxConcurrent: cacheEpisode ? 2 : 3,
      cancellationToken: cancellationToken,
      verify: (line) => verifyPlaybackLine(
        line,
        enrichMetadata: false,
        cancellationToken: cancellationToken,
      ),
    )) {
      if (!_isCurrent(scope) || cancellationToken.isCancelled) return;
      candidates = replacePlaybackLine(candidates, verified);
    }
    if (!_isCurrent(scope) || cancellationToken.isCancelled) return;
    final ranked = rankPlaybackLinesForStartup(candidates);
    if (cacheEpisode) {
      if (ranked.isEmpty) return;
      _episodeWarmupCache.write(
        _episodePrefetchKey(scope, subject, episode),
        episodeIdentity: episode.identityKey(subjectKey: subject.identityKey),
        primary: ranked.first,
        fallbacks: ranked.skip(1).take(1),
        preferredProviderId: preferred,
        ttl: const Duration(minutes: 45),
      );
    } else {
      _cacheBackendPlaybackLines(scope, subject, episode, ranked);
    }
  }

  Future<List<PlaybackLine>> _backendLinesForEpisode(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    bool forceRefresh = false,
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
    if (forceRefresh) {
      _backendLookups.remove(lookupKey)?.cancel();
      _backendCache.remove(lookupKey);
    }

    var operation = _backendLookups[lookupKey];
    if (operation == null && !forceRefresh) {
      final cached = _backendCache.read(lookupKey);
      if (cached != null) return Future.value(cached);
    }
    if (operation == null) {
      operation = _BackendLookupOperation();
      _backendLookups[lookupKey] = operation;
      final ownedOperation = operation;
      ownedOperation.future =
          Future<List<PlaybackLine>>.sync(() {
                final repository = _backendRepository(services);
                if (repository == null) return const <PlaybackLine>[];
                return repository.linesForEpisodeMode(
                  subject,
                  episode,
                  expandAll: expandAll,
                  cancellationToken: ownedOperation.token,
                );
              })
              .timeout(
                const Duration(seconds: 20),
                onTimeout: () {
                  ownedOperation.token.cancel();
                  return const <PlaybackLine>[];
                },
              )
              .onError((_, _) => const <PlaybackLine>[])
              .then((lines) {
                ownedOperation.settled = true;
                if (identical(_backendLookups[lookupKey], ownedOperation)) {
                  _backendLookups.remove(lookupKey);
                  if (_isCurrent(scope) && !ownedOperation.token.isCancelled) {
                    _backendCache.write(lookupKey, lines);
                  }
                }
                return List<PlaybackLine>.unmodifiable(lines);
              });
    }

    return _subscribeToBackendOperation(
      lookupKey,
      operation,
      cancellationToken: cancellationToken,
    );
  }

  Future<List<PlaybackLine>> _subscribeToBackendOperation(
    String lookupKey,
    _BackendLookupOperation operation, {
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled == true) {
      return const <PlaybackLine>[];
    }
    operation.subscribers++;
    final callerCancelled = Completer<List<PlaybackLine>>();
    final unlinkCaller = cancellationToken?.register(() {
      if (!callerCancelled.isCompleted) {
        callerCancelled.complete(const <PlaybackLine>[]);
      }
    });
    try {
      return await Future.any<List<PlaybackLine>>(<Future<List<PlaybackLine>>>[
        operation.future,
        operation.stopped.future.then((_) => const <PlaybackLine>[]),
        if (cancellationToken != null) callerCancelled.future,
      ]);
    } finally {
      unlinkCaller?.call();
      operation.subscribers--;
      if (operation.subscribers == 0 && !operation.settled) {
        if (identical(_backendLookups[lookupKey], operation)) {
          _backendLookups.remove(lookupKey);
        }
        operation.cancel();
      }
    }
  }

  Future<List<PlaybackLine>> _ruleLinesForEpisode(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool expandAll = false,
    String? preferredProviderId,
    RulePlaybackCancellationToken? cancellationToken,
  }) async {
    if (!_isCurrent(scope) || !_mayHaveRuleProviders(_ruleState)) {
      return const [];
    }
    final repository = _ruleRepository(_ruleState);
    final preferred = preferredProviderId?.trim();
    final preferredRepository = repository is PreferredPlaybackSourceRepository
        ? repository as PreferredPlaybackSourceRepository
        : null;
    final lookup =
        preferred == null || preferred.isEmpty || preferredRepository == null
        ? repository.linesForEpisodeMode(
            subject,
            episode,
            expandAll: expandAll,
            cancellationToken: cancellationToken,
          )
        : preferredRepository.linesForEpisodeWithPreferredProvider(
            subject,
            episode,
            preferredProviderId: preferred,
            expandAll: expandAll,
            cancellationToken: cancellationToken,
          );
    final lines = await lookup
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () => const <PlaybackLine>[],
        )
        .onError((_, _) => const <PlaybackLine>[]);
    return _isCurrent(scope) && cancellationToken?.isCancelled != true
        ? lines
        : const <PlaybackLine>[];
  }

  static bool _mayHaveRuleProviders(RulePluginState state) =>
      state.enabledIds.isNotEmpty || state.customRules.isNotEmpty;

  Future<List<PlaybackLine>> _probeBackendClientCandidates(
    _PlaybackDiscoveryScope scope,
    List<PlaybackLine> lines, {
    int maxCandidates = 4,
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
        .take(maxCandidates)
        .toList(growable: false);
    if (candidates.isEmpty || cancellationToken?.isCancelled == true) {
      return const <PlaybackLine>[];
    }
    final checked = <PlaybackLine>[];
    await for (final line in probePlaybackLinesProgressively(
      candidates,
      maxConcurrent: maxCandidates,
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

  String _prefetchJobKey(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode, {
    bool episodeCache = false,
  }) => <Object?>[
    episodeCache ? 'next-prefetch' : 'detail-prefetch',
    scope.accountId,
    scope.contextVersion,
    scope.epoch,
    subject.identityKey,
    episode.identityKey(subjectKey: subject.identityKey),
  ].join('|');

  String _episodePrefetchKey(
    _PlaybackDiscoveryScope scope,
    AnimeSubject subject,
    AnimeEpisode episode,
  ) => <Object?>[
    'next-episode',
    scope.accountId,
    scope.contextVersion,
    scope.epoch,
    subject.identityKey,
    episode.identityKey(subjectKey: subject.identityKey),
  ].join('|');

  static bool _isPrefetchableSubject(AnimeSubject subject) {
    final source = subject.source.trim().toLowerCase();
    return source != 'direct' && source != 'offline';
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
    for (final token in _activeLookupTokens.toList(growable: false)) {
      token.cancel();
    }
    _activeLookupTokens.clear();
    for (final operation in _backendLookups.values.toList(growable: false)) {
      operation.cancel();
    }
    _backendLookups.clear();
    _backendCache.clear();
    _episodeWarmupCache.clear();
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

final class _BackendLookupOperation {
  final RulePlaybackCancellationToken token = RulePlaybackCancellationToken();
  final Completer<void> stopped = Completer<void>();
  late Future<List<PlaybackLine>> future;
  int subscribers = 0;
  bool settled = false;

  void cancel() {
    token.cancel();
    if (!stopped.isCompleted) stopped.complete();
  }
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
