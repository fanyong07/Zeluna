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

List<PlaybackLine> playablePlaybackLinesInSourceOrder(
  Iterable<PlaybackLine> lines,
) {
  return List<PlaybackLine>.unmodifiable(
    lines.where(
      (line) => line.available && (line.url?.trim().isNotEmpty ?? false),
    ),
  );
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
