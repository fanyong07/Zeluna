import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import 'local_account_repository.dart';

const _defaultZelunaBackendUrl = String.fromEnvironment(
  'ZELUNA_BACKEND_URL',
  defaultValue: 'https://api.zeluna.top',
);
const defaultCloudAccountBaseUrl = String.fromEnvironment(
  'ZELUNA_ACCOUNT_URL',
  defaultValue: _defaultZelunaBackendUrl,
);

abstract interface class CloudAccountService {
  Future<LocalAccount?> restoreSession(LocalAccount? cachedAccount);

  Future<void> requestRegistrationCode(String email);

  Future<void> requestPasswordResetCode(String email);

  Future<LocalAccount> register({
    required String email,
    required String nickname,
    required String password,
    required String verificationCode,
  });

  Future<LocalAccount> login({required String email, required String password});

  Future<void> logout();

  Future<LocalAccount> updateNickname(String nickname);

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });

  Future<void> verifyPassword(String password);

  Future<Uint8List> exportAccountData();

  Future<AccountDeletionSchedule> requestAccountDeletion(String password);

  Future<void> cancelAccountDeletion({
    required String email,
    required String password,
  });

  Future<void> resetPassword({
    required String email,
    required String verificationCode,
    required String newPassword,
  });
}

abstract interface class CloudAccountTokenStore {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> delete();
}

class SecureCloudAccountTokenStore implements CloudAccountTokenStore {
  SecureCloudAccountTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'zeluna.cloud.account.token.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class AccountDeletionSchedule {
  const AccountDeletionSchedule({
    required this.requestedAt,
    required this.dueAt,
  });

  final DateTime requestedAt;
  final DateTime dueAt;
}

class AccountDeletionPendingException extends AccountException {
  const AccountDeletionPendingException({
    required String message,
    required this.dueAt,
    required this.canCancel,
  }) : super(message);

  final DateTime dueAt;
  final bool canCancel;
}

class CloudAccountRepository implements CloudAccountService {
  CloudAccountRepository({
    String baseUrl = defaultCloudAccountBaseUrl,
    http.Client? client,
    CloudAccountTokenStore? tokenStore,
    this.requestTimeout = const Duration(seconds: 12),
  }) : _baseUri = _normalizeBaseUrl(baseUrl),
       _client = client == null
           ? createNetworkHttpClient(
               NetworkRequestPolicy.forService(
                 NetworkServiceKind.accountBackend,
               ),
             )
           : PolicyHttpClient(
               inner: client,
               ownsInner: false,
               policy: NetworkRequestPolicy.forService(
                 NetworkServiceKind.accountBackend,
               ),
             ),
       _ownsClient = true,
       _tokenStore = tokenStore ?? SecureCloudAccountTokenStore();

  final Uri _baseUri;
  final http.Client _client;
  final bool _ownsClient;
  final CloudAccountTokenStore _tokenStore;
  final Duration requestTimeout;

  @override
  Future<LocalAccount?> restoreSession(LocalAccount? cachedAccount) async {
    final token = await _readToken();
    if (token == null) return null;
    try {
      final response = await _send('GET', 'me', token: token);
      if (response.statusCode == 401 ||
          response.statusCode == 410 ||
          response.statusCode == 423) {
        await _tokenStore.delete();
        return null;
      }
      final body = _decodeSuccess(response);
      return _accountFrom(body['user']);
    } on TimeoutException {
      return cachedAccount;
    } on http.ClientException {
      return cachedAccount;
    } on NetworkSecurityException {
      return cachedAccount;
    } on FormatException {
      return cachedAccount;
    } on AccountException {
      return cachedAccount;
    }
  }

  @override
  Future<void> requestRegistrationCode(String email) async {
    final normalized = _validateEmail(email);
    final response = await _post(
      'code',
      body: {'email': normalized, 'purpose': 'register'},
    );
    _decodeSuccess(response);
  }

  @override
  Future<void> requestPasswordResetCode(String email) async {
    final normalized = _validateEmail(email);
    final response = await _post(
      'code',
      body: {'email': normalized, 'purpose': 'reset_password'},
    );
    _decodeSuccess(response);
  }

  @override
  Future<LocalAccount> register({
    required String email,
    required String nickname,
    required String password,
    required String verificationCode,
  }) async {
    final response = await _post(
      'register',
      body: {
        'email': _validateEmail(email),
        'nickname': _validateNickname(nickname),
        'password': _validatePassword(password),
        'code': _validateCode(verificationCode),
      },
    );
    return _persistSession(_decodeSuccess(response));
  }

  @override
  Future<LocalAccount> login({
    required String email,
    required String password,
  }) async {
    final response = await _post(
      'login',
      body: {'email': _validateEmail(email), 'password': password},
    );
    return _persistSession(_decodeSuccess(response));
  }

