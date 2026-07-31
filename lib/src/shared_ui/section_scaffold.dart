import 'package:flutter/material.dart';

import 'app_design.dart';

class SectionScaffold extends StatelessWidget {
  const SectionScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const [],
    this.eyebrow,
    this.leading,
    this.maxWidth = AppLayout.maxContentWidth,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;
  final String? eyebrow;
  final Widget? leading;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: AppLayout.pagePadding(context),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PageHeader(
                  title: title,
                  subtitle: subtitle,
                  eyebrow: eyebrow,
                  leading: leading,
                  actions: actions,
                ),
                const SizedBox(height: AppSpacing.xl),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.title,
    required this.subtitle,
    required this.eyebrow,
    required this.leading,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final String? eyebrow;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleBlock = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leading != null) ...[
          leading!,
          const SizedBox(width: AppSpacing.lg),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow != null && eyebrow!.trim().isNotEmpty) ...[
                Text(
                  eyebrow!.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.headlineMedium?.copyWith(color: scheme.onSurface),
              ),
              if (subtitle.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (actions.isEmpty) return titleBlock;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 720;
        if (stack) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleBlock,
              const SizedBox(height: AppSpacing.lg),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: actions,
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: titleBlock),
            const SizedBox(width: AppSpacing.xl),
            Flexible(
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: actions,
              ),
            ),
          ],
        );
      },
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.compact = false,
    this.onTheater = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool compact;
  final bool onTheater;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      icon: icon,
      title: title,
      message: message,
      action: action,
      compact: compact,
      onTheater: onTheater,
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({
    super.key,
    this.title = '正在加载',
    this.message = '正在整理内容，请稍候。',
    this.compact = false,
  });

  final String title;
  final String message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      icon: Icons.hourglass_top_rounded,
      title: title,
      message: message,
      compact: compact,
      progress: true,
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.title = '加载失败',
    this.onRetry,
    this.retryLabel = '重新加载',
    this.compact = false,
    this.onTheater = false,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final bool compact;
  final bool onTheater;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      icon: Icons.cloud_off_rounded,
      title: title,
      message: message,
      compact: compact,
      onTheater: onTheater,
      tone: AppStateTone.error,
      action: onRetry == null
          ? null
          : FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(retryLabel),
            ),
    );
  }
}

enum AppStateTone { neutral, info, success, warning, error }

class AppStateView extends StatelessWidget {
  const AppStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.compact = false,
    this.progress = false,
    this.tone = AppStateTone.neutral,
    this.onTheater = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool compact;
  final bool progress;
  final AppStateTone tone;

  /// When true, ink stays on fixed theater tokens (player panels).
  final bool onTheater;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = onTheater
        ? switch (tone) {
            AppStateTone.error => AppStatusColors.failed,
            AppStateTone.warning => AppStatusColors.probing,
            AppStateTone.success => AppStatusColors.available,
            _ => AppColors.primary2,
          }
        : _toneColor(context, tone);
    final titleColor = onTheater ? AppColors.theaterInk : scheme.onSurface;
    final bodyColor =
        onTheater ? AppColors.theaterMuted : scheme.onSurfaceVariant;
    final content = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: compact ? 360 : 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.13),
              shape: BoxShape.circle,
              border: Border.all(color: accent.withValues(alpha: 0.24)),
            ),
            child: SizedBox.square(
              dimension: compact ? 54 : 66,
              child: progress
                  ? Padding(
                      padding: EdgeInsets.all(compact ? 16 : 20),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: accent,
                      ),
                    )
                  : Icon(icon, size: compact ? 27 : 32, color: accent),
            ),
          ),
          SizedBox(height: compact ? AppSpacing.md : AppSpacing.lg),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(color: titleColor),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: bodyColor),
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.xl),
            action!,
          ],
        ],
      ),
    );

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: compact
            ? content
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: onTheater
                      ? AppColors.theaterPanel.withValues(alpha: 0.92)
                      : scheme.surfaceContainer.withValues(alpha: 0.74),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  border: Border.all(
                    color: onTheater
                        ? AppColors.theaterBorder
                        : scheme.outlineVariant,
                  ),
                  boxShadow: onTheater ? const [] : AppShadows.panel,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 36,
                    vertical: 32,
                  ),
                  child: content,
                ),
              ),
      ),
    );
  }
}

class AppStatusBanner extends StatelessWidget {
  const AppStatusBanner({
    super.key,
    required this.title,
    required this.message,
    this.tone = AppStateTone.info,
    this.action,
  });

  final String title;
  final String message;
  final AppStateTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final accent = _toneColor(context, tone);
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.08),
          scheme.surfaceContainer,
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_toneIcon(tone), color: accent, size: 21),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: AppSpacing.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Standard grid geometry for posters and media tiles.
class AppResponsiveGrid extends StatelessWidget {
  const AppResponsiveGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.minItemWidth = 180,
    this.childAspectRatio = 0.62,
    this.spacing = AppSpacing.lg,
    this.padding = EdgeInsets.zero,
    this.physics,
    this.shrinkWrap = false,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double minItemWidth;
  final double childAspectRatio;
  final double spacing;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics? physics;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count =
            ((constraints.maxWidth + spacing) / (minItemWidth + spacing))
                .floor()
                .clamp(1, 12);
        return GridView.builder(
          padding: padding,
          physics: physics,
          shrinkWrap: shrinkWrap,
          itemCount: itemCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: childAspectRatio,
          ),
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}

Color _toneColor(BuildContext context, AppStateTone tone) {
  final scheme = Theme.of(context).colorScheme;
  return switch (tone) {
    AppStateTone.neutral => scheme.primary,
    AppStateTone.info => scheme.secondary,
    AppStateTone.success => AppColors.success,
    AppStateTone.warning => AppColors.warning,
    AppStateTone.error => AppColors.danger,
  };
}

IconData _toneIcon(AppStateTone tone) {
  return switch (tone) {
    AppStateTone.neutral => Icons.info_outline_rounded,
    AppStateTone.info => Icons.info_outline_rounded,
    AppStateTone.success => Icons.check_circle_outline_rounded,
    AppStateTone.warning => Icons.warning_amber_rounded,
    AppStateTone.error => Icons.error_outline_rounded,
  };
}
