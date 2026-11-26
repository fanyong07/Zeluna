import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/anime_app.dart';
import '../core/identity/stable_identity.dart';
import '../data/anime_controller.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../sources/source_catalog_models.dart';
import 'bundled_community_subscriptions.dart';
import 'github_rule_repository_scanner.dart';
import 'rule_importer.dart';
import 'rule_models.dart';
import 'rule_plugin_repository.dart';
import 'rule_security.dart';

Color _surfaceText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _surfaceMuted(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

Color _surfaceHigh(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHigh;

Color _surfaceBorder(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant;

Color _accent(BuildContext context) => Theme.of(context).colorScheme.primary;

class RuleManagementPage extends ConsumerStatefulWidget {
  const RuleManagementPage({super.key});

  @override
  ConsumerState<RuleManagementPage> createState() => _RuleManagementPageState();
}

class _RuleManagementPageState extends ConsumerState<RuleManagementPage> {
  final Set<RuleContentType> _expandedGroups = <RuleContentType>{};
  final Set<RuleContentType> _refreshingGroups = <RuleContentType>{};

  Future<void> _refreshGroup(RuleContentType type) async {
    if (_refreshingGroups.contains(type)) return;
    setState(() => _refreshingGroups.add(type));
    try {
      await _refreshRules(context, ref, groupLabel: type.label);
    } finally {
      if (mounted) setState(() => _refreshingGroups.remove(type));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final repository = RulePluginRepository(
          extraRules: state.rulePlugins.customRules,
        );
        final visibleAllRules = visibleUserRules(
          repository.allRules,
          repositories: state.rulePlugins.repositories,
        );
        final visibleRepositories = visibleUserRuleRepositories(
          state.rulePlugins.repositories,
        );
        final installed = visibleUserRules(
          repository.installedRules(state.rulePlugins),
          repositories: state.rulePlugins.repositories,
        );
        final executableInstalled = installed
            .where((rule) => rule.canResolveNatively)
            .toList(growable: false);
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
            executableInstalled.isEmpty ||
            executableInstalled.every(
              (rule) => state.rulePlugins.isEnabled(rule.id),
            );
        final allCatalogEnabled =
            catalogPlaybackSources.isEmpty ||
            catalogPlaybackSources.every((source) => source.enabled);
        final noCatalogEnabled = catalogPlaybackSources.every(
          (source) => !source.enabled,
        );
        final compact = MediaQuery.sizeOf(context).width < 760;
        final horizontalPadding = compact
            ? const EdgeInsets.symmetric(horizontal: 14)
            : const EdgeInsets.fromLTRB(24, 0, 20, 0);
        final topActions = _RuleTopActions(
          onRefresh: () => _refreshRules(context, ref),
          onAdd: () => _showImportSheet(context, ref),
        );
        final rulesByType = <RuleContentType, List<RulePlugin>>{
          for (final type in RuleContentType.values)
            type: installed
                .where((rule) => rule.contentType == type)
                .toList(growable: false),
        };
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '扩展来源',
          onBack: () => safeNavigateBack(context, fallbackRoute: '/profile'),
          trailing: topActions,
          compactAction: topActions,
          rightRail: _RuleStatsRail(
            rules: visibleAllRules,
            state: state.rulePlugins,
          ),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding.left,
                  6,
                  horizontalPadding.right,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        repositoryCount: visibleRepositories.length + 1,
                        onOpenRepository: () =>
                            context.push('/profile/rules/repository'),
                        onEnableAll: allInstalledEnabled && allCatalogEnabled
                            ? null
                            : () async {
                                final controller = ref.read(
                                  animeControllerProvider.notifier,
                                );
                                await controller.setInstalledRulePluginsEnabled(
                                  executableInstalled.map((rule) => rule.id),
                                  true,
                                );
                                for (final source in catalogPlaybackSources) {
                                  if (!source.enabled) {
                                    await controller.toggleVideoSource(
                                      source.id,
                                      true,
                                    );
                                  }
                                }
                                if (context.mounted) {
                                  _showSnack(context, '已启用全部扩展来源');
                                }
                              },
                        onDisableAll:
                            installedEnabledCount == 0 && noCatalogEnabled
                            ? null
                            : () async {
                                final controller = ref.read(
                                  animeControllerProvider.notifier,
                                );
                                await controller.setInstalledRulePluginsEnabled(
                                  installed.map((rule) => rule.id),
                                  false,
                                );
                                for (final source in catalogPlaybackSources) {
                                  if (source.enabled) {
                                    await controller.toggleVideoSource(
                                      source.id,
                                      false,
                                    );
                                  }
                                }
                                if (context.mounted) {
                                  _showSnack(context, '已关闭全部扩展来源');
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
                        ),
                    ],
                  ),
                ),
              ),
              if (installed.isNotEmpty)
                for (final type in RuleContentType.values) ...[
                  SliverPadding(
                    padding: horizontalPadding,
                    sliver: SliverToBoxAdapter(
                      child: _InstalledRuleGroupHeader(
                        type: type,
                        rules: rulesByType[type]!,
                        state: state.rulePlugins,
                        expanded: _expandedGroups.contains(type),
                        refreshing: _refreshingGroups.contains(type),
                        onToggleExpanded: () => setState(() {
                          if (!_expandedGroups.remove(type)) {
                            _expandedGroups.add(type);
                          }
                        }),
                        onSetEnabled: (rules, enabled) => ref
                            .read(animeControllerProvider.notifier)
                            .setInstalledRulePluginsEnabled(
                              rules.map((rule) => rule.id),
                              enabled,
                            ),
                        onRefresh: () => _refreshGroup(type),
                      ),
                    ),
                  ),
                  if (_expandedGroups.contains(type))
                    if (rulesByType[type]!.isEmpty)
                      SliverPadding(
                        padding: horizontalPadding,
                        sliver: SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                            child: Text(
                              '还没有安装这一类规则。',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: _surfaceMuted(context)),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding.left,
                          10,
                          horizontalPadding.right,
                          0,
                        ),
                        sliver: SliverList.builder(
                          itemCount: rulesByType[type]!.length,
                          itemBuilder: (_, index) {
                            final rule = rulesByType[type]![index];
                            return _InstalledRuleRow(
                              rule: rule,
                              enabled: state.rulePlugins.isEnabled(rule.id),
                              onToggle: (value) =>
                                  _toggleRulePluginWithApproval(
                                    context,
                                    ref,
                                    state.rulePlugins,
                                    rule,
                                    value,
                                  ),
                              onRemove: () => ref
                                  .read(animeControllerProvider.notifier)
                                  .uninstallRulePlugin(rule.id),
                            );
                          },
                        ),
                      ),
                  const SliverToBoxAdapter(child: SizedBox(height: 14)),
                ],
              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
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
        final visibleAllRules = visibleUserRules(
          repository.allRules,
          repositories: state.rulePlugins.repositories,
        );
        final visibleRepositories = visibleUserRuleRepositories(
          state.rulePlugins.repositories,
        );
        final rules = visibleUserRules(
          repository.rulesFor(_type),
          repositories: state.rulePlugins.repositories,
        );
        final compact = MediaQuery.sizeOf(context).width < 760;
        final topActions = _RuleTopActions(
          onAdd: () => _showImportSheet(context, ref),
        );
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '来源合集',
          onBack: () =>
              safeNavigateBack(context, fallbackRoute: '/profile/rules'),
          trailing: topActions,
          compactAction: topActions,
          rightRail: _RepositoryRail(
            rules: visibleAllRules,
            selected: _type,
            onSelected: (value) => setState(() => _type = value),
          ),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: compact
                    ? const EdgeInsets.fromLTRB(14, 6, 14, 16)
                    : const EdgeInsets.fromLTRB(24, 6, 20, 16),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _RepositoryHeader(
                        selected: _type,
                        repositories: visibleRepositories,
                        onSelected: (value) => setState(() => _type = value),
                        onImport: () => _showRepositoryUrlDialog(context, ref),
                        onReviewSubscription: (url) =>
                            _handleRepositoryAddress(context, ref, url),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: compact
                    ? const EdgeInsets.fromLTRB(14, 0, 14, 120)
                    : const EdgeInsets.fromLTRB(24, 0, 20, 120),
                sliver: SliverList.builder(
                  itemCount: rules.length,
                  itemBuilder: (_, index) {
                    final rule = rules[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _RepositoryRuleCard(
                        rule: rule,
                        installed: state.rulePlugins.isInstalled(rule.id),
                        onInstall: () => ref
                            .read(animeControllerProvider.notifier)
                            .installRulePlugin(rule.id),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RuleTopActions extends StatelessWidget {
  const _RuleTopActions({this.onRefresh, this.onAdd});

  final VoidCallback? onRefresh;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
    final scheme = Theme.of(context).colorScheme;
    return AppPanel(
      borderColor: scheme.primary.withValues(alpha: 0.25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '扩展播放来源',
            icon: Icons.extension_outlined,
            subtitle:
                '番剧、电视剧、电影分开管理 · $repositoryCount 个合集'
                '${catalogPlaybackCount > 0 ? ' · 已自动启用 $catalogPlaybackCount 个来源' : ''}',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _RuleMetric(label: '已安装', value: '$installedCount'),
              const SizedBox(width: 10),
              _RuleMetric(label: '已启用', value: '$enabledCount'),
              const SizedBox(width: 10),
              _RuleMetric(label: '用于找线路', value: '$playbackCount'),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: onOpenRepository,
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('打开来源合集'),
              ),
              OutlinedButton.icon(
                onPressed: onEnableAll,
                icon: const Icon(Icons.toggle_on_outlined, size: 18),
                label: const Text('全部启用'),
              ),
              OutlinedButton.icon(
                onPressed: onDisableAll,
                icon: const Icon(Icons.toggle_off_outlined, size: 18),
                label: const Text('全部关闭'),
              ),
              OutlinedButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.restore_rounded, size: 18),
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
          const SectionTitle(title: '自动来源', subtitle: '跟着在线服务自动更新，不用单独管理'),
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
                      ? '可以提供 ${group.candidateRuleCount} 条播放线路'
                      : '合并了 ${group.sources.length} 个同名来源，共 '
                            '${group.candidateRuleCount} 条线路，找线路时会自动去掉重复的',
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

class _InstalledRuleGroupHeader extends StatelessWidget {
  const _InstalledRuleGroupHeader({
    required this.type,
    required this.rules,
    required this.state,
    required this.expanded,
    required this.refreshing,
    required this.onToggleExpanded,
    required this.onSetEnabled,
    required this.onRefresh,
  });

  final RuleContentType type;
  final List<RulePlugin> rules;
  final RulePluginState state;
  final bool expanded;
  final bool refreshing;
  final VoidCallback onToggleExpanded;
  final Future<void> Function(List<RulePlugin> rules, bool enabled)
  onSetEnabled;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final executableRules = rules
        .where((rule) => rule.canResolveNatively)
        .toList(growable: false);
    final enabledCount = executableRules
        .where((rule) => state.isEnabled(rule.id))
        .length;
    final allEnabled =
        executableRules.isNotEmpty && enabledCount == executableRules.length;
    final title = '${type.label}规则';

    Widget expandButton() => IconButton(
      key: ValueKey('ruleGroupExpand:${type.name}'),
      tooltip: expanded ? '收起$title' : '展开$title',
      onPressed: onToggleExpanded,
      icon: AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: const Duration(milliseconds: 180),
        child: const Icon(Icons.keyboard_arrow_down_rounded),
      ),
    );

    final refreshButton = OutlinedButton.icon(
      key: ValueKey('ruleGroupRefresh:${type.name}'),
      onPressed: refreshing ? null : onRefresh,
      icon: refreshing
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh_rounded, size: 18),
      label: Text(refreshing ? '更新中' : '更新'),
    );
    final toggleButton = FilledButton.tonalIcon(
      key: ValueKey('ruleGroupToggle:${type.name}'),
      onPressed: executableRules.isEmpty
          ? null
          : () => onSetEnabled(executableRules, !allEnabled),
      icon: Icon(
        allEnabled ? Icons.toggle_off_outlined : Icons.toggle_on_outlined,
        size: 19,
      ),
      label: Text(allEnabled ? '全部关闭' : '全部开启'),
    );

    return AppPanel(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final heading = SectionTitle(
            title: title,
            subtitle:
                '${rules.length} 个已安装 · '
                '$enabledCount/${executableRules.length} 个可用的已开启',
          );
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: heading),
                    expandButton(),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [refreshButton, toggleButton],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: heading),
              refreshButton,
              const SizedBox(width: 8),
              toggleButton,
              const SizedBox(width: 4),
              expandButton(),
            ],
          );
        },
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
    final canExecute = rule.canResolveNatively;
    final effectiveEnabled = enabled && canExecute;
    return Padding(
      key: ValueKey('installedRule:${rule.id}'),
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
                effectiveEnabled
                    ? Icons.power_settings_new
                    : Icons.power_off_outlined,
                color: effectiveEnabled
                    ? _accent(context)
                    : _surfaceMuted(context),
              ),
              const SizedBox(width: 12),
              Expanded(child: _RuleCardText(rule: rule)),
              Tooltip(
                message: canExecute ? '开启或关闭这个规则' : rule.executionStatus.label,
                child: Switch(
                  key: ValueKey('ruleToggle:${rule.id}'),
                  value: effectiveEnabled,
                  onChanged: canExecute ? onToggle : null,
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
                subtitle: '当前使用内置版本，暂时没有更新',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showSnack(context, '${rule.name} 用的是内置版本，暂时没有更新');
                },
              ),
              _RuleAction(
                icon: Icons.delete_outline,
                title: '删除规则',
                subtitle: '删掉之后还能从来源合集里重新装回来',
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

class _RepositoryHeader extends StatelessWidget {
  const _RepositoryHeader({
    required this.selected,
    required this.repositories,
    required this.onSelected,
    required this.onImport,
    required this.onReviewSubscription,
  });

  final RuleContentType selected;
  final List<RuleRepositoryRecord> repositories;
  final ValueChanged<RuleContentType> onSelected;
  final VoidCallback onImport;
  final ValueChanged<String> onReviewSubscription;

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
                  subtitle: '预览扩展来源，整组订阅启用或挑选安装',
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
                '支持标准自定义规则订阅地址。确认订阅后，应用运行时会定期刷新。新增或变更的规则不会自动启用，点订阅名称可整组重新确认。',
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
                for (final repository in repositories)
                  if (repository.url.isEmpty)
                    SmallBadge(
                      label: '${repository.name} · ${repository.ruleCount}',
                      active: true,
                    )
                  else
                    ActionChip(
                      label: Text(
                        '${repository.name} · ${repository.ruleCount}'
                        '${repository.autoRefresh ? ' · 定时刷新' : ''}',
                      ),
                      tooltip: '预览订阅并确认权限',
                      onPressed: () => onReviewSubscription(repository.url),
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
  });

  final RulePlugin rule;
  final bool installed;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
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
      key: ValueKey('ruleCard:${rule.id}'),
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
            SmallBadge(label: _ruleEngineLabel(rule.engine)),
            SmallBadge(label: rule.sourceLabel),
            SmallBadge(
              label: rule.effectiveManifest.trustLevel.label,
              active:
                  rule.effectiveManifest.trustLevel == RuleTrustLevel.official,
            ),
            if (rule.requiresCaptcha) const SmallBadge(label: '需验证码'),
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

Future<void> _toggleRulePluginWithApproval(
  BuildContext context,
  WidgetRef ref,
  RulePluginState state,
  RulePlugin rule,
  bool enabled,
) async {
  final controller = ref.read(animeControllerProvider.notifier);
  if (!enabled || state.hasApprovedPermissions(rule)) {
    await controller.toggleRulePlugin(rule.id, enabled);
    return;
  }
  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _RulePermissionDialog(rule: rule),
  );
  if (approved == true) {
    await controller.approveRulePluginPermissionsAndEnable(rule.id);
  }
}

class _RulePermissionDialog extends StatelessWidget {
  const _RulePermissionDialog({required this.rule});

  final RulePlugin rule;

  @override
  Widget build(BuildContext context) {
    final manifest = rule.effectiveManifest;
    final customHeaders = <String>[
      if (manifest.customReferer) 'Referer',
      if (manifest.customOrigin) 'Origin',
      if (manifest.customUserAgent) 'User-Agent',
    ];
    return AlertDialog(
      title: const Text('确认规则权限'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${manifest.name} · ${manifest.version}',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              _PermissionLine(label: '来源', value: manifest.sourceRepository),
              _PermissionLine(
                label: '版本指纹',
                value: _permissionFingerprint(manifest.contentHash),
                monospace: true,
              ),
              _PermissionLine(label: '信任等级', value: manifest.trustLevel.label),
              _PermissionLine(
                label: '页面域名',
                value: _permissionList(manifest.pageDomains),
              ),
              _PermissionLine(
                label: '媒体域名',
                value: _permissionList(manifest.mediaDomains),
              ),
              _PermissionLine(
                label: 'JavaScript',
                value: _permissionBool(manifest.javascript),
              ),
              _PermissionLine(
                label: 'Cookie',
                value: manifest.cookiePolicy.label,
              ),
              _PermissionLine(
                label: 'WebView',
                value: _permissionBool(manifest.webViewSniffing),
              ),
              _PermissionLine(
                label: '不加密的连接（HTTP）',
                value: _permissionBool(manifest.cleartextHttp),
              ),
              _PermissionLine(
                label: '自定义请求头',
                value: _permissionList(customHeaders),
              ),
              const SizedBox(height: 10),
              Text(
                '这次只授权当前这个版本；规则更新后会再问你一次。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _surfaceMuted(context)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('批准并启用'),
        ),
      ],
    );
  }
}

class _PermissionLine extends StatelessWidget {
  const _PermissionLine({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: _surfaceMuted(context)),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.trim().isEmpty ? '无' : value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _permissionBool(bool enabled) => enabled ? '允许' : '不允许';

String _permissionList(Iterable<String> values) {
  final normalized = values.where((value) => value.trim().isNotEmpty).toList();
  return normalized.isEmpty ? '无' : normalized.join('、');
}

/// 只展示指纹前 8 位，完整摘要对用户没有判断价值。
String _permissionFingerprint(String hash) {
  final normalized = hash.trim();
  if (normalized.length <= 8) return normalized;
  return normalized.substring(0, 8);
}

String _ruleStatusLabel(RulePlugin rule) {
  return rule.executionStatus.label;
}

/// 把内部引擎代号换成可读的规则类型名，避免 `xbpq` / `drpy-js` 这类裸代号上屏。
String _ruleEngineLabel(String engine) {
  return switch (engine.trim().toLowerCase()) {
    'xbpq' => 'XBPQ 规则',
    'drpy-js' => 'drpy 规则',
    'animeko-web-selector' => '网页规则',
    'animeko-rss' => '订阅来源',
    'tvbox-json-api' || 'tvbox-xml-api' => 'TVBox 接口',
    'tvbox-spider' => 'TVBox 扩展',
    'android-csp' || 'csp' => 'CSP 规则',
    'native' => '内置规则',
    'aikanbot-api' || 'sorani-api' => '站点接口',
    'repository-link' => '合集地址',
    _ => '其他规则',
  };
}

String _ruleDisplayNote(RulePlugin rule) {
  final reason = rule.unsupportedReason?.trim() ?? '';
  if (!rule.canResolveNatively && reason.isNotEmpty) return reason;
  if (rule.canResolveNatively) {
    return rule.note.trim().isEmpty ? '这个来源可以直接用来找线路。' : rule.note;
  }
  return switch (rule.executionStatus) {
    RuleExecutionStatus.needsWebView => '需要你在网页里手动过一次验证。',
    RuleExecutionStatus.needsPrivateAuth => '需要登录、Cookie 或其他私密授权后才能使用。',
    RuleExecutionStatus.missingConfig => '这条规则信息不全，暂时用不了。',
    RuleExecutionStatus.unsupportedEngine => '这类来源暂时不支持。',
    RuleExecutionStatus.executable => rule.note,
  };
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
            '还没有扩展来源',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _surfaceText(context),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '可从来源合集添加推荐项。日常播放主要靠在线服务；扩展来源用于补充更多线路。',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _surfaceMuted(context)),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: onOpenRepository, child: const Text('去来源合集')),
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
              const SectionTitle(title: '规则状态', subtitle: '番剧、电视剧、电影分开管理'),
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
              _RailNote(text: '只收信息齐全、能搜索、分类清楚的来源'),
              _RailNote(text: '不收直播、教育，以及要登录网盘或走本地代理的来源'),
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
                subtitle: '填名称和搜索地址，存在这台设备上',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showManualRuleDialog(context, ref);
                },
              ),
              const SizedBox(height: 10),
              _ImportAction(
                icon: Icons.inventory_2_outlined,
                title: '从来源合集导入',
                subtitle: '可安装推荐项，也可粘贴自己的合集地址',
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
                title: '粘贴 GitHub 仓库或规则文件地址',
                subtitle: '先预览内容，再整组启用或挑选安装',
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
    _showSnack(context, '请输入 GitHub 仓库或规则文件地址');
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
                    '这个仓库用的是 ${scan.defaultBranch} 分支。挑一个文件看看内容，不会一次性全导进来。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (scan.truncated) ...[
                    const SizedBox(height: 6),
                    Text(
                      '仓库文件太多，这里只列出了一部分。',
                      style: TextStyle(color: colors.tertiary),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: scan.candidates.isEmpty
                        ? const Center(child: Text('这个仓库里没有能导入的规则文件'))
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
                                      '${candidate.sizeLabel} · 先看内容，再决定装哪些',
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

Future<void> _showRuleSelectionDialog(
  BuildContext context,
  WidgetRef ref,
  RuleImportBundle bundle,
) async {
  final controller = ref.read(animeControllerProvider.notifier);
  final accountVersion = controller.accountContextVersion;
  final isRemote = bundle.sourceUrl.trim().isNotEmpty;
  final selectedIds = <String>{};
  var importing = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = Theme.of(context).colorScheme;
          Future<void> install({required bool enable}) async {
            setDialogState(() => importing = true);
            try {
              if (!controller.isAccountContextCurrent(accountVersion)) {
                throw const FormatException('账号已切换，请重新打开规则预览。');
              }
              final result = await controller.importSelectedRulePlugins(
                repositoryName: bundle.name,
                rules: enable
                    ? bundle.rules
                    : bundle.rules
                          .where((rule) => selectedIds.contains(rule.id))
                          .toList(),
                sourceUrl: bundle.sourceUrl,
                enable: enable,
              );
              if (!dialogContext.mounted) return;
              _showSnack(
                context,
                enable
                    ? '${isRemote ? '已订阅' : '已安装'} ${result.installedCount} 条规则，已启用 ${result.enabledCount} 条'
                    : '已安装 ${result.installedCount} 条规则，未额外启用',
              );
              Navigator.of(dialogContext).pop();
            } catch (error) {
              if (dialogContext.mounted) {
                _showSnack(context, _friendlyImportError(error));
                setDialogState(() => importing = false);
              }
            }
          }

          return AlertDialog(
            title: Text('预览规则 · ${bundle.name}'),
            content: SizedBox(
              width: 680,
              height: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '这些规则来自外部来源。整组启用即批准下列可用规则的当前版本及所列权限；新增或变更后需重新确认。只想安装部分规则，可勾选后选「仅安装所选」。',
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
                        final manifest = rule.effectiveManifest;
                        final capabilities = <String>[
                          if (manifest.javascript) 'JavaScript',
                          if (manifest.webViewSniffing) 'WebView',
                          if (manifest.cookiePolicy != RuleCookiePolicy.none)
                            'Cookie（${manifest.cookiePolicy.label}）',
                          if (manifest.cleartextHttp) 'HTTP',
                          if (manifest.customReferer) 'Referer',
                          if (manifest.customOrigin) 'Origin',
                          if (manifest.customUserAgent) 'User-Agent',
                        ];
                        return CheckboxListTile(
                          value: selectedIds.contains(rule.id),
                          onChanged: importing
                              ? null
                              : (selected) {
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
                            '${rule.contentLabel} · ${_ruleEngineLabel(rule.engine)} · '
                            '${rule.executionStatus.label} · ${manifest.version}\n'
                            '页面域名：${_permissionList(manifest.pageDomains)}\n'
                            '附加权限：${_permissionList(capabilities)}',
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
              OutlinedButton(
                onPressed: importing || selectedIds.isEmpty
                    ? null
                    : () => install(enable: false),
                child: const Text('仅安装所选'),
              ),
              FilledButton.icon(
                onPressed: importing ? null : () => install(enable: true),
                icon: importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_done_rounded),
                label: Text(
                  importing ? '正在导入' : (isRemote ? '订阅并启用' : '全部安装并启用'),
                ),
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
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '粘贴仓库地址会先列出里面的文件；直接粘贴规则文件地址就会跳到规则预览。',
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
                        labelText: 'GitHub 仓库或规则文件地址',
                        hintText: 'https://github.com/owner/repo',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '订阅并启用后会在应用运行时定期刷新；也可只安装所选规则。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _surfaceMuted(context),
                      ),
                    ),
                  ],
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
                  final id = stableRuleKey(
                    ruleId: 'manual:${name.trim().toLowerCase()}',
                    engine: 'native',
                    sourceRepository: baseUrl,
                    contentHash: stableDigest('${type.name}|$searchUrl'),
                  );
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

Future<void> _refreshRules(
  BuildContext context,
  WidgetRef ref, {
  String? groupLabel,
}) async {
  final result = await ref
      .read(animeControllerProvider.notifier)
      .refreshRuleRepositories();
  if (!context.mounted) return;
  final prefix = groupLabel == null ? '播放规则' : '$groupLabel规则';
  if (!result.hasRemoteRepositories) {
    _showSnack(context, '$prefix已同步到当前内置版本');
    return;
  }
  if (result.failedCount == 0) {
    _showSnack(
      context,
      '已更新$prefix · ${result.refreshedCount} 个仓库，${result.ruleCount} 条规则',
    );
    return;
  }
  _showSnack(
    context,
    '$prefix更新完成：${result.refreshedCount} 个成功，'
    '${result.failedCount} 个失败',
  );
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
