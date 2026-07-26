import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import 'app_design.dart';
import 'poster_card.dart';

export 'app_design.dart';

class AppChrome extends StatelessWidget {
  const AppChrome({
    super.key,
    required this.active,
    required this.child,
    this.searchController,
    this.onSearch,
    this.trailing,
    this.rightRail,
    this.bottomPlayer,
    this.title,
    this.showSearch = true,
    this.onBack,
  });

  final ChromeDestination active;
  final Widget child;
  final TextEditingController? searchController;
  final ValueChanged<String>? onSearch;
  final Widget? trailing;
  final Widget? rightRail;
  final Widget? bottomPlayer;
  final String? title;
  final bool showSearch;
  final VoidCallback? onBack;

  static final profileHistorySectionKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= AppBreakpoints.desktop;
    final showRightRail =
        rightRail != null && width >= AppBreakpoints.extraWide;
    const railWidth = 300.0;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final mobileBottomSpace = desktop
        ? 0.0
        : AppLayout.mobileNavigationHeight + bottomInset + 20;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: _ChromeBackdrop(
        child: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Row(
                children: [
                  if (desktop)
                    _SideNavigation(active: active, bottomPlayer: bottomPlayer),
                  Expanded(
                    child: Column(
                      children: [
                        _TopBar(
                          controller: searchController,
                          onSearch: onSearch,
                          title: title,
                          trailing: trailing,
                          showSearch: showSearch,
                          onBack: onBack,
                        ),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    bottom: mobileBottomSpace,
                                  ),
                                  child: child,
                                ),
                              ),
                              if (showRightRail) ...[
                                const SizedBox(width: AppSpacing.lg),
                                SizedBox(
                                  width: railWidth,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      right: AppSpacing.lg,
                                      bottom: AppSpacing.xxl,
                                    ),
                                    child: rightRail!,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!desktop)
                Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.sm + bottomInset,
                  child: _BottomNavigation(active: active),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum ChromeDestination {
  home(Icons.home_rounded, '首页', '/'),
  anime(Icons.explore_outlined, '番剧', '/anime'),
  schedule(Icons.calendar_month_outlined, '周期表', '/schedule'),
  series(Icons.live_tv_outlined, '剧集', '/series'),
  movie(Icons.movie_outlined, '电影', '/movies'),
  favorite(Icons.person_outline_rounded, '我的', '/profile'),
  download(Icons.download_for_offline_outlined, '下载', '/profile/offline'),
  history(Icons.history_rounded, '历史', '/history'),
  settings(Icons.settings_outlined, '设置', '/settings');

  const ChromeDestination(this.icon, this.label, this.route);

  final IconData icon;
  final String label;
  final String route;
}

/// A consistent surface for cards, rails, settings groups and detail sections.
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.radius = AppRadius.lg,
    this.borderColor,
    this.color,
    this.gradient,
    this.elevated = false,
    this.onTap,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? borderColor;
  final Color? color;
  final Gradient? gradient;
  final bool elevated;
  final VoidCallback? onTap;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = _resolveLegacySurface(context, color);
    final resolvedBorder = _resolveLegacyBorder(context, borderColor);
    final decoration = BoxDecoration(
      color: gradient == null ? resolvedColor : null,
      gradient: gradient,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: resolvedBorder),
      boxShadow: elevated ? AppShadows.elevated : AppShadows.panel,
    );
    final content = Padding(padding: padding, child: child);

    return DecoratedBox(
      decoration: decoration,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: clipBehavior,
        child: onTap == null
            ? content
            : Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap, child: content),
              ),
      ),
    );
  }
}

Color _resolveLegacySurface(BuildContext context, Color? color) {
  final scheme = Theme.of(context).colorScheme;
  if (color == null) return scheme.surfaceContainer;
  if (Theme.of(context).brightness == Brightness.dark) return color;
  final opaque = color.withValues(alpha: 1);
  final alpha = color.a;
  if (opaque == AppColors.bg) {
    return scheme.surfaceContainerLowest.withValues(alpha: alpha);
  }
  if (opaque == AppColors.bg2) {
    return scheme.surfaceContainerLow.withValues(alpha: alpha);
  }
  if (opaque == AppColors.panel) {
    return scheme.surfaceContainer.withValues(alpha: alpha);
  }
  if (opaque == AppColors.panelHigh || opaque == AppColors.panelHover) {
    return scheme.surfaceContainerHigh.withValues(alpha: alpha);
  }
  return color;
}

