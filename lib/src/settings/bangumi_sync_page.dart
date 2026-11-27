import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../accounts/local_account_repository.dart';
import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../data/bangumi_credential_store.dart';
import '../data/bangumi_metadata_repository.dart';
import '../domain/anime_models.dart';
import '../library/bangumi_sync_service.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';

final _credentialStatus = FutureProvider.autoDispose
    .family<BangumiCredentialStatus, String?>(
      (ref, account) => ref
          .watch(bangumiCredentialStoreProvider)
          .readStatus(accountId: account),
    );
const _tokenGuide = 'https://next.bgm.tv/demo/access-token';

class BangumiSyncPage extends StatelessWidget {
  const BangumiSyncPage({super.key});

  @override
  Widget build(BuildContext context) => AsyncAnimeGate(
    builder: (context, state) {
      final account = state.accountSession.current?.id;
      return AppChrome(
        title: 'Bangumi 同步',
        active: ChromeDestination.settings,
        showSearch: false,
        onBack: () => safeNavigateBack(context, fallbackRoute: '/settings'),
        child: _BangumiSettings(
          key: ValueKey(account),
          account: account,
          misc: state.misc,
        ),
      );
    },
  );
}

class _BangumiSettings extends ConsumerStatefulWidget {
  const _BangumiSettings({
    super.key,
    required this.account,
    required this.misc,
  });
  final String? account;
  final MiscSettings misc;

  @override
  ConsumerState<_BangumiSettings> createState() => _BangumiSettingsState();
}

