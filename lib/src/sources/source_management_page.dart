import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import 'source_catalog_models.dart';

class SourceManagementPage extends ConsumerWidget {
  const SourceManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final catalog = state.sourceCatalog;
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '外部源目录',
          onBack: () => safeNavigateBack(context, fallbackRoute: '/profile'),
          rightRail: _SourceStatsRail(catalog: catalog),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 120),
            children: [
              _SourceHeader(catalog: catalog),
              const SizedBox(height: 16),
              if (catalog.hasError)
                _SourceLoadError(message: catalog.loadError ?? '读取失败')
              else if (catalog.sources.isEmpty)
                const _SourceEmpty()
              else
                for (final source in catalog.sources) ...[
                  _SourceCard(
                    source: source,
                    playbackRuleCount: catalog.playbackRuleCountFor(source.id),
                    onChanged: (enabled) => ref
                        .read(animeControllerProvider.notifier)
                        .toggleVideoSource(source.id, enabled),
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

class _SourceHeader extends StatelessWidget {
  const _SourceHeader({required this.catalog});

  final SourceCatalogState catalog;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      borderColor: AppColors.borderBright,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.hub_outlined, color: AppColors.primary),
              SizedBox(width: 10),
              Expanded(
                child: SectionTitle(
                  title: '已登记外部资源',
                  subtitle: 'TVBox 参与影视查源，M3U 提供直播，BT 资源交给外部客户端',
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _SourceMetric(label: '目录', value: '${catalog.importedCount}'),
              const SizedBox(width: 10),
              _SourceMetric(label: '启用', value: '${catalog.enabledCount}'),
              const SizedBox(width: 10),
              _SourceMetric(label: '可搜索', value: '${catalog.searchableCount}'),
            ],
          ),
          if (catalog.generatedAt != null) ...[
            const SizedBox(height: 12),
            Text(
              '目录生成于 ${_formatDate(catalog.generatedAt!)}，版本 ${catalog.version}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceMetric extends StatelessWidget {
  const _SourceMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
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
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.playbackRuleCount,
    required this.onChanged,
  });

  final VideoSource source;
  final int playbackRuleCount;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return AppPanel(
      color: source.enabled ? const Color(0xFF111922) : AppColors.panel,
      borderColor: source.enabled ? AppColors.borderBright : AppColors.border,
      child: compact ? _compactLayout(context) : _wideLayout(context),
    );
  }

  Widget _wideLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SourceIcon(source: source),
        const SizedBox(width: 14),
        Expanded(
          child: _SourceText(
            source: source,
            playbackRuleCount: playbackRuleCount,
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _HealthBadge(source: source),
            const SizedBox(height: 12),
            Switch(
              key: ValueKey('sourceToggle:${source.id}'),
              value: source.enabled,
              onChanged: onChanged,
            ),
          ],
        ),
      ],
    );
  }

  Widget _compactLayout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SourceIcon(source: source),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                source.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Switch(
              key: ValueKey('sourceToggle:${source.id}'),
              value: source.enabled,
              onChanged: onChanged,
            ),
          ],
        ),
        const SizedBox(height: 10),
        _SourceText(
          source: source,
          playbackRuleCount: playbackRuleCount,
          showTitle: false,
        ),
        const SizedBox(height: 10),
        _HealthBadge(source: source),
      ],
    );
  }
}

class _SourceIcon extends StatelessWidget {
  const _SourceIcon({required this.source});

  final VideoSource source;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: source.enabled
            ? AppColors.primary.withValues(alpha: 0.18)
            : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: source.enabled ? AppColors.primary : AppColors.border,
        ),
      ),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Icon(
          source.kind == VideoSourceKind.liveM3u
              ? Icons.live_tv_outlined
              : source.kind == VideoSourceKind.torrent
              ? Icons.cloud_download_outlined
              : Icons.account_tree_outlined,
          color: source.enabled ? AppColors.primary : context.inkMuted,
        ),
      ),
    );
  }
}

class _SourceText extends StatelessWidget {
  const _SourceText({
    required this.source,
    required this.playbackRuleCount,
    this.showTitle = true,
  });

