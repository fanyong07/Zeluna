/// Cancellation shared by rule lookup, prefetch and source probing.
/// Callbacks are best-effort and run at most once; registration returns an
/// unregister function so completed requests do not remain retained.
class RulePlaybackCancellationToken {
  final Set<void Function()> _callbacks = <void Function()>{};
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = _callbacks.toList(growable: false);
    _callbacks.clear();
    for (final callback in callbacks) {
      try {
        callback();
      } catch (_) {
        // Cancellation is best-effort; one client must not prevent the rest
        // of the lookup session from being stopped.
      }
    }
  }

  void Function() register(void Function() callback) {
    if (_cancelled) {
      try {
        callback();
      } catch (_) {
        // Already cancelled: registering work must not revive or fail it.
      }
      return () {};
    }
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }
}
