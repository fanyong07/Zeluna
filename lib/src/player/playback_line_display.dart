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
  if (line.serverVerified || line.clientVerified) return true;
  final rawUrl = line.url?.trim() ?? '';
  return Uri.tryParse(rawUrl)?.scheme.toLowerCase() == 'file';
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
    if (line.queried == true ||
        _diagnosticStatusWasQueried(status) ||
        legacyResolved) {
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
  final sourceName = line.sourceName.trim().toLowerCase();
  final providerId = line.providerId.trim().toLowerCase();
  if (sourceName.isNotEmpty) return '$providerId|$sourceName';
  if (providerId.isNotEmpty) return providerId;
  return '${line.providerName.trim().toLowerCase()}|${line.id}';
}

bool _diagnosticStatusWasQueried(String status) {
  return status.isNotEmpty &&
      status != PlaybackDiscoveryStatus.notQueried &&
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
  final cards = <String, PlaybackLine>{};
  for (final line in lines) {
    final key = _playbackSourceCardIdentityKey(line);
    final previous = cards[key];
    if (previous == null ||
        _playbackSourceCardPriority(line, selectedLineId: selectedLineId) >
            _playbackSourceCardPriority(
              previous,
              selectedLineId: selectedLineId,
            )) {
      cards[key] = line;
    }
  }
  return List<PlaybackLine>.unmodifiable(cards.values);
}

String _playbackSourceCardIdentityKey(PlaybackLine line) {
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
}) {
  // media_kit may publish playing=true as soon as the play command is accepted,
  // before a frame has decoded. Position progress is the startup signal.
  return position > Duration.zero;
}

bool nativePlaybackReachedFirstFrame({
  required Duration previousPosition,
  required Duration currentPosition,
}) {
  return previousPosition <= Duration.zero && currentPosition > Duration.zero;
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

/// Curated alias pool for playback lines whose provider name is an internal
/// rule id. Names stay stable per provider because the pick is a pure hash.
const playbackProviderAliasPool = <String>[
  '晨风',
  '疏影',
  '栖云',
  '观澜',
  '听雨',
  '春汀',
  '月泉',
  '松声',
  '竹里',
  '澄江',
  '空山',
  '白露',
  '青崖',
  '半夏',
  '临溪',
  '望舒',
  '拂晓',
  '汀兰',
  '折柳',
  '灯前',
];

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

/// A user-facing name for the line's provider. Internal rule ids such as
/// `xfdmneo` never reach the UI; they map to a stable friendly alias instead.
String playbackLineProviderLabel(PlaybackLine line) {
  return playbackProviderLabel(
    providerId: line.providerId,
    providerName: line.providerName,
  );
}

String playbackProviderLabel({
  required String providerId,
  required String providerName,
}) {
  final name = providerName.trim();
  if (name.isNotEmpty && !_looksLikeInternalProviderId(name)) return name;
  final key = providerId.trim().isNotEmpty ? providerId.trim() : name;
  if (key.isEmpty) return '线路';
  final alias =
      playbackProviderAliasPool[_stableHash(key.toLowerCase()) %
          playbackProviderAliasPool.length];
  return '$alias线路';
}

/// Internal ids read as lowercase ascii tokens ("xfdmneo", "custom:abc-1").
/// Anything with CJK, uppercase letters or spaces is treated as a real name.
bool _looksLikeInternalProviderId(String value) {
  return RegExp(r'^[a-z0-9]+([-_.:][a-z0-9]+)*$').hasMatch(value);
}

int _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

String playbackLineLatencyLabel(PlaybackLine line) {
  final latency = line.latency;
  if (latency != null) return '${latency.inMilliseconds}ms';
  if (line.requiresClientProbe) return '检查中';
  if (line.serverVerified && !line.clientVerified) return '测速中';
  if (line.clientVerified) return '可用';
  return '速度未知';
}

String playbackLineFailureLabel(PlaybackLine line) {
  final diagnosticReason = switch (line.diagnosticStatus) {
    // These land in the line list's status column, so they say what the user
    // sees rather than naming the mechanism behind it: no 验线 (internal probe
    // slang), 已隔离 (quarantine), or 暂缓请求 (circuit breaker).
    PlaybackDiscoveryStatus.notQueried => '未检查',
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

String playbackLineMediaLabel(PlaybackLine line) {
  return [
    _sizeLabel(line),
    _resolutionLabel(line),
    _formatLabel(line),
    if (line.bitrate != null && line.bitrate! > 0) _bitrateLabel(line.bitrate!),
    if ((line.codecs ?? '').trim().isNotEmpty) _codecLabel(line.codecs!),
  ].where((item) => item.isNotEmpty).join(' · ');
}

int _availabilityRank(PlaybackLine line) => line.available ? 0 : 1;

String _sizeLabel(PlaybackLine line) {
  // 动态流 came from the HLS "no ENDLIST" / DASH dynamic-manifest check; what
  // that actually means to a viewer is simply that it is live.
  if (line.isLive) return '直播';
  final bytes = line.sizeBytes;
  if (bytes != null && bytes > 0) {
    final value = (bytes / 1024 / 1024).toStringAsFixed(1);
    return '${line.sizeEstimated ? '约 ' : ''}$value MB';
  }
  final legacy = (line.sizeLabel ?? '').trim();
  if (legacy.isEmpty || legacy == '--') return '大小未知';
  return legacy;
}

String _resolutionLabel(PlaybackLine line) {
  final width = line.videoWidth;
  final height = line.videoHeight;
  if (width != null && width > 0 && height != null && height > 0) {
    return '${line.adaptive ? '最高 ' : ''}$width×$height';
  }
  final quality = line.quality.trim();
  if (quality.isEmpty ||
      quality == '--' ||
      quality.toLowerCase() == 'unknown') {
    return '分辨率未知';
  }
  return quality;
}

String _formatLabel(PlaybackLine line) {
  final format = line.format.trim();
  return format.isEmpty ? '格式未知' : format;
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
