import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import '../../domain/anime_models.dart';

enum SubtitleActionStatus { applied, unavailable, failed, stale }

@immutable
final class SubtitleActionResult {
  const SubtitleActionResult._(this.status, {this.message, this.error});

  const SubtitleActionResult.applied() : this._(SubtitleActionStatus.applied);
  const SubtitleActionResult.unavailable(String message)
    : this._(SubtitleActionStatus.unavailable, message: message);
  const SubtitleActionResult.failed(Object error)
    : this._(SubtitleActionStatus.failed, error: error);
  const SubtitleActionResult.stale() : this._(SubtitleActionStatus.stale);

  final SubtitleActionStatus status;
  final String? message;
  final Object? error;
}

typedef SubtitleTrackApplier = Future<void> Function(SubtitleTrack track);

/// Owns external subtitle selection and guards asynchronous player callbacks
/// from publishing state after a newer action, episode change or disposal.
final class SubtitleController extends ChangeNotifier {
  SubtitleController({required SubtitleTrackApplier applyTrack})
    : _applyTrack = applyTrack;

  final SubtitleTrackApplier _applyTrack;
  SubtitleCandidate? _selected;
  int _actionSerial = 0;
  bool _disposed = false;

  SubtitleCandidate? get selected => _selected;
  bool get isDisposed => _disposed;

  Future<SubtitleActionResult> select(SubtitleCandidate candidate) async {
    final url = candidate.downloadUrl?.trim() ?? '';
    if (!candidate.available || url.isEmpty) {
      return SubtitleActionResult.unavailable(candidate.message ?? '该字幕暂不可用');
    }
    if (_disposed) return const SubtitleActionResult.stale();
    final serial = ++_actionSerial;

    try {
      await _applyTrack(
        SubtitleTrack.uri(
          url,
          title: candidate.title,
          language: candidate.language,
        ),
      );
      if (!_acceptsAction(serial)) return const SubtitleActionResult.stale();
      _selected = candidate;
      notifyListeners();
      return const SubtitleActionResult.applied();
    } catch (error) {
      if (!_acceptsAction(serial)) return const SubtitleActionResult.stale();
      return SubtitleActionResult.failed(error);
    }
  }

  Future<SubtitleActionResult> disable() async {
    if (_disposed) return const SubtitleActionResult.stale();
    final serial = ++_actionSerial;
    try {
      await _applyTrack(SubtitleTrack.no());
      if (!_acceptsAction(serial)) return const SubtitleActionResult.stale();
      _selected = null;
      notifyListeners();
      return const SubtitleActionResult.applied();
    } catch (error) {
      if (!_acceptsAction(serial)) return const SubtitleActionResult.stale();
      return SubtitleActionResult.failed(error);
    }
  }

  void invalidatePendingAction() {
    if (_disposed) return;
    _actionSerial++;
  }

  bool _acceptsAction(int serial) {
    return !_disposed && serial == _actionSerial;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _actionSerial++;
    super.dispose();
  }
}
