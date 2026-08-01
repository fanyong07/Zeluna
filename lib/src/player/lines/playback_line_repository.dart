import 'dart:async';

import '../../data/playback_source_repository.dart';
import '../../domain/anime_models.dart';
import '../../rules/rule_playback_resolver.dart';
import '../playback_line_display.dart';

typedef QuickPlaybackLineLoader =
    Future<List<PlaybackLine>> Function(
      AnimeSubject subject,
      AnimeEpisode episode,
      RulePlaybackCancellationToken cancellationToken,
    );

typedef PlaybackLineVerifier =
    Future<PlaybackLine> Function(
      PlaybackLine line,
      RulePlaybackCancellationToken cancellationToken,
    );

typedef ExpandedPlaybackLineLoader =
    Stream<PlaybackLineLookupUpdate> Function(
      AnimeSubject subject,
      AnimeEpisode episode,
      RulePlaybackCancellationToken cancellationToken,
    );

typedef BackupPlaybackLineLoader =
    Future<List<PlaybackLine>> Function(
      AnimeSubject subject,
      AnimeEpisode episode,
      PlaybackLine currentLine,
      RulePlaybackCancellationToken cancellationToken,
    );

typedef PreserveLoadedPlaybackLine =
    List<PlaybackLine> Function(List<PlaybackLine> lines);

final class PlaybackLineInventory {
  const PlaybackLineInventory({
    required this.lines,
    required this.playableLines,
  });

  final List<PlaybackLine> lines;
  final List<PlaybackLine> playableLines;
}

final class PlaybackLineInventoryUpdate {
  const PlaybackLineInventoryUpdate({
    required this.source,
    required this.inventory,
  });

  final PlaybackLineLookupUpdate source;
  final PlaybackLineInventory inventory;
}

/// Owns playback-line discovery work and the resulting line inventory.
///
/// Selection and recovery policy intentionally remain in their dedicated
/// controllers. This repository owns request serials, cancellation tokens and
/// the progressive lookup subscription so stale work cannot update the page.
final class PlaybackLineRepository {
  PlaybackLineRepository({
    required QuickPlaybackLineLoader loadQuickLines,
    required PlaybackLineVerifier verifyLine,
    required ExpandedPlaybackLineLoader loadExpandedLines,
    required BackupPlaybackLineLoader loadSingleBackup,
    required int initialEpisodeId,
    Iterable<PlaybackLine> initialLines = const <PlaybackLine>[],
    bool lookupInProgress = false,
  }) : _loadQuickLines = loadQuickLines,
       _verifyLine = verifyLine,
       _loadExpandedLines = loadExpandedLines,
       _loadSingleBackup = loadSingleBackup,
       _lines = List<PlaybackLine>.unmodifiable(initialLines),
       _activeEpisodeId = initialEpisodeId,
       _lookupInProgress = lookupInProgress;

  final QuickPlaybackLineLoader _loadQuickLines;
  final PlaybackLineVerifier _verifyLine;
  final ExpandedPlaybackLineLoader _loadExpandedLines;
  final BackupPlaybackLineLoader _loadSingleBackup;

  List<PlaybackLine> _lines;
  int? _activeEpisodeId;
  StreamSubscription<PlaybackLineLookupUpdate>? _lookupSubscription;
  RulePlaybackCancellationToken? _lookupCancellationToken;
  RulePlaybackCancellationToken? _backupCancellationToken;
  var _lookupSerial = 0;
  var _backupSerial = 0;
  var _lookupInProgress = false;
  var _scanInProgress = false;
  var _scanComplete = false;
  var _scanCompletedRules = 0;
  var _scanTotalRules = 0;
  var _backupInProgress = false;
  var _disposed = false;

  List<PlaybackLine> get lines => _lines;
  bool get lookupInProgress => _lookupInProgress;
  bool get scanInProgress => _scanInProgress;
  bool get scanComplete => _scanComplete;
  int get scanCompletedRules => _scanCompletedRules;
  int get scanTotalRules => _scanTotalRules;
  bool get backupInProgress => _backupInProgress;
  bool get hasExpandedLookup => _lookupSubscription != null;
  bool get isDisposed => _disposed;
  RulePlaybackCancellationToken? get activeCancellationToken =>
      _lookupCancellationToken;

