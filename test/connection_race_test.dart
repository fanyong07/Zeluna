import 'dart:async';
import 'package:anime/src/core/network/connection_race.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unresponsive first IP cannot block a working second IP', (
    tester,
  ) async {
    final blocked = Completer<int>();
    var cancelled = 0;
    final closed = <int>[];
    final race = raceConnections<int>(
      candidates: [
        () async => ConnectionAttempt(blocked.future, () => cancelled++),
        () async => ConnectionAttempt(Future.value(2), () {}),
      ],
      close: closed.add,
    );
    int? winner;
    unawaited(race.value.then((v) => winner = v));
    await tester.pump();
    expect(winner, isNull);
    await tester.pump(const Duration(milliseconds: 251));
    expect(winner, 2);
    expect(cancelled, 1);
    blocked.complete(1);
    await tester.pump();
    expect(closed, [1]);
  });
  testWidgets('cancellation cleans a late-created task and its socket', (
    tester,
  ) async {
    final starter = Completer<ConnectionAttempt<int>>();
    var cancelled = 0;
    final closed = <int>[];
    final race = raceConnections<int>(
      candidates: [() => starter.future],
      close: closed.add,
    );
    final failed = expectLater(race.value, throwsStateError);
    race.cancel();
    await failed;
    starter.complete(ConnectionAttempt(Future.value(7), () => cancelled++));
    await tester.pump();
    expect(cancelled, 1);
    expect(closed, [7]);
  });
  testWidgets('all silent handshakes are bounded by one deadline', (
    tester,
  ) async {
    var cancelled = 0;
    final race = raceConnections<int>(
      candidates: [
        () async =>
            ConnectionAttempt(Completer<int>().future, () => cancelled++),
        () async =>
            ConnectionAttempt(Completer<int>().future, () => cancelled++),
      ],
      close: (_) {},
      timeout: const Duration(seconds: 1),
    );
    final failure = expectLater(race.value, throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    await failure;
    expect(cancelled, 2);
  });
  testWidgets('failure starts the next address without waiting for stagger', (
    tester,
  ) async {
    final race = raceConnections<int>(
      candidates: [
        () async =>
            ConnectionAttempt(Future.error(StateError('unreachable')), () {}),
        () async => ConnectionAttempt(Future.value(2), () {}),
      ],
      close: (_) {},
    );
    int? winner;
    unawaited(race.value.then((v) => winner = v));
    await tester.pump();
    expect(winner, 2);
  });
}
