import 'dart:async';

import 'package:anime/src/accounts/password_hasher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PBKDF2-SHA256 matches the standard one-iteration vector', () async {
    final hash = await derivePasswordHash(
      password: 'password',
      salt: 'c2FsdA',
      iterations: 1,
    );
    expect(hash, 'Eg-2z_z4syxD5yJSVsT4N6hlSMkszDVICAWYfLcL4Xs');
  });

  test(
    'production password hashing yields without blocking the event loop',
    () async {
      var eventLoopYielded = false;
      Timer.run(() => eventLoopYielded = true);
      final hashFuture = derivePasswordHash(
        password: 'correct-horse-battery-staple',
        salt: 'c2FsdC1mb3ItcHJvZHVjdGlvbg',
        iterations: 120000,
      );

      await Future<void>.delayed(Duration.zero);
      expect(eventLoopYielded, isTrue);
      expect(await hashFuture.timeout(const Duration(seconds: 5)), isNotEmpty);
    },
  );
}