  void replaceLines(Iterable<PlaybackLine> lines) {
    if (_disposed) return;
    _lines = List<PlaybackLine>.unmodifiable(lines);
  }

  void resetForEpisode({
    required int episodeId,
    Iterable<PlaybackLine> initialLines = const <PlaybackLine>[],
    required bool lookupInProgress,
  }) {
    if (_disposed) return;
    _activeEpisodeId = episodeId;
    replaceLines(initialLines);
    _lookupInProgress = lookupInProgress;
    _scanInProgress = false;
    _scanComplete = false;
    _scanCompletedRules = 0;
    _scanTotalRules = 0;
  }

  Future<PlaybackLineInventory?> lookupQuick({
    required AnimeSubject subject,
    required AnimeEpisode episode,
    required bool progressive,
  }) async {
    if (_disposed) return null;
    final serial = ++_lookupSerial;
    final episodeId = episode.id;
    _activeEpisodeId = episodeId;
    cancelSingleBackupLookup();
    _lookupCancellationToken?.cancel();
    final previousSubscription = _lookupSubscription;
    _lookupSubscription = null;
    final token = RulePlaybackCancellationToken();
    _lookupCancellationToken = token;
    _lookupInProgress = true;
    _scanInProgress = false;
    _scanComplete = !progressive;
    _scanCompletedRules = 0;
    _scanTotalRules = 0;

    if (previousSubscription != null) await previousSubscription.cancel();
    if (!_isCurrentLookup(serial, episodeId, token)) return null;

    try {
      final discovered = await _loadQuickLines(subject, episode, token);
      if (!_isCurrentLookup(serial, episodeId, token)) return null;
      final verified = await verifyPlaybackLinesBeforeDisplay(
        discovered,
        verify: (line) => _verifyLine(line, token),
      );
      if (!_isCurrentLookup(serial, episodeId, token)) return null;
      replaceLines(verified);
      final inventory = _inventory();
      _lookupInProgress = inventory.playableLines.isEmpty && progressive;
      return inventory;
    } catch (_) {
      if (!_isCurrentLookup(serial, episodeId, token)) return null;
      replaceLines(const <PlaybackLine>[]);
      _lookupInProgress = false;
      rethrow;
    }
  }

  bool startExpandedLookup({
    required AnimeSubject subject,
    required AnimeEpisode episode,
    required bool hasActivePlayableLine,
    required PreserveLoadedPlaybackLine preserveLoadedLine,
    required void Function(PlaybackLineInventoryUpdate update) onUpdate,
    required void Function(Object error, StackTrace stackTrace) onError,
    required void Function() onDone,
  }) {
    if (_disposed ||
        _scanComplete ||
        _scanInProgress ||
        _lookupSubscription != null) {
      return false;
    }
    cancelSingleBackupLookup();
    final serial = _lookupSerial;
    final episodeId = episode.id;
    final token = _lookupCancellationToken ??= RulePlaybackCancellationToken();
    if (token.isCancelled) return false;
    _scanInProgress = true;
    _scanCompletedRules = 0;
    _scanTotalRules = 0;
    if (!hasActivePlayableLine) _lookupInProgress = true;

    late final StreamSubscription<PlaybackLineLookupUpdate> subscription;
    subscription = _loadExpandedLines(subject, episode, token).listen(
      (update) {
        if (!_isCurrentExpandedLookup(serial, episodeId, token)) {
          return;
        }
        var merged = mergePlaybackLineSnapshot(
          currentLines: _lines,
          snapshotLines: update.lines,
          replacedProviderId:
              update.phase == PlaybackLineLookupPhase.verification
              ? update.resolvedProviderId
              : null,
          authoritative: update.isComplete,
        );
        merged = preserveLoadedLine(merged);
        replaceLines(merged);
        final inventory = _inventory();
        _scanInProgress = !update.isComplete;
        _scanComplete = update.isComplete;
        _scanCompletedRules = update.completedRules;
        _scanTotalRules = update.totalRules;
        _lookupInProgress =
            inventory.playableLines.isEmpty && !update.isComplete;
        onUpdate(
          PlaybackLineInventoryUpdate(source: update, inventory: inventory),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_isCurrentExpandedLookup(serial, episodeId, token)) {
          return;
        }
        _scanInProgress = false;
        _lookupInProgress = false;
        onError(error, stackTrace);
      },
      onDone: () {
        if (identical(_lookupSubscription, subscription)) {
          _lookupSubscription = null;
        }
        if (!_isCurrentExpandedLookup(serial, episodeId, token)) {
          return;
        }
        _scanInProgress = false;
        _scanComplete = true;
        _lookupInProgress = false;
        onDone();
      },
    );
    _lookupSubscription = subscription;
    return true;
  }

