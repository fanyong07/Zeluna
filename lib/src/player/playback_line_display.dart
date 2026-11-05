import '../domain/anime_models.dart';

enum PlaybackLineValidationAction { keep, open, stop }

const playbackLineFailureThreshold = 2;
const playbackStallDetectionWindow = Duration(seconds: 5);
const playbackStallRecoveryCooldown = Duration(seconds: 8);
const playbackStallBufferThreshold = Duration(seconds: 2);
const playbackBackupProbeDelay = Duration(seconds: 12);
const playbackBackupProbeMinimumPosition = Duration(seconds: 8);
const playbackBackupProbeMinimumBuffer = Duration(seconds: 8);

int nextPlaybackLineFailureCount(int currentCount, {bool definitive = false}) {
  return definitive ? playbackLineFailureThreshold : currentCount + 1;
}

bool shouldRetryPlaybackLineAfterFailure(int failureCount) {
  return failureCount < playbackLineFailureThreshold;
}

Duration playbackBufferedAhead({
  required Duration position,
  required Duration buffer,
}) {
  return buffer > position ? buffer - position : Duration.zero;
}

bool playbackShouldRecoverFromStall({
  required bool appInForeground,
  required bool playing,
  required bool buffering,
  required bool loading,
  required bool playbackFailed,
  required Duration position,
  required Duration duration,
  required Duration buffer,
  required Duration stalledFor,
  required Duration sinceLastRecovery,
}) {
  if (!appInForeground ||
      !playing ||
      loading ||
      playbackFailed ||
      position <= Duration.zero ||
      stalledFor < playbackStallDetectionWindow ||
      sinceLastRecovery < playbackStallRecoveryCooldown) {
    return false;
  }
  if (duration > Duration.zero &&
      duration - position <= const Duration(seconds: 3)) {
    return false;
  }
  final bufferedAhead = playbackBufferedAhead(
    position: position,
    buffer: buffer,
  );
  return buffering || bufferedAhead <= playbackStallBufferThreshold;
}

bool playbackShouldPrepareSingleBackup({
  required bool appInForeground,
  required bool playing,
  required bool buffering,
  required bool loading,
  required bool playbackFailed,
  required bool hasAlternative,
  required Duration position,
  required Duration buffer,
}) {
  if (!appInForeground ||
      !playing ||
      buffering ||
      loading ||
      playbackFailed ||
      hasAlternative ||
      position < playbackBackupProbeMinimumPosition) {
    return false;
  }
  // Some media_kit backends do not publish a buffer position. In that case a
  // sustained period of advancing playback is the best available signal that
  // a single low-concurrency fallback probe will not delay the current stream.
  if (buffer <= Duration.zero) return true;
  return playbackBufferedAhead(position: position, buffer: buffer) >=
      playbackBackupProbeMinimumBuffer;
}

class PlaybackLineValidationDecision {
  const PlaybackLineValidationDecision({
    required this.action,
    required this.targetLine,
    required this.selectedLine,
  });

  final PlaybackLineValidationAction action;
  final PlaybackLine? targetLine;
  final PlaybackLine? selectedLine;
}

bool playbackLineNeedsPreDisplayVerification(PlaybackLine line) {
  if (!line.available) return false;
  // Rule resolution and next-episode warmup already verified these requests.
  // Do not repeat the manifest/segment probe on the first-frame critical path.
  if (line.clientVerified &&
      (line.expiresAt == null ||
          line.expiresAt!.isAfter(
            DateTime.now().add(const Duration(seconds: 15)),
          ))) {
    return false;
  }
  // Modern backend namespaces also carry explicit server evidence. Fresh
  // evidence can start playback; stale or client-probe-only routes cannot.
  if (line.serverVerified &&
      !line.requiresClientProbe &&
      line.cacheState != 'stale' &&
      (line.expiresAt == null ||
          line.expiresAt!.isAfter(
            DateTime.now().add(const Duration(seconds: 15)),
          ))) {
    return false;
  }
  // Zeluna's backend only returns lines after a manifest/segment probe. Doing
  // the same work again on the client delays first paint and makes cached
  // playback feel slower than the backend response itself.
  if (line.providerId.startsWith('zeluna:')) return false;
  final rawUrl = line.url?.trim() ?? '';
  final uri = Uri.tryParse(rawUrl);
  return uri?.scheme.toLowerCase() != 'file';
}

/// Trusted backend and already client-verified lines may be handed to the
/// player immediately. Their inventory probe runs in the background so route
/// timing never blocks the first frame.
bool playbackLineCanStartImmediately(PlaybackLine line) {
  return line.available &&
      (line.url?.trim().isNotEmpty ?? false) &&
      !playbackLineNeedsPreDisplayVerification(line);
}

List<PlaybackLine> initialPlaybackLinesForDisplay(PlaybackLine? line) {
  if (line == null || playbackLineNeedsPreDisplayVerification(line)) {
    return const <PlaybackLine>[];
  }
  return List<PlaybackLine>.unmodifiable(<PlaybackLine>[line]);
}

Future<List<PlaybackLine>> verifyPlaybackLinesBeforeDisplay(
  Iterable<PlaybackLine> lines, {
  required Future<PlaybackLine> Function(PlaybackLine line) verify,
}) async {
  final verified = await Future.wait(<Future<PlaybackLine>>[
    for (final line in lines)
      if (playbackLineNeedsPreDisplayVerification(line))
        verify(line)
      else
        Future<PlaybackLine>.value(line),
  ]);
  return List<PlaybackLine>.unmodifiable(verified);
}

List<PlaybackLine> upsertPlaybackLine(
  Iterable<PlaybackLine> lines,
  PlaybackLine replacement,
) {
  var replaced = false;
  final result = <PlaybackLine>[];
  for (final line in lines) {
    if (line.id != replacement.id) {
      result.add(line);
      continue;
    }
    if (!replaced) {
      result.add(replacement);
      replaced = true;
    }
  }
  if (!replaced) result.add(replacement);
  return List<PlaybackLine>.unmodifiable(result);
}

