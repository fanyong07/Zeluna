import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/anime_models.dart';

enum LocalDanmakuSendResult { accepted, empty, disabled, blocked }

@immutable
final class LocalDanmakuEntry {
  const LocalDanmakuEntry({required this.id, required this.text});

  final int id;
  final String text;
}

/// Owns danmaku input, asynchronous episode loading and transient local
/// comment timers for one playback page.
final class DanmakuController extends ChangeNotifier {
  DanmakuController({
    Duration localCommentLifetime = const Duration(seconds: 9),
    DateTime Function()? now,
  }) : _localCommentLifetime = localCommentLifetime,
       _now = now ?? DateTime.now;

  final Duration _localCommentLifetime;
  final DateTime Function() _now;
  final TextEditingController input = TextEditingController();
  final List<LocalDanmakuEntry> _localComments = [];
  final Set<Timer> _localCommentTimers = {};

  List<DanmakuComment> _remoteComments = const [];
  int _loadSerial = 0;
  int? _requestedEpisodeId;
  int _lastLocalCommentId = 0;
  bool _disposed = false;

  List<LocalDanmakuEntry> get localComments =>
      List<LocalDanmakuEntry>.unmodifiable(_localComments);
  List<DanmakuComment> get remoteComments => _remoteComments;
  int? get requestedEpisodeId => _requestedEpisodeId;
  bool get isDisposed => _disposed;

  void changeEpisode() {
    if (_disposed) return;
    _loadSerial++;
    _requestedEpisodeId = null;
    if (_remoteComments.isEmpty) return;
    _remoteComments = const [];
    notifyListeners();
  }

  Future<void> loadEpisode({
    required int episodeId,
    required Future<DanmakuTimeline> Function() load,
  }) async {
    if (_disposed || _requestedEpisodeId == episodeId) return;
    _requestedEpisodeId = episodeId;
    final serial = ++_loadSerial;

    try {
      final timeline = await load();
      if (!_acceptsLoadResult(serial, episodeId)) return;
      _remoteComments = List<DanmakuComment>.unmodifiable(timeline.comments);
      notifyListeners();
    } catch (_) {
      if (!_acceptsLoadResult(serial, episodeId)) return;
      _requestedEpisodeId = null;
      _remoteComments = const [];
      notifyListeners();
    }
  }

  LocalDanmakuSendResult sendLocal(
    String text, {
    required DanmakuSettings settings,
  }) {
    if (_disposed) return LocalDanmakuSendResult.empty;
    final value = text.trim();
    if (value.isEmpty) return LocalDanmakuSendResult.empty;
    if (!settings.enabled) return LocalDanmakuSendResult.disabled;
    if (settings.blockKeywords.any(value.contains)) {
      return LocalDanmakuSendResult.blocked;
    }

    final timestamp = _now().microsecondsSinceEpoch;
    final id = timestamp > _lastLocalCommentId
        ? timestamp
        : _lastLocalCommentId + 1;
    _lastLocalCommentId = id;
    final entry = LocalDanmakuEntry(id: id, text: value);
    _localComments.add(entry);
    input.clear();
    notifyListeners();

    late final Timer timer;
    timer = Timer(_localCommentLifetime, () {
      _localCommentTimers.remove(timer);
      if (_disposed) return;
      _localComments.removeWhere((item) => item.id == entry.id);
      notifyListeners();
    });
    _localCommentTimers.add(timer);
    return LocalDanmakuSendResult.accepted;
  }

  void addRemoteComment(DanmakuComment comment) {
    if (_disposed) return;
    final next =
        _remoteComments.where((item) => item.id != comment.id).followedBy([
          comment,
        ]).toList()..sort((left, right) {
          final byTime = left.time.compareTo(right.time);
          return byTime != 0 ? byTime : left.id.compareTo(right.id);
        });
    _remoteComments = List.unmodifiable(next);
    notifyListeners();
  }

  void removeRemoteComment(String id) {
    if (_disposed || !_remoteComments.any((item) => item.id == id)) return;
    _remoteComments = List.unmodifiable(
      _remoteComments.where((item) => item.id != id),
    );
    notifyListeners();
  }

  bool _acceptsLoadResult(int serial, int episodeId) {
    return !_disposed &&
        serial == _loadSerial &&
        episodeId == _requestedEpisodeId;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadSerial++;
    _requestedEpisodeId = null;
    for (final timer in _localCommentTimers) {
      timer.cancel();
    }
    _localCommentTimers.clear();
    input.dispose();
    super.dispose();
  }
}