  final VideoSource source;
  final int playbackRuleCount;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle) ...[
          Row(
            children: [
              Flexible(
                child: Text(
                  source.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SmallBadge(
                label: source.enabled ? '启用' : '禁用',
                active: source.enabled,
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            SmallBadge(label: source.kind.label, active: source.enabled),
            if (source.canSearchAtRuntime) const SmallBadge(label: '可搜索'),
            if (source.supportsCategories) const SmallBadge(label: '分类'),
            if (source.supportsDanmaku) const SmallBadge(label: '弹幕'),
            if (source.usesNativePlayer) const SmallBadge(label: '原生播放'),
            if (source.kind == VideoSourceKind.tvBox)
              SmallBadge(
                label: '接入 $playbackRuleCount 条规则',
                active: source.enabled && playbackRuleCount > 0,
              ),
            if (source.antiCrawlerEnabled) const SmallBadge(label: '需验证'),
            ...source.tags.take(3).map((tag) => SmallBadge(label: tag)),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          source.message.trim().isEmpty ? '暂无说明' : source.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
        ),
        const SizedBox(height: 5),
        Text(
          source.endpointText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.inkFaint),
        ),
      ],
    );
  }
}

class _HealthBadge extends StatelessWidget {
  const _HealthBadge({required this.source});

  final VideoSource source;

  @override
  Widget build(BuildContext context) {
    final color = _healthColor(source);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.62)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_healthIcon(source), size: 17, color: color),
            const SizedBox(width: 6),
            Text(
              source.healthLabel,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceStatsRail extends StatelessWidget {
  const _SourceStatsRail({required this.catalog});

  final SourceCatalogState catalog;

  @override
  Widget build(BuildContext context) {
    final tvBoxCount = catalog.sources
        .where((source) => source.kind == VideoSourceKind.tvBox)
        .length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '源状态', subtitle: '按本地目录汇总'),
              const SizedBox(height: 14),
              _RailSourceLine(
                icon: Icons.account_tree_outlined,
                label: 'TVBox 配置',
                value: '$tvBoxCount',
              ),
              _RailSourceLine(
                icon: Icons.live_tv_outlined,
                label: 'M3U 直播',
                value: '${catalog.liveCount}',
              ),
              _RailSourceLine(
                icon: Icons.cloud_download_outlined,
                label: 'BT/磁力',
                value: '${catalog.torrentCount}',
              ),
              _RailSourceLine(
                icon: Icons.search_rounded,
                label: '支持搜索',
                value: '${catalog.searchableCount}',
              ),
              _RailSourceLine(
                icon: Icons.rule_folder_outlined,
                label: '参与播放查源',
                value: '${catalog.activePlaybackRuleCount}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: '目录与规则'),
              SizedBox(height: 12),
              _RailNote(text: '启用/禁用会保存到本地设置'),
              _RailNote(text: 'TVBox JSON/XBPQ 可解析项会自动加入播放查源'),
              _RailNote(text: 'M3U、BT 和公开媒体仍按各自功能使用'),
            ],
          ),
        ),
      ],
    );
  }
}

class _RailSourceLine extends StatelessWidget {
  const _RailSourceLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SmallBadge(label: value),
        ],
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
              ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceLoadError extends StatelessWidget {
  const _SourceLoadError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        children: [
          const Icon(Icons.error_outline, color: AppColors.primary, size: 34),
          const SizedBox(height: 12),
          Text(
            '源目录读取失败',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: context.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _SourceEmpty extends StatelessWidget {
  const _SourceEmpty();

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        children: [
          const Icon(Icons.hub_outlined, color: AppColors.primary, size: 34),
          const SizedBox(height: 12),
          Text(
            '还没有导入源',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: context.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '生成 sources_catalog.json 后，这里会展示可管理的外部资源目录。',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
          ),
        ],
      ),
    );
  }
}

Color _healthColor(VideoSource source) {
  if (source.executableUnsupported) return const Color(0xFFFF9F6E);
  if (source.antiCrawlerEnabled) return const Color(0xFFFFD166);
  return switch (source.health.trim().toLowerCase()) {
    'ok' || 'healthy' || 'pass' || 'available' => const Color(0xFF4DD7A5),
    'warning' || 'degraded' || 'limited' => const Color(0xFFFFD166),
    'error' || 'failed' || 'unhealthy' || 'offline' => const Color(0xFFFF7A90),
    _ => const Color(0xFF9A968A),
  };
}

IconData _healthIcon(VideoSource source) {
  if (source.executableUnsupported) return Icons.block_outlined;
  if (source.antiCrawlerEnabled) return Icons.verified_user_outlined;
  return switch (source.health.trim().toLowerCase()) {
    'ok' || 'healthy' || 'pass' || 'available' => Icons.check_circle_outline,
    'warning' || 'degraded' || 'limited' => Icons.info_outline,
    'error' || 'failed' || 'unhealthy' || 'offline' => Icons.error_outline,
    _ => Icons.help_outline,
  };
}

String _formatDate(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}
