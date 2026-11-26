import 'dart:convert';
import 'dart:typed_data';

import 'package:anime/src/accounts/cloud_account_repository.dart';
import 'package:anime/src/accounts/local_account_repository.dart';

class FakeCloudAccountService implements CloudAccountService {
  final _accounts = <String, LocalAccount>{};
  final _passwords = <String, String>{};
  final _deletionDueAt = <String, DateTime>{};
  LocalAccount? _current;

  @override
  Future<LocalAccount?> restoreSession(LocalAccount? cachedAccount) async {
    _current = cachedAccount;
    if (cachedAccount != null) {
      _accounts[cachedAccount.email] = cachedAccount;
    }
    return cachedAccount;
  }

  @override
  Future<void> requestRegistrationCode(String email) async {}

  @override
  Future<void> requestPasswordResetCode(String email) async {}

  @override
  Future<LocalAccount> register({
    required String email,
    required String nickname,
    required String password,
    required String verificationCode,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (_accounts.containsKey(normalized)) {
      throw const AccountException('这个邮箱已经注册过了');
    }
    final now = DateTime.now().toUtc();
    final account = LocalAccount(
      id: 'cloud-${normalized.hashCode.abs()}',
      email: normalized,
      nickname: nickname.trim(),
      createdAt: now,
      lastLoginAt: now,
      cloudAuthenticated: true,
    );
    _accounts[normalized] = account;
    _passwords[normalized] = password;
    _current = account;
    return account;
  }

  @override
  Future<LocalAccount> login({
    required String email,
    required String password,
  }) async {
    final normalized = email.trim().toLowerCase();
    final account = _accounts[normalized];
    if (account == null || _passwords[normalized] != password) {
      throw const AccountException('邮箱或密码不正确');
    }
    final deletionDueAt = _deletionDueAt[normalized];
    if (deletionDueAt != null) {
      throw AccountDeletionPendingException(
        message: '账号处于删除冷静期，可在截止前撤销',
        dueAt: deletionDueAt,
        canCancel: deletionDueAt.isAfter(DateTime.now().toUtc()),
      );
    }
    _current = account.copyWith(lastLoginAt: DateTime.now().toUtc());
    _accounts[normalized] = _current!;
    return _current!;
  }

  @override
  Future<void> logout() async => _current = null;

  @override
  Future<LocalAccount> updateNickname(String nickname) async {
    final account = _current;
    if (account == null) throw const AccountException('请先登录账号');
    _current = account.copyWith(nickname: nickname.trim());
    _accounts[account.email] = _current!;
    return _current!;
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final account = _current;
    if (account == null || _passwords[account.email] != currentPassword) {
      throw const AccountException('当前密码不正确');
    }
    _passwords[account.email] = newPassword;
  }

  @override
  Future<void> verifyPassword(String password) async {
    final account = _current;
    if (account == null || _passwords[account.email] != password) {
      throw const AccountException('密码不正确，数据没有清除');
    }
  }

  @override
  Future<Uint8List> exportAccountData() async {
    final account = _current;
    if (account == null) throw const AccountException('请先登录账号');
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema_version': 1,
          'account': {'id': account.id, 'email': account.email},
        }),
      ),
    );
  }

  @override
  Future<AccountDeletionSchedule> requestAccountDeletion(
    String password,
  ) async {
    final account = _current;
    if (account == null || _passwords[account.email] != password) {
      throw const AccountException('密码不正确，账号没有进入删除流程');
    }
    final requestedAt = DateTime.now().toUtc();
    final dueAt = requestedAt.add(const Duration(days: 7));
    _deletionDueAt[account.email] = dueAt;
    _current = null;
    return AccountDeletionSchedule(requestedAt: requestedAt, dueAt: dueAt);
  }

  @override
  Future<void> cancelAccountDeletion({
    required String email,
    required String password,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (_passwords[normalized] != password) {
      throw const AccountException('邮箱或密码不正确');
    }
    final dueAt = _deletionDueAt[normalized];
    if (dueAt != null && !dueAt.isAfter(DateTime.now().toUtc())) {
      throw const AccountException('删除冷静期已经结束，无法撤销');
    }
    _deletionDueAt.remove(normalized);
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String verificationCode,
    required String newPassword,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (!_accounts.containsKey(normalized)) {
      throw const AccountException('验证码错误或已过期');
    }
    _passwords[normalized] = newPassword;
    if (_current?.email == normalized) _current = null;
  }
}
