import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../shared_ui/app_chrome.dart';
import 'rule_models.dart';
import 'rule_plugin_repository.dart';

class RuleManagementPage extends ConsumerWidget {
  const RuleManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = const RulePluginRepository();
    return AsyncAnimeGate(
      builder: (context, state) {
        final installed = repository.installedRules(state.rulePlugins);
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '规则管理',
          onBack: () => Navigator.of(context).pop(),
          trailing: _RuleTopActions(
            onRefresh: () => _showSnack(context, '已刷新本地规则索引'),
            onAdd: () => _showImportSheet(context),
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
    final repository = const RulePluginRepository();
    return AsyncAnimeGate(
      builder: (context, state) {
        final rules = repository.rulesFor(_type);
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '规则仓库',
          onBack: () => Navigator.of(context).pop(),
          trailing: _RuleTopActions(
            onHistory: () => _showSnack(context, '仓库更新时间已同步到本地索引'),
            onRefresh: () => _showSnack(context, '已重新扫描内置仓库'),
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
                onSelected: (value) => setState(() => _type = value),
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
    required this.onOpenRepository,
    required this.onReset,
  });

  final int installedCount;
  final int enabledCount;
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
              const _RuleMetric(label: '来源', value: '2'),
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
              Switch(value: enabled, onChanged: onToggle),
              IconButton(
                tooltip: '卸载',
                onPressed: onRemove,
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RepositoryHeader extends StatelessWidget {
  const _RepositoryHeader({required this.selected, required this.onSelected});

  final RuleContentType selected;
  final ValueChanged<RuleContentType> onSelected;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            title: '规则仓库',
            subtitle: '已筛掉直播、教育、网盘授权源、本地代理和不适合内置的混合源',
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
        ],
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
            child: Text(installed ? '已安装' : '安装'),
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
          rule.note,
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

void _showImportSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF202820),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ImportAction(
                title: '新建规则',
                onTap: () => Navigator.of(context).pop(),
              ),
              _ImportAction(
                title: '从规则仓库导入',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/profile/rules/repository');
                },
              ),
              _ImportAction(
                title: '从剪贴板导入',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ImportAction extends StatelessWidget {
  const _ImportAction({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 68,
        width: double.infinity,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