List<PlaybackLine> playablePlaybackLinesInSourceOrder(
  Iterable<PlaybackLine> lines,
) {
  return List<PlaybackLine>.unmodifiable(
    lines.where(
      (line) => line.available && (line.url?.trim().isNotEmpty ?? false),
    ),
  );
}

List<PlaybackLine> selectablePlaybackLinesForDisplay(
  Iterable<PlaybackLine> lines, {
  Set<String> failedLineIds = const <String>{},
}) {
  return sortPlaybackLinesForDisplay(
    playablePlaybackLinesInSourceOrder(
      lines,
    ).where((line) => !failedLineIds.contains(line.id)),
  );
}

List<PlaybackLine> allPlaybackLinesForDisplay(Iterable<PlaybackLine> lines) {
  return sortPlaybackLinesForDisplay(lines);
}

class PlaybackSourceDiagnosticSummary {
  const PlaybackSourceDiagnosticSummary({
    required this.totalSources,
    required this.queriedSources,
    required this.matchedSources,
    required this.playableSources,
  });

  final int totalSources;
  final int queriedSources;
  final int matchedSources;
  final int playableSources;
}

PlaybackSourceDiagnosticSummary summarizePlaybackSourceDiagnostics(
  Iterable<PlaybackLine> lines,
) {
  final queried = <String>{};
  final matched = <String>{};
  final playable = <String>{};
  final all = <String>{};
  for (final line in lines) {
    final key = playbackSourceIdentityKey(line);
    all.add(key);
    final status = line.diagnosticStatus;
    final legacyResolved =
        status.isEmpty &&
        (line.available || line.serverVerified || line.requiresClientProbe);
    if (line.queried ??
        (_diagnosticStatusWasQueried(status) || legacyResolved)) {
      queried.add(key);
    }
    if (line.matched == true ||
        _diagnosticStatusWasMatched(status) ||
        legacyResolved) {
      matched.add(key);
    }
    if (line.available && (line.url?.trim().isNotEmpty ?? false)) {
      playable.add(key);
    }
  }
  return PlaybackSourceDiagnosticSummary(
    totalSources: all.length,
    queriedSources: queried.length,
    matchedSources: matched.length,
    playableSources: playable.length,
  );
}

String playbackSourceIdentityKey(PlaybackLine line) {
  if (line.sourceInventoryId.isNotEmpty) return line.sourceInventoryId;
  final sourceName = line.sourceName.trim().toLowerCase();
  final providerId = line.providerId.trim().toLowerCase();
  if (sourceName.isNotEmpty) return '$providerId|$sourceName';
  if (providerId.isNotEmpty) return providerId;
  return '${line.providerName.trim().toLowerCase()}|${line.id}';
}

bool _diagnosticStatusWasQueried(String status) {
  return status.isNotEmpty &&
      status != PlaybackDiscoveryStatus.notQueried &&
      status != PlaybackDiscoveryStatus.sourceDisabled &&
      status != PlaybackDiscoveryStatus.candidateUnadmitted &&
      status != PlaybackDiscoveryStatus.compatibilityInactive &&
      status != PlaybackDiscoveryStatus.quarantined &&
      status != PlaybackDiscoveryStatus.retired;
}

bool _diagnosticStatusWasMatched(String status) {
  return const <String>{
    PlaybackDiscoveryStatus.matched,
    PlaybackDiscoveryStatus.matchedNoEpisode,
    PlaybackDiscoveryStatus.circuitSuppressed,
    PlaybackDiscoveryStatus.routeUnavailable,
    PlaybackDiscoveryStatus.clientProbeRequired,
    PlaybackDiscoveryStatus.serverVerified,
  }.contains(status);
}

class PlaybackLineDiagnosticGroups {
  const PlaybackLineDiagnosticGroups({
    required this.primary,
    required this.other,
  });

  final List<PlaybackLine> primary;
  final List<PlaybackLine> other;
}

PlaybackLineDiagnosticGroups groupPlaybackLinesForDiagnostics(
  Iterable<PlaybackLine> lines, {
  String? selectedLineId,
}) {
  final ordered = allPlaybackLinesForDisplay(lines);
  final sourceCards = _playbackSourceCardsForDisplay(
    ordered,
    selectedLineId: selectedLineId,
  );
  final indexedPrimary = <(int, int, PlaybackLine)>[];
  final other = <PlaybackLine>[];
  for (var index = 0; index < sourceCards.length; index++) {
    final line = sourceCards[index];
    final priority = _diagnosticPrimaryPriority(line);
    if (priority == null) {
      other.add(line);
    } else {
      indexedPrimary.add((priority, index, line));
    }
  }
  indexedPrimary.sort((left, right) {
    final statusOrder = left.$1.compareTo(right.$1);
    return statusOrder != 0 ? statusOrder : left.$2.compareTo(right.$2);
  });
  return PlaybackLineDiagnosticGroups(
    primary: List<PlaybackLine>.unmodifiable(
      indexedPrimary.map((entry) => entry.$3),
    ),
    other: List<PlaybackLine>.unmodifiable(other),
  );
}

List<PlaybackLine> _playbackSourceCardsForDisplay(
  Iterable<PlaybackLine> lines, {
  String? selectedLineId,
}) {
  final grouped = <String, List<PlaybackLine>>{};
  for (final line in lines) {
    grouped
        .putIfAbsent(_playbackSourceCardIdentityKey(line), () => [])
        .add(line);
  }
  final cards = <PlaybackLine>[];
  for (final candidates in grouped.values) {
    // A pending chapter resolver and a failed matched candidate still describe
    // distinct routes, even before they have a media URL. Collapse only source
    // inventory placeholders; never hide those candidates behind another route.
    final routes = <String, PlaybackLine>{
      for (final line in candidates)
        if (line.url?.trim().isNotEmpty == true ||
            line.clientResolver != null ||
            line.diagnosticStatus ==
                PlaybackDiscoveryStatus.clientResolverRequired ||
            line.diagnosticStatus == PlaybackDiscoveryStatus.routeUnavailable)
          line.id: line,
    };
    if (routes.isNotEmpty) {
      cards.addAll(routes.values);
      continue;
    }
    var best = candidates.first;
    for (final line in candidates.skip(1)) {
      if (_playbackSourceCardPriority(line, selectedLineId: selectedLineId) >
          _playbackSourceCardPriority(best, selectedLineId: selectedLineId)) {
        best = line;
      }
    }
    cards.add(best);
  }
  return List<PlaybackLine>.unmodifiable(cards);
}