  Future<PlaybackLineInventory?> prepareSingleBackup({
    required AnimeSubject subject,
    required AnimeEpisode episode,
    required PlaybackLine currentLine,
    required PreserveLoadedPlaybackLine preserveLoadedLine,
  }) async {
    if (_disposed || _backupInProgress) return null;
    final serial = ++_backupSerial;
    final episodeId = episode.id;
    final token = RulePlaybackCancellationToken();
    _backupCancellationToken?.cancel();
    _backupCancellationToken = token;
    _backupInProgress = true;
    try {
      final snapshot = await _loadSingleBackup(
        subject,
        episode,
        currentLine,
        token,
      );
      if (!_isCurrentBackup(serial, episodeId, token) || snapshot.isEmpty) {
        return null;
      }
      var merged = mergePlaybackLineSnapshot(
        currentLines: _lines,
        snapshotLines: snapshot,
      );
      merged = preserveLoadedLine(merged);
      replaceLines(merged);
      return _inventory();
    } catch (_) {
      // Preparing a backup is best-effort and must not disturb current media.
      return null;
    } finally {
      if (serial == _backupSerial) {
        _backupInProgress = false;
        if (identical(_backupCancellationToken, token)) {
          _backupCancellationToken = null;
        }
      }
    }
  }

  void cancelSingleBackupLookup() {
    _backupSerial++;
    _backupCancellationToken?.cancel();
    _backupCancellationToken = null;
    _backupInProgress = false;
  }

  Future<void> cancelLookup() async {
    _lookupSerial++;
    _lookupCancellationToken?.cancel();
    _lookupCancellationToken = null;
    final subscription = _lookupSubscription;
    _lookupSubscription = null;
    _lookupInProgress = false;
    _scanInProgress = false;
    if (subscription != null) await subscription.cancel();
  }

  PlaybackLineInventory _inventory() {
    return PlaybackLineInventory(
      lines: _lines,
      playableLines: playablePlaybackLinesInSourceOrder(_lines),
    );
  }

  bool _isCurrentLookup(
    int serial,
    int episodeId,
    RulePlaybackCancellationToken token,
  ) {
    return !_disposed &&
        serial == _lookupSerial &&
        _activeEpisodeId == episodeId &&
        identical(_lookupCancellationToken, token) &&
        !token.isCancelled;
  }

  bool _isCurrentExpandedLookup(
    int serial,
    int episodeId,
    RulePlaybackCancellationToken token,
  ) {
    return _isCurrentLookup(serial, episodeId, token);
  }

  bool _isCurrentBackup(
    int serial,
    int episodeId,
    RulePlaybackCancellationToken token,
  ) {
    return !_disposed &&
        serial == _backupSerial &&
        _activeEpisodeId == episodeId &&
        identical(_backupCancellationToken, token) &&
        !token.isCancelled;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lookupSerial++;
    _backupSerial++;
    _lookupCancellationToken?.cancel();
    _lookupCancellationToken = null;
    _backupCancellationToken?.cancel();
    _backupCancellationToken = null;
    final subscription = _lookupSubscription;
    _lookupSubscription = null;
    _lookupInProgress = false;
    _scanInProgress = false;
    _backupInProgress = false;
    if (subscription != null) await subscription.cancel();
  }
}