Color _resolveLegacyBorder(BuildContext context, Color? color) {
  final scheme = Theme.of(context).colorScheme;
  if (color == null) return scheme.outlineVariant;
  if (Theme.of(context).brightness == Brightness.dark) return color;
  final opaque = color.withValues(alpha: 1);
  final alpha = color.a;
  if (opaque == AppColors.border) {
    return scheme.outlineVariant.withValues(alpha: alpha);
  }
  if (opaque == AppColors.borderBright) {
    return scheme.outline.withValues(alpha: alpha);
  }
  return color;
}

/// Constrains page content without forcing every screen to repeat max-width
/// and responsive padding decisions.
class AppContentContainer extends StatelessWidget {
  const AppContentContainer({
    super.key,
    required this.child,
    this.padding,
    this.maxWidth = AppLayout.maxContentWidth,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double maxWidth;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: padding ?? AppLayout.pagePadding(context),
          child: child,
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.20)),
            ),
            child: SizedBox(
              width: 34,
              height: 34,
              child: Icon(icon, size: 18, color: scheme.primary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (action == null) return heading;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 460;
        if (stack) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading,
              const SizedBox(height: AppSpacing.md),
              Align(alignment: Alignment.centerLeft, child: action!),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: heading),
            const SizedBox(width: AppSpacing.lg),
            action!,
          ],
        );
      },
    );
  }
}

class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = true,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = compact
        ? ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          )
        : null;
    if (filled) {
      return DecoratedBox(
        decoration: const BoxDecoration(boxShadow: AppShadows.primaryGlow),
        child: FilledButton.icon(
          onPressed: onTap,
          style: style,
          icon: Icon(icon, size: compact ? 17 : 18),
          label: Text(label),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onTap,
      style: style,
      icon: Icon(icon, size: compact ? 17 : 18),
      label: Text(label),
    );
  }
}

class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.size = 42,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: size,
            child: Icon(
              icon,
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class SmallBadge extends StatelessWidget {
  const SmallBadge({
    super.key,
    required this.label,
    this.active = false,
    this.icon,
    this.onTap,
  });

  final String label;
  final bool active;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 14,
              color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: active ? scheme.primary : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(
          color: active ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: content,
    );
    if (onTap == null) return decorated;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: decorated,
      ),
    );
  }
}

class CompactSubjectRow extends StatelessWidget {
  const CompactSubjectRow({
    super.key,
    required this.subject,
    this.trailing,
    this.onTap,
  });

