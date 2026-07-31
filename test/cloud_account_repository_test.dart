import 'dart:convert';
import 'dart:io';

import 'package:anime/src/accounts/cloud_account_repository.dart';
import 'package:anime/src/accounts/local_account_repository.dart';
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
