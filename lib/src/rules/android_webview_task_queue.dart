import 'dart:async';
import 'dart:collection';

import 'rule_playback_cancellation.dart';

/// One Android WebView owns the process-wide cookie/storage APIs at a time.
/// Waiting work is bounded and its deadline includes time spent in the queue.
/// An active lease is held until native teardown finishes, even after cancellation.
final class AndroidWebViewTaskQueue {
  AndroidWebViewTaskQueue({this.maxWaiting = 8}) : assert(maxWaiting >= 0);

  final int maxWaiting;
  final Queue<_WaitingTask> _waiting = Queue<_WaitingTask>();
  AndroidWebViewTaskLease? _active;
  bool _quarantined = false;

  /// A failed native create/dispose acknowledgement leaves ownership uncertain.
  /// Fail closed until process restart rather than accumulating hidden WebViews.
  void quarantine() {
    if (_quarantined) return;
    _quarantined = true;
    _active?.cancellation.cancel();
    while (_waiting.isNotEmpty) {
      final task = _waiting.removeFirst();
      task.finishWaiting();
      task.result.complete(null);
    }
  }

  Future<AndroidWebViewTaskLease?> acquire({
    required Duration timeout,
    RulePlaybackCancellationToken? cancellationToken,
  }) {
    if (_quarantined ||
        timeout <= Duration.zero ||
        cancellationToken?.isCancelled == true ||
        (_active != null && _waiting.length >= maxWaiting)) {
      return Future.value(null);
    }
    final task = _WaitingTask();
    void cancel() {
      final lease = task.lease;
      if (lease != null) {
        lease.cancellation.cancel();
      } else {
        _waiting.remove(task);
        task.finishWaiting();
        if (!task.result.isCompleted) task.result.complete(null);
      }
    }

    task.timer = Timer(timeout, cancel);
    task.unlink = cancellationToken?.register(cancel);
    _waiting.add(task);
    _dispatch();
    return task.result.future;
  }

  void _dispatch() {
    if (_quarantined || _active != null || _waiting.isEmpty) return;
    final task = _waiting.removeFirst();
    final lease = AndroidWebViewTaskLease._(() {
      task.finishWaiting();
      _active = null;
      _dispatch();
    });
    task.lease = lease;
    _active = lease;
    task.result.complete(lease);
  }
}

final class AndroidWebViewTaskLease {
  AndroidWebViewTaskLease._(this._release);

  final RulePlaybackCancellationToken cancellation =
      RulePlaybackCancellationToken();
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    cancellation.cancel();
    _release();
  }
}

final class _WaitingTask {
  final result = Completer<AndroidWebViewTaskLease?>();
  AndroidWebViewTaskLease? lease;
  Timer? timer;
  void Function()? unlink;

  void finishWaiting() {
    timer?.cancel();
    unlink?.call();
    unlink = null;
  }
}