  @override
  Future<void> logout() async {
    final token = await _readToken();
    try {
      if (token != null) {
        await _post('logout', token: token);
      }
    } on Object {
      // Signing out locally must remain possible when the network is down.
    } finally {
      await _tokenStore.delete();
    }
  }

  @override
  Future<LocalAccount> updateNickname(String nickname) async {
    final token = await _requiredToken();
    final response = await _patch(
      'profile',
      token: token,
      body: {'nickname': _validateNickname(nickname)},
    );
    final body = _decodeSuccess(response);
    return _accountFrom(body['user']);
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final token = await _requiredToken();
    final response = await _post(
      'password',
      token: token,
      body: {
        'current_password': currentPassword,
        'new_password': _validatePassword(newPassword),
      },
    );
    _decodeSuccess(response);
  }

  @override
  Future<void> verifyPassword(String password) async {
    final token = await _requiredToken();
    final response = await _post(
      'password/verify',
      token: token,
      body: {'password': password},
    );
    _decodeSuccess(response);
  }

  @override
  Future<Uint8List> exportAccountData() async {
    final token = await _requiredToken();
    final response = await _send(
      'GET',
      'privacy/export',
      token: token,
      maxResponseBytes: accountBackendExportMaxResponseBytes,
    );
    final body = _decodeSuccess(response);
    if (body['schema_version'] != 1 || body['account'] is! Map) {
      throw const AccountException('服务器返回的账号数据导出格式无效');
    }
    return Uint8List.fromList(response.bodyBytes);
  }

  @override
  Future<AccountDeletionSchedule> requestAccountDeletion(
    String password,
  ) async {
    final token = await _requiredToken();
    final response = await _post(
      'privacy/deletion',
      token: token,
      body: {'password': password},
    );
    final body = _decodeSuccess(response);
    final requestedAt = _dateTimeFromSeconds(body['deletion_requested_at']);
    final dueAt = _dateTimeFromSeconds(body['deletion_due_at']);
    if (body['status'] != 'pending' ||
        requestedAt == null ||
        dueAt == null ||
        !dueAt.isAfter(requestedAt)) {
      throw const AccountException('服务器返回的账号删除时间无效');
    }
    try {
      await _tokenStore.delete();
    } catch (_) {
      // The server already revoked every session. A stale local token is inert.
    }
    return AccountDeletionSchedule(requestedAt: requestedAt, dueAt: dueAt);
  }

