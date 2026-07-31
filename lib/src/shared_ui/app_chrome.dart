import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dart:async';

import '../catalog/search_ranking.dart';
import '../data/anime_controller.dart';
import '../data/search_history_store.dart';
import '../domain/subject_content_type.dart';
import '../domain/anime_models.dart';
import 'app_design.dart';
import 'poster_card.dart';

export 'app_design.dart';
export 'app_empty_state.dart';
export 'section_scaffold.dart' show EmptyState, ErrorState, LoadingState;

class AppChrome extends StatelessWidget {
  const AppChrome({
    super.key,
    required this.active,
    required this.child,
    this.searchController,
    this.onSearch,
    this.trailing,
    this.compactAction,
    this.showCompactTrailing = true,
    this.rightRail,
    this.bottomPlayer,
    this.title,
    this.showSearch = true,
    this.onBack,
    this.onOpenSuggestion,
  });

  final ChromeDestination active;
  final Widget child;
  final TextEditingController? searchController;
  final ValueChanged<String>? onSearch;
  final Widget? trailing;
  final Widget? compactAction;
  final bool showCompactTrailing;
  final Widget? rightRail;
  final Widget? bottomPlayer;
  final String? title;
  final bool showSearch;
  final VoidCallback? onBack;

  /// Opens a suggested subject directly (usually the detail page). When null,
  /// picking a suggestion falls back to a normal keyword search.
  final ValueChanged<AnimeSubject>? onOpenSuggestion;

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
                          compactAction: compactAction,
                          showCompactTrailing: showCompactTrailing,
                          showSearch: showSearch,
                          onBack: onBack,
                          onOpenSuggestion: onOpenSuggestion,
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

class AccentButton extends StatefulWidget {
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
  State<AccentButton> createState() => _AccentButtonState();
}

class _AccentButtonState extends State<AccentButton> {
  var _pressed = false;

