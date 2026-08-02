import 'dart:convert';
import 'dart:io';

import 'package:anime/src/accounts/cloud_account_repository.dart';
import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:anime/src/core/network/network_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'registration uses cloud API and stores only the returned token',
    () async {
      final tokens = _MemoryTokenStore();
      late Map<String, dynamic> sent;
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api.example/api/v1/auth/register',
        );
        expect(request.method, 'POST');
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'access_token': 'server-token',
            'user': {
              'id': '42',
              'email': 'user@example.com',
              'nickname': '星野',
              'created_at': 1767225600,
              'updated_at': 1767225601,
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(client.close);
      final repository = CloudAccountRepository(
        baseUrl: 'https://api.example',
        client: client,
        tokenStore: tokens,
      );

      final account = await repository.register(
        email: 'USER@example.com ',
        nickname: '星野',
        password: 'password-123',
        verificationCode: '123456',
      );

      expect(sent['email'], 'user@example.com');
      expect(sent['code'], '123456');
      expect(account.id, '42');
      expect(account.cloudAuthenticated, isTrue);
      expect(tokens.value, 'server-token');
    },
  );

  test('expired cloud session clears the secure token', () async {
    final tokens = _MemoryTokenStore()..value = 'expired-token';
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer expired-token');
      return http.Response.bytes(
        utf8.encode(jsonEncode({'detail': '登录状态已失效，请重新登录'})),
        401,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: tokens,
    );

    final restored = await repository.restoreSession(null);

    expect(restored, isNull);
    expect(tokens.value, isNull);
  });

  test('password verification uses separate URL path segments', () async {
    final tokens = _MemoryTokenStore()..value = 'session-token';
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://api.example/api/v1/auth/password/verify',
      );
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer session-token');
      return http.Response('', 204);
    });
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: tokens,
    );

    await repository.verifyPassword('password-123');
  });

  test(
    'password reset uses email code and clears no unrelated token',
    () async {
      final tokens = _MemoryTokenStore()..value = 'other-session-token';
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          '{}',
          request.url.path.endsWith('/code') ? 202 : 200,
        );
      });
      addTearDown(client.close);
      final repository = CloudAccountRepository(
        baseUrl: 'https://api.example',
        client: client,
        tokenStore: tokens,
      );

      await repository.requestPasswordResetCode('USER@example.com ');
      await repository.resetPassword(
        email: 'USER@example.com ',
        verificationCode: '123456',
        newPassword: 'new-password-123',
      );

      expect(requests, hasLength(2));
      expect(requests.first.url.path, '/api/v1/auth/code');
      expect(jsonDecode(requests.first.body), {
        'email': 'user@example.com',
        'purpose': 'reset_password',
      });
      expect(requests.last.url.path, '/api/v1/auth/password/reset');
      expect(jsonDecode(requests.last.body), {
        'email': 'user@example.com',
        'code': '123456',
        'new_password': 'new-password-123',
      });
      expect(tokens.value, 'other-session-token');
    },
  );

  test('temporary restore failure keeps the cached cloud account', () async {
    final tokens = _MemoryTokenStore()..value = 'session-token';
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'detail': '服务正在维护'}),
        503,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: tokens,
    );
    final cached = LocalAccount(
      id: 'cloud-1',
      email: 'user@example.com',
      nickname: '星野',
      createdAt: DateTime.utc(2026),
      lastLoginAt: DateTime.utc(2026),
      cloudAuthenticated: true,
    );

    expect(await repository.restoreSession(cached), same(cached));
    expect(tokens.value, 'session-token');
  });

  test('account requests never follow redirects with credentials', () async {
    final tokens = _MemoryTokenStore()..value = 'session-token';
    final client = MockClient((request) async {
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer session-token');
      return http.Response(
        '',
        302,
        headers: {'location': 'http://attacker.example/collect'},
      );
    });
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: tokens,
    );

    expect(await repository.restoreSession(null), isNull);
    expect(tokens.value, 'session-token');
  });

  test('session restore keeps the ordinary account response limit', () async {
    final tokens = _MemoryTokenStore()..value = 'session-token';
    final client = MockClient.streaming((request, bodyStream) async {
      expect(request.url.path, '/api/v1/auth/me');
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        200,
        contentLength: accountBackendDefaultMaxResponseBytes + 1,
      );
    });
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: tokens,
    );
    final cached = LocalAccount(
      id: 'cloud-1',
      email: 'user@example.com',
      nickname: '星野',
      createdAt: DateTime.utc(2026),
      lastLoginAt: DateTime.utc(2026),
      cloudAuthenticated: true,
    );

    expect(await repository.restoreSession(cached), same(cached));
    expect(tokens.value, 'session-token');
  });

  test('cloud account cache never stores password material', () async {
    final root = await Directory.systemTemp.createTemp('cloud-account-cache-');
    Hive.init(root.path);
    final box = await Hive.openBox<dynamic>('cloud-account-cache');
    addTearDown(() async {
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final now = DateTime.utc(2026);
    final account = LocalAccount(
      id: 'cloud-1',
      email: 'user@example.com',
      nickname: '星野',
      createdAt: now,
      lastLoginAt: now,
      cloudAuthenticated: true,
    );
    final repository = LocalAccountRepository(box);

    await repository.rememberCloudAccount(account);

    final raw = Map<String, dynamic>.from(box.get('account.cloud-1') as Map);
    expect(raw['authSource'], 'cloud');
    expect(raw, isNot(contains('passwordHash')));
    expect(raw, isNot(contains('passwordSalt')));
  });

  test(
    'account export is authenticated, bounded, and preserves token',
    () async {
      final tokens = _MemoryTokenStore()..value = 'session-token';
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/auth/privacy/export');
        expect(request.headers['Authorization'], 'Bearer session-token');
        return http.Response(
          jsonEncode({
            'schema_version': 1,
            'account': {'id': '42', 'email': 'user@example.com'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(client.close);
      final repository = CloudAccountRepository(
        baseUrl: 'https://api.example',
        client: client,
        tokenStore: tokens,
      );

      final exported = await repository.exportAccountData();

      expect(jsonDecode(utf8.decode(exported))['schema_version'], 1);
      expect(tokens.value, 'session-token');
    },
  );

  test('account export rejects an oversized declared response', () async {
    final tokens = _MemoryTokenStore()..value = 'session-token';
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        200,
        contentLength: accountBackendExportMaxResponseBytes + 1,
      );
    });
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: tokens,
    );

    await expectLater(
      repository.exportAccountData(),
      throwsA(isA<AccountException>()),
    );
  });

  test(
    'pending deletion login exposes only the cancellable deadline',
    () async {
      final tokens = _MemoryTokenStore();
      final dueAt = DateTime.utc(2026, 8, 9, 12);
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/auth/login');
        return http.Response(
          jsonEncode({
            'detail': {
              'code': 'account_deletion_pending',
              'message': '账号处于删除冷静期，可在截止前撤销',
              'deletion_due_at': dueAt.millisecondsSinceEpoch / 1000,
            },
          }),
          423,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(client.close);
      final repository = CloudAccountRepository(
        baseUrl: 'https://api.example',
        client: client,
        tokenStore: tokens,
      );

      await expectLater(
        repository.login(email: 'user@example.com', password: 'password-123'),
        throwsA(
          isA<AccountDeletionPendingException>()
              .having((error) => error.canCancel, 'canCancel', isTrue)
              .having((error) => error.dueAt, 'dueAt', dueAt),
        ),
      );
      expect(tokens.value, isNull);
    },
  );

  test('finalizing deletion login is not offered as cancellable', () async {
    final dueAt = DateTime.utc(2026, 8, 2, 12);
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'detail': {
            'code': 'account_deletion_finalizing',
            'message': '删除冷静期已经结束，正在完成账号删除',
            'deletion_due_at': dueAt.millisecondsSinceEpoch / 1000,
          },
        }),
        410,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: _MemoryTokenStore(),
    );

    await expectLater(
      repository.login(email: 'user@example.com', password: 'password-123'),
      throwsA(
        isA<AccountDeletionPendingException>()
            .having((error) => error.canCancel, 'canCancel', isFalse)
            .having((error) => error.dueAt, 'dueAt', dueAt),
      ),
    );
  });
  test(
    'deletion request is authenticated, timed, and clears the token',
    () async {
      final tokens = _MemoryTokenStore()..value = 'session-token';
      final requestedAt = DateTime.utc(2026, 8, 2, 12);
      final dueAt = requestedAt.add(const Duration(days: 7));
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/auth/privacy/deletion');
        expect(request.headers['Authorization'], 'Bearer session-token');
        expect(jsonDecode(request.body)['password'], 'password-123');
        return http.Response(
          jsonEncode({
            'status': 'pending',
            'deletion_requested_at': requestedAt.millisecondsSinceEpoch / 1000,
            'deletion_due_at': dueAt.millisecondsSinceEpoch / 1000,
          }),
          202,
        );
      });
      addTearDown(client.close);
      final repository = CloudAccountRepository(
        baseUrl: 'https://api.example',
        client: client,
        tokenStore: tokens,
      );

      final schedule = await repository.requestAccountDeletion('password-123');

      expect(schedule.requestedAt, requestedAt);
      expect(schedule.dueAt, dueAt);
      expect(tokens.value, isNull);
    },
  );

  test(
    'deletion cancellation uses credentials without a bearer token',
    () async {
      final tokens = _MemoryTokenStore();
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/auth/privacy/deletion/cancel');
        expect(request.headers['Authorization'], isNull);
        expect(jsonDecode(request.body), {
          'email': 'user@example.com',
          'password': 'password-123',
        });
        return http.Response('', 204);
      });
      addTearDown(client.close);
      final repository = CloudAccountRepository(
        baseUrl: 'https://api.example',
        client: client,
        tokenStore: tokens,
      );

      await repository.cancelAccountDeletion(
        email: 'USER@example.com',
        password: 'password-123',
      );
    },
  );

  test('session restore signs out a frozen account', () async {
    final tokens = _MemoryTokenStore()..value = 'session-token';
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'detail': {
            'code': 'account_deletion_pending',
            'message': '账号处于删除冷静期，可在截止前撤销',
            'deletion_due_at':
                DateTime.utc(2026, 8, 9).millisecondsSinceEpoch / 1000,
          },
        }),
        423,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    addTearDown(client.close);
    final repository = CloudAccountRepository(
      baseUrl: 'https://api.example',
      client: client,
      tokenStore: tokens,
    );
    final cached = LocalAccount(
      id: 'cloud-1',
      email: 'user@example.com',
      nickname: '星野',
      createdAt: DateTime.utc(2026),
      lastLoginAt: DateTime.utc(2026),
      cloudAuthenticated: true,
    );

    expect(await repository.restoreSession(cached), isNull);
    expect(tokens.value, isNull);
  });
}

class _MemoryTokenStore implements CloudAccountTokenStore {
  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;
}
