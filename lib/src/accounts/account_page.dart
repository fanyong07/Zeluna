import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import 'local_account_repository.dart';

enum _AccountPageMode { manage, login, register, password }

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
                      _AccountStatusCard(session: state.accountSession),
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
                subtitle: '密码经过加盐派生后保存在本机，不会保存明文',
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
                icon: Icons.logout_rounded,
                title: '退出登录',
                subtitle: '账号数据会保留，下次登录可继续使用',
                color: Colors.orangeAccent,
                onTap: _busy ? null : _signOut,
              ),
              _AccountAction(
                icon: Icons.delete_forever_outlined,
                title: '删除本机账号',
                subtitle: '删除账号及其本机数据，需要再次输入密码',
                color: Colors.redAccent,
                onTap: _busy ? null : () => _confirmDeleteAccount(account),
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
                subtitle: '登录本机已注册的账号',
                icon: Icons.login_rounded,
              ),
              const SizedBox(height: 18),
              _AccountTextField(
                controller: _email,
                label: '登录邮箱（仅作本机标识）',
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
        const _LocalOnlyNotice(),
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
                subtitle: '为不同使用者建立独立空间',
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
                label: '登录邮箱（仅作本机标识）',
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
                    ? '首次创建账号后，当前游客的收藏、追番、历史、下载和私密源配置会安全迁移进新账号，游客空间随后清空。'
                    : '新账号会从空白资料开始，不会看到其他账号的收藏、历史和个人偏好。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
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
        const _LocalOnlyNotice(),
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
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .loginAccount(email: _email.text, password: _password.text),
      success: '登录成功，已切换到该账号',
      successMode: _AccountPageMode.manage,
      clearPasswords: true,
    );
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
          ),
      success: '账号已创建并登录',
      successMode: _AccountPageMode.manage,
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
        title: const Text('删除本机账号？'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将永久删除“${account.nickname}”的收藏、历史、偏好、下载记录和私密源配置。这个操作无法撤销。'),
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
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmedPassword == null || confirmedPassword.isEmpty || !mounted) {
      return;
    }
    await _runAccountAction(
      action: () => ref
          .read(animeControllerProvider.notifier)
          .deleteCurrentAccount(password: confirmedPassword),
      success: '账号及其本机数据已删除',
      successMode: _AccountPageMode.login,
      clearPasswords: true,
    );
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
    _currentPassword.clear();
    _newPassword.clear();
    _confirmNewPassword.clear();
  }

  void _clearCredentialFields() {
    _email.clear();
    _nickname.clear();
    _clearPasswords();
  }
}

class _AccountStatusCard extends StatelessWidget {
  const _AccountStatusCard({required this.session});

  final LocalAccountSession session;

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
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  account == null
                      ? '尚未登录，当前使用独立的游客空间'
                      : '${account.email}  ·  UID ${account.shortId}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (!veryCompact) ...[
            const SizedBox(width: 10),
            SmallBadge(
              label: account == null ? '未登录' : '本机账号',
              active: account != null,
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
            title: '本机账号',
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
                          : AppColors.panelHigh,
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
                                  color: AppColors.text,
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          Text(
                            _maskEmail(account.email),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    if (account.id == currentId)
                      const SmallBadge(label: '当前', active: true)
                    else
                      const Icon(Icons.login_rounded, color: AppColors.muted),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LocalOnlyNotice extends StatelessWidget {
  const _LocalOnlyNotice();

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.devices_outlined, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '当前是本机账号系统：账号和数据只保存在这台设备，不会上传，也暂不支持跨设备同步。邮箱仅作登录标识，忘记密码无法通过邮件找回；密码用于应用内分区，不会加密设备文件。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
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
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '通常是文件正被其他程序占用；这不会阻止你使用或创建其他账号。',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
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
    this.color = AppColors.text,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
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
