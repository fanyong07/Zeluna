import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../sync/sync_controller.dart';
import 'cloud_account_repository.dart';
import 'local_account_repository.dart';

enum _AccountPageMode { manage, login, register, resetPassword, password }

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  final _email = TextEditingController();
  final _nickname = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _verificationCode = TextEditingController();
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmNewPassword = TextEditingController();
  final _deletePassword = TextEditingController();
  final _scrollController = ScrollController();

  _AccountPageMode _mode = _AccountPageMode.login;
  String? _boundAccountId;
  String? _message;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _nickname.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _verificationCode.dispose();
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmNewPassword.dispose();
    _deletePassword.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        _bindAccount(state.accountSession.current);
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '账号管理',
          onBack: () => safeNavigateBack(context, fallbackRoute: '/profile'),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final contentWidth = constraints.maxWidth > 980
                  ? 980.0
                  : constraints.maxWidth;
              final horizontal = contentWidth < 760 ? 14.0 : 24.0;
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: contentWidth,
                  height: constraints.maxHeight,
                  child: ListView(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(
                      horizontal,
                      6,
                      horizontal,
                      120,
                    ),
                    children: [
                      _AccountStatusCard(
                        session: state.accountSession,
                        syncStatus: state.syncStatus,
                      ),
                      if (state.accountSession.hasPendingCleanup) ...[
                        const SizedBox(height: 14),
                        _PendingCleanupNotice(
                          busy: _busy,
                          onRetry: _retryPendingCleanup,
                        ),
                      ],
                      const SizedBox(height: 14),
                      if (_error != null)
                        _MessageBanner(
                          message: _error!,
                          color: Colors.redAccent,
                        ),
                      if (_message != null)
                        _MessageBanner(
                          message: _message!,
                          color: Colors.greenAccent,
                        ),
                      if (_error != null || _message != null)
                        const SizedBox(height: 14),
                      if (state.accountSession.isSignedIn &&
                          _mode == _AccountPageMode.manage)
                        _buildManage(state)
                      else if (_mode == _AccountPageMode.register)
                        _buildRegister(state)
                      else if (_mode == _AccountPageMode.resetPassword)
                        _buildResetPassword(state)
                      else if (_mode == _AccountPageMode.password &&
                          state.accountSession.isSignedIn)
                        _buildChangePassword()
                      else
                        _buildLogin(state),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildManage(AnimeState state) {
    final account = state.accountSession.current!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(
                title: '个人资料',
                subtitle: '昵称会显示在“我的”页面',
                icon: Icons.badge_outlined,
              ),
              const SizedBox(height: 18),
              _AccountTextField(
                controller: _nickname,
                label: '昵称',
                hint: '2 到 24 个字符',
                enabled: !_busy,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _saveNickname(state),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _saveNickname(state),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存昵称'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(
                title: '登录与安全',
                subtitle: '密码在云端校验，登录信息保存在系统的加密存储里',
                icon: Icons.shield_outlined,
              ),
              const SizedBox(height: 12),
              _AccountAction(
                icon: Icons.password_rounded,
                title: '修改密码',
                subtitle: '需要先验证当前密码',
                onTap: _busy
                    ? null
                    : () => _selectMode(_AccountPageMode.password),
              ),
              _AccountAction(
                icon: Icons.switch_account_outlined,
                title: '切换账号',
                subtitle: state.accountSession.available.length > 1
                    ? '本机还有 ${state.accountSession.available.length - 1} 个其他账号'
                    : '使用另一个已注册邮箱登录',
                onTap: _busy
                    ? null
                    : () {
                        _email.clear();
                        _password.clear();
                        _selectMode(_AccountPageMode.login);
                      },
              ),
              _AccountAction(
                icon: Icons.person_add_alt_1_outlined,
                title: '创建新账号',
                subtitle: '新账号拥有独立的收藏、追番、历史和偏好',
                onTap: _busy
                    ? null
                    : () {
                        _clearCredentialFields();
                        _selectMode(_AccountPageMode.register);
                      },
              ),
              _AccountAction(
                icon: Icons.download_outlined,
                title: '导出我的账号数据',
                subtitle: '保存为 JSON，包含云端资料、收藏、历史与本人发布内容',
                onTap: _busy ? null : _exportAccountData,
              ),
              _AccountAction(
                icon: Icons.logout_rounded,
                title: '退出登录',
                subtitle: '账号数据会保留，下次登录可继续使用',
                color: Colors.orangeAccent,
                onTap: _busy ? null : _signOut,
              ),
              _AccountAction(
                icon: Icons.delete_forever_outlined,
                title: '清除此设备的账号数据',
                subtitle: '云端账号会保留，本机收藏与历史将被删除',
                color: Colors.redAccent,
                onTap: _busy ? null : () => _confirmDeleteAccount(account),
              ),
              _AccountAction(
                icon: Icons.person_off_outlined,
                title: '永久删除云端账号',
                subtitle: '7 天内可撤销；私有数据删除，公开内容匿名保留',
                color: Colors.redAccent,
                onTap: _busy
                    ? null
                    : () => _confirmCloudAccountDeletion(account),
              ),
            ],
          ),
        ),
        if (state.accountSession.available.length > 1) ...[
          const SizedBox(height: 14),
          _KnownAccountsCard(
            accounts: state.accountSession.available,
            currentId: account.id,
            onSelected: _prepareLogin,
          ),
        ],
      ],
    );
  }

  Widget _buildLogin(AnimeState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(
                title: state.accountSession.isSignedIn ? '切换账号' : '登录',
                subtitle: '使用邮箱和密码登录云端账号',
                icon: Icons.login_rounded,
              ),
              const SizedBox(height: 18),
              _AccountTextField(
                controller: _email,
                label: '邮箱',
                hint: 'name@example.com',
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.email,
                ],
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _password,
                label: '密码',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _login(),
                suffixIcon: _passwordVisibilityButton(),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _login,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_rounded),
                    label: Text(_busy ? '正在验证' : '登录'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            _clearCredentialFields();
                            _selectMode(_AccountPageMode.register);
                          },
                    child: const Text('创建新账号'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            _verificationCode.clear();
                            _newPassword.clear();
                            _confirmNewPassword.clear();
                            _selectMode(_AccountPageMode.resetPassword);
                          },
                    child: const Text('忘记密码'),
                  ),
                  if (state.accountSession.isSignedIn)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () =>
                                _returnToManage(state.accountSession.current!),
                      child: const Text('返回当前账号'),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (state.accountSession.available.isNotEmpty) ...[
          const SizedBox(height: 14),
          _KnownAccountsCard(
            accounts: state.accountSession.available,
            currentId: state.accountSession.current?.id,
            onSelected: _prepareLogin,
          ),
        ],
        const SizedBox(height: 14),
        const _CloudAccountNotice(),
      ],
    );
  }

  Widget _buildRegister(AnimeState state) {
    final firstAccount = state.accountSession.available.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(
                title: '创建账号',
                subtitle: '通过邮箱验证码创建云端账号',
                icon: Icons.person_add_alt_1_rounded,
              ),
              const SizedBox(height: 18),
              _AccountTextField(
                controller: _nickname,
                label: '昵称',
                hint: '2 到 24 个字符',
                enabled: !_busy,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _email,
                label: '邮箱',
                hint: 'name@example.com',
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [
                  AutofillHints.newUsername,
                  AutofillHints.email,
                ],
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: _AccountTextField(
                      controller: _verificationCode,
                      label: '邮箱验证码',
                      hint: '6 位数字',
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: OutlinedButton(
                      onPressed: _busy ? null : _requestRegistrationCode,
                      child: const Text('发送验证码'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _password,
                label: '密码',
                hint: '至少 8 个字符',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.next,
                suffixIcon: _passwordVisibilityButton(),
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _confirmPassword,
                label: '确认密码',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _register(),
              ),
              const SizedBox(height: 14),
              Text(
                firstAccount
                    ? '创建账号后，你现在的收藏、追番、历史和下载会转入新账号，游客空间会被清空。'
                    : '新账号会从空白资料开始，不会看到其他账号的收藏、历史和个人偏好。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.inkMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _register,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(_busy ? '正在创建' : '创建并登录'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => state.accountSession.isSignedIn
                              ? _returnToManage(state.accountSession.current!)
                              : _selectMode(_AccountPageMode.login),
                    child: Text(
                      state.accountSession.isSignedIn ? '取消' : '已有账号，去登录',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _CloudAccountNotice(),
      ],
    );
  }

  Widget _buildResetPassword(AnimeState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(
                title: '重置密码',
                subtitle: '通过注册邮箱验证身份并设置新密码',
                icon: Icons.lock_reset_rounded,
              ),
              const SizedBox(height: 18),
              _AccountTextField(
                controller: _email,
                label: '邮箱',
                hint: 'name@example.com',
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.email,
                ],
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: _AccountTextField(
                      controller: _verificationCode,
                      label: '邮箱验证码',
                      hint: '6 位数字',
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: OutlinedButton(
                      onPressed: _busy ? null : _requestPasswordResetCode,
                      child: const Text('发送验证码'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _newPassword,
                label: '新密码',
                hint: '至少 8 个字符',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.next,
                suffixIcon: _passwordVisibilityButton(),
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _confirmNewPassword,
                label: '确认新密码',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _resetPassword(),
              ),
              const SizedBox(height: 14),
              Text(
                '重置成功后，该账号在其他设备上的登录状态会全部失效，需要使用新密码重新登录。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.inkMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _resetPassword,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_reset_rounded),
                    label: Text(_busy ? '正在重置' : '确认重置'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => state.accountSession.isSignedIn
                              ? _returnToManage(state.accountSession.current!)
                              : _selectMode(_AccountPageMode.login),
                    child: Text(
                      state.accountSession.isSignedIn ? '取消' : '返回登录',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _CloudAccountNotice(),
      ],
    );
  }

  Widget _buildChangePassword() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(
                title: '修改密码',
                subtitle: '修改成功后，下次登录请使用新密码',
                icon: Icons.password_rounded,
              ),
              const SizedBox(height: 18),
              _AccountTextField(
                controller: _currentPassword,
                label: '当前密码',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.next,
                suffixIcon: _passwordVisibilityButton(),
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _newPassword,
                label: '新密码',
                hint: '至少 8 个字符',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              _AccountTextField(
                controller: _confirmNewPassword,
                label: '确认新密码',
                enabled: !_busy,
                obscureText: !_showPassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _changePassword(),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _changePassword,
                    icon: const Icon(Icons.check_rounded),
                    label: Text(_busy ? '正在修改' : '确认修改'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            final account = ref
                                .read(animeControllerProvider)
                                .value
                                ?.accountSession
                                .current;
                            if (account != null) _returnToManage(account);
                          },
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconButton _passwordVisibilityButton() {
    return IconButton(
      tooltip: _showPassword ? '隐藏密码' : '显示密码',
      onPressed: () => setState(() => _showPassword = !_showPassword),
      icon: Icon(
        _showPassword
            ? Icons.visibility_off_outlined
            : Icons.visibility_outlined,
      ),
    );
  }

  void _bindAccount(LocalAccount? account) {
    final nextId = account?.id;
    if (_boundAccountId == nextId) return;
    _boundAccountId = nextId;
    if (account != null) {
      _nickname.text = account.nickname;
      _email.text = account.email;
      _mode = _AccountPageMode.manage;
    } else {
      _nickname.clear();
      _email.clear();
      _mode = _AccountPageMode.login;
    }
  }

  void _selectMode(_AccountPageMode mode) {
    setState(() {
      _mode = mode;
      _error = null;
      _message = null;
    });
  }

  void _prepareLogin(LocalAccount account) {
    setState(() {
      _email.text = account.email;
      _password.clear();
      _mode = _AccountPageMode.login;
      _error = null;
      _message = null;
    });
  }

  void _returnToManage(LocalAccount account) {
    _clearPasswords();
    setState(() {
      _nickname.text = account.nickname;
      _email.text = account.email;
      _mode = _AccountPageMode.manage;
      _error = null;
      _message = null;
    });
  }

  Future<void> _login() async {
    if (_busy) return;
    final email = _email.text;
    final password = _password.text;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await ref
          .read(animeControllerProvider.notifier)
          .loginAccount(email: email, password: password);
      if (!mounted) return;
      _clearPasswords();
      setState(() {
        _busy = false;
        _mode = _AccountPageMode.manage;
        _message = '登录成功，已切换到该账号';
      });
      _revealMessage();
    } on AccountDeletionPendingException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (!error.canCancel) {
        setState(() => _error = error.message);
        _revealMessage();
        return;
      }
      final shouldCancel = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('账号正在删除冷静期'),
          content: Text(
            '账号计划于 ${_formatDeletionDeadline(error.dueAt)} 永久删除。'
            '截止前可以撤销，撤销后会立即恢复登录。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('暂不撤销'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('撤销删除并登录'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (shouldCancel != true) {
        setState(() => _message = '账号仍处于删除冷静期');
        _revealMessage();
        return;
      }
      setState(() => _busy = true);
      try {
        await ref
            .read(animeControllerProvider.notifier)
            .cancelCloudAccountDeletionAndLogin(
              email: email,
              password: password,
            );
        if (!mounted) return;
        _clearPasswords();
        setState(() {
          _busy = false;
          _mode = _AccountPageMode.manage;
          _message = '账号删除已撤销，登录已恢复';
        });
        _revealMessage();
      } on AccountException catch (cancelError) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = cancelError.message;
        });
        _revealMessage();
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = '撤销没有完成，请稍后重试';
        });
        _revealMessage();
      }
    } on AccountException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
      _revealMessage();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '操作没有完成，请稍后重试';
      });
      _revealMessage();
    }
  }

  Future<void> _register() async {
    if (_password.text != _confirmPassword.text) {
      setState(() {
        _error = '两次输入的密码不一致';
        _message = null;
      });
      return;
    }
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .registerAccount(
            email: _email.text,
            nickname: _nickname.text,
            password: _password.text,
            verificationCode: _verificationCode.text,
          ),
      success: '账号已创建并登录',
      successMode: _AccountPageMode.manage,
      clearPasswords: true,
    );
  }

  Future<void> _requestRegistrationCode() async {
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .requestRegistrationCode(_email.text),
      success: '验证码已发送，请检查邮箱（10 分钟内有效）',
      successMode: _AccountPageMode.register,
    );
  }

  Future<void> _requestPasswordResetCode() async {
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .requestPasswordResetCode(_email.text),
      success: '验证码已发送，请检查邮箱（10 分钟内有效）',
      successMode: _AccountPageMode.resetPassword,
    );
  }

  Future<void> _resetPassword() async {
    if (_newPassword.text != _confirmNewPassword.text) {
      setState(() {
        _error = '两次输入的新密码不一致';
        _message = null;
      });
      return;
    }
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .resetAccountPassword(
            email: _email.text,
            verificationCode: _verificationCode.text,
            newPassword: _newPassword.text,
          ),
      success: '密码已重置，请使用新密码登录',
      successMode: _AccountPageMode.login,
      clearPasswords: true,
    );
  }

  Future<void> _saveNickname(AnimeState state) async {
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .updateProfile(state.profile.copyWith(nickname: _nickname.text)),
      success: '昵称已更新',
      successMode: _AccountPageMode.manage,
    );
  }

  Future<void> _changePassword() async {
    if (_newPassword.text != _confirmNewPassword.text) {
      setState(() {
        _error = '两次输入的新密码不一致';
        _message = null;
      });
      return;
    }
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .changeAccountPassword(
            currentPassword: _currentPassword.text,
            newPassword: _newPassword.text,
          ),
      success: '密码已修改',
      successMode: _AccountPageMode.manage,
      clearPasswords: true,
    );
  }

  Future<void> _signOut() async {
    await _runAccountAction(
      action: () => ref.read(animeControllerProvider.notifier).signOutAccount(),
      success: '已退出登录，当前进入游客空间',
      successMode: _AccountPageMode.login,
      clearPasswords: true,
    );
  }

  Future<void> _retryPendingCleanup() async {
    final signedIn = ref
        .read(animeControllerProvider)
        .value
        ?.accountSession
        .isSignedIn;
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .retryPendingAccountCleanup(),
      success: '上次删除的账号数据已清理完成',
      successMode: signedIn == true
          ? _AccountPageMode.manage
          : _AccountPageMode.login,
    );
  }

  Future<void> _confirmDeleteAccount(LocalAccount account) async {
    _deletePassword.clear();
    final confirmedPassword = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除此设备的账号数据？'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将删除“${account.nickname}”保存在此设备上的收藏、历史、偏好、下载记录和私密源配置，并退出登录。云端账号不会被删除。',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _deletePassword,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onSubmitted: (value) {
                  if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
                },
                decoration: const InputDecoration(labelText: '输入当前密码确认'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              if (_deletePassword.text.isNotEmpty) {
                Navigator.of(dialogContext).pop(_deletePassword.text);
              }
            },
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    _deletePassword.clear();
    if (confirmedPassword == null || confirmedPassword.isEmpty || !mounted) {
      return;
    }
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .deleteCurrentAccount(password: confirmedPassword),
      success: '此设备上的账号数据已清除，云端账号仍然保留',
      successMode: _AccountPageMode.login,
      clearPasswords: true,
    );
  }

  Future<void> _confirmCloudAccountDeletion(LocalAccount account) async {
    _deletePassword.clear();
    final confirmedPassword = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('永久删除云端账号？'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('“${account.nickname}”会立即冻结并退出所有设备。'),
              const SizedBox(height: 10),
              const Text(
                '• 7 天内可使用邮箱和密码登录并撤销\n'
                '• 期满删除云端收藏、历史、互动和账号资料\n'
                '• 帖子、评论、弹幕及其图片会匿名保留\n'
                '• 此设备上的本地数据不会自动删除',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _deletePassword,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onSubmitted: (value) {
                  if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
                },
                decoration: const InputDecoration(labelText: '输入当前密码确认'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              if (_deletePassword.text.isNotEmpty) {
                Navigator.of(dialogContext).pop(_deletePassword.text);
              }
            },
            child: const Text('进入 7 天冷静期'),
          ),
        ],
      ),
    );
    _deletePassword.clear();
    if (confirmedPassword == null || confirmedPassword.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final schedule = await ref
          .read(animeControllerProvider.notifier)
          .requestCloudAccountDeletion(password: confirmedPassword);
      if (!mounted) return;
      _clearPasswords();
      setState(() {
        _busy = false;
        _mode = _AccountPageMode.login;
        _message =
            '删除申请已提交，计划于 ${_formatDeletionDeadline(schedule.dueAt)} 完成；截止前可登录撤销';
      });
      _revealMessage();
    } on AccountException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
      _revealMessage();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '删除申请没有完成，请稍后重试';
      });
      _revealMessage();
    }
  }

  Future<void> _exportAccountData() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final bytes = await ref
          .read(animeControllerProvider.notifier)
          .exportCurrentAccountData();
      final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      final savedPath = await FilePicker.saveFile(
        dialogTitle: '导出 Zeluna 账号数据',
        fileName: 'zeluna-account-data-$day.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = kIsWeb || savedPath != null ? '账号数据已导出' : '已取消导出';
      });
      _revealMessage();
    } on AccountException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
      _revealMessage();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '无法保存账号数据，请检查存储权限后重试';
      });
      _revealMessage();
    }
  }

  Future<void> _runAccountAction({
    required Future<void> Function() action,
    required String success,
    required _AccountPageMode successMode,
    bool clearPasswords = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
      if (!mounted) return;
      if (clearPasswords) _clearPasswords();
      setState(() {
        _busy = false;
        _mode = successMode;
        _message = success;
      });
      _revealMessage();
    } on AccountException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
      _revealMessage();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '操作没有完成，请稍后重试';
      });
      _revealMessage();
    }
  }

  void _revealMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _clearPasswords() {
    _password.clear();
    _confirmPassword.clear();
    _verificationCode.clear();
    _currentPassword.clear();
    _newPassword.clear();
    _confirmNewPassword.clear();
    _deletePassword.clear();
  }

  void _clearCredentialFields() {
    _email.clear();
    _nickname.clear();
    _clearPasswords();
  }
}

