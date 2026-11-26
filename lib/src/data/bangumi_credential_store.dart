import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum BangumiCredentialHealth {
  notConfigured,
  ready,
  expiringSoon,
  expired,
  rejected,
}

class BangumiCredentialStatus {
  const BangumiCredentialStatus({
    required this.health,
    this.savedAt,
    this.expiresAt,
    this.rejectedAt,
    this.userId,
    this.username,
    this.displayName,
  });

  const BangumiCredentialStatus.notConfigured()
    : this(health: BangumiCredentialHealth.notConfigured);

  final BangumiCredentialHealth health;
  final DateTime? savedAt;
  final DateTime? expiresAt;
  final DateTime? rejectedAt;
  final String? userId;
  final String? username;
  final String? displayName;

  bool get isConfigured => health != BangumiCredentialHealth.notConfigured;

  bool get canAuthenticate =>
      health == BangumiCredentialHealth.ready ||
      health == BangumiCredentialHealth.expiringSoon;

  int? remainingDays(DateTime now) {
    final expiry = expiresAt;
    if (expiry == null) return null;
    final remaining = expiry.difference(now.toUtc());
    if (remaining.isNegative) return 0;
    return (remaining.inHours / 24).ceil();
  }
}

abstract interface class BangumiCredentialBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterSecureBangumiCredentialBackend
    implements BangumiCredentialBackend {
  const FlutterSecureBangumiCredentialBackend({
    this.storage = const FlutterSecureStorage(),
  });

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

class BangumiCredentialStore {
  BangumiCredentialStore({
    BangumiCredentialBackend? backend,
    DateTime Function()? clock,
    this.validity = const Duration(days: 365),
  }) : _backend = backend ?? const FlutterSecureBangumiCredentialBackend(),
       _clock = clock ?? DateTime.now;

  static const _recordPrefix = 'anime.bangumi.credential.v1';
  static const _guestScope = 'guest';
  static const _expiringSoonWindow = Duration(days: 30);
  static Future<void> _mutationQueue = Future<void>.value();

  final BangumiCredentialBackend _backend;
  final DateTime Function() _clock;
  final Duration validity;

  Future<String?> readAccessToken({String? accountId}) async {
    final record = await _readRecord(accountId);
    if (record == null || !_statusFor(record).canAuthenticate) return null;
    final token = record.token.trim();
    return token.isEmpty ? null : token;
  }

  Future<BangumiCredentialStatus> readStatus({String? accountId}) async {
    final record = await _readRecord(accountId);
    return record == null
        ? const BangumiCredentialStatus.notConfigured()
        : _statusFor(record);
  }

  Future<BangumiCredentialStatus> saveToken({
    String? accountId,
    required String token,
    String? userId,
    String? username,
    String? displayName,
  }) async {
    final normalized = token.trim();
    if (normalized.length < 16 ||
        normalized.length > 512 ||
        RegExp(r'\s').hasMatch(normalized)) {
      throw const FormatException('令牌格式不正确');
    }
    return _serializeMutation(() async {
      final savedAt = _clock().toUtc();
      final record = _BangumiCredentialRecord(
        token: normalized,
        savedAt: savedAt,
        expiresAt: savedAt.add(validity),
        userId: _clean(userId),
        username: _clean(username),
        displayName: _clean(displayName),
      );
      final scope = _scopeFor(accountId);
      final key = _recordKey(scope);
      await _backend.write(key, jsonEncode(record.toJson()));
      return _statusFor(record);
    });
  }

  Future<void> markRejected({String? accountId}) =>
      _serializeMutation(() async {
        final record = await _readRecord(accountId);
        if (record == null || record.rejectedAt != null) return;
        await _markRecordRejected(accountId, record);
      });

  Future<void> markRejectedToken({
    String? accountId,
    required String rejectedToken,
  }) => _serializeMutation(() async {
    final record = await _readRecord(accountId);
    if (record == null ||
        record.rejectedAt != null ||
        record.token != rejectedToken) {
      return;
    }
    await _markRecordRejected(accountId, record);
  });

  Future<void> _markRecordRejected(
    String? accountId,
    _BangumiCredentialRecord record,
  ) async {
    final next = record.copyWith(rejectedAt: _clock().toUtc());
    final scope = _scopeFor(accountId);
    await _backend.write(_recordKey(scope), jsonEncode(next.toJson()));
  }

  Future<void> clearAccount(String? accountId) => _serializeMutation(() async {
    final scope = _scopeFor(accountId);
    await _backend.delete(_recordKey(scope));
  });

  Future<void> migrateGuestToAccount(String accountId) => _serializeMutation(
    () async {
      final targetScope = _scopeFor(accountId);
      if (targetScope == _guestScope) return;
      final sourceKey = '$_recordPrefix.$_guestScope';
      final targetKey = '$_recordPrefix.$targetScope';
      final source = await _backend.read(sourceKey);
      if (source == null || source.trim().isEmpty) return;
      _decodeRecord(source);
      final target = await _backend.read(targetKey);
      if (target == null || target.trim().isEmpty) {
        await _backend.write(targetKey, source);
        final written = await _backend.read(targetKey);
        if (written != source) {
          throw const FormatException('Bangumi credential migration failed');
        }
        _decodeRecord(written!);
      } else {
        _decodeRecord(target);
      }
      await _backend.delete(sourceKey);
      if (await _backend.read(sourceKey) != null) {
        throw const FormatException('Bangumi guest credential was not removed');
      }
    },
  );

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    final previous = _mutationQueue;
    _mutationQueue = previous.then<void>(
      (_) async {
        try {
          result.complete(await operation());
        } catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        }
      },
      onError: (_, _) async {
        try {
          result.complete(await operation());
        } catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        }
      },
    );
    return result.future;
  }

  static String _recordKey(String scope) => '$_recordPrefix.$scope';

  Future<_BangumiCredentialRecord?> _readRecord(String? accountId) async {
    final scope = _scopeFor(accountId);
    final raw = await _backend.read(_recordKey(scope));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final record = _BangumiCredentialRecord.fromJson(
        decoded.cast<String, dynamic>(),
      );
      return record;
    } catch (_) {
      return null;
    }
  }

  BangumiCredentialStatus _statusFor(_BangumiCredentialRecord record) {
    final now = _clock().toUtc();
    final health = record.rejectedAt != null
        ? BangumiCredentialHealth.rejected
        : !record.expiresAt.isAfter(now)
        ? BangumiCredentialHealth.expired
        : record.expiresAt.difference(now) <= _expiringSoonWindow
        ? BangumiCredentialHealth.expiringSoon
        : BangumiCredentialHealth.ready;
    return BangumiCredentialStatus(
      health: health,
      savedAt: record.savedAt,
      expiresAt: record.expiresAt,
      rejectedAt: record.rejectedAt,
      userId: record.userId,
      username: record.username,
      displayName: record.displayName,
    );
  }

  static String _scopeFor(String? accountId) {
    final normalized = accountId?.trim() ?? '';
    if (normalized.isEmpty) return _guestScope;
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 24);
  }

  static String? _clean(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  static _BangumiCredentialRecord _decodeRecord(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Invalid Bangumi credential record');
    }
    return _BangumiCredentialRecord.fromJson(decoded.cast<String, dynamic>());
  }
}

