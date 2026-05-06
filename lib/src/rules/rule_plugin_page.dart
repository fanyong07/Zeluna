import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import 'rule_models.dart';
import 'rule_plugin_repository.dart';

const _creamycakeCssRepositoryUrl = 'https://sub.creamycake.org/v1/css1.json';

class RuleManagementPage extends ConsumerWidget {
  const RuleManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final repository = RulePluginRepository(
          extraRules: state.rulePlugins.customRules,
        );
        final installed = repository.installedRules(state.rulePlugins);
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '规则管理',
          onBack: () => safeNavigateBack(context, fallbackRoute: '/profile'),
          trailing: _RuleTopActions(
            onRefresh: () => _showSnack(context, '已刷新本地规则索引'),
            onAdd: () => _showImportSheet(context, ref),
          ),
          rightRail: _RuleStatsRail(
            rules: repository.allRules,
            state: state.rulePlugins,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 120),
            children: [
              _RuleHero(
                installedCount: installed.length,
                enabledCount: state.rulePlugins.enabledIds.length,
                repositoryCount: state.rulePlugins.repositories.length + 1,
                onOpenRepository: () =>
                    context.push('/profile/rules/repository'),
                onReset: () => ref
                    .read(animeControllerProvider.notifier)
                    .resetRulePlugins(),
              ),
              const SizedBox(height: 16),
              if (installed.isEmpty)
                _RuleEmpty(
                  onOpenRepository: () =>
                      context.push('/profile/rules/repository'),
                )
              else
                for (final type in RuleContentType.values) ...[
                  _InstalledRuleGroup(
                    title: '${type.label}规则',
                    rules: installed
                        .where((rule) => rule.contentType == type)
                        .toList(growable: false),
                    state: state.rulePlugins,
                    onToggle: (rule, enabled) => ref
                        .read(animeControllerProvider.notifier)
                        .toggleRulePlugin(rule.id, enabled),
                    onRemove: (rule) => ref
                        .read(animeControllerProvider.notifier)
                        .uninstallRulePlugin(rule.id),
                  ),
                  const SizedBox(height: 14),
                ],
            ],
          ),
        );
      },
    );
  }
}

class RuleRepositoryPage extends ConsumerStatefulWidget {
  const RuleRepositoryPage({super.key});

  @override
  ConsumerState<RuleRepositoryPage> createState() => _RuleRepositoryPageState();
}

class _RuleRepositoryPageState extends ConsumerState<RuleRepositoryPage> {
  RuleContentType _type = RuleContentType.anime;

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final repository = RulePluginRepository(
          extraRules: state.rulePlugins.customRules,
        );
        final rules = repository.rulesFor(_type);
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '规则仓库',
          onBack: () =>
              safeNavigateBack(context, fallbackRoute: '/profile/rules'),
          trailing: _RuleTopActions(
            onHistory: () => _showSnack(context, '仓库更新时间已同步到本地索引'),
            onRefresh: () => _showSnack(context, '已重新扫描内置仓库'),
            onAdd: () => _showImportSheet(context, ref),
          ),
          rightRail: _RepositoryRail(
            rules: repository.allRules,
            selected: _type,
            onSelected: (value) => setState(() => _type = value),
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 120),
            children: [
              _RepositoryHeader(
                selected: _type,
                repositories: state.rulePlugins.repositories,
                onSelected: (value) => setState(() => _type = value),
                onImport: () => _showImportSheet(context, ref),
                onImportCreamycakeCss: () => _importRepositoryUrl(
                  context,
                  ref,
                  _creamycakeCssRepositoryUrl,
                ),
              ),
              const SizedBox(height: 16),
              for (final rule in rules) ...[
                _RepositoryRuleCard(
                  rule: rule,
                  installed: state.rulePlugins.isInstalled(rule.id),
                  onInstall: () => ref
                      .read(animeControllerProvider.notifier)
                      .installRulePlugin(rule.id),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RuleTopActions extends StatelessWidget {
  const _RuleTopActions({this.onHistory, this.onRefresh, this.onAdd});

  final VoidCallback? onHistory;
  final VoidCallback? onRefresh;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onHistory != null)
          _RoundToolButton(
            icon: Icons.history_rounded,
            tooltip: '导入记录',
            onTap: onHistory!,
          ),
        if (onHistory != null) const SizedBox(width: 8),
        if (onRefresh != null)
          _RoundToolButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            onTap: onRefresh!,
          ),
        if (onAdd != null) ...[
          const SizedBox(width: 8),
          _RoundToolButton(
            icon: Icons.add_rounded,
            tooltip: '添加规则',
            onTap: onAdd!,
          ),
        ],
      ],
    );
  }
}