  IconData get icon => widget.icon;
  String get label => widget.label;
  VoidCallback? get onTap => widget.onTap;
  bool get filled => widget.filled;
  bool get compact => widget.compact;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final button = filled
        ? DecoratedBox(
            decoration: const BoxDecoration(boxShadow: AppShadows.primaryGlow),
            child: FilledButton.icon(
              onPressed: onTap,
              style: style,
              icon: Icon(icon, size: compact ? 17 : 18),
              label: Text(label),
            ),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            style: style,
            icon: Icon(icon, size: compact ? 17 : 18),
            label: Text(label),
          );
    if (reduceMotion || onTap == null) return button;
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1,
        duration: AppMotion.quick,
        curve: Curves.easeOut,
        child: button,
      ),
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: scheme.outlineVariant),
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
                width: active ? 40 : 30,
                height: 28,
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary.withValues(
                          alpha: context.isDarkMode ? 0.26 : 0.15,
                        )
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Icon(
                  item.icon,
                  size: 21,
                  color: active ? _navAccent(context) : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: active ? _navAccent(context) : scheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
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
          color: active
              ? scheme.primary.withValues(
                  alpha: context.isDarkMode ? 0.22 : 0.13,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
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
                    color: active
                        ? _navAccent(context)
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: active
                            ? _navAccent(context)
                            : scheme.onSurfaceVariant,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
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
    required this.compactAction,
    required this.showCompactTrailing,
    required this.showSearch,
    required this.onBack,
    required this.onOpenSuggestion,
  });

  final TextEditingController? controller;
  final ValueChanged<String>? onSearch;
  final String? title;
  final Widget? trailing;
  final Widget? compactAction;
  final bool showCompactTrailing;
  final bool showSearch;
  final VoidCallback? onBack;
  final ValueChanged<AnimeSubject>? onOpenSuggestion;

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
              ? _SearchField(
                  controller: controller,
                  onSearch: onSearch,
                  onOpenSuggestion: onOpenSuggestion,
                )
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
        if (compact && compactAction != null) ...[
          compactAction!,
          const SizedBox(width: AppSpacing.sm),
        ],
        const _ThemeModeButton(),
        if (!compact && trailing != null) ...[
          const SizedBox(width: AppSpacing.lg),
          trailing!,
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
            if (compact &&
                trailing != null &&
                compactAction == null &&
                showCompactTrailing) ...[
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

class _SearchField extends ConsumerStatefulWidget {
  const _SearchField({
    required this.controller,
    required this.onSearch,
    required this.onOpenSuggestion,
  });

  final TextEditingController? controller;
  final ValueChanged<String>? onSearch;
  final ValueChanged<AnimeSubject>? onOpenSuggestion;

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  static const _debounce = Duration(milliseconds: 300);

  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _focus = FocusNode();
  TextEditingController? _ownController;
  Timer? _debounceTimer;
  var _querySerial = 0;
  var _suggestions = const <AnimeSubject>[];
  var _history = const <String>[];
  var _fieldWidth = 560.0;

  TextEditingController get _controller =>
      widget.controller ?? (_ownController ??= TextEditingController());

  String get _accountId =>
      ref.read(animeControllerProvider).value?.accountSession.current?.id ?? '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(_handleFocus);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _focus.removeListener(_handleFocus);
    _focus.dispose();
    _ownController?.dispose();
    super.dispose();
  }

  void _handleFocus() {
    if (_focus.hasFocus) {
      _refreshOverlay();
    } else {
      _debounceTimer?.cancel();
      _querySerial++;
      _portal.hide();
    }
  }

  Future<void> _refreshOverlay() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _debounceTimer?.cancel();
      final serial = ++_querySerial;
      final history = await ref
          .read(searchHistoryStoreProvider)
          .load(_accountId);
      if (!mounted ||
          serial != _querySerial ||
          !_focus.hasFocus ||
          _controller.text.trim().isNotEmpty) {
        return;
      }
      setState(() {
        _history = history;
        _suggestions = const [];
      });
      history.isEmpty ? _portal.hide() : _portal.show();
      return;
    }
    _queueSuggestions(text);
  }

  void _queueSuggestions(String text) {
    _debounceTimer?.cancel();
    final serial = ++_querySerial;
    _debounceTimer = Timer(_debounce, () async {
      try {
        final results = await ref
            .read(animeControllerProvider.notifier)
            .search(text);
        if (!mounted || serial != _querySerial || !_focus.hasFocus) return;
        final ranked = rankSearchSubjects(text, results)
            .where((item) => !item.source.startsWith('m3u-channel:'))
            .take(6)
            .toList(growable: false);
        setState(() {
          _suggestions = ranked;
          _history = const [];
        });
        ranked.isEmpty ? _portal.hide() : _portal.show();
      } on Exception {
        // Suggestions are best-effort; typing must never surface errors.
      }
    });
  }

  void _submit(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) return;
    _portal.hide();
    _focus.unfocus();
    unawaited(ref.read(searchHistoryStoreProvider).add(_accountId, text));
    widget.onSearch?.call(text);
  }

  void _openSuggestion(AnimeSubject subject) {
    _portal.hide();
    _focus.unfocus();
    unawaited(
      ref.read(searchHistoryStoreProvider).add(_accountId, subject.title),
    );
    final open = widget.onOpenSuggestion;
    if (open != null) {
      open(subject);
    } else {
      widget.onSearch?.call(subject.title);
    }
  }

  Future<void> _removeHistory(String term) async {
    final next = await ref
        .read(searchHistoryStoreProvider)
        .remove(_accountId, term);
    if (!mounted) return;
    setState(() => _history = next);
    if (next.isEmpty && _suggestions.isEmpty) _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _fieldWidth = constraints.maxWidth;
            return OverlayPortal(
              controller: _portal,
              overlayChildBuilder: (context) => Positioned(
                width: _fieldWidth,
                child: CompositedTransformFollower(
                  link: _link,
                  targetAnchor: Alignment.bottomLeft,
                  offset: const Offset(0, 6),
                  showWhenUnlinked: false,
                  child: TapRegion(
                    groupId: this,
                    child: _SearchOverlayCard(
                      suggestions: _suggestions,
                      history: _history,
                      onPickSuggestion: _openSuggestion,
                      onPickHistory: _submit,
                      onRemoveHistory: _removeHistory,
                    ),
                  ),
                ),
              ),
              child: CompositedTransformTarget(
                link: _link,
                child: TapRegion(
                  groupId: this,
                  onTapOutside: (_) {
                    _portal.hide();
                    _focus.unfocus();
                  },
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => _refreshOverlay(),
                    onSubmitted: _submit,
                    style: Theme.of(context).textTheme.bodyMedium,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: IconButton(
                        key: const ValueKey('appSearchSubmit'),
                        tooltip: '搜索',
                        onPressed: widget.onSearch == null
                            ? null
                            : () => _submit(_controller.text),
                        icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 48,
                        maxWidth: 48,
                        minHeight: 48,
                        maxHeight: 48,
                      ),
                      hintText: '搜索番剧、剧集、电影、演员',
                      fillColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHigh
                          .withValues(alpha: 0.78),
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
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SearchOverlayCard extends StatelessWidget {
  const _SearchOverlayCard({
    required this.suggestions,
    required this.history,
    required this.onPickSuggestion,
    required this.onPickHistory,
    required this.onRemoveHistory,
  });

  final List<AnimeSubject> suggestions;
  final List<String> history;
  final ValueChanged<AnimeSubject> onPickSuggestion;
  final ValueChanged<String> onPickHistory;
  final ValueChanged<String> onRemoveHistory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 336),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            if (suggestions.isNotEmpty)
              for (final subject in suggestions)
                InkWell(
                  onTap: () => onPickSuggestion(subject),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.north_east_rounded,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            subject.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurface),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SmallBadge(
                          label: switch (subjectContentTypeOf(subject)) {
                            SubjectContentType.anime => '番剧',
                            SubjectContentType.series => '剧集',
                            SubjectContentType.movie => '电影',
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            if (suggestions.isEmpty && history.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                child: Text(
                  '搜索历史',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              for (final term in history)
                InkWell(
                  onTap: () => onPickHistory(term),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14, right: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.history_rounded,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            term,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurface),
                          ),
                        ),
                        IconButton(
                          tooltip: '删除',
                          iconSize: 15,
                          onPressed: () => onRemoveHistory(term),
                          icon: Icon(
                            Icons.close_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
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

/// Readable accent for active navigation states: deep mist blue on paper,
/// lightened mist blue on charcoal.
Color _navAccent(BuildContext context) =>
    context.isDarkMode ? AppColors.primary2 : AppColors.accentDeep;

void _go(BuildContext context, ChromeDestination item) {
  GoRouter.of(context).go(item.route);
}