class _BangumiCredentialRecord {
  const _BangumiCredentialRecord({
    required this.token,
    required this.savedAt,
    required this.expiresAt,
    this.rejectedAt,
    this.userId,
    this.username,
    this.displayName,
  });

  final String token;
  final DateTime savedAt;
  final DateTime expiresAt;
  final DateTime? rejectedAt;
  final String? userId;
  final String? username;
  final String? displayName;

  _BangumiCredentialRecord copyWith({DateTime? rejectedAt}) {
    return _BangumiCredentialRecord(
      token: token,
      savedAt: savedAt,
      expiresAt: expiresAt,
      rejectedAt: rejectedAt ?? this.rejectedAt,
      userId: userId,
      username: username,
      displayName: displayName,
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'savedAt': savedAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    if (rejectedAt != null) 'rejectedAt': rejectedAt!.toIso8601String(),
    if (userId != null) 'userId': userId,
    if (username != null) 'username': username,
    if (displayName != null) 'displayName': displayName,
  };

  factory _BangumiCredentialRecord.fromJson(Map<String, dynamic> json) {
    final token = json['token']?.toString().trim() ?? '';
    final savedAt = DateTime.tryParse(json['savedAt']?.toString() ?? '');
    final expiresAt = DateTime.tryParse(json['expiresAt']?.toString() ?? '');
    if (token.isEmpty || savedAt == null || expiresAt == null) {
      throw const FormatException('Invalid Bangumi credential record');
    }
    return _BangumiCredentialRecord(
      token: token,
      savedAt: savedAt.toUtc(),
      expiresAt: expiresAt.toUtc(),
      rejectedAt: DateTime.tryParse(
        json['rejectedAt']?.toString() ?? '',
      )?.toUtc(),
      userId: BangumiCredentialStore._clean(json['userId']?.toString()),
      username: BangumiCredentialStore._clean(json['username']?.toString()),
      displayName: BangumiCredentialStore._clean(
        json['displayName']?.toString(),
      ),
    );
  }
}