class _RuleHero extends StatelessWidget {
  const _RuleHero({
    required this.installedCount,
    required this.enabledCount,
    required this.repositoryCount,
    required this.onOpenRepository,
    required this.onReset,
  });

  final int installedCount;
  final int enabledCount;
  final int repositoryCount;
  final VoidCallback onOpenRepository;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      borderColor: AppColors.borderBright,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.extension_outlined, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: SectionTitle(title: '播放规则插件', subtitle: '番剧、电视剧、电影分开管理'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _RuleMetric(label: '已安装', value: '$installedCount'),
              const SizedBox(width: 10),
              _RuleMetric(label: '已启用', value: '$enabledCount'),
              const SizedBox(width: 10),
              _RuleMetric(label: '来源', value: '$repositoryCount'),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: onOpenRepository,
                icon: const Icon(Icons.inventory_2_outlined),
                label: const Text('打开规则仓库'),
              ),
              OutlinedButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.restore_rounded),
                label: const Text('恢复推荐安装'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RuleMetric extends StatelessWidget {
  const _RuleMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.panelHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstalledRuleGroup extends StatelessWidget {
  const _InstalledRuleGroup({
    required this.title,
    required this.rules,
    required this.state,
    required this.onToggle,
    required this.onRemove,
  });

  final String title;
  final List<RulePlugin> rules;
  final RulePluginState state;
  final void Function(RulePlugin rule, bool enabled) onToggle;
  final ValueChanged<RulePlugin> onRemove;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title: title, subtitle: '${rules.length} 个已安装规则'),
          const SizedBox(height: 12),
          if (rules.isEmpty)
            Text(
              '还没有安装这一类规则。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
            )
          else
            for (final rule in rules)
              _InstalledRuleRow(
                rule: rule,
                enabled: state.isEnabled(rule.id),
                onToggle: (value) => onToggle(rule, value),
                onRemove: () => onRemove(rule),
              ),
        ],
      ),
    );
  }
}

class _InstalledRuleRow extends StatelessWidget {
  const _InstalledRuleRow({
    required this.rule,
    required this.enabled,
    required this.onToggle,
    required this.onRemove,
  });