String _playbackSourceCardIdentityKey(PlaybackLine line) {
  if (line.sourceInventoryId.isNotEmpty) return line.sourceInventoryId;
  final providerId = line.providerId.trim().toLowerCase();
  final sourceName = line.sourceName.trim().toLowerCase();
  if (providerId == 'managed.urls' || providerId.startsWith('managed:')) {
    return 'line|${line.id}';
  }
  if (sourceName.isEmpty) return 'line|${line.id}';
  return '$providerId|$sourceName';
}

int _playbackSourceCardPriority(PlaybackLine line, {String? selectedLineId}) {
  if (selectedLineId != null && line.id == selectedLineId) return 2000;
  if (line.available && (line.url?.trim().isNotEmpty ?? false)) return 1000;
  if (line.serverVerified) return 950;
  if (line.requiresClientProbe) return 850;
  return switch (line.diagnosticStatus) {
    PlaybackDiscoveryStatus.serverVerified => 900,
    PlaybackDiscoveryStatus.clientProbeRequired => 800,
    PlaybackDiscoveryStatus.routeUnavailable => 700,
    PlaybackDiscoveryStatus.matchedNoEpisode => 600,
    PlaybackDiscoveryStatus.matched => 550,
    PlaybackDiscoveryStatus.circuitSuppressed => 500,
    PlaybackDiscoveryStatus.searchHitNoMatch => 400,
    PlaybackDiscoveryStatus.searchTimeout => 350,
    PlaybackDiscoveryStatus.searchError => 340,
    PlaybackDiscoveryStatus.searchMiss => 300,
    PlaybackDiscoveryStatus.searching => 200,
    PlaybackDiscoveryStatus.notQueried => 100,
    PlaybackDiscoveryStatus.quarantined => 50,
    PlaybackDiscoveryStatus.retired => 0,
    _ when line.url?.trim().isNotEmpty == true => 450,
    _ => 10,
  };
}

int? _diagnosticPrimaryPriority(PlaybackLine line) {
  return switch (line.diagnosticStatus) {
    PlaybackDiscoveryStatus.serverVerified => 0,
    PlaybackDiscoveryStatus.clientProbeRequired => 1,
    PlaybackDiscoveryStatus.routeUnavailable => 2,
    '' when line.available => 0,
    '' when line.requiresClientProbe => 1,
    _ => null,
  };
}

List<PlaybackLine> mergePlaybackLineSnapshot({
  required Iterable<PlaybackLine> currentLines,
  required Iterable<PlaybackLine> snapshotLines,
  String? replacedProviderId,
  bool authoritative = false,
}) {
  final currentById = <String, PlaybackLine>{
    for (final line in currentLines) line.id: line,
  };
  final snapshot = snapshotLines.toList(growable: false);
  final enrichedSnapshot = snapshot
      .map(
        (line) => preservePlaybackLineProbeMetadata(
          previous: currentById[line.id],
          incoming: line,
        ),
      )
      .toList(growable: false);
  if (authoritative) {
    return List<PlaybackLine>.unmodifiable(enrichedSnapshot);
  }

  final merged = <String, PlaybackLine>{
    for (final line in currentLines)
      if (replacedProviderId == null || line.providerId != replacedProviderId)
        line.id: line,
    for (final line in enrichedSnapshot) line.id: line,
  };
  return List<PlaybackLine>.unmodifiable(merged.values);
}

PlaybackLine preservePlaybackLineProbeMetadata({
  required PlaybackLine? previous,
  required PlaybackLine incoming,
}) {
  if (previous == null ||
      previous.url?.trim() != incoming.url?.trim() ||
      incoming.url?.trim().isEmpty != false) {
    return incoming;
  }
  return PlaybackLine(
    id: incoming.id,
    episodeId: incoming.episodeId,
    providerId: incoming.providerId,
    providerName: incoming.providerName,
    title: incoming.title,
    quality: incoming.quality,
    format: incoming.format,
    url: incoming.url,
    clientResolver: incoming.clientResolver,
    headers: incoming.headers,
    latency: incoming.latency ?? previous.latency,
    sizeLabel: incoming.sizeLabel ?? previous.sizeLabel,
    sizeBytes: incoming.sizeBytes ?? previous.sizeBytes,
    sizeEstimated: incoming.sizeBytes == null
        ? previous.sizeEstimated
        : incoming.sizeEstimated,
    videoWidth: incoming.videoWidth ?? previous.videoWidth,
    videoHeight: incoming.videoHeight ?? previous.videoHeight,
    bitrate: incoming.bitrate ?? previous.bitrate,
    codecs: incoming.codecs ?? previous.codecs,
    isLive: incoming.isLive || previous.isLive,
    adaptive: incoming.adaptive || previous.adaptive,
    publicHttpOnly: incoming.publicHttpOnly,
    serverVerified: incoming.serverVerified,
    requiresClientProbe: previous.clientVerified
        ? false
        : incoming.requiresClientProbe,
    clientVerified: incoming.clientVerified || previous.clientVerified,
    startupProfile: incoming.startupProfile == PlaybackStartupProfile.unknown
        ? previous.startupProfile
        : incoming.startupProfile,
    cacheState: incoming.cacheState == 'unknown'
        ? previous.cacheState
        : incoming.cacheState,
    sourceErrorCategory: incoming.sourceErrorCategory.isEmpty
        ? previous.sourceErrorCategory
        : incoming.sourceErrorCategory,
    sourceName: incoming.sourceName.isEmpty
        ? previous.sourceName
        : incoming.sourceName,
    sourceInventoryId: incoming.sourceInventoryId.isEmpty
        ? previous.sourceInventoryId
        : incoming.sourceInventoryId,
    clientQuerySupported:
        incoming.clientQuerySupported || previous.clientQuerySupported,
    queryLocation: incoming.queryLocation.isEmpty
        ? previous.queryLocation
        : incoming.queryLocation,
    sourceAddress: incoming.sourceAddress.isEmpty
        ? previous.sourceAddress
        : incoming.sourceAddress,
    diagnosticStatus: incoming.diagnosticStatus.isEmpty
        ? previous.diagnosticStatus
        : incoming.diagnosticStatus,
    queried: incoming.queried ?? previous.queried,
    aliasesAttempted: incoming.aliasesAttempted ?? previous.aliasesAttempted,
    searchHitCount: incoming.searchHitCount ?? previous.searchHitCount,
    bestMatchScore: incoming.bestMatchScore ?? previous.bestMatchScore,
    matched: incoming.matched ?? previous.matched,
    episodeFound: incoming.episodeFound ?? previous.episodeFound,
    discoveryElapsed: incoming.discoveryElapsed ?? previous.discoveryElapsed,
    expiresAt: incoming.expiresAt ?? previous.expiresAt,
    available: previous.clientVerified
        ? previous.available
        : incoming.available,
    message: previous.clientVerified ? previous.message : incoming.message,
  );
}

