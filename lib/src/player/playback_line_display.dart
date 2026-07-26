import '../domain/anime_models.dart';

enum PlaybackLineValidationAction { keep, open, stop }

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
  final rawUrl = line.url?.trim() ?? '';
  final uri = Uri.tryParse(rawUrl);
  return uri?.scheme.toLowerCase() != 'file';
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

List<PlaybackLine> mergePlaybackLineSnapshot({
  required Iterable<PlaybackLine> currentLines,
  required Iterable<PlaybackLine> snapshotLines,
  String? replacedProviderId,
  bool authoritative = false,
}) {
  final snapshot = snapshotLines.toList(growable: false);
  if (authoritative) return List<PlaybackLine>.unmodifiable(snapshot);

  final merged = <String, PlaybackLine>{
    for (final line in currentLines)
      if (replacedProviderId == null || line.providerId != replacedProviderId)
        line.id: line,
    for (final line in snapshot) line.id: line,
  };
  return List<PlaybackLine>.unmodifiable(merged.values);
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
  required bool hasAlternative,
}) {
  // A slow HLS stream may need more than seven seconds for its first segment.
  // Only abandon it early when another playable line is already available.
  return position <= Duration.zero && hasAlternative;
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
  return latency == null ? '延迟未知' : '${latency.inMilliseconds}ms';
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
  if (line.isLive) return '动态流';
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