String _formatDeletionDeadline(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}（本地时间）';
}

String _syncStatusLabel(SyncStatus status) => switch (status.phase) {
  SyncPhase.localOnly => '仅保存在本机',
  SyncPhase.checking => '正在检查同步',
  SyncPhase.pending =>
    status.pendingMutations == 0 ? '等待同步' : '${status.pendingMutations} 项等待同步',
  SyncPhase.synced => '已同步',
  SyncPhase.offline =>
    status.pendingMutations == 0
        ? '离线使用本机缓存'
        : '离线，${status.pendingMutations} 项待同步',
  SyncPhase.expired => '登录已失效，待重新登录同步',
  SyncPhase.error => '同步需要重试',
};

class _AccountStatusCard extends StatelessWidget {
  const _AccountStatusCard({required this.session, required this.syncStatus});

  final LocalAccountSession session;
  final SyncStatus syncStatus;

  @override
  Widget build(BuildContext context) {
    final account = session.current;
    final veryCompact = MediaQuery.sizeOf(context).width < 380;
    return AppPanel(
      borderColor: account == null ? AppColors.border : AppColors.borderBright,
      child: Row(
        children: [
          CircleAvatar(
            radius: veryCompact ? 25 : 30,
            backgroundColor: account == null
                ? AppColors.panelHigh
                : AppColors.primary,
            child: Text(
              account?.avatarText ?? '游',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(width: veryCompact ? 12 : 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account?.nickname ?? '游客模式',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (account != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _syncStatusLabel(syncStatus),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          syncStatus.phase == SyncPhase.expired ||
                              syncStatus.phase == SyncPhase.error
                          ? Colors.orangeAccent
                          : context.inkMuted,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  account == null
                      ? '尚未登录，当前使用独立的游客空间'
                      : '${account.email}  ·  UID ${account.shortId}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.inkMuted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (!veryCompact) ...[
            const SizedBox(width: 10),
            SmallBadge(
              label: account == null ? '未登录' : _syncStatusLabel(syncStatus),
              active: syncStatus.phase == SyncPhase.synced,
            ),
          ],
        ],
      ),
    );
  }
}

class _KnownAccountsCard extends StatelessWidget {
  const _KnownAccountsCard({
    required this.accounts,
    required this.currentId,
    required this.onSelected,
  });

  final List<LocalAccount> accounts;
  final String? currentId;
  final ValueChanged<LocalAccount> onSelected;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '此设备保存的账号',
            subtitle: '共 ${accounts.length} 个，切换时仍需输入密码',
            icon: Icons.people_outline_rounded,
          ),
          const SizedBox(height: 12),
          for (final account in accounts)
            InkWell(
              onTap: account.id == currentId ? null : () => onSelected(account),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: account.id == currentId
                          ? AppColors.primary
                          : Theme.of(context).colorScheme.surfaceContainerHigh,
                      child: Text(
                        account.avatarText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: context.ink,
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          Text(
                            _maskEmail(account.email),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: context.inkMuted),
                          ),
                        ],
                      ),
                    ),
                    if (account.id == currentId)
                      const SmallBadge(label: '当前', active: true)
                    else
                      Icon(Icons.login_rounded, color: context.inkMuted),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CloudAccountNotice extends StatelessWidget {
  const _CloudAccountNotice();

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_done_outlined, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '同一个邮箱可以在安卓和 Windows 上登录。登录信息保存在系统的加密存储里。收藏、追番、历史和播放进度会同步到账号；下载的视频和你自己填写的来源账号信息只留在本机，不会上传。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.inkMuted,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingCleanupNotice extends StatelessWidget {
  const _PendingCleanupNotice({required this.busy, required this.onRetry});

  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      borderColor: Colors.orangeAccent.withValues(alpha: 0.7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.cleaning_services_outlined,
            color: Colors.orangeAccent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '有账号文件尚未清理完成',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '通常是文件正被其他程序占用；这不会阻止你使用或创建其他账号。',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: busy ? null : onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重新清理'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountTextField extends StatelessWidget {
  const _AccountTextField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.hint,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.onSubmitted,
    this.suffixIcon,
    this.autofillHints,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffixIcon;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      autocorrect: false,
      enableSuggestions: !obscureText,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffixIcon,
      ),
    );
  }
}

class _AccountAction extends StatelessWidget {
  const _AccountAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color ?? context.ink),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: color ?? context.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: context.inkMuted),
          ],
        ),
      ),
    );
  }
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

String _maskEmail(String email) {
  final separator = email.indexOf('@');
  if (separator <= 0 || separator == email.length - 1) return '***';
  final local = email.substring(0, separator);
  final domain = email.substring(separator + 1);
  final visible = local.runes.isEmpty
      ? ''
      : String.fromCharCode(local.runes.first);
  return '$visible***@$domain';
}
