import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum TmdbCredentialHealth { notConfigured, ready, rejected }

class TmdbCredentialStatus {
  const TmdbCredentialStatus({
    required this.health,
    this.savedAt,
    this.rejectedAt,
  });

  const TmdbCredentialStatus.notConfigured()
    : this(health: TmdbCredentialHealth.notConfigured);

  final TmdbCredentialHealth health;
  final DateTime? savedAt;
  final DateTime? rejectedAt;

  bool get isConfigured => health != TmdbCredentialHealth.notConfigured;

  bool get canAuthenticate => health == TmdbCredentialHealth.ready;
}

abstract interface class TmdbCredentialBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterSecureTmdbCredentialBackend implements TmdbCredentialBackend {
  const FlutterSecureTmdbCredentialBackend({
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

class TmdbCredentialStore {
  TmdbCredentialStore({
    TmdbCredentialBackend? backend,
    DateTime Function()? clock,
  }) : _backend = backend ?? const FlutterSecureTmdbCredentialBackend(),
       _clock = clock ?? DateTime.now;

  static const _recordPrefix = 'anime.tmdb.credential.v1';
  static const _rejectionPrefix = 'anime.tmdb.credential-rejection.v1';
  static const _guestScope = 'guest';
  static final Random _secureRandom = Random.secure();

  final TmdbCredentialBackend _backend;
  final DateTime Function() _clock;
  Future<void> _mutationQueue = Future<void>.value();

  Future<String?> readAccessToken({String? accountId}) async {
    final record = await _readRecord(accountId);
    if (record == null) return null;
    final rejection = await _readRejection(accountId);
    if (!_statusFor(record, rejection).canAuthenticate) return null;
    final token = record.token.trim();
    return token.isEmpty ? null : token;
  }

  Future<TmdbCredentialStatus> readStatus({String? accountId}) async {
    final record = await _readRecord(accountId);
    if (record == null) return const TmdbCredentialStatus.notConfigured();
    return _statusFor(record, await _readRejection(accountId));
  }

  Future<TmdbCredentialStatus> saveToken({
    String? accountId,
    required String token,
  }) async {
    final normalized = token.trim();
    if (!_isValidToken(normalized)) {
      throw const FormatException('TMDB token format is invalid');
    }
    return _serializeMutation(() async {
      final scope = _scopeFor(accountId);
      final record = _TmdbCredentialRecord(
        recordId: _newRecordId(),
        token: normalized,
        savedAt: _clock().toUtc(),
      );
      await _backend.write(_recordKey(scope), jsonEncode(record.toJson()));
      // The main record is written first so a failed cleanup cannot revive an
      // older rejected token. A late rejection remains harmless because it is
      // bound to the previous record id.
      await _backend.delete(_rejectionKey(scope));
      return _statusFor(record, null);
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
    _TmdbCredentialRecord record,
  ) async {
    final rejection = _TmdbCredentialRejection(
      recordId: record.recordId,
      rejectedAt: _clock().toUtc(),
    );
    await _backend.write(
      _rejectionKey(_scopeFor(accountId)),
      jsonEncode(rejection.toJson()),
    );
  }

  Future<void> clearAccount(String? accountId) => _serializeMutation(() async {
    final scope = _scopeFor(accountId);
    await _backend.delete(_recordKey(scope));
    await _backend.delete(_rejectionKey(scope));
  });

  Future<void> migrateGuestToAccount(String accountId) => _serializeMutation(
    () async {
      final targetScope = _scopeFor(accountId);
      if (targetScope == _guestScope) return;

      final sourceKey = _recordKey(_guestScope);
      final targetKey = _recordKey(targetScope);
      final sourceRejectionKey = _rejectionKey(_guestScope);
      final targetRejectionKey = _rejectionKey(targetScope);
      final source = await _backend.read(sourceKey);
      if (source == null || source.trim().isEmpty) {
        await _backend.delete(sourceRejectionKey);
        return;
      }
      final sourceRecord = _decodeRecord(source);
      final sourceRejectionRaw = await _backend.read(sourceRejectionKey);
      final sourceRejection = _tryDecodeRejection(sourceRejectionRaw);

      final target = await _backend.read(targetKey);
      var targetHasSourceRecord = false;
      if (target == null || target.trim().isEmpty) {
        await _backend.write(targetKey, source);
        final written = await _backend.read(targetKey);
        if (written != source) {
          throw const FormatException('TMDB credential migration failed');
        }
        _decodeRecord(written!);
        targetHasSourceRecord = true;
      } else {
        final targetRecord = _decodeRecord(target);
        targetHasSourceRecord = targetRecord.recordId == sourceRecord.recordId;
      }

      if (targetHasSourceRecord &&
          sourceRejection != null &&
          sourceRejection.recordId == sourceRecord.recordId) {
        await _backend.write(targetRejectionKey, sourceRejectionRaw!);
        final written = await _backend.read(targetRejectionKey);
        if (written != sourceRejectionRaw ||
            _decodeRejection(written!).recordId != sourceRecord.recordId) {
          throw const FormatException(
            'TMDB credential rejection migration failed',
          );
        }
      } else if (targetHasSourceRecord) {
        final targetRejectionRaw = await _backend.read(targetRejectionKey);
        final targetRejection = _tryDecodeRejection(targetRejectionRaw);
        if (targetRejection?.recordId != sourceRecord.recordId) {
          await _backend.delete(targetRejectionKey);
        }
      }

      await _backend.delete(sourceRejectionKey);
      if (await _backend.read(sourceRejectionKey) != null) {
        throw const FormatException(
          'TMDB guest credential rejection was not removed',
        );
      }
      await _backend.delete(sourceKey);
      if (await _backend.read(sourceKey) != null) {
        throw const FormatException('TMDB guest credential was not removed');
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

  static String _rejectionKey(String scope) => '$_rejectionPrefix.$scope';

  Future<_TmdbCredentialRecord?> _readRecord(String? accountId) async {
    final raw = await _backend.read(_recordKey(_scopeFor(accountId)));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return _decodeRecord(raw);
    } catch (_) {
      return null;
    }
  }

  Future<_TmdbCredentialRejection?> _readRejection(String? accountId) async {
    final raw = await _backend.read(_rejectionKey(_scopeFor(accountId)));
    return _tryDecodeRejection(raw);
  }

  static TmdbCredentialStatus _statusFor(
    _TmdbCredentialRecord record,
    _TmdbCredentialRejection? rejection,
  ) {
    final rejectedAt =
        record.rejectedAt ??
        (rejection?.recordId == record.recordId ? rejection?.rejectedAt : null);
    return TmdbCredentialStatus(
      health: rejectedAt == null
          ? TmdbCredentialHealth.ready
          : TmdbCredentialHealth.rejected,
      savedAt: record.savedAt,
      rejectedAt: rejectedAt,
    );
  }

  static bool _isValidToken(String token) {
    return token.length >= 32 &&
        token.length <= 2048 &&
        !RegExp(r'\s').hasMatch(token);
  }

  static String _newRecordId() {
    final bytes = List<int>.generate(
      24,
      (_) => _secureRandom.nextInt(256),
      growable: false,
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _scopeFor(String? accountId) {
    final normalized = accountId?.trim() ?? '';
    if (normalized.isEmpty) return _guestScope;
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 24);
  }

  static _TmdbCredentialRecord _decodeRecord(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Invalid TMDB credential record');
    }
    final legacyRecordId =
        'legacy-${sha256.convert(utf8.encode(raw)).toString()}';
    return _TmdbCredentialRecord.fromJson(
      decoded.cast<String, dynamic>(),
      legacyRecordId: legacyRecordId,
    );
  }

  static _TmdbCredentialRejection? _tryDecodeRejection(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return _decodeRejection(raw);
    } catch (_) {
      return null;
    }
  }

  static _TmdbCredentialRejection _decodeRejection(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Invalid TMDB credential rejection');
    }
    return _TmdbCredentialRejection.fromJson(decoded.cast<String, dynamic>());
  }
}

class _TmdbCredentialRecord {
  const _TmdbCredentialRecord({
    required this.recordId,
    required this.token,
    required this.savedAt,
    this.rejectedAt,
  });

  final String recordId;
  final String token;
  final DateTime savedAt;
  final DateTime? rejectedAt;

  Map<String, dynamic> toJson() => {
    'recordId': recordId,
    'token': token,
    'savedAt': savedAt.toIso8601String(),
    if (rejectedAt != null) 'rejectedAt': rejectedAt!.toIso8601String(),
  };

  factory _TmdbCredentialRecord.fromJson(
    Map<String, dynamic> json, {
    required String legacyRecordId,
  }) {
    final tokenRaw = json['token']?.toString() ?? '';
    final token = tokenRaw.trim();
    final savedAt = DateTime.tryParse(json['savedAt']?.toString() ?? '');
    final rejectedAtRaw = json['rejectedAt']?.toString();
    final rejectedAt = rejectedAtRaw == null
        ? null
        : DateTime.tryParse(rejectedAtRaw);
    final persistedRecordId = json['recordId']?.toString() ?? '';
    final recordId = persistedRecordId.isEmpty
        ? legacyRecordId
        : persistedRecordId;
    if (tokenRaw != token ||
        !TmdbCredentialStore._isValidToken(token) ||
        !_isValidRecordId(recordId) ||
        savedAt == null ||
        (rejectedAtRaw != null && rejectedAt == null)) {
      throw const FormatException('Invalid TMDB credential record');
    }
    return _TmdbCredentialRecord(
      recordId: recordId,
      token: token,
      savedAt: savedAt.toUtc(),
      rejectedAt: rejectedAt?.toUtc(),
    );
  }

  static bool _isValidRecordId(String value) {
    return value.length >= 16 &&
        value.length <= 128 &&
        RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(value);
  }
}

class _TmdbCredentialRejection {
  const _TmdbCredentialRejection({
    required this.recordId,
    required this.rejectedAt,
  });

  final String recordId;
  final DateTime rejectedAt;

  Map<String, dynamic> toJson() => {
    'recordId': recordId,
    'rejectedAt': rejectedAt.toIso8601String(),
  };

  factory _TmdbCredentialRejection.fromJson(Map<String, dynamic> json) {
    final recordId = json['recordId']?.toString() ?? '';
    final rejectedAt = DateTime.tryParse(json['rejectedAt']?.toString() ?? '');
    if (!_TmdbCredentialRecord._isValidRecordId(recordId) ||
        rejectedAt == null) {
      throw const FormatException('Invalid TMDB credential rejection');
    }
    return _TmdbCredentialRejection(
      recordId: recordId,
      rejectedAt: rejectedAt.toUtc(),
    );
  }
}
