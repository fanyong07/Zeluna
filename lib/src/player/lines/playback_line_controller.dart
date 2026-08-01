import '../../domain/anime_models.dart';
import '../playback_line_display.dart';

/// Owns mutable line-selection state and all asynchronous lookup handles.
final class PlaybackLineController {
  final Set<String> failedLineIds = <String>{};
  final Map<String, int> failureCounts = <String, int>{};
  String? preferredProviderId;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void clearFailures() {
    failedLineIds.clear();
    failureCounts.clear();
  }

  void clearFailure(String lineId) {
    failedLineIds.remove(lineId);
    failureCounts.remove(lineId);
  }

  bool markFailure(PlaybackLine line, {bool definitive = false}) {
    final count = nextPlaybackLineFailureCount(
      failureCounts[line.id] ?? 0,
      definitive: definitive,
    );
    failureCounts[line.id] = count;
    final shouldRetry = shouldRetryPlaybackLineAfterFailure(count);
    if (!shouldRetry) {
      failedLineIds.add(line.id);
    }
    return !shouldRetry;
  }

  PlaybackLine? preferredPlayableLine(List<PlaybackLine> lines) {
    if (lines.isEmpty) return null;
    final preferred = preferredProviderId;
    if (preferred != null) {
      for (final line in lines) {
        if (line.providerId == preferred && !failedLineIds.contains(line.id)) {
          return line;
        }
      }
    }
    for (final line in lines) {
      if (!failedLineIds.contains(line.id)) return line;
    }
    return null;
  }

  PlaybackLine? nextPlayableLine({
    required PlaybackLine? currentLine,
    required List<PlaybackLine> lines,
  }) {
    final currentId = currentLine?.id;
    for (final line in playablePlaybackLinesInSourceOrder(lines)) {
      if (line.id == currentId || failedLineIds.contains(line.id)) continue;
      return line;
    }
    return null;
  }

  List<PlaybackLine> preserveLoadedLineIfProbeDisagrees({
    required List<PlaybackLine> lines,
    required PlaybackLine? currentLine,
    required String? loadedUrl,
    required bool playbackFailed,
  }) {
    if (currentLine == null) return lines;
    PlaybackLine? replacement;
    for (final line in lines) {
      if (line.id == currentLine.id) {
        replacement = line;
        break;
      }
    }
    if (!shouldPreserveLoadedPlaybackLine(
      currentLine: currentLine,
      replacementLine: replacement,
      loadedUrl: loadedUrl,
      failedLineIds: failedLineIds,
      playbackFailed: playbackFailed,
    )) {
      return lines;
    }
    return <String, PlaybackLine>{
      for (final line in lines) line.id: line,
      currentLine.id: currentLine,
    }.values.toList(growable: false);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clearFailures();
  }
}
