import 'dart:async';

import 'package:anime/src/data/bangumi_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const guestToken = 'guest_test_token_abcdefghijklmnopqrstuvwxyz';
  const accountToken = 'account_test_token_abcdefghijklmnopqrstuvwxyz';
  final now = DateTime.utc(2026, 7, 23, 12);

  test(
    'token is isolated by local account and expires after one year',
    () async {
      final backend = _MemoryCredentialBackend();
      final store = BangumiCredentialStore(backend: backend, clock: () => now);

      final guestStatus = await store.saveToken(
        token: guestToken,
        userId: '42',
        username: 'guest-user',
        displayName: '测试用户',
      );

      expect(await store.readAccessToken(), guestToken);
      expect(guestStatus.health, BangumiCredentialHealth.ready);
      expect(guestStatus.expiresAt, DateTime.utc(2027, 7, 23, 12));
      expect(guestStatus.displayName, '测试用户');

      expect(await store.readAccessToken(accountId: 'account-a'), isNull);
      expect(
        (await store.readStatus(accountId: 'account-a')).health,
        BangumiCredentialHealth.notConfigured,
      );
      await store.saveToken(accountId: 'account-a', token: accountToken);
      expect(await store.readAccessToken(accountId: 'account-a'), accountToken);

      expect(await store.readAccessToken(), guestToken);
      expect(backend.values.keys, hasLength(2));
      expect(backend.values.keys, everyElement(isNot(contains('account-a'))));
    },
  );

  test(
    'rejected or expired token is retained for status but not sent',
    () async {
      var clock = now;
      final store = BangumiCredentialStore(
        backend: _MemoryCredentialBackend(),
        clock: () => clock,
      );
      await store.saveToken(token: guestToken);

      await store.markRejected();
      expect(await store.readAccessToken(), isNull);
      expect(
        (await store.readStatus()).health,
        BangumiCredentialHealth.rejected,
      );

      await store.saveToken(token: accountToken);
      clock = DateTime.utc(2027, 7, 24);
      expect(await store.readAccessToken(), isNull);
      expect(
        (await store.readStatus()).health,
        BangumiCredentialHealth.expired,
      );
    },
  );

  test(
    'guest credential migrates once and account deletion clears it',
    () async {
      final backend = _MemoryCredentialBackend();
      final store = BangumiCredentialStore(backend: backend, clock: () => now);
      await store.saveToken(token: guestToken);

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

  test('guest migration never overwrites an existing account token', () async {
    final backend = _MemoryCredentialBackend();
    final store = BangumiCredentialStore(backend: backend, clock: () => now);
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
    final store = BangumiCredentialStore(backend: backend, clock: () => now);
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
    final store = BangumiCredentialStore(backend: backend, clock: () => now);
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
    final first = BangumiCredentialStore(backend: backend, clock: () => now);
    final second = BangumiCredentialStore(backend: backend, clock: () => now);
    await first.saveToken(token: guestToken);
    expect(await second.readAccessToken(), guestToken);

    await first.saveToken(token: accountToken);
    expect(await second.readAccessToken(), accountToken);
    await first.clearAccount(null);
    expect(await second.readAccessToken(), isNull);
  });

  test('a delayed rejection cannot overwrite a replacement token', () async {
    final backend = _PausingReadCredentialBackend();
    final store = BangumiCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(token: guestToken);

    backend.pauseNextRead();
    final rejection = store.markRejectedToken(rejectedToken: guestToken);
    await backend.readStarted.future;
    final replacement = store.saveToken(token: accountToken);
    backend.releaseRead();
    await Future.wait([rejection, replacement]);

    expect(await store.readAccessToken(), accountToken);
    expect((await store.readStatus()).health, BangumiCredentialHealth.ready);
  });

  test('a delayed rejection cannot restore a cleared token', () async {
    final backend = _PausingReadCredentialBackend();
    final store = BangumiCredentialStore(backend: backend, clock: () => now);
    await store.saveToken(token: guestToken);

    backend.pauseNextRead();
    final rejection = store.markRejectedToken(rejectedToken: guestToken);
    await backend.readStarted.future;
    final clearing = store.clearAccount(null);
    backend.releaseRead();
    await Future.wait([rejection, clearing]);

    expect(await store.readAccessToken(), isNull);
    expect(
      (await store.readStatus()).health,
      BangumiCredentialHealth.notConfigured,
    );
  });
}

class _MemoryCredentialBackend implements BangumiCredentialBackend {
  final values = <String, String>{};

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