  final RulePlugin rule;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final canSwitch = rule.canResolveNatively || enabled;
    final unavailableMessage = _ruleUnavailableMessage(rule);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.panelHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                enabled ? Icons.power_settings_new : Icons.power_off_outlined,
                color: enabled ? AppColors.primary : AppColors.muted,
              ),
              const SizedBox(width: 12),
              Expanded(child: _RuleCardText(rule: rule)),
              Tooltip(
                message: canSwitch ? '切换规则启用状态' : unavailableMessage,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: canSwitch
                      ? null
                      : () => _showRuleUnavailableDialog(context, rule),
                  child: Switch(
                    value: enabled,
                    onChanged: canSwitch ? onToggle : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: '更多操作',
                onPressed: () => _showRuleActionSheet(context, rule, onRemove),
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showRuleActionSheet(
  BuildContext context,
  RulePlugin rule,
  VoidCallback onRemove,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.panelHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rule.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              if (!rule.canResolveNatively) ...[
                _RuleAction(
                  icon: Icons.info_outline_rounded,
                  title: '为什么不能启用',
                  subtitle: _ruleUnavailableMessage(rule),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showRuleUnavailableDialog(context, rule);
                  },
                ),
              ],
              if (rule.baseUrl.trim().isNotEmpty) ...[
                _RuleAction(
                  icon: Icons.open_in_browser_rounded,
                  title: '打开原站',
                  subtitle: '跳到规则对应的网站，手动完成验证或查找资源',
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _openRuleSite(context, rule);
                  },
                ),
              ],
              _RuleAction(
                icon: Icons.refresh_rounded,
                title: '更新规则',
                subtitle: '从当前规则仓库检查这个规则的最新版本',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showSnack(context, '${rule.name} 已是当前仓库版本');
                },
              ),
              _RuleAction(
                icon: Icons.delete_outline,
                title: '删除规则',
                subtitle: '从已安装列表移除，之后可在规则仓库重新安装',
                destructive: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onRemove();
                  _showSnack(context, '已删除 ${rule.name}');
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _RuleAction extends StatelessWidget {
  const _RuleAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? const Color(0xFFFF7A90) : AppColors.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 72,
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RepositoryHeader extends StatelessWidget {
  const _RepositoryHeader({
    required this.selected,
    required this.repositories,
    required this.onSelected,
    required this.onImport,
    required this.onImportCreamycakeCss,
  });

  final RuleContentType selected;
  final List<RuleRepositoryRecord> repositories;
  final ValueChanged<RuleContentType> onSelected;
  final VoidCallback onImport;
  final VoidCallback onImportCreamycakeCss;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: SectionTitle(
                  title: '规则仓库',
                  subtitle: '内置推荐源 + 你导入的规则仓库',
                ),
              ),
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('导入仓库'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _RecommendedRepositoryCard(
            title: 'CreamyCake CSS 播放规则',
            subtitle: 'Animeko web-selector 规则包，导入后默认只启用前 6 条优先线路',
            imported: repositories.any(
              (repository) => repository.url == _creamycakeCssRepositoryUrl,
            ),
            onImport: onImportCreamycakeCss,
          ),
          const SizedBox(height: 14),
          SegmentedButton<RuleContentType>(
            segments: [
              for (final type in RuleContentType.values)
                ButtonSegment(
                  value: type,
                  label: Text(type.label),
                  icon: Icon(_iconForType(type)),
                ),
            ],
            selected: {selected},
            onSelectionChanged: (value) => onSelected(value.first),
          ),
          if (repositories.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final repository in repositories.take(4))
                  SmallBadge(
                    label: '${repository.name} · ${repository.ruleCount}',
                    active: true,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RecommendedRepositoryCard extends StatelessWidget {
  const _RecommendedRepositoryCard({
    required this.title,
    required this.subtitle,
    required this.imported,
    required this.onImport,
  });

  final String title;
  final String subtitle;
  final bool imported;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panelHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            const Icon(Icons.hub_outlined, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: onImport,
              icon: Icon(
                imported
                    ? Icons.refresh_rounded
                    : Icons.cloud_download_outlined,
              ),
              label: Text(imported ? '重新导入' : '导入'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RepositoryRuleCard extends StatelessWidget {
  const _RepositoryRuleCard({
    required this.rule,
    required this.installed,
    required this.onInstall,
  });

  final RulePlugin rule;
  final bool installed;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      color: const Color(0xFF111922),
      child: Row(
        children: [
          Expanded(child: _RuleCardText(rule: rule)),
          const SizedBox(width: 12),
          TextButton(
            onPressed: installed ? null : onInstall,
            child: Text(
              installed
                  ? '已安装'
                  : rule.canResolveNatively
                  ? '安装'
                  : '安装备用',
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleCardText extends StatelessWidget {
  const _RuleCardText({required this.rule});

  final RulePlugin rule;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                rule.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SmallBadge(label: rule.version, active: true),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            SmallBadge(label: rule.engine),
            SmallBadge(label: rule.sourceLabel),
            if (rule.requiresCaptcha) const SmallBadge(label: 'captcha'),
            SmallBadge(
              label: _ruleStatusLabel(rule),
              active: rule.canResolveNatively,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '更新时间：${rule.updateLabel}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: 4),
        Text(
          _ruleDisplayNote(rule),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
        ),
      ],
    );
  }
}

String _ruleStatusLabel(RulePlugin rule) {
  if (rule.canResolveNatively) return '可自动播放';
  if (rule.requiresCaptcha) return '需手动验证';
  if (rule.requiresPrivateAuth) return '需私有授权';
  if (rule.requiresWebView) return '需 WebView';
  return '暂不能自动播放';
}

String _ruleDisplayNote(RulePlugin rule) {
  final reason = rule.unsupportedReason?.trim();
  if (reason != null && reason.isNotEmpty) return reason;
  return rule.note;
}

String _ruleUnavailableMessage(RulePlugin rule) {
  final reason = rule.unsupportedReason?.trim();
  if (reason != null && reason.isNotEmpty) return reason;
  if (rule.requiresCaptcha) {
    return '这个规则需要先在网页里完成验证码验证，当前自动解析器不能直接启用。';
  }
  if (rule.requiresPrivateAuth) {
    return '这个规则需要私有授权信息，当前不能作为自动播放线路启用。';
  }
  if (rule.requiresWebView) {
    return '这个规则需要 WebView 手动处理页面，当前不能作为自动播放线路启用。';
  }
  return '这个规则当前没有可用的本地解析器，暂时只能作为备用规则保存。';
}

void _showRuleUnavailableDialog(BuildContext context, RulePlugin rule) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: AppColors.panelHigh,
        title: Text('${rule.name} 暂不能启用'),
        content: Text(
          '${_ruleUnavailableMessage(rule)}\n\n'
          '所以应用不会把它加入自动播放线路，避免出现“开关打开了但还是不能播放”的情况。',
        ),
        actions: [
          if (rule.baseUrl.trim().isNotEmpty)
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _openRuleSite(context, rule);
              },
              child: const Text('打开原站'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}

Future<void> _openRuleSite(BuildContext context, RulePlugin rule) async {
  final uri = Uri.tryParse(rule.baseUrl.trim());
  if (uri == null || !uri.hasScheme) {
    _showSnack(context, '这个规则没有可打开的网站地址');
    return;
  }
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) {
    _showSnack(context, '没有找到可以打开网站的应用');
  }
}

class _RuleEmpty extends StatelessWidget {
  const _RuleEmpty({required this.onOpenRepository});

  final VoidCallback onOpenRepository;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        children: [
          const Icon(Icons.extension_off_outlined, color: AppColors.primary),
          const SizedBox(height: 12),
          Text(
            '还没有安装规则',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '先从规则仓库安装推荐规则，播放页会按番剧、电视剧、电影分别显示线路。',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: onOpenRepository, child: const Text('去规则仓库')),
        ],
      ),
    );
  }
}

class _RuleStatsRail extends StatelessWidget {
  const _RuleStatsRail({required this.rules, required this.state});

  final List<RulePlugin> rules;
  final RulePluginState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '规则状态', subtitle: '按内容类型隔离'),
              const SizedBox(height: 14),
              for (final type in RuleContentType.values)
                _RailRuleTypeLine(
                  type: type,
                  installed: rules
                      .where(
                        (rule) =>
                            rule.contentType == type &&
                            state.installedIds.contains(rule.id),
                      )
                      .length,
                  total: rules.where((rule) => rule.contentType == type).length,
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: '筛选原则'),
              SizedBox(height: 12),
              _RailNote(text: '保留字段完整、可搜索、分类明确的规则'),
              _RailNote(text: '过滤直播、教育、网盘授权源和本地代理源'),
              _RailNote(text: '番剧、电视剧、电影分别安装和启停'),
            ],
          ),
        ),
      ],
    );
  }
}

