import 'dart:convert';
import 'dart:math';

import 'package:hive_ce/hive.dart';

import 'password_hasher.dart';

class LocalAccount {
  const LocalAccount({
    required this.id,
    required this.email,
    required this.nickname,
    required this.createdAt,
    required this.lastLoginAt,
  });

  final String id;
  final String email;
  final String nickname;
  final DateTime createdAt;
  final DateTime lastLoginAt;

  String get shortId {
    final normalized = id.replaceAll('-', '').toUpperCase();
    return normalized.length <= 10 ? normalized : normalized.substring(0, 10);
  }

  String get avatarText {
    final text = nickname.trim();
    return text.isEmpty
        ? 'A'
        : String.fromCharCode(text.runes.first).toUpperCase();
  }

  LocalAccount copyWith({String? nickname, DateTime? lastLoginAt}) {
    return LocalAccount(
      id: id,
      email: email,
      nickname: nickname ?? this.nickname,
      createdAt: createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'nickname': nickname,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastLoginAt': lastLoginAt.toUtc().toIso8601String(),
  };

  factory LocalAccount.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now().toUtc();
    return LocalAccount(
      id: json['id']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? now,
      lastLoginAt:
          DateTime.tryParse(json['lastLoginAt']?.toString() ?? '') ?? now,
    );
  }
}

class LocalAccountSession {
  const LocalAccountSession({
    this.current,
    this.available = const [],
    this.hasPendingCleanup = false,
  });

  final LocalAccount? current;
  final List<LocalAccount> available;
  final bool hasPendingCleanup;

  bool get isSignedIn => current != null;
}

class PendingLocalAccountRegistration {
  const PendingLocalAccountRegistration({
    required this.account,
    required this.importGuestData,
  });

  final LocalAccount account;
  final bool importGuestData;
}

class PendingLocalAccountDeletion {
  const PendingLocalAccountDeletion({
    required this.accountId,
    this.taskIds = const [],
    this.paths = const [],
  });

  final String accountId;
  final List<String> taskIds;
  final List<String> paths;

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'taskIds': taskIds,
    'paths': paths,
  };

  factory PendingLocalAccountDeletion.fromJson(Map<String, dynamic> json) {
    final accountId = json['accountId']?.toString() ?? '';
    if (accountId.isEmpty) {
      throw const FormatException('Invalid pending account deletion');
    }
    return PendingLocalAccountDeletion(
      accountId: accountId,
      taskIds: _normalizedStringList(json['taskIds']),
      paths: _normalizedStringList(json['paths']),
    );
  }
}