/// Applies background measurements without replacing the active route's state.
/// An enrichment request may fail or finish after a route change: only the same
/// URL and exact request headers may contribute media metadata, never failure,
/// verification, cache, diagnostics, resolver or identity fields.
PlaybackLine mergePlaybackLineMediaMetadata({
  required PlaybackLine current,
  required PlaybackLine metadata,
}) {
  final currentUrl = current.url?.trim() ?? '';
  if (currentUrl.isEmpty ||
      currentUrl != metadata.url?.trim() ||
      !_samePlaybackLineHeaders(current.headers, metadata.headers)) {
    return current;
  }
  final hasCurrentBytes = current.sizeBytes != null && current.sizeBytes! > 0;
  final hasMetadataBytes =
      metadata.sizeBytes != null && metadata.sizeBytes! > 0;
  // An estimated manifest size must not replace a measured Content-Length.
  final useMetadataBytes =
      hasMetadataBytes &&
      !(hasCurrentBytes && !current.sizeEstimated && metadata.sizeEstimated);
  final legacyMetadata = _validLegacySizeLabel(metadata.sizeLabel);
  final useLegacyMetadata =
      !hasCurrentBytes &&
      !useMetadataBytes &&
      legacyMetadata != null &&
      (_validLegacySizeLabel(current.sizeLabel) == null ||
          current.sizeEstimated ||
          !metadata.sizeEstimated);
  int? positive(int? value, int? fallback) =>
      value != null && value > 0 ? value : fallback;
  String measuredText(String value, String fallback) =>
      _unknownPlaybackMetadata(value) ? fallback : value;

  return PlaybackLine(
    id: current.id,
    episodeId: current.episodeId,
    providerId: current.providerId,
    providerName: current.providerName,
    title: current.title,
    quality: measuredText(metadata.quality, current.quality),
    format: measuredText(metadata.format, current.format),
    url: current.url,
    clientResolver: current.clientResolver,
    headers: current.headers,
    latency: metadata.latency != null && metadata.latency! >= Duration.zero
        ? metadata.latency
        : current.latency,
    sizeLabel: useLegacyMetadata
        ? legacyMetadata
        : useMetadataBytes
        ? metadata.sizeLabel ?? current.sizeLabel
        : current.sizeLabel,
    sizeBytes: useMetadataBytes ? metadata.sizeBytes : current.sizeBytes,
    sizeEstimated: useMetadataBytes || useLegacyMetadata
        ? metadata.sizeEstimated
        : current.sizeEstimated,
    videoWidth: positive(metadata.videoWidth, current.videoWidth),
    videoHeight: positive(metadata.videoHeight, current.videoHeight),
    bitrate: positive(metadata.bitrate, current.bitrate),
    codecs: _unknownPlaybackMetadata(metadata.codecs ?? '')
        ? current.codecs
        : metadata.codecs,
    isLive: current.isLive || metadata.isLive,
    adaptive: current.adaptive || metadata.adaptive,
    publicHttpOnly: current.publicHttpOnly,
    serverVerified: current.serverVerified,
    requiresClientProbe: current.requiresClientProbe,
    clientVerified: current.clientVerified,
    startupProfile: current.startupProfile,
    cacheState: current.cacheState,
    sourceErrorCategory: current.sourceErrorCategory,
    sourceName: current.sourceName,
    sourceInventoryId: current.sourceInventoryId,
    clientQuerySupported: current.clientQuerySupported,
    queryLocation: current.queryLocation,
    sourceAddress: current.sourceAddress,
    diagnosticStatus: current.diagnosticStatus,
    queried: current.queried,
    aliasesAttempted: current.aliasesAttempted,
    searchHitCount: current.searchHitCount,
    bestMatchScore: current.bestMatchScore,
    matched: current.matched,
    episodeFound: current.episodeFound,
    discoveryElapsed: current.discoveryElapsed,
    expiresAt: current.expiresAt,
    available: current.available,
    message: current.message,
  );
}

bool _samePlaybackLineHeaders(
  Map<String, String> left,
  Map<String, String> right,
) {
  return left.length == right.length &&
      left.entries.every((entry) => right[entry.key] == entry.value);
}

Duration playbackRecoveryPosition(Duration position) {
  return position > const Duration(seconds: 2) ? position : Duration.zero;
}

bool shouldSwitchAfterPlaybackInterruption({
  required Duration position,
  required bool hasAlternative,
}) {
  return hasAlternative && playbackRecoveryPosition(position) > Duration.zero;
}

bool nativePlaybackHasFirstFrame({
  required bool playing,
  required Duration position,
  required bool decodedVideo,
}) {
  // Command acceptance and audio timestamps are not decoded video evidence.
  return decodedVideo && position > Duration.zero;
}

bool nativePlaybackReachedFirstFrame({
  required Duration previousPosition,
  required Duration currentPosition,
  required bool decodedVideo,
}) {
  return decodedVideo &&
      previousPosition <= Duration.zero &&
      currentPosition > Duration.zero;
}