class _RepositoryRail extends StatelessWidget {
  const _RepositoryRail({
    required this.rules,
    required this.selected,
    required this.onSelected,
  });

  final List<RulePlugin> rules;
  final RuleContentType selected;
  final ValueChanged<RuleContentType> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '仓库分组'),
              const SizedBox(height: 12),
              for (final type in RuleContentType.values)
                _RailSelectLine(
                  key: ValueKey('ruleRepositoryRail:${type.name}'),
                  label: type.label,
                  value:
                      '${rules.where((rule) => rule.contentType == type).length}',
                  active: type == selected,
                  onTap: () => onSelected(type),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RailRuleTypeLine extends StatelessWidget {
  const _RailRuleTypeLine({
    required this.type,
    required this.installed,
    required this.total,
  });

  final RuleContentType type;
  final int installed;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(_iconForType(type), color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              type.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SmallBadge(label: '$installed/$total'),
        ],
      ),
    );
  }
}

class _RailSelectLine extends StatelessWidget {
  const _RailSelectLine({
    super.key,
    required this.label,
    required this.value,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: active ? AppColors.text : AppColors.muted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SmallBadge(label: value, active: active),
          ],
        ),
      ),
    );
  }
}

class _RailNote extends StatelessWidget {
  const _RailNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 16,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundToolButton extends StatelessWidget {
  const _RoundToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.panelHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: SizedBox(
            width: 40,
            height: 38,
            child: Icon(icon, color: AppColors.text),
          ),
        ),
      ),
    );
  }
}

IconData _iconForType(RuleContentType type) {
  return switch (type) {
    RuleContentType.anime => Icons.auto_awesome_motion_outlined,
    RuleContentType.series => Icons.live_tv_outlined,
    RuleContentType.movie => Icons.movie_outlined,
  };
}

