import 'package:anime/src/accounts/cloud_account_repository.dart';
import 'package:anime/src/accounts/local_account_repository.dart';

class FakeCloudAccountService implements CloudAccountService {
  final _accounts = <String, LocalAccount>{};
  final _passwords = <String, String>{};
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