  @override
  Future<void> cancelAccountDeletion({
    required String email,
    required String password,
  }) async {
    final response = await _post(
      'privacy/deletion/cancel',
      body: {'email': _validateEmail(email), 'password': password},
    );
    _decodeSuccess(response);
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String verificationCode,
    required String newPassword,
  }) async {
    final response = await _post(
      'password/reset',
      body: {
        'email': _validateEmail(email),
        'code': _validateCode(verificationCode),
        'new_password': _validatePassword(newPassword),
      },
    );
    _decodeSuccess(response);
  }

  Future<LocalAccount> _persistSession(Map<String, dynamic> body) async {
    final token = body['access_token']?.toString().trim() ?? '';
    if (token.isEmpty) throw const AccountException('服务器没有返回登录状态，请重试');
    final account = _accountFrom(body['user']);
    try {
      await _tokenStore.write(token);
    } catch (_) {
      throw const AccountException('无法安全保存登录状态，请检查系统凭据存储');
    }
    return account;
  }

  Future<http.Response> _post(
    String path, {
    Map<String, Object?>? body,
    String? token,
  }) => _send('POST', path, body: body, token: token);

  Future<http.Response> _patch(
    String path, {
    required Map<String, Object?> body,
    String? token,
  }) => _send('PATCH', path, body: body, token: token);

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    int maxResponseBytes = accountBackendDefaultMaxResponseBytes,
  }) async {
    try {
      final request = http.Request(method, _endpoint(path));
      request.headers.addAll({
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json; charset=utf-8',
        if (token != null) 'Authorization': 'Bearer $token',
      });
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(requestTimeout);
      final declaredLength = streamed.contentLength;
      if (declaredLength != null && declaredLength > maxResponseBytes) {
        throw const AccountException('账号服务返回的数据过大，已停止读取');
      }
      final responseBytes = await _readBoundedBytes(
        streamed.stream,
        maxResponseBytes: maxResponseBytes,
      ).timeout(requestTimeout);
      return http.Response.bytes(
        responseBytes,
        streamed.statusCode,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
        request: streamed.request,
      );
    } on TimeoutException {
      throw const AccountException('连接账号服务器超时，请检查网络后重试');
    } on http.ClientException {
      throw const AccountException('无法连接账号服务器，请检查网络后重试');
    } on NetworkSecurityException {
      throw const AccountException('账号服务器未通过安全连接检查');
    }
  }

  Map<String, dynamic> _decodeSuccess(http.Response response) {
    Map<String, dynamic> body = const {};
    if (response.bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map) body = decoded.cast<String, dynamic>();
      } catch (_) {
        throw const AccountException('账号服务器返回了无法识别的数据');
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    if (response.statusCode == 401) {
      unawaited(_tokenStore.delete());
    }
    final detail = body['detail'];
    if (detail is Map) {
      final detailMap = detail.cast<Object?, Object?>();
      final code = detailMap['code']?.toString();
      if (code == 'account_deletion_pending' ||
          code == 'account_deletion_finalizing') {
        final dueAt = _dateTimeFromSeconds(detailMap['deletion_due_at']);
        if (dueAt != null) {
          throw AccountDeletionPendingException(
            message: detailMap['message']?.toString().trim().isNotEmpty == true
                ? detailMap['message'].toString().trim()
                : '账号正在删除流程中',
            dueAt: dueAt,
            canCancel: code == 'account_deletion_pending',
          );
        }
      }
    }
    final message = detail is String && detail.trim().isNotEmpty
        ? detail.trim()
        : switch (response.statusCode) {
            429 => '操作太频繁，请稍后再试',
            503 => '邮箱服务暂不可用，请稍后再试',
            _ => '账号操作没有完成，请稍后重试',
          };
    throw AccountException(message);
  }

  LocalAccount _accountFrom(Object? value) {
    if (value is! Map) throw const AccountException('服务器没有返回账号信息');
    final json = value.cast<Object?, Object?>();
    final id = json['id']?.toString().trim() ?? '';
    final email = json['email']?.toString().trim().toLowerCase() ?? '';
    final nickname = json['nickname']?.toString().trim() ?? '';
    if (id.isEmpty || email.isEmpty || nickname.isEmpty) {
      throw const AccountException('服务器返回的账号信息不完整');
    }
    final createdSeconds = switch (json['created_at']) {
      final num value => value.toDouble(),
      _ => null,
    };
    final updatedSeconds = switch (json['updated_at']) {
      final num value => value.toDouble(),
      _ => null,
    };
    final now = DateTime.now().toUtc();
    return LocalAccount(
      id: id,
      email: email,
      nickname: nickname,
      createdAt: createdSeconds == null
          ? now
          : DateTime.fromMillisecondsSinceEpoch(
              (createdSeconds * 1000).round(),
              isUtc: true,
            ),
      lastLoginAt: updatedSeconds == null
          ? now
          : DateTime.fromMillisecondsSinceEpoch(
              (updatedSeconds * 1000).round(),
              isUtc: true,
            ),
      cloudAuthenticated: true,
    );
  }

  Future<String?> _readToken() async {
    try {
      final value = await _tokenStore.read();
      final token = value?.trim() ?? '';
      return token.isEmpty ? null : token;
    } catch (_) {
      return null;
    }
  }

  Future<String> _requiredToken() async {
    final token = await _readToken();
    if (token == null) throw const AccountException('登录状态已失效，请重新登录');
    return token;
  }

  Uri _endpoint(String path) => _baseUri.replace(
    pathSegments: [
      ..._baseUri.pathSegments.where((segment) => segment.isNotEmpty),
      'api',
      'v1',
      'auth',
      ...path.split('/').where((segment) => segment.isNotEmpty),
    ],
  );

  void close() {
    if (_ownsClient) _client.close();
  }
}

DateTime? _dateTimeFromSeconds(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (value.toDouble() * 1000).round(),
    isUtc: true,
  );
}

Future<Uint8List> _readBoundedBytes(
  Stream<List<int>> stream, {
  required int maxResponseBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > maxResponseBytes) {
      throw const AccountException('账号服务返回的数据过大，已停止读取');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Uri _normalizeBaseUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw ArgumentError.value(value, 'baseUrl', '必须是完整的 HTTPS 地址');
  }
  NetworkRequestPolicy.forService(
    NetworkServiceKind.accountBackend,
  ).ensureUriAllowed(uri);
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

String _validateEmail(String value) {
  final email = value.trim().toLowerCase();
  final at = email.indexOf('@');
  if (email.length > 254 ||
      at <= 0 ||
      at == email.length - 1 ||
      !email.substring(at).contains('.')) {
    throw const AccountException('请输入有效的邮箱地址');
  }
  return email;
}

String _validateNickname(String value) {
  final nickname = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (nickname.length < 2 || nickname.length > 40) {
    throw const AccountException('昵称需要 2 到 40 个字符');
  }
  return nickname;
}

String _validatePassword(String value) {
  if (value.length < 8 || value.length > 128) {
    throw const AccountException('密码需要 8 到 128 个字符');
  }
  return value;
}

String _validateCode(String value) {
  final code = value.trim();
  if (!RegExp(r'^\d{6}$').hasMatch(code)) {
    throw const AccountException('请输入邮件中的 6 位验证码');
  }
  return code;
}