void _showImportSheet(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.add_circle_outline,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '添加规则',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _ImportAction(
                icon: Icons.edit_note_rounded,
                title: '新建规则',
                subtitle: '填写名称、搜索地址和解析字段，保存到本地规则库',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showManualRuleDialog(context, ref);
                },
              ),
              const SizedBox(height: 10),
              _ImportAction(
                icon: Icons.inventory_2_outlined,
                title: '从规则仓库导入',
                subtitle: '打开仓库页，可安装内置规则，也可粘贴自己的仓库地址',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (context.mounted) {
                      context.push('/profile/rules/repository');
                    }
                  });
                },
              ),
              const SizedBox(height: 10),
              _ImportAction(
                icon: Icons.content_paste_go_rounded,
                title: '从剪贴板导入',
                subtitle: '读取剪贴板里的规则 JSON 或 TVBox 配置并导入',
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _importFromClipboard(context, ref);
                },
              ),
              const SizedBox(height: 10),
              _ImportAction(
                icon: Icons.add_link_rounded,
                title: '导入仓库 URL',
                subtitle: '粘贴 raw JSON 地址，自动下载并保存仓库规则',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showRepositoryUrlDialog(context, ref);
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ImportAction extends StatelessWidget {
  const _ImportAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.panelHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(icon, color: AppColors.primary),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}

Future<void> _importFromClipboard(BuildContext context, WidgetRef ref) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text?.trim() ?? '';
  if (!context.mounted) return;
  if (text.isEmpty) {
    _showSnack(context, '剪贴板里没有可导入内容');
    return;
  }
  try {
    final result = await ref
        .read(animeControllerProvider.notifier)
        .importRuleRepositoryText(text);
    if (context.mounted) {
      _showSnack(
        context,
        '已导入 ${result.repositoryName}：${result.ruleCount} 条规则',
      );
    }
  } catch (error) {
    if (context.mounted) _showSnack(context, _friendlyImportError(error));
  }
}

Future<bool> _importRepositoryUrl(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  try {
    final result = await ref
        .read(animeControllerProvider.notifier)
        .importRuleRepositoryUrl(url);
    if (context.mounted) {
      _showSnack(
        context,
        '已导入 ${result.repositoryName}：${result.ruleCount} 条规则',
      );
    }
    return true;
  } catch (error) {
    if (context.mounted) _showSnack(context, _friendlyImportError(error));
    return false;
  }
}

void _showRepositoryUrlDialog(BuildContext context, WidgetRef ref) {
  final controller = TextEditingController();
  var importing = false;
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.panel,
            title: const Text('导入规则仓库'),
            content: SizedBox(
              width: 520,
              child: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '仓库 JSON 地址',
                  hintText: 'https://example.com/rules.json',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: importing
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: importing
                    ? null
                    : () async {
                        final url = controller.text.trim();
                        setDialogState(() => importing = true);
                        final imported = await _importRepositoryUrl(
                          context,
                          ref,
                          url,
                        );
                        if (imported && dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        } else if (dialogContext.mounted) {
                          setDialogState(() => importing = false);
                        }
                      },
                icon: importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download_outlined),
                label: Text(importing ? '导入中' : '导入'),
              ),
            ],
          );
        },
      );
    },
  );
}

void _showManualRuleDialog(BuildContext context, WidgetRef ref) {
  final nameController = TextEditingController();
  final baseController = TextEditingController();
  final searchController = TextEditingController();
  var type = RuleContentType.anime;
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.panel,
            title: const Text('新建规则'),
            content: SizedBox(
              width: 540,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: '规则名称'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<RuleContentType>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: '内容类型'),
                    items: [
                      for (final value in RuleContentType.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setDialogState(() => type = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: baseController,
                    decoration: const InputDecoration(
                      labelText: '站点主页',
                      hintText: 'https://example.com',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: searchController,
                    decoration: const InputDecoration(
                      labelText: '搜索地址',
                      hintText: 'https://example.com/search?wd=@keyword',
                    ),
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
                onPressed: () async {
                  final name = nameController.text.trim();
                  final baseUrl = baseController.text.trim();
                  final searchUrl = searchController.text.trim();
                  if (name.isEmpty || baseUrl.isEmpty || searchUrl.isEmpty) {
                    _showSnack(context, '请填写名称、主页和搜索地址');
                    return;
                  }
                  final id = 'manual:${DateTime.now().microsecondsSinceEpoch}';
                  final json =
                      '''
{
  "name": "手动规则",
  "rules": [
    {
      "id": "$id",
      "name": ${_jsonString(name)},
      "source": "custom",
      "contentType": "${type.name}",
      "engine": "native",
      "baseUrl": ${_jsonString(baseUrl)},
      "searchUrl": ${_jsonString(searchUrl)},
      "searchable": true,
      "quickSearch": true,
      "filterable": false,
      "unsupportedReason": "手动新建规则还缺少播放页 XPath 字段，请继续补全后再启用播放。",
      "note": "用户手动新建规则。"
    }
  ]
}
''';
                  await ref
                      .read(animeControllerProvider.notifier)
                      .importRuleRepositoryText(json);
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                  if (context.mounted) _showSnack(context, '已新建规则：$name');
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
}

String _friendlyImportError(Object error) {
  final text = error.toString().replaceFirst('FormatException: ', '');
  if (text.contains('SocketException')) return '仓库地址无法访问，请检查网络或地址';
  if (text.contains('TimeoutException')) return '仓库请求超时';
  return text;
}

String _jsonString(String value) => jsonEncode(value);

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