class AccountException implements Exception {
  const AccountException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalAccountRepository {
  LocalAccountRepository(this._box);

  static const boxName = 'anime.accounts.v1';
  static const _activeAccountKey = 'activeAccountId';
  static const _pendingRegistrationKey = 'pendingRegistration';
  static const _pendingDeletionKey = 'pendingDeletion';
  static const _recordPrefix = 'account.';
  static const _passwordIterations = 120000;
  static const _maxPasswordIterations = 1000000;
  static const _passwordAlgorithm = 'pbkdf2-hmac-sha256';

  final Box<dynamic> _box;

  List<LocalAccount> listAccounts() {
    final accounts = <LocalAccount>[];
    final deletingAccountId = pendingDeletion()?.accountId;
    for (final key in _box.keys) {
      if (!key.toString().startsWith(_recordPrefix)) continue;
      final raw = _box.get(key);
      if (raw is! Map) continue;
      try {
        final account = _StoredLocalAccount.fromJson(
          raw.cast<String, dynamic>(),
        ).account;
        if (account.id.isNotEmpty &&
            account.id != deletingAccountId &&
            account.email.isNotEmpty) {
          accounts.add(account);
        }
      } catch (_) {
        // A damaged record is ignored so one account cannot block app startup.
      }
    }
    accounts.sort((a, b) => b.lastLoginAt.compareTo(a.lastLoginAt));
    return List.unmodifiable(accounts);
  }

  LocalAccount? currentAccount() {
    final id = _box.get(_activeAccountKey)?.toString() ?? '';
    if (id.isEmpty) return null;
    if (pendingDeletion()?.accountId == id) return null;
    final stored = _readStored(id);
    if (stored != null) return stored.account;
    return null;
  }

  PendingLocalAccountRegistration? pendingRegistration() {
    final raw = _box.get(_pendingRegistrationKey);
    if (raw is! Map) return null;
    try {
      final json = raw.cast<String, dynamic>();
      final stored = _StoredLocalAccount.fromJson(json);
      return PendingLocalAccountRegistration(
        account: stored.account,
        importGuestData: json['importGuestData'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  PendingLocalAccountDeletion? pendingDeletion() {
    final raw = _box.get(_pendingDeletionKey);
    if (raw is! Map) return null;
    try {
      return PendingLocalAccountDeletion.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<LocalAccount> beginRegistration({
    required String email,
    required String nickname,
    required String password,
    required bool importGuestData,
  }) async {
    validateNewAccount(email: email, nickname: nickname, password: password);
    final normalizedEmail = _validateEmail(email);
    final normalizedNickname = _validateNickname(nickname);

    final salt = _randomToken(18);
    final passwordHash = await derivePasswordHash(
      password: password,
      salt: salt,
      iterations: _passwordIterations,
    );
    if (_findByEmail(normalizedEmail) != null) {
      throw const AccountException('这个邮箱已经注册过了');
    }

    final now = DateTime.now().toUtc();
    final account = LocalAccount(
      id: _randomToken(15),
      email: normalizedEmail,
      nickname: normalizedNickname,
      createdAt: now,
      lastLoginAt: now,
    );
    final stored = _StoredLocalAccount(
      account: account,
      passwordAlgorithm: _passwordAlgorithm,
      passwordSalt: salt,
      passwordHash: passwordHash,
      passwordIterations: _passwordIterations,
    );
    await _box.put(_pendingRegistrationKey, {
      ...stored.toJson(),
      'importGuestData': importGuestData,
    });
    return account;
  }

  void validateNewAccount({
    required String email,
    required String nickname,
    required String password,
  }) {
    final normalizedEmail = _validateEmail(email);
    _validateNickname(nickname);
    _validatePassword(password);
    if (_findByEmail(normalizedEmail) != null) {
      throw const AccountException('这个邮箱已经注册过了');
    }
    if (pendingRegistration() != null) {
      throw const AccountException('上一个账号仍在完成初始化，请重启应用后再试');
    }
  }

  Future<void> completeRegistration(String accountId) async {
    final raw = _box.get(_pendingRegistrationKey);
    if (raw is! Map) throw const AccountException('待完成的账号已不存在');
    final stored = _StoredLocalAccount.fromJson(raw.cast<String, dynamic>());
    if (stored.account.id != accountId) {
      throw const AccountException('待完成的账号与当前操作不一致');
    }
    await _box.put(_recordKey(accountId), stored.toJson());
  }

  Future<void> finalizeRegistration(String accountId) async {
    final raw = _box.get(_pendingRegistrationKey);
    if (raw is! Map) return;
    final stored = _StoredLocalAccount.fromJson(raw.cast<String, dynamic>());
    if (stored.account.id != accountId) {
      throw const AccountException('待完成的账号与当前操作不一致');
    }
    if (_readStored(accountId) == null) {
      throw const AccountException('账号初始化尚未完成');
    }
    await _box.delete(_pendingRegistrationKey);
  }

  Future<LocalAccount> login({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final stored = _findByEmail(normalizedEmail);
    if (stored == null || pendingDeletion()?.accountId == stored.account.id) {
      throw const AccountException('邮箱或密码不正确');
    }
    if (!await _passwordMatches(stored, password)) {
      throw const AccountException('邮箱或密码不正确');
    }
    final account = stored.account.copyWith(
      lastLoginAt: DateTime.now().toUtc(),
    );
    var nextStored = stored.copyWith(account: account);
    if (stored.passwordIterations < _passwordIterations) {
      nextStored = await _rehash(nextStored, password);
    }
    await _box.put(_recordKey(account.id), nextStored.toJson());
    return account;
  }

  Future<LocalAccount> updateNickname(String accountId, String nickname) async {
    final stored = _readStored(accountId);
    if (stored == null) throw const AccountException('当前账号已不存在');
    final account = stored.account.copyWith(
      nickname: _validateNickname(nickname),
    );
    await _box.put(
      _recordKey(accountId),
      stored.copyWith(account: account).toJson(),
    );
    return account;
  }

  Future<void> changePassword({
    required String accountId,
    required String currentPassword,
    required String newPassword,
  }) async {
    final stored = _readStored(accountId);
    if (stored == null) throw const AccountException('当前账号已不存在');
    _validatePassword(newPassword);
    if (!await _passwordMatches(stored, currentPassword)) {
      throw const AccountException('当前密码不正确');
    }
    final salt = _randomToken(18);
    final passwordHash = await derivePasswordHash(
      password: newPassword,
      salt: salt,
      iterations: _passwordIterations,
    );
    await _box.put(
      _recordKey(accountId),
      _StoredLocalAccount(
        account: stored.account,
        passwordAlgorithm: _passwordAlgorithm,
        passwordSalt: salt,
        passwordHash: passwordHash,
        passwordIterations: _passwordIterations,
      ).toJson(),
    );
  }

  Future<void> signOut() => _box.delete(_activeAccountKey);

  Future<void> setActiveAccount(String? accountId) {
    if (accountId == null) return signOut();
    if (pendingDeletion()?.accountId == accountId) {
      throw const AccountException('这个账号仍在清理，无法登录');
    }
    if (_readStored(accountId) == null) {
      throw const AccountException('要切换的账号已不存在');
    }
    return _box.put(_activeAccountKey, accountId);
  }

  Future<void> verifyAccountPassword({
    required String accountId,
    required String password,
  }) async {
    final stored = _readStored(accountId);
    if (stored == null) throw const AccountException('当前账号已不存在');
    if (!await _passwordMatches(stored, password)) {
      throw const AccountException('密码不正确，账号没有删除');
    }
  }

  Future<void> deleteAccount({
    required String accountId,
    required String password,
  }) async {
    await verifyAccountPassword(accountId: accountId, password: password);
    await deleteAccountRecord(accountId);
  }

  Future<void> deleteAccountRecord(String accountId) async {
    await _box.delete(_recordKey(accountId));
    if (_box.get(_activeAccountKey)?.toString() == accountId) {
      await _box.delete(_activeAccountKey);
    }
  }

  Future<PendingLocalAccountDeletion> beginDeletion({
    required String accountId,
    required Iterable<String> taskIds,
    required Iterable<String?> paths,
  }) async {
    if (_readStored(accountId) == null) {
      throw const AccountException('当前账号已不存在');
    }
    final existing = pendingDeletion();
    if (existing != null && existing.accountId != accountId) {
      throw const AccountException('另一个账号仍在清理，请重启应用后再试');
    }
    final pending = PendingLocalAccountDeletion(
      accountId: accountId,
      taskIds: _uniqueNonEmpty(taskIds),
      paths: _uniqueNonEmpty(paths.whereType<String>()),
    );
    await _box.put(_pendingDeletionKey, pending.toJson());
    return pending;
  }

  Future<void> completeDeletion(String accountId) async {
    final pending = pendingDeletion();
    if (pending == null) return;
    if (pending.accountId != accountId) {
      throw const AccountException('待清理账号与当前操作不一致');
    }
    await _box.delete(_pendingDeletionKey);
  }

  _StoredLocalAccount? _findByEmail(String email) {
    for (final account in _storedAccounts()) {
      if (account.account.email.toLowerCase() == email) return account;
    }
    return null;
  }

  _StoredLocalAccount? _readStored(String id) {
    final raw = _box.get(_recordKey(id));
    if (raw is! Map) return null;
    try {
      return _StoredLocalAccount.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<bool> _passwordMatches(
    _StoredLocalAccount stored,
    String password,
  ) async {
    if (stored.passwordAlgorithm != _passwordAlgorithm) return false;
    final candidate = await derivePasswordHash(
      password: password,
      salt: stored.passwordSalt,
      iterations: stored.passwordIterations,
    );
    return _constantTimeEquals(candidate, stored.passwordHash);
  }

  Future<_StoredLocalAccount> _rehash(
    _StoredLocalAccount stored,
    String password,
  ) async {
    final salt = _randomToken(18);
    final hash = await derivePasswordHash(
      password: password,
      salt: salt,
      iterations: _passwordIterations,
    );
    return _StoredLocalAccount(
      account: stored.account,
      passwordAlgorithm: _passwordAlgorithm,
      passwordSalt: salt,
      passwordHash: hash,
      passwordIterations: _passwordIterations,
    );
  }

  Iterable<_StoredLocalAccount> _storedAccounts() sync* {
    for (final key in _box.keys) {
      if (!key.toString().startsWith(_recordPrefix)) continue;
      final raw = _box.get(key);
      if (raw is! Map) continue;
      try {
        yield _StoredLocalAccount.fromJson(raw.cast<String, dynamic>());
      } catch (_) {
        // Ignore damaged records; valid accounts remain usable.
      }
    }
  }

  static String _validateEmail(String email) {
    final normalized = email.trim().toLowerCase();
    final pattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (normalized.length > 254 || !pattern.hasMatch(normalized)) {
      throw const AccountException('请输入有效的邮箱地址');
    }
    return normalized;
  }

  static String _validateNickname(String nickname) {
    final normalized = nickname.trim();
    if (normalized.runes.length < 2 || normalized.runes.length > 24) {
      throw const AccountException('昵称需要 2 到 24 个字符');
    }
    return normalized;
  }

  static void _validatePassword(String password) {
    if (password.length < 8 || password.length > 128) {
      throw const AccountException('密码需要 8 到 128 个字符');
    }
  }

  static String _recordKey(String id) => '$_recordPrefix$id';

  static String _randomToken(int byteLength) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class _StoredLocalAccount {
  const _StoredLocalAccount({
    required this.account,
    required this.passwordAlgorithm,
    required this.passwordSalt,
    required this.passwordHash,
    required this.passwordIterations,
  });

  final LocalAccount account;
  final String passwordAlgorithm;
  final String passwordSalt;
  final String passwordHash;
  final int passwordIterations;

  _StoredLocalAccount copyWith({LocalAccount? account}) {
    return _StoredLocalAccount(
      account: account ?? this.account,
      passwordAlgorithm: passwordAlgorithm,
      passwordSalt: passwordSalt,
      passwordHash: passwordHash,
      passwordIterations: passwordIterations,
    );
  }

  Map<String, dynamic> toJson() => {
    ...account.toJson(),
    'passwordAlgorithm': passwordAlgorithm,
    'passwordSalt': passwordSalt,
    'passwordHash': passwordHash,
    'passwordIterations': passwordIterations,
  };

  factory _StoredLocalAccount.fromJson(Map<String, dynamic> json) {
    final iterations = switch (json['passwordIterations']) {
      final num value => value.toInt(),
      _ => 0,
    };
    final stored = _StoredLocalAccount(
      account: LocalAccount.fromJson(json),
      passwordAlgorithm:
          json['passwordAlgorithm']?.toString() ??
          LocalAccountRepository._passwordAlgorithm,
      passwordSalt: json['passwordSalt']?.toString() ?? '',
      passwordHash: json['passwordHash']?.toString() ?? '',
      passwordIterations: iterations,
    );
    if (stored.account.id.isEmpty ||
        stored.passwordSalt.isEmpty ||
        stored.passwordHash.isEmpty ||
        stored.passwordIterations < 10000 ||
        stored.passwordIterations >
            LocalAccountRepository._maxPasswordIterations) {
      throw const FormatException('Invalid local account record');
    }
    return stored;
  }
}

bool _constantTimeEquals(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  var difference = leftBytes.length ^ rightBytes.length;
  final length = max(leftBytes.length, rightBytes.length);
  for (var index = 0; index < length; index++) {
    final leftByte = index < leftBytes.length ? leftBytes[index] : 0;
    final rightByte = index < rightBytes.length ? rightBytes[index] : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference == 0;
}

List<String> _normalizedStringList(Object? value) {
  if (value is! List) return const [];
  return _uniqueNonEmpty(value.map((item) => item.toString()));
}

List<String> _uniqueNonEmpty(Iterable<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (value.trim().isNotEmpty && seen.add(value.trim())) value.trim(),
  ];
}