bool nativePlaybackShouldSwitchAtSoftTimeout({
  required Duration position,
  required Duration buffer,
  required bool buffering,
  required bool hasAlternative,
}) {
  // A slow HLS stream may need more than seven seconds for its first segment.
  // Buffer progress is evidence that the current line is alive, even before
  // media_kit advances the playback position.
  return position <= Duration.zero &&
      buffer <= Duration.zero &&
      !buffering &&
      hasAlternative;
}

bool webPlaybackStartupTimedOut({required bool waitingForReady}) {
  // A ready web video can still be paused because the browser rejected
  // autoplay. That is a user-gesture state, not a broken playback line.
  return waitingForReady;
}

bool webPlaybackShouldSwitchAtSoftTimeout({
  required bool waitingForReady,
  required bool hasAlternative,
}) {
  // Seven seconds is useful for a fast fallback, but some valid HLS sources
  // need longer than that to download their first complete segment.
  return waitingForReady && hasAlternative;
}

bool webPlaybackShouldApplyPlayingUpdate({
  required bool loading,
  required bool playing,
}) {
  // Resetting an existing HTML video emits pause while the new source is still
  // loading. Preserve the autoplay intent until ready; a real autoplay denial
  // is reported after loading completes.
  return playing || !loading;
}

bool webPlaybackHasFirstFrame({required Duration position}) {
  // HTMLMediaElement.onPlay only confirms command acceptance. Advancing media
  // time is the portable signal that playback has produced content.
  return position > Duration.zero;
}

bool shouldPreserveLoadedPlaybackLine({
  required PlaybackLine? currentLine,
  required PlaybackLine? replacementLine,
  required String? loadedUrl,
  required Set<String> failedLineIds,
  required bool playbackFailed,
}) {
  if (currentLine == null ||
      !currentLine.available ||
      currentLine.url?.trim().isEmpty != false ||
      playbackFailed ||
      failedLineIds.contains(currentLine.id) ||
      loadedUrl?.trim() != currentLine.url?.trim()) {
    return false;
  }
  if (replacementLine == null || !replacementLine.available) return true;
  return replacementLine.url?.trim() != currentLine.url?.trim();
}

bool shouldExpandPlaybackLookupAfterQuickLines(Iterable<PlaybackLine> lines) {
  return playablePlaybackLinesInSourceOrder(lines).isEmpty;
}

PlaybackLineValidationDecision decidePlaybackLineAfterValidation({
  required PlaybackLine? currentLine,
  required String? loadedUrl,
  required Iterable<PlaybackLine> lines,
  required Set<String> failedLineIds,
  required bool playbackFailed,
  required bool autoplay,
}) {
  final available = playablePlaybackLinesInSourceOrder(lines);
  final currentFailed =
      playbackFailed ||
      (currentLine != null && failedLineIds.contains(currentLine.id));
  PlaybackLine? validatedCurrent;
  if (!currentFailed && currentLine != null) {
    for (final candidate in available) {
      if (candidate.id == currentLine.id) {
        validatedCurrent = candidate;
        break;
      }
    }
  }
  final currentLineRemoved =
      currentLine != null && !currentFailed && validatedCurrent == null;
  PlaybackLine? targetLine = validatedCurrent;
  if (currentFailed || targetLine == null) {
    targetLine = null;
    for (final candidate in available) {
      if (failedLineIds.contains(candidate.id)) continue;
      targetLine = candidate;
      break;
    }
  }

  final normalizedLoadedUrl = loadedUrl?.trim();
  final targetUrl = targetLine?.url?.trim();
  final currentMediaUpdated =
      !currentFailed &&
      currentLine != null &&
      targetLine != null &&
      targetLine.id == currentLine.id &&
      normalizedLoadedUrl != null &&
      normalizedLoadedUrl.isNotEmpty &&
      targetUrl != null &&
      targetUrl.isNotEmpty &&
      normalizedLoadedUrl != targetUrl;
  final shouldOpen =
      targetLine != null &&
      (currentLineRemoved ||
          currentMediaUpdated ||
          (autoplay &&
              (currentFailed ||
                  currentLine == null ||
                  !currentLine.available ||
                  (currentLine.url?.trim().isEmpty ?? true))));
  final shouldStop = currentLineRemoved && targetLine == null;
  if (shouldOpen) {
    return PlaybackLineValidationDecision(
      action: PlaybackLineValidationAction.open,
      targetLine: targetLine,
      selectedLine: currentLine,
    );
  }
  if (shouldStop) {
    return const PlaybackLineValidationDecision(
      action: PlaybackLineValidationAction.stop,
      targetLine: null,
      selectedLine: null,
    );
  }
  final targetMatchesLoadedMedia =
      normalizedLoadedUrl != null &&
      normalizedLoadedUrl.isNotEmpty &&
      normalizedLoadedUrl == targetUrl;
  return PlaybackLineValidationDecision(
    action: PlaybackLineValidationAction.keep,
    targetLine: targetLine,
    selectedLine: targetMatchesLoadedMedia ? targetLine : currentLine,
  );
}

List<PlaybackLine> sortPlaybackLinesForDisplay(Iterable<PlaybackLine> lines) {
  final indexed = lines.indexed.toList(growable: false);
  final sorted = [...indexed]
    ..sort((left, right) {
      final availability = _availabilityRank(
        left.$2,
      ).compareTo(_availabilityRank(right.$2));
      if (availability != 0) return availability;

      final leftLatency = left.$2.latency?.inMicroseconds;
      final rightLatency = right.$2.latency?.inMicroseconds;
      if (leftLatency == null && rightLatency != null) return 1;
      if (leftLatency != null && rightLatency == null) return -1;
      if (leftLatency != null && rightLatency != null) {
        final latency = leftLatency.compareTo(rightLatency);
        if (latency != 0) return latency;
      }
      return left.$1.compareTo(right.$1);
    });
  return List<PlaybackLine>.unmodifiable(sorted.map((item) => item.$2));
}

