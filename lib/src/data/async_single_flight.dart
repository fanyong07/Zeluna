import 'dart:async';

/// Shares one in-flight asynchronous operation between callers with the same
/// key. Completed operations are never cached.
class AsyncSingleFlight<K, V> {
  final Map<K, Future<V>> _pending = <K, Future<V>>{};

  Future<V> run(K key, Future<V> Function() operation) {
    final existing = _pending[key];
    if (existing != null) return existing;

    final future = Future<V>.sync(operation);
    _pending[key] = future;

    void removeIfCurrent() {
      if (identical(_pending[key], future)) _pending.remove(key);
    }

    unawaited(
      future.then<void>(
        (_) => removeIfCurrent(),
        onError: (_, _) => removeIfCurrent(),
      ),
    );
    return future;
  }

  void clear() => _pending.clear();

  int get pendingCount => _pending.length;
}