class _BangumiSettingsState extends ConsumerState<_BangumiSettings> {
  final _token = TextEditingController();
  bool _busy = false;
  bool _importing = false;
  String _bindingMessage = '';
  String _importMessage = '';

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<String> Function() action, {
    bool importing = false,
  }) async {
    setState(() {
      _busy = true;
      _importing = importing;
    });
    String message;
    try {
      message = await action();
    } on BangumiRateLimitException {
      message = 'Bangumi 请求过于频繁，请稍后再试';
    } on FormatException catch (error) {
      message = error.message;
    } on AccountException catch (error) {
      message = error.message;
    } on Exception {
      message = importing ? '导入未完成，请检查网络和本地存储后重试' : '无法访问令牌或服务，请稍后重试';
    }
    if (!mounted) return;
    ref.invalidate(_credentialStatus(widget.account));
    setState(() {
      _busy = false;
      _importing = false;
      if (importing) {
        _importMessage = message;
      } else {
        _bindingMessage = message;
      }
    });
  }

  Future<String> _changeToken({bool clear = false}) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final store = ref.read(bangumiCredentialStoreProvider);
    final controller = ref.read(animeControllerProvider.notifier);
    final version = controller.accountContextVersion;
    final account = widget.account;
    if (clear) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('清除 Bangumi 令牌？'),
          content: const Text('不会删除本地追番和历史记录。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清除'),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          !controller.isAccountContextCurrent(version)) {
        return '';
      }
      await store.clearAccount(account);
    } else {
      final token = _token.text.trim();
      final result = await ref
          .read(bangumiMetadataRepositoryProvider)
          .validateAccessToken(token);
      if (!result.isValid) return result.message;
      if (!mounted || !controller.isAccountContextCurrent(version)) return '';
      await store.saveToken(
        accountId: account,
        token: token,
        userId: result.userId,
        username: result.username,
        displayName: result.displayName,
      );
    }
    if (controller.isAccountContextCurrent(version)) {
      controller.handleBangumiCredentialChanged();
      container.invalidate(bangumiSyncServiceProvider);
    }
    if (mounted) _token.clear();
    return clear ? '令牌已清除' : '令牌已验证并保存';
  }

  Future<String> _import() async {
    final result = await ref
        .read(bangumiSyncServiceProvider)
        .importWatchingToLibrary();
    return '共读取 ${result.totalFetched} 部在看，新增追番 ${result.newlyFollowed} 部，更新进度 ${result.progressUpdated} 部';
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(_credentialStatus(widget.account));
    final scheme = Theme.of(context).colorScheme;
    final health = status.value?.health;
    final binding = status.when(
      loading: () => '读取中…',
      error: (_, _) => '无法读取本地凭证',
      data: (s) => switch (s.health) {
        BangumiCredentialHealth.notConfigured => '未绑定',
        BangumiCredentialHealth.expired ||
        BangumiCredentialHealth.rejected => '已过期或失效，请重新验证',
        _ => '已绑定：${s.username ?? s.displayName ?? 'Bangumi 用户'}',
      },
    );
    final statusColor = switch (health) {
      BangumiCredentialHealth.ready ||
      BangumiCredentialHealth.expiringSoon => AppColors.success,
      BangumiCredentialHealth.expired ||
      BangumiCredentialHealth.rejected => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    final statusIcon = switch (health) {
      BangumiCredentialHealth.ready ||
      BangumiCredentialHealth.expiringSoon => Icons.verified_rounded,
      BangumiCredentialHealth.expired ||
      BangumiCredentialHealth.rejected => Icons.warning_amber_rounded,
      _ => Icons.link_off_rounded,
    };

    Widget messageBanner(String text) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final contentWidth = constraints.maxWidth > 840
            ? 840.0
            : constraints.maxWidth;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: contentWidth,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                wide ? 24 : 14,
                12,
                wide ? 24 : 14,
                96,
              ),
              children: [
                AppPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionTitle(
                        title: 'Bangumi 令牌绑定',
                        subtitle: '使用个人访问令牌读取“在看”列表并同步单集进度',
                        icon: Icons.vpn_key_outlined,
                      ),
                      const SizedBox(height: 12),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.30),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(statusIcon, size: 15, color: statusColor),
                              const SizedBox(width: 6),
                              Text(
                                binding,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: statusColor,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _token,
                        enabled: !_busy,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: '个人访问令牌',
                          hintText: '粘贴 Bangumi Personal Access Token',
                          prefixIcon: const Icon(Icons.key_rounded, size: 18),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy ? null : () => _run(_changeToken),
                            icon: const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 18,
                            ),
                            label: const Text('验证并保存'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                !_busy && status.value?.isConfigured == true
                                ? () => _run(() => _changeToken(clear: true))
                                : null,
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                            label: const Text('清除令牌'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              final opened = await launchUrl(
                                Uri.parse(_tokenGuide),
                                mode: LaunchMode.externalApplication,
                              ).onError<Exception>((_, _) => false);
                              if (!opened && mounted) {
                                setState(
                                  () =>
                                      _bindingMessage = '请在浏览器打开 $_tokenGuide',
                                );
                              }
                            },
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 16,
                            ),
                            label: const Text('前往 Bangumi 获取令牌'),
                          ),
                        ],
                      ),
                      if (_bindingMessage.isNotEmpty)
                        messageBanner(_bindingMessage),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                AppPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionTitle(
                        title: '导入在看',
                        subtitle: '只补充缺少的追番和进度，不会覆盖更靠前的本地记录。',
                        icon: Icons.cloud_download_outlined,
                      ),
                      const SizedBox(height: 14),
                      FilledButton.tonalIcon(
                        key: const ValueKey('bangumiImportWatchingButton'),
                        onPressed:
                            !_busy && status.value?.canAuthenticate == true
                            ? () => _run(_import, importing: true)
                            : null,
                        icon: _importing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync_rounded, size: 18),
                        label: const Text('从 Bangumi 导入在看'),
                      ),
                      if (_importMessage.isNotEmpty)
                        messageBanner(_importMessage),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                AppPanel(
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('bangumiAutoSyncSwitch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('看完自动同步进度到 Bangumi'),
                    subtitle: const Text('绑定令牌后，单集播放达到 85% 或播完时静默同步，不会打断播放。'),
                    value: widget.misc.bangumiAutoSyncProgress,
                    onChanged: (enabled) => ref
                        .read(animeControllerProvider.notifier)
                        .updateMisc(
                          widget.misc.copyWith(
                            bangumiAutoSyncProgress: enabled,
                          ),
                        ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
