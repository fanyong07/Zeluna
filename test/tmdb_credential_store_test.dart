import 'dart:async';
import 'dart:convert';

import 'package:anime/src/data/tmdb_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const guestToken = 'tmdb_guest_test_token_abcdefghijklmnopqrstuvwxyz';
  const accountToken = 'tmdb_account_test_token_abcdefghijklmnopqrstuvwxyz';
  final now = DateTime.utc(2026, 7, 23, 12);

  test(
    'token is isolated by local account and has no artificial expiry',
    () async {
      final backend = _MemoryCredentialBackend();
      final store = TmdbCredentialStore(backend: backend, clock: () => now);

      final guestStatus = await store.saveToken(token: guestToken);

      expect(await store.readAccessToken(), guestToken);
      expect(guestStatus.health, TmdbCredentialHealth.ready);
      expect(guestStatus.savedAt, now);
      expect(guestStatus.rejectedAt, isNull);

      expect(await store.readAccessToken(accountId: 'account-a'), isNull);
      expect(
        (await store.readStatus(accountId: 'account-a')).health,
        TmdbCredentialHealth.notConfigured,
      );
      await store.saveToken(accountId: 'account-a', token: accountToken);
      expect(await store.readAccessToken(accountId: 'account-a'), accountToken);
      expect(await store.readAccessToken(), guestToken);

      expect(backend.values.keys, hasLength(2));
      expect(backend.values.keys, everyElement(isNot(contains('account-a'))));
      expect(backend.values.values, everyElement(isNot(contains('expiresAt'))));
    },
  );

  test('rejected token is retained for status but not sent', () async {
    final rejectedAt = now.add(const Duration(minutes: 5));
    var clock = now;
    final backend = _MemoryCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => clock);
    await store.saveToken(token: guestToken);
    final primaryKey = backend.primaryKeys.single;
    final primaryBeforeRejection = backend.values[primaryKey];

    clock = rejectedAt;
    await store.markRejectedToken(rejectedToken: guestToken);

    expect(backend.values[primaryKey], primaryBeforeRejection);
    expect(backend.values, hasLength(2));
    expect(await store.readAccessToken(), isNull);
    final status = await store.readStatus();
    expect(status.health, TmdbCredentialHealth.rejected);
    expect(status.savedAt, now);
    expect(status.rejectedAt, rejectedAt);
    expect(status.isConfigured, isTrue);
    expect(status.canAuthenticate, isFalse);
  });

  test('rejection for another token does not affect current token', () async {
    final store = TmdbCredentialStore(
      backend: _MemoryCredentialBackend(),
      clock: () => now,
    );
    await store.saveToken(token: guestToken);

    await store.markRejectedToken(rejectedToken: accountToken);

    expect(await store.readAccessToken(), guestToken);
    expect((await store.readStatus()).health, TmdbCredentialHealth.ready);
  });

  test('saving again clears the separate rejection record', () async {
    final backend = _MemoryCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(token: guestToken);
    await store.markRejectedToken(rejectedToken: guestToken);
    expect(backend.values, hasLength(2));

    await store.saveToken(token: guestToken);

    expect(backend.values, hasLength(1));
    expect(await store.readAccessToken(), guestToken);
    expect((await store.readStatus()).health, TmdbCredentialHealth.ready);
  });

  test(
    'guest credential migrates once and account deletion clears it',
    () async {
      final backend = _MemoryCredentialBackend();
      final store = TmdbCredentialStore(backend: backend, clock: () => now);
      await store.saveToken(token: guestToken);

      await store.migrateGuestToAccount('first-account');
      await store.migrateGuestToAccount('first-account');

      expect(await store.readAccessToken(), isNull);
      expect(
        await store.readAccessToken(accountId: 'first-account'),
        guestToken,
      );
      await store.clearAccount('first-account');
      expect(await store.readAccessToken(accountId: 'first-account'), isNull);
      expect(backend.values, isEmpty);
    },
  );

  test('guest migration carries and clears the separate rejection', () async {
    final rejectedAt = now.add(const Duration(minutes: 5));
    var clock = now;
    final backend = _MemoryCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => clock);
    await store.saveToken(token: guestToken);
    clock = rejectedAt;
    await store.markRejectedToken(rejectedToken: guestToken);

    await store.migrateGuestToAccount('rejected-account');

    expect(
      (await store.readStatus()).health,
      TmdbCredentialHealth.notConfigured,
    );
    final migrated = await store.readStatus(accountId: 'rejected-account');
    expect(migrated.health, TmdbCredentialHealth.rejected);
    expect(migrated.savedAt, now);
    expect(migrated.rejectedAt, rejectedAt);
    expect(backend.values, hasLength(2));

    await store.clearAccount('rejected-account');
    expect(backend.values, isEmpty);
  });

  test('guest migration never overwrites an existing account token', () async {
    final backend = _MemoryCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(accountId: 'first-account', token: accountToken);
    await store.saveToken(token: guestToken);

    await store.migrateGuestToAccount('first-account');

    expect(
      await store.readAccessToken(accountId: 'first-account'),
      accountToken,
    );
    expect(await store.readAccessToken(), isNull);
  });

  test('failed guest migration is idempotent and succeeds on retry', () async {
    final backend = _FaultingCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(token: guestToken);
    backend.failNextWrite = true;

    await expectLater(
      store.migrateGuestToAccount('retry-account'),
      throwsA(isA<StateError>()),
    );
    expect(await store.readAccessToken(), guestToken);
    expect(await store.readAccessToken(accountId: 'retry-account'), isNull);

    await store.migrateGuestToAccount('retry-account');
    expect(await store.readAccessToken(), isNull);
    expect(await store.readAccessToken(accountId: 'retry-account'), guestToken);
  });

  test('failed guest deletion leaves a retryable duplicate', () async {
    final backend = _FaultingCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(token: guestToken);
    backend.failNextDelete = true;

    await expectLater(
      store.migrateGuestToAccount('retry-account'),
      throwsA(isA<StateError>()),
    );
    expect(await store.readAccessToken(), guestToken);
    expect(await store.readAccessToken(accountId: 'retry-account'), guestToken);

    await store.migrateGuestToAccount('retry-account');
    expect(await store.readAccessToken(), isNull);
    expect(await store.readAccessToken(accountId: 'retry-account'), guestToken);
  });

  test('separate store instances observe replacement and clearing', () async {
    final backend = _MemoryCredentialBackend();
    final first = TmdbCredentialStore(backend: backend, clock: () => now);
    final second = TmdbCredentialStore(backend: backend, clock: () => now);
    await first.saveToken(token: guestToken);
    expect(await second.readAccessToken(), guestToken);

    await first.saveToken(token: accountToken);
    expect(await second.readAccessToken(), accountToken);
    await first.clearAccount(null);
    expect(await second.readAccessToken(), isNull);
  });

  test('a delayed rejection cannot overwrite a replacement token', () async {
    final backend = _PausingReadCredentialBackend();
    final first = TmdbCredentialStore(backend: backend, clock: () => now);
    final second = TmdbCredentialStore(backend: backend, clock: () => now);
    await first.saveToken(token: guestToken);

    backend.pauseNextRead();
    final rejection = first.markRejectedToken(rejectedToken: guestToken);
    await backend.readStarted.future;
    await second.saveToken(token: accountToken);
    backend.releaseRead();
    await rejection;

    expect(await first.readAccessToken(), accountToken);
    expect((await first.readStatus()).health, TmdbCredentialHealth.ready);
  });

  test(
    'a delayed rejection cannot poison the same token saved again',
    () async {
      final backend = _PausingReadCredentialBackend();
      final first = TmdbCredentialStore(backend: backend, clock: () => now);
      final second = TmdbCredentialStore(backend: backend, clock: () => now);
      await first.saveToken(token: guestToken);
      final primaryKey = backend.primaryKeys.single;
      final firstRecordId = _recordId(backend.values[primaryKey]!);

      backend.pauseNextRead();
      final rejection = first.markRejectedToken(rejectedToken: guestToken);
      await backend.readStarted.future;
      await second.saveToken(token: guestToken);
      final replacementRecordId = _recordId(backend.values[primaryKey]!);
      expect(replacementRecordId, isNot(firstRecordId));
      backend.releaseRead();
      await rejection;

      expect(await first.readAccessToken(), guestToken);
      expect((await first.readStatus()).health, TmdbCredentialHealth.ready);
    },
  );

  test('a delayed rejection cannot restore a cleared token', () async {
    final backend = _PausingReadCredentialBackend();
    final first = TmdbCredentialStore(backend: backend, clock: () => now);
    final second = TmdbCredentialStore(backend: backend, clock: () => now);
    await first.saveToken(token: guestToken);

    backend.pauseNextRead();
    final rejection = first.markRejectedToken(rejectedToken: guestToken);
    await backend.readStarted.future;
    await second.clearAccount(null);
    backend.releaseRead();
    await rejection;

    expect(await first.readAccessToken(), isNull);
    expect(
      (await first.readStatus()).health,
      TmdbCredentialHealth.notConfigured,
    );
    await second.clearAccount(null);
    expect(backend.values, isEmpty);
  });

  test('legacy inline rejection remains readable and replaceable', () async {
    final backend = _MemoryCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(token: guestToken);
    final primaryKey = backend.primaryKeys.single;
    final rejectedAt = now.add(const Duration(minutes: 5));
    backend.values[primaryKey] = jsonEncode({
      'token': guestToken,
      'savedAt': now.toIso8601String(),
      'rejectedAt': rejectedAt.toIso8601String(),
    });

    expect(await store.readAccessToken(), isNull);
    final legacy = await store.readStatus();
    expect(legacy.health, TmdbCredentialHealth.rejected);
    expect(legacy.rejectedAt, rejectedAt);

    await store.saveToken(token: guestToken);
    expect(await store.readAccessToken(), guestToken);
    expect((await store.readStatus()).health, TmdbCredentialHealth.ready);
  });

  test(
    'short whitespace and oversized tokens are rejected before storage write',
    () async {
      final backend = _MemoryCredentialBackend();
      final store = TmdbCredentialStore(backend: backend, clock: () => now);

      for (final invalidToken in [
        List.filled(31, 'a').join(),
        'tmdb_test_token_with embedded_whitespace_123456789',
        List.filled(2049, 'a').join(),
      ]) {
        await expectLater(
          store.saveToken(token: invalidToken),
          throwsA(isA<FormatException>()),
        );
      }
      expect(backend.values, isEmpty);
    },
  );

  test('legacy records with invalid token format are ignored', () async {
    final backend = _MemoryCredentialBackend();
    final store = TmdbCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(token: guestToken);
    final primaryKey = backend.primaryKeys.single;

    for (final invalidToken in [
      List.filled(31, 'a').join(),
      'tmdb_test_token_with embedded_whitespace_123456789',
      List.filled(2049, 'a').join(),
    ]) {
      backend.values[primaryKey] = jsonEncode({
        'token': invalidToken,
        'savedAt': now.toIso8601String(),
      });
      expect(await store.readAccessToken(), isNull);
      expect(
        (await store.readStatus()).health,
        TmdbCredentialHealth.notConfigured,
      );
    }
  });
}

String _recordId(String raw) {
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded['recordId'] as String;
}

class _MemoryCredentialBackend implements TmdbCredentialBackend {
  final values = <String, String>{};

  Iterable<String> get primaryKeys =>
      values.keys.where((key) => key.contains('.credential.v1.'));

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _FaultingCredentialBackend extends _MemoryCredentialBackend {
  bool failNextWrite = false;
  bool failNextDelete = false;

  @override
  Future<void> delete(String key) async {
    if (failNextDelete) {
      failNextDelete = false;
      throw StateError('simulated secure delete failure');
    }
    await super.delete(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('simulated secure write failure');
    }
    await super.write(key, value);
  }
}

class _PausingReadCredentialBackend extends _MemoryCredentialBackend {
  Completer<void> readStarted = Completer<void>();
  Completer<void>? _readRelease;

  void pauseNextRead() {
    readStarted = Completer<void>();
    _readRelease = Completer<void>();
  }

  void releaseRead() {
    _readRelease?.complete();
    _readRelease = null;
  }

  @override
  Future<String?> read(String key) async {
    final captured = values[key];
    final release = _readRelease;
    if (release != null) {
      if (!readStarted.isCompleted) readStarted.complete();
      await release.future;
    }
    return captured;
  }
}