/// Quality chip text for the player chrome, or null when the source carries
/// no real information ("未知" placeholders never earn chrome space).
String? playbackQualityChipLabel(PlaybackLine? line) {
  if (line == null) return null;
  final quality = line.quality.trim();
  if (quality.isEmpty ||
      quality == '--' ||
      quality.toLowerCase() == 'unknown' ||
      quality.contains('未知')) {
    return null;
  }
  return quality;
}

/// Site/rule identities, not made-up aliases. Unlisted explicit rule names stay
/// intact so a new upstream rule never silently becomes an unrelated site.
const _playbackSourceNames = <String, String>{
  'xfdm': '稀饭动漫',
  'xfdmneo': '稀饭动漫',
  'xfdmnext': '稀饭动漫 Next',
  'xifan': '稀饭动漫',
  'xifan-dongman': '稀饭动漫',
  'xifan-dongman-next': '稀饭动漫 Next',
  'mxdm': 'MX动漫',
  'moonci': '月城动漫',
  'sorani': '青空次元',
  'lmm': '路漫漫',
  'girigirilove': 'GiriGiri爱动漫',
  'girigiri-ai-dongman': 'GiriGiri爱动漫',
  'haixing-dongman': '海星动漫',
  'jibi-dongman': '叽哔动漫',
  'dm-yhdm': '樱花动漫',
  'yinghua': '樱花动漫',
  'yinghua2': '樱花动漫',
  'dm-mxdm': 'MX动漫',
  'dm-cyfz': '次元方舟',
  'dm-ml': '米粒动漫',
  '2k-dongman': '2k动漫',
  'aafun': '风铃动漫',
  'aafun-dongman': '风铃动漫',
  'cyfz': '次元方舟',
  'mcy': '漫次元',
  'mitaodm': '蜜桃动漫',
  'ciyuancheng': '次元城动画',
  'baimao': '白毛动漫',
  'dalvdm': '打驴动漫',
  'eacg': 'E-ACG',
  'age': 'AGE动漫',
  'fantuan': '饭团动漫',
};

final _playbackAggregatorPrefix = RegExp(
  r'^(?:(?:crawler|zeluna)[.:])?(?:anich|kazumi|animeko)'
  r'(?:[\s·•:：/|\\_\-]+|$)',
  caseSensitive: false,
);
final _playbackServicePrefix = RegExp(
  r'^(?:在线服务|聚合服务|聚合器)(?:[\s·•:：/|\\_\-]+|$)',
);
final _playbackBracketedAggregator = RegExp(
  r'^[\[【(（]\s*(?:anich|kazumi|animeko)\s*[\]】)）]\s*',
  caseSensitive: false,
);
final _playbackNumberedRoute = RegExp(
  r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*-\d+(?:-\d+)*$',
  caseSensitive: false,
);

/// Removes transport/catalog labels without touching the actual site or route.
/// Also used for the optional secondary title so prefixes never leak back in.
String playbackLineTitleLabel(PlaybackLine line) =>
    _playbackSourceLabel(line.title);

String playbackLineProviderLabel(PlaybackLine line) {
  final provider = _playbackSourceLabel(line.providerName);
  final source = _playbackSourceLabel(line.sourceName);
  // An AniCh tag such as hb-10 or yhdm-cn-10 names a distinct real route.
  if (_playbackNumberedRoute.hasMatch(provider)) return provider;
  if (_playbackNumberedRoute.hasMatch(source)) return source;
  if (source.isNotEmpty) return source;
  if (provider.isNotEmpty) return provider;
  final resolverName = _playbackSourceLabel(
    line.clientResolver?.ruleName ?? '',
  );
  if (resolverName.isNotEmpty) return resolverName;
  return playbackProviderLabel(
    providerId: line.clientResolver?.ruleId ?? line.providerId,
    providerName: '',
  );
}

String playbackProviderLabel({
  required String providerId,
  required String providerName,
}) {
  final name = _playbackSourceLabel(providerName);
  if (name.isNotEmpty) return name;
  final id = _stripPlaybackAggregatorPrefix(providerId);
  final known = _knownPlaybackSourceName(id);
  if (known != null) return known;
  if (_playbackNumberedRoute.hasMatch(id)) return id;
  // Opaque provider namespaces/hashes are not a source name.
  return '线路';
}

String _stripPlaybackAggregatorPrefix(String value) {
  var result = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  while (result.isNotEmpty) {
    final stripped = result
        .replaceFirst(_playbackBracketedAggregator, '')
        .replaceFirst(_playbackServicePrefix, '')
        .replaceFirst(_playbackAggregatorPrefix, '')
        .trim();
    if (stripped == result) break;
    result = stripped;
  }
  return result;
}

String? _knownPlaybackSourceName(String value) {
  final key = value.trim().toLowerCase();
  final direct = _playbackSourceNames[key];
  if (direct != null) return direct;
  // Imported Animeko rules can have factory prefixes. Only map exact known ids;
  // never guess a site from a partial token such as hb or a media CDN hostname.
  final tail = key.split(':').last;
  return _playbackSourceNames[tail];
}

String _playbackSourceLabel(String value) {
  final name = _stripPlaybackAggregatorPrefix(value);
  if (name.isEmpty ||
      const {
        'unknown',
        '未知',
        '--',
        'null',
        'none',
      }.contains(name.toLowerCase())) {
    return '';
  }
  if (RegExp(r'^(?:rule|line):v\d+:', caseSensitive: false).hasMatch(name) ||
      RegExp(r'^[a-f0-9]{32,}$', caseSensitive: false).hasMatch(name)) {
    return '';
  }
  final known = _knownPlaybackSourceName(name);
  if (known != null) return known;
  final parts = name.split(RegExp(r'\s*[:：·]\s*'));
  if (parts.length > 1) {
    final knownSite = _knownPlaybackSourceName(parts.first);
    if (knownSite != null) {
      return '$knownSite · ${parts.skip(1).join(' · ')}';
    }
  }
  return name;
}

enum PlaybackLineLatencyBand { unknown, fast, moderate, slow }

