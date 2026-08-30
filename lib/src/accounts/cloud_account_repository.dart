import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/network/network_http_client.dart';
import '../core/network/network_security.dart';
import '../domain/anime_models.dart';
import '../sync/cloud_sync_transport.dart';
import 'local_account_repository.dart';

const _defaultZelunaBackendUrl = String.fromEnvironment(
  'ZELUNA_BACKEND_URL',
  defaultValue: 'https://api.zeluna.top',
);
const defaultCloudAccountBaseUrl = String.fromEnvironment(
  'ZELUNA_ACCOUNT_URL',
  defaultValue: _defaultZelunaBackendUrl,
);

String get _deviceName => kIsWeb
    ? 'Web'
    : switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'Windows',
        TargetPlatform.android => 'Android',
        TargetPlatform.iOS => 'iOS',
        TargetPlatform.macOS => 'macOS',
        TargetPlatform.linux => 'Linux',
        TargetPlatform.fuchsia => 'Fuchsia',
      };

String get _platformName => kIsWeb ? 'web' : defaultTargetPlatform.name;

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

abstract interface class CloudDanmakuService {
  Future<DanmakuComment> createDanmaku({
    required String subjectKey,
    required String episodeKey,
    required Duration time,
    required DanmakuMode mode,
    required int color,
    required String text,
  });

  Future<void> deleteDanmaku(String commentId);
}

abstract interface class CloudAccountTokenStore {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> delete();
}

