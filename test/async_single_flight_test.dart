import 'dart:async';

import 'package:anime/src/data/async_single_flight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same key shares one in-flight operation', () async {
    final singleFlight = AsyncSingleFlight<String, int>();
    final completer = Completer<int>();
    var calls = 0;

    Future<int> load() {
      calls++;
      return completer.future;
    }

    final first = singleFlight.run('episode:1', load);
    final second = singleFlight.run('episode:1', load);

    expect(calls, 1);
    expect(identical(first, second), isTrue);
    expect(singleFlight.pendingCount, 1);

    completer.complete(7);
    expect(await Future.wait([first, second]), [7, 7]);
    await Future<void>.delayed(Duration.zero);
    expect(singleFlight.pendingCount, 0);
  });

  test('completed and failed operations are not cached', () async {
    final singleFlight = AsyncSingleFlight<String, int>();
    var calls = 0;

    expect(await singleFlight.run('episode:1', () async => ++calls), 1);
    await Future<void>.delayed(Duration.zero);
    expect(await singleFlight.run('episode:1', () async => ++calls), 2);

    await expectLater(
      singleFlight.run('episode:error', () async => throw StateError('boom')),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(singleFlight.pendingCount, 0);
    expect(await singleFlight.run('episode:error', () async => ++calls), 3);
  });
}
