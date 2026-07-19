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
import '../sources/source_catalog_models.dart';
import 'github_rule_repository_scanner.dart';
import 'kazumi_rule_repository.dart';
import 'rule_importer.dart';
import 'rule_models.dart';
import 'rule_plugin_repository.dart';

Color _surfaceText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _surfaceMuted(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

Color _surfaceHigh(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHigh;

Color _surfaceBorder(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant;

Color _accent(BuildContext context) => Theme.of(context).colorScheme.primary;

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
        final installedEnabledCount = installed
            .where((rule) => state.rulePlugins.isEnabled(rule.id))
            .length;
        final installedPlaybackCount = installed
            .where(
              (rule) =>
                  state.rulePlugins.isEnabled(rule.id) &&
                  rule.searchable &&
                  rule.canResolveNatively,
            )
            .length;
        final playbackCount =
            installedPlaybackCount +
            state.sourceCatalog.activePlaybackRuleCount;
        final catalogPlaybackSources = state.sourceCatalog.sources
            .where(
              (source) =>
                  state.sourceCatalog.playbackRuleCountFor(source.id) > 0,
            )
            .toList(growable: false);
        final catalogPlaybackGroups = _groupAutomaticRulePackages(
          state.sourceCatalog,
          catalogPlaybackSources,
        );
        final allInstalledEnabled =
            installed.isEmpty || installedEnabledCount == installed.length;
        final allCatalogEnabled =
            catalogPlaybackSources.isEmpty ||
            catalogPlaybackSources.every((source) => source.enabled);
        final noCatalogEnabled = catalogPlaybackSources.every(
          (source) => !source.enabled,
        );
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '播放规则',
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
                installedCount:
                    installed.length +
                    state.sourceCatalog.availablePlaybackRuleCount,
                enabledCount:
                    installedEnabledCount +
                    state.sourceCatalog.activePlaybackRuleCount,
                playbackCount: playbackCount,
                catalogPlaybackCount:
                    state.sourceCatalog.activePlaybackRuleCount,
                repositoryCount: state.rulePlugins.repositories.length + 1,
                onOpenRepository: () =>
                    context.push('/profile/rules/repository'),
                onEnableAll: allInstalledEnabled && allCatalogEnabled
                    ? null
                    : () async {
                        await ref
                            .read(animeControllerProvider.notifier)
                            .setAllInstalledRulePluginsEnabled(true);
                        if (context.mounted) {
                          _showSnack(context, '已启用全部播放规则');
                        }
                      },
                onDisableAll: installedEnabledCount == 0 && noCatalogEnabled
                    ? null
                    : () async {
                        await ref
                            .read(animeControllerProvider.notifier)
                            .setAllInstalledRulePluginsEnabled(false);
                        if (context.mounted) {
                          _showSnack(context, '已关闭全部播放规则');
                        }
                      },
                onReset: () => ref
                    .read(animeControllerProvider.notifier)
                    .resetRulePlugins(),
              ),
              const SizedBox(height: 16),
              if (catalogPlaybackSources.isNotEmpty) ...[
                _AutomaticRulePackages(
                  groups: catalogPlaybackGroups,
                  onToggle: (group, enabled) async {
                    final controller = ref.read(
                      animeControllerProvider.notifier,
                    );
                    if (group.sources.length == 1) {
                      await controller.toggleVideoSource(
                        group.sources.single.id,
                        enabled,
                      );
                    } else {
                      await controller.setVideoSourcesEnabled(
                        group.sources.map((source) => source.id),
                        enabled,
                      );
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],
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
  final KazumiRuleRepository _kazumiRepository = const KazumiRuleRepository();
  KazumiRuleCatalog _kazumiCatalog = KazumiRuleRepository.bundledCatalog;
  final Set<String> _loadingKazumiIds = <String>{};
  bool _refreshingKazumi = false;

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final repository = RulePluginRepository(
          extraRules: state.rulePlugins.customRules,
        );
        final storedRules = repository.rulesFor(_type);
        final entriesById = <String, KazumiRuleCatalogEntry>{
          if (_type == RuleContentType.anime)
            for (final entry in _kazumiCatalog.entries) entry.id: entry,
        };
        final rules = <RulePlugin>[];
        final seenRuleIds = <String>{};
        for (final rule in storedRules) {
          if (seenRuleIds.add(rule.id)) rules.add(rule);
        }
        if (_type == RuleContentType.anime) {
          for (final entry in _kazumiCatalog.entries) {
            if (seenRuleIds.add(entry.id)) rules.add(entry.toPreviewRule());
          }
        }
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '规则仓库',
          onBack: () =>
              safeNavigateBack(context, fallbackRoute: '/profile/rules'),
          trailing: _RuleTopActions(
            onHistory: () => _showSnack(context, '仓库更新时间已同步到本地索引'),
            onRefresh: _refreshingKazumi
                ? null
                : () => _refreshKazumiCatalog(state.rulePlugins),
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
              if (_type == RuleContentType.anime) ...[
                _KazumiRepositoryHeader(
                  catalog: _kazumiCatalog,
                  installedCount: _kazumiCatalog.entries
                      .where((entry) => state.rulePlugins.isInstalled(entry.id))
                      .length,
                  refreshing: _refreshingKazumi,
                  onRefresh: _refreshingKazumi
                      ? null
                      : () => _refreshKazumiCatalog(state.rulePlugins),
                  onBatchInstall: () => _showKazumiSelectionDialog(
                    context,
                    entries: _kazumiCatalog.entries,
                    installedIds: state.rulePlugins.installedIds,
                    onInstall: _installKazumiEntries,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _RepositoryHeader(
                selected: _type,
                repositories: state.rulePlugins.repositories,
                onSelected: (value) => setState(() => _type = value),
                onImport: () => _showRepositoryUrlDialog(context, ref),
              ),
              const SizedBox(height: 16),
              for (final rule in rules) ...[
                _RepositoryRuleCard(
                  rule: rule,
                  installed: state.rulePlugins.isInstalled(rule.id),
                  busy: _loadingKazumiIds.contains(rule.id),
                  onInstall: entriesById.containsKey(rule.id)
                      ? () => _installKazumiEntries([entriesById[rule.id]!])
                      : () => ref
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

  Future<bool> _installKazumiEntries(
    List<KazumiRuleCatalogEntry> entries,
  ) async {
    if (entries.isEmpty) return false;
    setState(() {
      _loadingKazumiIds.addAll(entries.map((entry) => entry.id));
    });
    try {
      final loaded = await _kazumiRepository.loadRules(entries);
      final result = await ref
          .read(animeControllerProvider.notifier)
          .importSelectedRulePlugins(
            repositoryName: loaded.bundle.name,
            rules: loaded.bundle.rules,
            sourceUrl: loaded.bundle.sourceUrl,
          );
      if (mounted) {
        final failed = loaded.failedNames.length;
        _showSnack(
          context,
          failed == 0
              ? '已安装 ${result.installedCount} 条番剧规则，默认未启用'
              : '已安装 ${result.installedCount} 条，另有 $failed 条暂时无法读取',
        );
      }
      return true;
    } catch (error) {
      if (mounted) _showSnack(context, _friendlyImportError(error));
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _loadingKazumiIds.removeAll(entries.map((entry) => entry.id));
        });
      }
    }
  }

  Future<void> _refreshKazumiCatalog(RulePluginState pluginState) async {
    if (_refreshingKazumi) return;
    setState(() => _refreshingKazumi = true);
    try {
      final catalog = await _kazumiRepository.refreshCatalog();
      final installedEntries = catalog.entries
          .where((entry) => pluginState.isInstalled(entry.id))
          .toList(growable: false);
      var refreshedCount = 0;
      var failedCount = 0;
      if (installedEntries.isNotEmpty) {
        final loaded = await _kazumiRepository.loadRules(installedEntries);
        final result = await ref
            .read(animeControllerProvider.notifier)
            .importSelectedRulePlugins(
              repositoryName: loaded.bundle.name,
              rules: loaded.bundle.rules,
              sourceUrl: loaded.bundle.sourceUrl,
            );
        refreshedCount = result.installedCount;
        failedCount = loaded.failedNames.length;
      }
      if (!mounted) return;
      setState(() => _kazumiCatalog = catalog);
      _showSnack(
        context,
        installedEntries.isEmpty
            ? '已刷新内置规则目录，共 ${catalog.entries.length} 条'
            : failedCount == 0
            ? '已刷新目录，并更新 $refreshedCount 条已安装规则'
            : '已更新 $refreshedCount 条规则，$failedCount 条暂时读取失败',
      );
    } catch (error) {
      if (mounted) _showSnack(context, _friendlyImportError(error));
    } finally {
      if (mounted) setState(() => _refreshingKazumi = false);
    }
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
    required this.playbackCount,
    required this.catalogPlaybackCount,
    required this.repositoryCount,
    required this.onOpenRepository,
    required this.onEnableAll,
    required this.onDisableAll,
    required this.onReset,
  });

  final int installedCount;
  final int enabledCount;
  final int playbackCount;
  final int catalogPlaybackCount;
  final int repositoryCount;
  final VoidCallback onOpenRepository;
  final VoidCallback? onEnableAll;
  final VoidCallback? onDisableAll;
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
              Icon(Icons.extension_outlined, color: _accent(context)),
              const SizedBox(width: 10),
              Expanded(
                child: SectionTitle(
                  title: '播放规则插件',
                  subtitle:
                      '番剧、电视剧、电影分开管理 · $repositoryCount 个仓库'
                      '${catalogPlaybackCount > 0 ? ' · 自动接入 $catalogPlaybackCount 条' : ''}',
                ),
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
              _RuleMetric(label: '参与查源', value: '$playbackCount'),
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
                onPressed: onEnableAll,
                icon: const Icon(Icons.toggle_on_outlined),
                label: const Text('全部启用'),
              ),
              OutlinedButton.icon(
                onPressed: onDisableAll,
                icon: const Icon(Icons.toggle_off_outlined),
                label: const Text('全部关闭'),
              ),
              OutlinedButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.restore_rounded),
                label: const Text('恢复推荐规则'),
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
        key: ValueKey('ruleMetric:$label'),
        decoration: BoxDecoration(
          color: _surfaceHigh(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _surfaceBorder(context)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: _surfaceText(context),
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _surfaceMuted(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AutomaticRulePackages extends StatelessWidget {
  const _AutomaticRulePackages({required this.groups, required this.onToggle});

  final List<_AutomaticRulePackageGroup> groups;
  final void Function(_AutomaticRulePackageGroup group, bool enabled) onToggle;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: '自动规则包', subtitle: '已直接并入播放规则，不再单独管理视频源'),
          const SizedBox(height: 10),
          for (var index = 0; index < groups.length; index++) ...[
            _AutomaticRulePackageRow(
              group: groups[index],
              onChanged: (enabled) => onToggle(groups[index], enabled),
            ),
            if (index != groups.length - 1)
              Divider(height: 1, color: _surfaceBorder(context)),
          ],
        ],
      ),
    );
  }
}

class _AutomaticRulePackageRow extends StatelessWidget {
  const _AutomaticRulePackageRow({
    required this.group,
    required this.onChanged,
  });

  final _AutomaticRulePackageGroup group;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(Icons.account_tree_outlined, color: _accent(context), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _surfaceText(context),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  group.sources.length == 1
                      ? '提供 ${group.candidateRuleCount} 条可执行播放规则'
                      : '合并 ${group.sources.length} 个同名规则包 · '
                            '${group.candidateRuleCount} 条候选规则，查源时自动去重',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _surfaceMuted(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            key: ValueKey('automaticRulePackage:${group.key}'),
            value: group.enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _AutomaticRulePackageGroup {
  const _AutomaticRulePackageGroup({
    required this.key,
    required this.displayName,
    required this.sources,
    required this.candidateRuleCount,
  });

  final String key;
  final String displayName;
  final List<VideoSource> sources;
  final int candidateRuleCount;

  bool get enabled => sources.every((source) => source.enabled);
}

List<_AutomaticRulePackageGroup> _groupAutomaticRulePackages(
  SourceCatalogState catalog,
  List<VideoSource> sources,
) {
  final grouped = <String, List<VideoSource>>{};
  for (final source in sources) {
    final key = source.displayName.trim().toLowerCase();
    grouped.putIfAbsent(key, () => <VideoSource>[]).add(source);
  }
  return [
    for (final entry in grouped.entries)
      _AutomaticRulePackageGroup(
        key: entry.value.map((source) => source.id).join('|'),
        displayName: entry.value.first.displayName,
        sources: List.unmodifiable(entry.value),
        candidateRuleCount: entry.value.fold(
          0,
          (total, source) => total + catalog.playbackRuleCountFor(source.id),
        ),
      ),
  ];
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
              ).textTheme.bodyMedium?.copyWith(color: _surfaceMuted(context)),
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
          color: _surfaceHigh(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _surfaceBorder(context)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                enabled ? Icons.power_settings_new : Icons.power_off_outlined,
                color: enabled ? _accent(context) : _surfaceMuted(context),
              ),
              const SizedBox(width: 12),
              Expanded(child: _RuleCardText(rule: rule)),
              Tooltip(
                message: '切换规则启用状态',
                child: Switch(value: enabled, onChanged: onToggle),
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
    backgroundColor: _surfaceHigh(context),
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
                  color: _surfaceText(context),
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
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
    final color = destructive
        ? Theme.of(context).colorScheme.error
        : _surfaceText(context);
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
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _surfaceMuted(context),
                    ),
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

class _KazumiRepositoryHeader extends StatelessWidget {
  const _KazumiRepositoryHeader({
    required this.catalog,
    required this.installedCount,
    required this.refreshing,
    required this.onRefresh,
    required this.onBatchInstall,
  });

  final KazumiRuleCatalog catalog;
  final int installedCount;
  final bool refreshing;
  final VoidCallback? onRefresh;
  final VoidCallback onBatchInstall;

  @override
  Widget build(BuildContext context) {
    final latest = catalog.entries.isEmpty
        ? null
        : catalog.entries.reduce(
            (current, entry) =>
                entry.lastUpdateMilliseconds > current.lastUpdateMilliseconds
                ? entry
                : current,
          );
    final latestDate = latest == null
        ? ''
        : '${latest.updatedAt.year}-${latest.updatedAt.month.toString().padLeft(2, '0')}-${latest.updatedAt.day.toString().padLeft(2, '0')}';
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final title = SectionTitle(
                title: '内置番剧规则',
                subtitle: '已内置 ${catalog.entries.length} 条规则目录，可直接浏览和批量安装',
              );
              final actions = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: refreshing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: Text(refreshing ? '刷新中' : '刷新目录'),
                  ),
                  FilledButton.icon(
                    onPressed: onBatchInstall,
                    icon: const Icon(Icons.library_add_check_rounded),
                    label: const Text('批量安装'),
                  ),
                ],
              );
              if (constraints.maxWidth < 660) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, const SizedBox(height: 12), actions],
                );
              }
              return Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 12),
                  actions,
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SmallBadge(label: '已安装 $installedCount 条', active: true),
              if (latestDate.isNotEmpty) SmallBadge(label: '最近更新 $latestDate'),
              SmallBadge(label: catalog.remote ? '在线目录' : '内置目录'),
            ],
          ),
        ],
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
  });

  final RuleContentType selected;
  final List<RuleRepositoryRecord> repositories;
  final ValueChanged<RuleContentType> onSelected;
  final VoidCallback onImport;

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
                  title: '自定义仓库',
                  subtitle: '粘贴仓库地址，扫描候选文件，再逐条选择规则',
                ),
              ),
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('粘贴仓库地址'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Text(
                '使用方法：① 粘贴 GitHub 仓库首页或 raw JSON；② 从扫描结果中选择一个配置文件；③ 勾选需要的规则。导入后默认关闭，由你自己逐条启用。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<RuleContentType>(
            segments: [
              for (final type in RuleContentType.values)
                ButtonSegment(
                  value: type,
                  label: Text(
                    type.label,
                    key: ValueKey('ruleRepositorySegment:${type.name}'),
                  ),
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

class _RepositoryRuleCard extends StatelessWidget {
  const _RepositoryRuleCard({
    required this.rule,
    required this.installed,
    required this.onInstall,
    this.busy = false,
  });

  final RulePlugin rule;
  final bool installed;
  final VoidCallback onInstall;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Row(
        children: [
          Expanded(child: _RuleCardText(rule: rule)),
          const SizedBox(width: 12),
          TextButton(
            onPressed: installed || busy ? null : onInstall,
            child: Text(
              installed
                  ? '已安装'
                  : busy
                  ? '读取中'
                  : '安装',
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
                  color: _surfaceText(context),
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
            SmallBadge(label: _ruleStatusLabel(rule), active: true),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '更新时间：${rule.updateLabel}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: _surfaceMuted(context)),
        ),
        const SizedBox(height: 4),
        Text(
          _ruleDisplayNote(rule),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: _surfaceMuted(context)),
        ),
      ],
    );
  }
}

String _ruleStatusLabel(RulePlugin rule) {
  return '可启用';
}

String _ruleDisplayNote(RulePlugin rule) {
  return rule.note;
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
          Icon(Icons.extension_off_outlined, color: _accent(context)),
          const SizedBox(height: 12),
          Text(
            '还没有安装规则',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _surfaceText(context),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '先从规则仓库安装推荐规则，播放页会按番剧、电视剧、电影分别显示线路。',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _surfaceMuted(context)),
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
          Icon(_iconForType(type), color: _accent(context), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              type.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: _surfaceText(context),
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
                  color: active
                      ? _surfaceText(context)
                      : _surfaceMuted(context),
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
          Icon(Icons.check_circle_outline, size: 16, color: _accent(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: _surfaceMuted(context)),
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
            color: _surfaceHigh(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _surfaceBorder(context)),
          ),
          child: SizedBox(
            width: 40,
            height: 38,
            child: Icon(icon, color: _surfaceText(context)),
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
    backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
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
                  Icon(Icons.add_circle_outline, color: _accent(context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '添加规则',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: _surfaceText(context),
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
                title: '粘贴 GitHub 仓库或 raw JSON',
                subtitle: '先扫描并预览候选文件，只导入你明确勾选的规则',
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
          color: _surfaceHigh(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _surfaceBorder(context)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: _accent(context).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(icon, color: _accent(context)),
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
                        color: _surfaceText(context),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _surfaceMuted(context),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: _surfaceMuted(context)),
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
    final bundle = const RuleImporter().importFromText(text);
    if (context.mounted) await _showRuleSelectionDialog(context, ref, bundle);
  } catch (error) {
    if (context.mounted) _showSnack(context, _friendlyImportError(error));
  }
}

Future<bool> _handleRepositoryAddress(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    _showSnack(context, '请输入 GitHub 仓库或 raw JSON 地址');
    return false;
  }
  try {
    if (GitHubRuleRepositoryScanner.isRepositoryUrl(trimmed)) {
      final scan = await const GitHubRuleRepositoryScanner().scan(trimmed);
      if (!context.mounted) return false;
      await _showGitHubCandidateDialog(context, ref, scan);
      return true;
    }
    final bundle = await const RuleImporter().importFromUrl(trimmed);
    if (!context.mounted) return false;
    await _showRuleSelectionDialog(context, ref, bundle);
    return true;
  } catch (error) {
    if (context.mounted) _showSnack(context, _friendlyImportError(error));
    return false;
  }
}

Future<void> _showGitHubCandidateDialog(
  BuildContext context,
  WidgetRef ref,
  GitHubRepositoryScan scan,
) async {
  String? selectedUrl;
  var loading = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = Theme.of(context).colorScheme;
          return AlertDialog(
            title: Text('扫描结果 · ${scan.name}'),
            content: SizedBox(
              width: 680,
              height: 480,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '默认分支：${scan.defaultBranch}。请选择一个候选文件预览，系统不会自动导入整仓。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (scan.truncated) ...[
                    const SizedBox(height: 6),
                    Text(
                      'GitHub 返回的文件树已截断，当前仅展示可见候选。',
                      style: TextStyle(color: colors.tertiary),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: scan.candidates.isEmpty
                        ? const Center(child: Text('没有找到 JSON/TXT 候选文件'))
                        : ListView.separated(
                            itemCount: scan.candidates.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final candidate = scan.candidates[index];
                              return CheckboxListTile(
                                value: selectedUrl == candidate.rawUrl,
                                onChanged: candidate.canImport
                                    ? (selected) {
                                        setDialogState(() {
                                          selectedUrl = selected == true
                                              ? candidate.rawUrl
                                              : null;
                                        });
                                      }
                                    : null,
                                title: Text(candidate.path),
                                subtitle: Text(
                                  candidate.blockedReason ??
                                      '${candidate.sizeLabel} · 只读预览后再选择规则',
                                ),
                                secondary: Icon(
                                  candidate.canImport
                                      ? Icons.description_outlined
                                      : Icons.error_outline_rounded,
                                  color: candidate.canImport
                                      ? colors.primary
                                      : colors.error,
                                ),
                                controlAffinity:
                                    ListTileControlAffinity.trailing,
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: loading
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: loading || selectedUrl == null
                    ? null
                    : () async {
                        setDialogState(() => loading = true);
                        try {
                          final bundle = await const RuleImporter()
                              .importFromUrl(selectedUrl!);
                          if (!dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop();
                          if (context.mounted) {
                            await _showRuleSelectionDialog(
                              context,
                              ref,
                              bundle,
                            );
                          }
                        } catch (error) {
                          if (context.mounted) {
                            _showSnack(context, _friendlyImportError(error));
                          }
                          if (dialogContext.mounted) {
                            setDialogState(() => loading = false);
                          }
                        }
                      },
                icon: loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.preview_outlined),
                label: Text(loading ? '读取中' : '预览规则'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> _showKazumiSelectionDialog(
  BuildContext context, {
  required List<KazumiRuleCatalogEntry> entries,
  required Set<String> installedIds,
  required Future<bool> Function(List<KazumiRuleCatalogEntry> entries)
  onInstall,
}) async {
  final selectedIds = <String>{
    for (final entry in entries)
      if (!installedIds.contains(entry.id)) entry.id,
  };
  var importing = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = Theme.of(context).colorScheme;
          return AlertDialog(
            title: const Text('批量安装番剧规则'),
            content: SizedBox(
              width: 680,
              height: 500,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已默认选中尚未安装的规则，也可以自行增减。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                      TextButton(
                        onPressed: importing
                            ? null
                            : () => setDialogState(() {
                                selectedIds
                                  ..clear()
                                  ..addAll(entries.map((entry) => entry.id));
                              }),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: importing
                            ? null
                            : () => setDialogState(selectedIds.clear),
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final installed = installedIds.contains(entry.id);
                        final updatedAt = entry.updatedAt;
                        final date =
                            '${updatedAt.year}-${updatedAt.month.toString().padLeft(2, '0')}-${updatedAt.day.toString().padLeft(2, '0')}';
                        return CheckboxListTile(
                          value: selectedIds.contains(entry.id),
                          onChanged: importing
                              ? null
                              : (selected) {
                                  setDialogState(() {
                                    if (selected == true) {
                                      selectedIds.add(entry.id);
                                    } else {
                                      selectedIds.remove(entry.id);
                                    }
                                  });
                                },
                          title: Text(entry.name),
                          subtitle: Text(
                            'v${entry.version} · $date${installed ? ' · 已安装，可重新获取更新' : ''}',
                          ),
                          secondary: Icon(
                            installed
                                ? Icons.check_circle_outline_rounded
                                : Icons.rule_folder_outlined,
                            color: colors.primary,
                          ),
                        );
                      },
                    ),
                  ),
                ],
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
                onPressed: importing || selectedIds.isEmpty
                    ? null
                    : () async {
                        setDialogState(() => importing = true);
                        final selected = entries
                            .where((entry) => selectedIds.contains(entry.id))
                            .toList(growable: false);
                        final installed = await onInstall(selected);
                        if (!dialogContext.mounted) return;
                        if (installed) {
                          Navigator.of(dialogContext).pop();
                        } else {
                          setDialogState(() => importing = false);
                        }
                      },
                icon: importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_done_rounded),
                label: Text(importing ? '安装中' : '安装所选 ${selectedIds.length} 条'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> _showRuleSelectionDialog(
  BuildContext context,
  WidgetRef ref,
  RuleImportBundle bundle,
) async {
  final selectedIds = <String>{};
  var importing = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = Theme.of(context).colorScheme;
          return AlertDialog(
            title: Text('选择规则 · ${bundle.name}'),
            content: SizedBox(
              width: 680,
              height: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '默认不勾选。导入后可在播放规则中自行启用执行。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: bundle.rules.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final rule = bundle.rules[index];
                        return CheckboxListTile(
                          value: selectedIds.contains(rule.id),
                          onChanged: (selected) {
                            setDialogState(() {
                              if (selected == true) {
                                selectedIds.add(rule.id);
                              } else {
                                selectedIds.remove(rule.id);
                              }
                            });
                          },
                          title: Text(rule.name),
                          subtitle: Text(
                            '${rule.contentLabel} · ${rule.engine}',
                          ),
                          secondary: Icon(
                            Icons.rule_folder_outlined,
                            color: colors.primary,
                          ),
                        );
                      },
                    ),
                  ),
                ],
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
                onPressed: importing || selectedIds.isEmpty
                    ? null
                    : () async {
                        setDialogState(() => importing = true);
                        final selected = bundle.rules
                            .where((rule) => selectedIds.contains(rule.id))
                            .toList(growable: false);
                        try {
                          final result = await ref
                              .read(animeControllerProvider.notifier)
                              .importSelectedRulePlugins(
                                repositoryName: bundle.name,
                                rules: selected,
                                sourceUrl: bundle.sourceUrl,
                              );
                          if (!dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop();
                          if (context.mounted) {
                            _showSnack(
                              context,
                              '已安装 ${result.installedCount} 条规则，默认未启用',
                            );
                          }
                        } catch (error) {
                          if (context.mounted) {
                            _showSnack(context, _friendlyImportError(error));
                          }
                          if (dialogContext.mounted) {
                            setDialogState(() => importing = false);
                          }
                        }
                      },
                icon: importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_done_rounded),
                label: Text(importing ? '安装中' : '安装所选'),
              ),
            ],
          );
        },
      );
    },
  );
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
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
            title: const Text('添加自定义仓库'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '粘贴 GitHub 仓库首页时，会列出 JSON/TXT 文件；粘贴 raw JSON 时，会直接进入规则预览。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _surfaceMuted(context),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'GitHub 仓库或 raw JSON 地址',
                      hintText: 'https://github.com/owner/repo',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '配置字段会按原样保留，导入后可在播放规则中自行启用。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _surfaceMuted(context),
                    ),
                  ),
                ],
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
                        final imported = await _handleRepositoryAddress(
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
                    : const Icon(Icons.manage_search_rounded),
                label: Text(importing ? '读取中' : '扫描 / 预览'),
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
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
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