class CloudAccountCredentials {
  const CloudAccountCredentials({
    required this.accessToken,
    this.refreshToken,
    this.sessionId,
    this.deviceId,
    this.deviceName,
    this.platform,
    this.accessExpiresAt,
    this.refreshExpiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final String? sessionId;
  final String? deviceId;
  final String? deviceName;
  final String? platform;
  final DateTime? accessExpiresAt;
  final DateTime? refreshExpiresAt;
}

abstract interface class CloudAccountCredentialStore {
  Future<CloudAccountCredentials?> readCredentials();

  Future<void> writeCredentials(CloudAccountCredentials credentials);
}

class SecureCloudAccountTokenStore
    implements CloudAccountTokenStore, CloudAccountCredentialStore {
  SecureCloudAccountTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'zeluna.cloud.account.token.v1';
  static const _accessKey = 'zeluna.cloud.account.access.v2';
  static const _refreshKey = 'zeluna.cloud.account.refresh.v2';
  static const _sessionKey = 'zeluna.cloud.account.session.v2';
  static const _deviceKey = 'zeluna.cloud.account.device.v2';
  static const _deviceNameKey = 'zeluna.cloud.account.device-name.v2';
  static const _platformKey = 'zeluna.cloud.account.platform.v2';
  static const _accessExpiryKey = 'zeluna.cloud.account.access-expiry.v2';
  static const _refreshExpiryKey = 'zeluna.cloud.account.refresh-expiry.v2';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    final access = await _storage.read(key: _accessKey);
    return access ?? await _storage.read(key: _key);
  }

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() async {
    for (final key in [
      _key,
      _accessKey,
      _refreshKey,
      _sessionKey,
      _deviceNameKey,
      _platformKey,
      _accessExpiryKey,
      _refreshExpiryKey,
    ]) {
      await _storage.delete(key: key);
    }
  }

  @override
  Future<CloudAccountCredentials?> readCredentials() async {
    final access = (await read())?.trim() ?? '';
    if (access.isEmpty) return null;
    return CloudAccountCredentials(
      accessToken: access,
      refreshToken: (await _storage.read(key: _refreshKey))?.trim(),
      sessionId: await _storage.read(key: _sessionKey),
      deviceId: await _storage.read(key: _deviceKey),
      deviceName: await _storage.read(key: _deviceNameKey),
      platform: await _storage.read(key: _platformKey),
      accessExpiresAt: _readDate(await _storage.read(key: _accessExpiryKey)),
      refreshExpiresAt: _readDate(await _storage.read(key: _refreshExpiryKey)),
    );
  }

  @override
  Future<void> writeCredentials(CloudAccountCredentials credentials) async {
    await _storage.write(key: _key, value: credentials.accessToken);
    await _storage.write(key: _accessKey, value: credentials.accessToken);
    await _writeOptional(_refreshKey, credentials.refreshToken);
    await _writeOptional(_sessionKey, credentials.sessionId);
    await _writeIfPresent(_deviceKey, credentials.deviceId);
    await _writeOptional(_deviceNameKey, credentials.deviceName);
    await _writeOptional(_platformKey, credentials.platform);
    await _writeOptional(
      _accessExpiryKey,
      credentials.accessExpiresAt?.millisecondsSinceEpoch.toString(),
    );
    await _writeOptional(
      _refreshExpiryKey,
      credentials.refreshExpiresAt?.millisecondsSinceEpoch.toString(),
    );
  }

  Future<String> readOrCreateDeviceId() async {
    final existing = (await _storage.read(key: _deviceKey))?.trim() ?? '';
    if (RegExp(r'^[a-f0-9]{32}$').hasMatch(existing)) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final deviceId = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    await _storage.write(key: _deviceKey, value: deviceId);
    return deviceId;
  }

  Future<void> _writeOptional(String key, String? value) async {
    if (value == null || value.trim().isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  Future<void> _writeIfPresent(String key, String? value) async {
    if (value != null && value.trim().isNotEmpty) {
      await _storage.write(key: key, value: value);
    }
  }

  DateTime? _readDate(String? value) {
    final milliseconds = int.tryParse(value?.trim() ?? '');
    if (milliseconds == null || milliseconds <= 0) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    } on Object {
      return null;
    }
  }
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

class CloudAccountRepository
    implements CloudAccountService, CloudDanmakuService, CloudSyncTransport {
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
  Future<String?>? _refreshInFlight;

  CloudAccountCredentialStore? get _credentialStore =>
      _tokenStore is CloudAccountCredentialStore
      ? _tokenStore as CloudAccountCredentialStore
      : null;

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
    final device = await _deviceMetadata();
    final response = await _post(
      'register',
      body: {
        'email': _validateEmail(email),
        'nickname': _validateNickname(nickname),
        'password': _validatePassword(password),
        'code': _validateCode(verificationCode),
        ...device,
      },
    );
    return _persistSession(_decodeSuccess(response));
  }

  @override
  Future<LocalAccount> login({
    required String email,
    required String password,
  }) async {
    final device = await _deviceMetadata();
    final response = await _post(
      'login',
      body: {'email': _validateEmail(email), 'password': password, ...device},
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
      throw const AccountException('账号数据导出失败，请稍后重试');
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
      throw const AccountException('删除申请没有提交成功，请稍后重试');
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

  @override
  Future<DanmakuComment> createDanmaku({
    required String subjectKey,
    required String episodeKey,
    required Duration time,
    required DanmakuMode mode,
    required int color,
    required String text,
  }) async {
    final token = await _requiredToken();
    final response = await _send(
      'POST',
      '',
      token: token,
      uri: _danmakuEndpoint(),
      body: {
        'subject_key': subjectKey,
        'episode_key': episodeKey,
        'time_seconds': time.inMilliseconds / 1000,
        'mode': switch (mode) {
          DanmakuMode.top => 'top',
          DanmakuMode.bottom => 'bottom',
          _ => 'scroll',
        },
        'color': color,
        'text': text.trim(),
      },
    );
    return _danmakuCommentFrom(_decodeSuccess(response));
  }

  @override
  Future<void> deleteDanmaku(String commentId) async {
    final normalized = commentId.trim().replaceFirst('zeluna-', '');
    if (!RegExp(r'^\d+$').hasMatch(normalized)) {
      throw const AccountException('这条弹幕已经不存在了');
    }
    final token = await _requiredToken();
    final response = await _send(
      'DELETE',
      '',
      token: token,
      uri: _danmakuEndpoint(normalized),
    );
    _decodeSuccess(response);
  }

  Future<LocalAccount> _persistSession(Map<String, dynamic> body) async {
    final token = body['access_token']?.toString().trim() ?? '';
    if (token.isEmpty) throw const AccountException('登录没有完成，请重试');
    final account = _accountFrom(body['user']);
    try {
      await _persistCredentialsBody(body);
    } catch (_) {
      throw const AccountException('登录信息保存失败，请重启应用后重试');
    }
    return account;
  }

  Future<void> _persistCredentialsBody(Map<String, dynamic> body) async {
    final token = body['access_token']?.toString().trim() ?? '';
    if (token.isEmpty) {
      throw const AccountException('登录没有完成，请重试');
    }
    final session = body['session'];
    final sessionMap = session is Map
        ? session.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final refreshToken = body['refresh_token']?.toString().trim();
    final store = _credentialStore;
    if (store != null) {
      if (refreshToken == null || refreshToken.isEmpty) {
        throw const AccountException('登录没有完成，请重试');
      }
      await store.writeCredentials(
        CloudAccountCredentials(
          accessToken: token,
          refreshToken: refreshToken,
          sessionId: sessionMap['session_id']?.toString(),
          deviceId: sessionMap['device_id']?.toString(),
          deviceName: sessionMap['device_name']?.toString(),
          platform: sessionMap['platform']?.toString(),
          accessExpiresAt: _dateTimeFromSeconds(
            sessionMap['access_expires_at'],
          ),
          refreshExpiresAt: _dateTimeFromSeconds(
            sessionMap['refresh_expires_at'],
          ),
        ),
      );
      return;
    }
    await _tokenStore.write(token);
  }

  Map<String, dynamic> _decodeJsonBody(http.Response response) {
    if (response.bodyBytes.isEmpty) {
      throw const AccountException('账号服务暂时无法使用，请稍后重试');
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException();
      return decoded.cast<String, dynamic>();
    } on Object {
      throw const AccountException('账号服务暂时无法使用，请稍后重试');
    }
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

  Future<String?> _refreshSingleFlight(String failedAccessToken) {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final future = _refresh(failedAccessToken);
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
  }

  Future<String?> _refresh(String failedAccessToken) async {
    final credentials = await _readCredentials();
    final refreshToken = credentials?.refreshToken?.trim() ?? '';
    if (credentials == null || refreshToken.isEmpty) return null;
    if (credentials.accessToken != failedAccessToken) {
      return credentials.accessToken;
    }
    try {
      final response = await _sendRaw(
        'POST',
        'refresh',
        body: {'refresh_token': refreshToken},
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _tokenStore.delete();
        return null;
      }
      final body = _decodeJsonBody(response);
      await _persistCredentialsBody(body);
      return body['access_token']?.toString().trim();
    } on Object {
      await _tokenStore.delete();
      return null;
    }
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    Uri? uri,
    int maxResponseBytes = accountBackendDefaultMaxResponseBytes,
  }) async {
    final response = await _sendRaw(
      method,
      path,
      body: body,
      token: token,
      uri: uri,
      maxResponseBytes: maxResponseBytes,
    );
    if (response.statusCode != 401 || token == null || path == 'refresh') {
      return response;
    }
    final refreshed = await _refreshSingleFlight(token);
    if (refreshed == null || refreshed == token) return response;
    return _sendRaw(
      method,
      path,
      body: body,
      token: refreshed,
      uri: uri,
      maxResponseBytes: maxResponseBytes,
    );
  }

  Future<http.Response> _sendRaw(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    Uri? uri,
    int maxResponseBytes = accountBackendDefaultMaxResponseBytes,
  }) async {
    try {
      final request = http.Request(method, uri ?? _endpoint(path));
      request.headers.addAll({
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json; charset=utf-8',
        if (token != null) 'Authorization': 'Bearer $token',
      });
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(requestTimeout);
      final declaredLength = streamed.contentLength;
      if (declaredLength != null && declaredLength > maxResponseBytes) {
        throw const AccountException('数据读取失败，请稍后重试');
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
      throw const AccountException('网络连接不安全，请检查网络后重试');
    }
  }

  Map<String, dynamic> _decodeSuccess(http.Response response) {
    Map<String, dynamic> body = const {};
    if (response.bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map) body = decoded.cast<String, dynamic>();
      } catch (_) {
        throw const AccountException('账号服务暂时无法使用，请稍后重试');
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    if (response.statusCode == 401) {
      unawaited(_tokenStore.delete().onError((_, _) {}));
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
    if (value is! Map) throw const AccountException('账号信息读取失败，请稍后重试');
    final json = value.cast<Object?, Object?>();
    final id = json['id']?.toString().trim() ?? '';
    final email = json['email']?.toString().trim().toLowerCase() ?? '';
    final nickname = json['nickname']?.toString().trim() ?? '';
    if (id.isEmpty || email.isEmpty || nickname.isEmpty) {
      throw const AccountException('账号信息读取失败，请稍后重试');
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

  Future<Map<String, String>> _deviceMetadata() async {
    final store = _tokenStore;
    if (store is! SecureCloudAccountTokenStore) return const {};
    final deviceId = await store.readOrCreateDeviceId();
    return {
      'device_id': deviceId,
      'device_name': _deviceName,
      'platform': _platformName,
    };
  }

  Future<CloudAccountCredentials?> _readCredentials() async {
    final store = _credentialStore;
    if (store == null) return null;
    try {
      return await store.readCredentials();
    } catch (_) {
      return null;
    }
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

  Uri _danmakuEndpoint([String? commentId]) => _baseUri.replace(
    pathSegments: [
      ..._baseUri.pathSegments.where((segment) => segment.isNotEmpty),
      'api',
      'v3',
      'danmaku',
      ?commentId,
    ],
  );

  DanmakuComment _danmakuCommentFrom(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final text = json['text']?.toString().trim() ?? '';
    final seconds = switch (json['time_seconds']) {
      final num value => value.toDouble(),
      _ => null,
    };
    final color = switch (json['color']) {
      final num value => value.toInt(),
      _ => null,
    };
    if (id.isEmpty ||
        text.isEmpty ||
        seconds == null ||
        !seconds.isFinite ||
        seconds < 0 ||
        color == null ||
        color < 0 ||
        color > 0xFFFFFF) {
      throw const AccountException('弹幕加载失败，请稍后重试');
    }
    final author = json['author'];
    final authorMap = author is Map
        ? author.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    return DanmakuComment(
      id: 'zeluna-$id',
      provider: 'Zeluna',
      time: Duration(milliseconds: (seconds * 1000).round()),
      mode: switch (json['mode']?.toString()) {
        'top' => DanmakuMode.top,
        'bottom' => DanmakuMode.bottom,
        _ => DanmakuMode.scroll,
      },
      color: color,
      text: text,
      authorName: authorMap['display_name']?.toString().trim() ?? '',
      isMine: authorMap['is_mine'] == true,
    );
  }

  @override
  Future<CloudSyncPushResult> push(List<CloudSyncMutation> mutations) async {
    if (mutations.isEmpty || mutations.length > 100) {
      throw const CloudSyncProtocolException();
    }
    final response = await _sendSync(
      'POST',
      _syncEndpoint('push'),
      body: {'mutations': mutations.map((item) => item.toJson()).toList()},
    );
    try {
      return CloudSyncPushResult.fromJson(_decodeSyncSuccess(response));
    } on FormatException {
      throw const CloudSyncProtocolException();
    }
  }

  @override
  Future<CloudSyncPullResult> pull({
    required int afterRevision,
    int limit = 200,
  }) async {
    if (afterRevision < 0 || limit < 1 || limit > 500) {
      throw const CloudSyncProtocolException();
    }
    final endpoint = _syncEndpoint('pull').replace(
      queryParameters: {'after_revision': '$afterRevision', 'limit': '$limit'},
    );
    final response = await _sendSync('GET', endpoint);
    try {
      return CloudSyncPullResult.fromJson(_decodeSyncSuccess(response));
    } on FormatException {
      throw const CloudSyncProtocolException();
    }
  }

  Future<http.Response> _sendSync(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
  }) async {
    final token = await _readToken();
    if (token == null) throw const CloudSyncAuthenticationException();
    try {
      return await _send(method, '', body: body, token: token, uri: uri);
    } on AccountException {
      throw const CloudSyncUnavailableException();
    }
  }

  Map<String, dynamic> _decodeSyncSuccess(http.Response response) {
    if (response.statusCode == 401) {
      unawaited(_tokenStore.delete().onError((_, _) {}));
      throw const CloudSyncAuthenticationException();
    }
    if (response.statusCode == 408 ||
        response.statusCode == 429 ||
        response.statusCode >= 500) {
      throw const CloudSyncUnavailableException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const CloudSyncProtocolException();
    }
    if (response.bodyBytes.isEmpty) {
      throw const CloudSyncProtocolException();
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException();
      return decoded.cast<String, dynamic>();
    } catch (_) {
      throw const CloudSyncProtocolException();
    }
  }

  Uri _syncEndpoint(String path) => _baseUri.replace(
    pathSegments: [
      ..._baseUri.pathSegments.where((segment) => segment.isNotEmpty),
      'api',
      'v1',
      'sync',
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
      throw const AccountException('数据读取失败，请稍后重试');
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