PlaybackLineLatencyBand playbackLineLatencyBand(PlaybackLine line) {
  final latency = line.latency;
  if (latency == null || latency < Duration.zero) {
    return PlaybackLineLatencyBand.unknown;
  }
  if (latency <= const Duration(milliseconds: 500)) {
    return PlaybackLineLatencyBand.fast;
  }
  if (latency <= const Duration(milliseconds: 1500)) {
    return PlaybackLineLatencyBand.moderate;
  }
  return PlaybackLineLatencyBand.slow;
}

String playbackLineLatencyLabel(PlaybackLine line) {
  final latency = line.latency;
  if (latency != null && latency >= Duration.zero) {
    return '${latency.inMilliseconds}ms';
  }
  if (line.clientResolver != null ||
      line.diagnosticStatus == PlaybackDiscoveryStatus.clientResolverRequired) {
    return '本机解析中';
  }
  if (line.requiresClientProbe) return '检查中';
  if (line.serverVerified && !line.clientVerified) return '测速中';
  if (line.clientVerified) return '可用';
  return '速度未知';
}

/// A chapter resolver/page task is not a video URL, even if a malformed input
/// happens to fill in both fields. Do not offer that page as a media copy action.
String? playbackLineMediaUrl(PlaybackLine line) {
  if (line.clientResolver != null ||
      line.diagnosticStatus == PlaybackDiscoveryStatus.clientResolverRequired) {
    return null;
  }
  final value = line.url?.trim() ?? '';
  if (value.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) return null;
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'file' || scheme == 'content') return value;
  if ((scheme != 'https' && scheme != 'http') || uri.host.isEmpty) return null;
  if (RegExp(
    r'\.(?:html?|php|aspx?)(?:$|/)',
    caseSensitive: false,
  ).hasMatch(uri.path)) {
    return null;
  }
  return value;
}

String playbackLineFailureLabel(PlaybackLine line) {
  final diagnosticReason = switch (line.diagnosticStatus) {
    // These land in the line list's status column, so they say what the user
    // sees rather than naming the mechanism behind it: no 验线 (internal probe
    // slang), 已隔离 (quarantine), or 暂缓请求 (circuit breaker).
    PlaybackDiscoveryStatus.notQueried => '未检查',
    PlaybackDiscoveryStatus.sourceDisabled => '未启用',
    PlaybackDiscoveryStatus.candidateUnadmitted => '候选未接入',
    PlaybackDiscoveryStatus.compatibilityInactive => '旧接口未启用',
    PlaybackDiscoveryStatus.unsupportedContentType => '不支持此内容类型',
    PlaybackDiscoveryStatus.clientResolverRequired => '本机解析中',
    PlaybackDiscoveryStatus.searching => '搜索中',
    PlaybackDiscoveryStatus.searchTimeout => '搜索超时',
    PlaybackDiscoveryStatus.searchError => '来源异常',
    PlaybackDiscoveryStatus.searchMiss => '未找到匹配',
    PlaybackDiscoveryStatus.searchHitNoMatch => '不是这部作品',
    PlaybackDiscoveryStatus.matched => '正在测试',
    PlaybackDiscoveryStatus.matchedNoEpisode => '缺少本集',
    PlaybackDiscoveryStatus.circuitSuppressed => '暂时跳过',
    PlaybackDiscoveryStatus.routeUnavailable => '线路失败',
    PlaybackDiscoveryStatus.quarantined => '暂时停用',
    PlaybackDiscoveryStatus.retired => '已停用',
    _ => null,
  };
  if (diagnosticReason != null) {
    final latency = line.latency;
    return latency == null
        ? diagnosticReason
        : '$diagnosticReason · ${latency.inMilliseconds}ms';
  }
  final message = (line.message ?? '').toLowerCase();
  String reason;
  if (message.contains('403') || message.contains('拒绝')) {
    reason = '访问被拒绝';
  } else if (message.contains('404') || message.contains('失效')) {
    reason = '线路失效';
  } else if (message.contains('超时') || message.contains('timeout')) {
    reason = '连接超时';
  } else if (message.contains('分片') || message.contains('segment')) {
    reason = '视频加载失败';
  } else if (message.contains('清单') || message.contains('manifest')) {
    reason = '线路无效';
  } else if (message.contains('网页') || message.contains('媒体内容')) {
    reason = '不是视频';
  } else if (message.contains('验证码')) {
    reason = '需要验证';
  } else if (message.contains('执行器') || message.contains('不支持')) {
    reason = '当前不支持';
  } else if (message.contains('会员') || message.contains('vip')) {
    // Worth keeping distinct: the viewer can act on this one.
    reason = '需要站点会员';
  } else if (message.contains('地区') || message.contains('防盗链')) {
    reason = '来源限制访问';
  } else if (message.contains('未匹配') ||
      message.contains('没有找到') ||
      message.contains('没有匹配') ||
      message.contains('没找到')) {
    reason = '未找到匹配';
  } else if (message.contains('没有这一集') || message.contains('缺少本集')) {
    reason = '缺少本集';
  } else if (message.contains('无法访问') ||
      message.contains('连不上') ||
      message.contains('网络')) {
    reason = '网络异常';
  } else {
    reason = '暂时不可用';
  }
  final latency = line.latency;
  return latency == null ? reason : '$reason · ${latency.inMilliseconds}ms';
}