  final AnimeSubject subject;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: SizedBox(
                  width: 64,
                  height: 44,
                  child: PosterArt(
                    coverUrl: subject.bannerUrl,
                    fallbackCoverUrl: subject.coverUrl,
                    title: subject.title,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subject.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      subject.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(
                  trailing!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (onTap != null) ...[
                const SizedBox(width: AppSpacing.xs),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 19,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChromeBackdrop extends StatelessWidget {
  const _ChromeBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        gradient: dark ? AppGradients.page : null,
      ),
      child: child,
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({required this.active, this.bottomPlayer});

  final ChromeDestination active;
  final Widget? bottomPlayer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: AppLayout.sideNavigationWidth,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.84),
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(8, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.lg),
          const _BrandMark(),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Column(
                children: [
                  _NavigationGroup(
                    label: '发现',
                    active: active,
                    items: _discoverDestinations,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _NavigationGroup(
                    label: '资料库',
                    active: active,
                    items: _libraryDestinations,
                  ),
                  if (bottomPlayer != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                      child: bottomPlayer!,
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.xs,
              bottom: AppSpacing.lg,
            ),
            child: _NavItem(
              item: ChromeDestination.settings,
              active: active == ChromeDestination.settings,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavigationGroup extends StatelessWidget {
  const _NavigationGroup({
    required this.label,
    required this.active,
    required this.items,
  });

  final String label;
  final ChromeDestination active;
  final List<ChromeDestination> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 12, 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 1.2,
            ),
          ),
        ),
        for (final item in items) _NavItem(item: item, active: item == active),
      ],
    );
  }
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({required this.active});

  final ChromeDestination active;

  @override
  Widget build(BuildContext context) {
    final items = _mobileDestinations(active);
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
            boxShadow: AppShadows.elevated,
          ),
          child: SizedBox(
            height: AppLayout.mobileNavigationHeight,
            child: Row(
              children: [
                for (final item in items)
                  Expanded(
                    child: _BottomNavItem(
                      item: item,
                      active: item == active,
                      onTap: () => _go(context, item),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.item,
    required this.active,
    required this.onTap,
  });

  final ChromeDestination item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: AppMotion.quick,
                width: active ? 38 : 30,
                height: 28,
                decoration: BoxDecoration(
                  color: active ? null : Colors.transparent,
                  gradient: active ? AppGradients.accent : null,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  boxShadow: active ? AppShadows.primaryGlow : null,
                ),
                child: Icon(
                  item.icon,
                  size: 21,
                  color: active ? Colors.white : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: active ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.item, required this.active});

  final ChromeDestination item;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active ? null : Colors.transparent,
          gradient: active ? AppGradients.accent : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: active
                ? scheme.primary.withValues(alpha: 0.42)
                : Colors.transparent,
          ),
          boxShadow: active ? AppShadows.primaryGlow : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _go(context, item),
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  const SizedBox(width: AppSpacing.md),
                  Icon(
                    item.icon,
                    size: 20,
                    color: active ? Colors.white : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: active ? Colors.white : scheme.onSurfaceVariant,
                        fontWeight: active ? FontWeight.w900 : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _discoverDestinations = <ChromeDestination>[
  ChromeDestination.home,
  ChromeDestination.anime,
  ChromeDestination.schedule,
  ChromeDestination.series,
  ChromeDestination.movie,
];

const _libraryDestinations = <ChromeDestination>[
  ChromeDestination.favorite,
  ChromeDestination.download,
  ChromeDestination.history,
];

List<ChromeDestination> _mobileDestinations(ChromeDestination active) {
  final items = <ChromeDestination>[
    ChromeDestination.home,
    ChromeDestination.anime,
    ChromeDestination.series,
    ChromeDestination.movie,
    ChromeDestination.favorite,
  ];
  if (!items.contains(active)) items[4] = active;
  return items;
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.onSearch,
    required this.title,
    required this.trailing,
    required this.showSearch,
    required this.onBack,
  });

  final TextEditingController? controller;
  final ValueChanged<String>? onSearch;
  final String? title;
  final Widget? trailing;
  final bool showSearch;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < AppBreakpoints.compact;
    final horizontal = width < AppBreakpoints.mobile ? 14.0 : 24.0;
    final mainRow = Row(
      children: [
        if (onBack != null) ...[
          AppIconButton(
            icon: Icons.arrow_back,
            tooltip: '返回',
            onPressed: onBack,
          ),
          const SizedBox(width: AppSpacing.md),
        ],
        Expanded(
          child: showSearch
              ? _SearchField(controller: controller, onSearch: onSearch)
              : Text(
                  title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
        const SizedBox(width: AppSpacing.md),
        const _ThemeModeButton(),
        if (!compact && trailing != null) ...[
          const SizedBox(width: AppSpacing.lg),
          trailing!,
        ],
        if (width >= AppBreakpoints.extraWide) ...[
          const SizedBox(width: AppSpacing.lg),
          const _AvatarChip(),
        ],
      ],
    );

    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.76),
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontal,
          12,
          horizontal,
          compact ? 8 : 12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: compact ? 46 : 48, child: mainRow),
            if (compact && trailing != null) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: trailing!,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onSearch});

  final TextEditingController? controller;
  final ValueChanged<String>? onSearch;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: onSearch,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: IconButton(
              key: const ValueKey('appSearchSubmit'),
              tooltip: '搜索',
              onPressed: onSearch == null
                  ? null
                  : () => onSearch!(controller?.text ?? ''),
              icon: const Icon(Icons.arrow_forward_rounded, size: 20),
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 48,
              maxWidth: 48,
              minHeight: 48,
              maxHeight: 48,
            ),
            hintText: '搜索番剧、剧集、电影、演员',
            fillColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.78),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              borderSide: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              borderSide: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              borderSide: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeModeButton extends ConsumerWidget {
  const _ThemeModeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(animeControllerProvider).value?.appearance;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AppIconButton(
      icon: dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
      tooltip: dark ? '切换到日间模式' : '切换到夜间模式',
      selected: true,
      onPressed: appearance == null
          ? null
          : () async {
              await ref
                  .read(animeControllerProvider.notifier)
                  .updateAppearance(
                    appearance.copyWith(followSystem: false, darkMode: !dark),
                  );
            },
    );
  }
}

class _AvatarChip extends StatelessWidget {
  const _AvatarChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/profile'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: scheme.primary,
                child: Icon(
                  Icons.person_rounded,
                  size: 18,
                  color: scheme.onPrimary,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '我的',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: scheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '返回首页',
      child: InkWell(
        onTap: () => context.go('/'),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: scheme.outlineVariant),
                  boxShadow: AppShadows.primaryGlow,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.lg - 1),
                    child: Image.asset(
                      'assets/brand/anime_logo_app_icon.png',
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Zeluna',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _go(BuildContext context, ChromeDestination item) {
  GoRouter.of(context).go(item.route);
}
