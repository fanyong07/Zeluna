import 'dart:async';

/// One connection owns both its pending handshake and its eventual socket.
final class ConnectionAttempt<T> {
  ConnectionAttempt(this.value, this.cancel) {
    // The task can fail before its asynchronous factory has returned it.
    // Observe early errors now; awaiting value still receives the same error.
    unawaited(value.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final Future<T> value;
  final void Function() cancel;
}

/// Stagger validated addresses instead of letting a black-holed first address
/// consume the complete request budget. The winner is the first completed TLS
/// handshake, not merely a TCP connect. All losers and late arrivals are closed.
ConnectionAttempt<T> raceConnections<T>({
  required List<Future<ConnectionAttempt<T>> Function()> candidates,
  required void Function(T) close,
  Duration stagger = const Duration(milliseconds: 250),
  Duration timeout = const Duration(seconds: 12),
}) {
  final result = Completer<T>();
  final attempts = <int, ConnectionAttempt<T>>{};
  Timer? nextTimer;
  Timer? deadline;
  var next = 0;
  var pending = 0;
  T? winner;
  Object? lastError;
  StackTrace? lastStack;
  void stop() {
    nextTimer?.cancel();
    deadline?.cancel();
    for (final attempt in attempts.values.toList()) {
      attempt.cancel();
    }
    attempts.clear();
  }

  void fail(Object error, [StackTrace? stack]) {
    if (result.isCompleted) return;
    result.completeError(error, stack);
    stop();
  }

  late void Function() launch;
  void schedule() {
    nextTimer?.cancel();
    if (!result.isCompleted && next < candidates.length) {
      nextTimer = Timer(stagger, launch);
    }
  }

  launch = () {
    if (result.isCompleted || next >= candidates.length) return;
    final index = next++;
    pending++;
    schedule();
    unawaited(() async {
      try {
        final attempt = await candidates[index]();
        if (result.isCompleted) {
          // Attach a handler before cancelling an asynchronously created task.
          unawaited(attempt.value.then(close, onError: (Object _) {}));
          attempt.cancel();
          return;
        }
        attempts[index] = attempt;
        final value = await attempt.value;
        attempts.remove(index);
        if (result.isCompleted) {
          close(value);
          return;
        }
        winner = value;
        result.complete(value);
        stop();
      } catch (error, stack) {
        attempts.remove(index)?.cancel();
        lastError = error;
        lastStack = stack;
      } finally {
        pending--;
        if (!result.isCompleted) {
          if (next < candidates.length) {
            nextTimer?.cancel();
            launch();
          } else if (pending == 0) {
            fail(
              lastError ?? StateError('No connection candidates'),
              lastStack,
            );
          }
        }
      }
    }());
  };
  deadline = Timer(
    timeout,
    () => fail(TimeoutException('Connection deadline', timeout)),
  );
  if (candidates.isEmpty) {
    fail(StateError('No connection candidates'));
  } else {
    launch();
  }
  return ConnectionAttempt(result.future, () {
    if (winner != null) {
      close(winner as T);
      winner = null;
    }
    fail(StateError('Connection cancelled'));
    stop();
  });
}