/// Curated explanations never display resolver payloads, URLs or private headers.
String playbackSourceStateExplanation(PlaybackLine line) {
  return switch (line.diagnosticStatus) {
    PlaybackDiscoveryStatus.notQueried => '尚未查询这部作品；未查询不等于没有资源。',
    PlaybackDiscoveryStatus.sourceDisabled => '此源当前未启用，本集没有发起查询。',
    PlaybackDiscoveryStatus.candidateUnadmitted => '该来源仅为候选，尚未接入查询；本集没有播放验证结果。',
    PlaybackDiscoveryStatus.compatibilityInactive => '旧兼容接口未启用，仅保留登记信息。',
    PlaybackDiscoveryStatus.quarantined => '此源原先已停用，本集未查询；不是本次播放失败。',
    PlaybackDiscoveryStatus.retired => '此源已停用，不会发起播放查询。',
    PlaybackDiscoveryStatus.unsupportedContentType => '此适配器不支持当前内容类型，本集未发起搜索。',
    PlaybackDiscoveryStatus.clientResolverRequired =>
      '已找到本集章节，正在本机解析播放器页面；尚未证明可播。',
    PlaybackDiscoveryStatus.searching => '正在搜索当前作品，暂未取得结果。',
    PlaybackDiscoveryStatus.searchTimeout => '本次搜索响应超时，不能据此认定源已永久失效。',
    PlaybackDiscoveryStatus.searchError => '本次搜索请求失败，未取得可靠的匹配结果。',
    PlaybackDiscoveryStatus.searchMiss => '已发起搜索，但当前作品的搜索词没有命中。',
    PlaybackDiscoveryStatus.searchHitNoMatch => '搜索有结果，但未匹配到当前作品；不会播放其他作品。',
    PlaybackDiscoveryStatus.matched => '已匹配作品，正在取得本集播放线路。',
    PlaybackDiscoveryStatus.matchedNoEpisode => '已匹配作品，但没有取得当前集的媒体候选。',
    PlaybackDiscoveryStatus.circuitSuppressed => '近期请求连续失败，当前暂时跳过；不代表永久失效。',
    PlaybackDiscoveryStatus.routeUnavailable => '已取得候选线路，但本次媒体验证未通过。',
    PlaybackDiscoveryStatus.clientProbeRequired => '已有媒体候选，仍需在客户端确认能否播放。',
    PlaybackDiscoveryStatus.serverVerified => '服务器已验证媒体响应，仍以播放器实际播放为准。',
    _ => '本集暂无可播放媒体，详细原因尚未确认。',
  };
}

String playbackLineMediaLabel(PlaybackLine line) {
  return [
    playbackLineSizeLabel(line),
    playbackLineResolutionLabel(line),
    playbackLineFormatLabel(line),
    if (line.bitrate != null && line.bitrate! > 0) _bitrateLabel(line.bitrate!),
    if ((line.codecs ?? '').trim().isNotEmpty) _codecLabel(line.codecs!),
  ].where((item) => item.isNotEmpty).join(' · ');
}

int _availabilityRank(PlaybackLine line) => line.available ? 0 : 1;

bool playbackLineHasKnownSize(PlaybackLine line) {
  if (line.isLive) return false;
  if (line.sizeBytes != null) return line.sizeBytes! > 0;
  return _validLegacySizeLabel(line.sizeLabel) != null;
}

/// Positive probe bytes take precedence; zero/negative bytes are unknown, not
/// proof of an empty video. Legacy size text is retained only when bytes are
/// absent and the text includes a positive, finite size with a real unit.
String playbackLineSizeLabel(PlaybackLine line) {
  if (line.isLive) return '直播';
  final bytes = line.sizeBytes;
  if (bytes != null) {
    if (bytes <= 0) return '大小未知';
    final megabytes = bytes / 1024 / 1024;
    final value = megabytes < 0.1 ? '<0.1' : megabytes.toStringAsFixed(1);
    return '${line.sizeEstimated ? '约 ' : ''}$value MB';
  }
  final legacy = _validLegacySizeLabel(line.sizeLabel);
  if (legacy == null) return '大小未知';
  return line.sizeEstimated && !legacy.contains('约') ? '约 $legacy' : legacy;
}

String? _validLegacySizeLabel(String? value) {
  final label = (value ?? '').trim();
  if (_unknownPlaybackMetadata(label)) return null;
  final match = RegExp(
    r'^(?:约\s*|~\s*)?(\d+(?:\.\d+)?)\s*(?:[kmgt]i?b|b|bytes?|字节)',
    caseSensitive: false,
  ).firstMatch(label);
  if (match == null) return null;
  final amount = double.tryParse(match.group(1)!);
  return amount != null && amount.isFinite && amount > 0 ? label : null;
}

bool playbackLineHasKnownResolution(PlaybackLine line) =>
    line.videoWidth != null &&
    line.videoWidth! > 0 &&
    line.videoHeight != null &&
    line.videoHeight! > 0;

String playbackLineResolutionLabel(PlaybackLine line) {
  final width = line.videoWidth;
  final height = line.videoHeight;
  if (width != null && width > 0 && height != null && height > 0) {
    return '$width×$height';
  }
  final quality = line.quality.trim();
  if (_unknownPlaybackMetadata(quality) ||
      RegExp(r'^0(?:[pPkK]|\s*[x×]\s*\d+)?$').hasMatch(quality)) {
    return '分辨率未知';
  }
  return '源标 $quality';
}

String playbackLineFormatLabel(PlaybackLine line) {
  final format = line.format.trim();
  return _unknownPlaybackMetadata(format) ? '格式未知' : format;
}

bool _unknownPlaybackMetadata(String value) {
  final lowered = value.trim().toLowerCase();
  return lowered.isEmpty ||
      lowered.contains('未知') ||
      lowered.contains('unknown') ||
      const {
        '--',
        '-',
        'n/a',
        'na',
        'null',
        'none',
        'nan',
        'infinity',
        'auto',
        '自动',
        'default',
      }.contains(lowered);
}

String _bitrateLabel(int bitsPerSecond) {
  if (bitsPerSecond >= 1000 * 1000) {
    return '${(bitsPerSecond / 1000 / 1000).toStringAsFixed(1)} Mbps';
  }
  return '${(bitsPerSecond / 1000).toStringAsFixed(0)} Kbps';
}

String _codecLabel(String codecs) {
  final values = codecs
      .split(',')
      .map((item) => item.trim().toLowerCase())
      .where((item) => item.isNotEmpty)
      .map((item) {
        if (item.startsWith('avc1') || item.startsWith('avc3')) return 'H.264';
        if (item.startsWith('hev1') || item.startsWith('hvc1')) return 'H.265';
        if (item.startsWith('av01')) return 'AV1';
        if (item.startsWith('vp09') || item.startsWith('vp9')) return 'VP9';
        if (item.startsWith('mp4a')) return 'AAC';
        if (item.startsWith('opus')) return 'Opus';
        return item.toUpperCase();
      })
      .toSet()
      .toList(growable: false);
  return values.join('/');
}
