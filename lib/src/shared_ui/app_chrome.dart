import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../domain/anime_models.dart';
import 'poster_card.dart';

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
    final desktop = width >= 980;
    final railWidth = width >= 1320 ? 310.0 : 270.0;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final mobileBottomSpace = desktop ? 0.0 : 76.0 + bottomInset;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
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
                          children: [
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: mobileBottomSpace,
                                ),
                                child: child,
                              ),
                            ),
                            if (rightRail != null && width >= 1180) ...[
                              const SizedBox(width: 18),
                              SizedBox(width: railWidth, child: rightRail!),
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
                left: 12,
                right: 12,
                bottom: 10 + bottomInset,
                child: _BottomNavigation(active: active),
              ),
          ],
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
  favorite(Icons.star_border_rounded, '我的', '/profile'),
  download(Icons.download_for_offline_outlined, '下载', '/profile/offline'),
  history(Icons.history_rounded, '历史', '/history'),
  settings(Icons.settings_outlined, '设置', '/settings');

  const ChromeDestination(this.icon, this.label, this.route);

  final IconData icon;
  final String label;
  final String route;
}

class AppColors {
  const AppColors._();

  static const bg = Color(0xFF060912);
  static const bg2 = Color(0xFF090D18);
  static const panel = Color(0xFF101522);
  static const panelHigh = Color(0xFF151C2C);
  static const border = Color(0xFF20283C);
  static const borderBright = Color(0xFF334064);
  static const primary = Color(0xFF7567FF);
  static const primary2 = Color(0xFF4C8DFF);
  static const cyan = Color(0xFF57B8FF);
  static const text = Color(0xFFE9ECF8);
  static const muted = Color(0xFF9DA7C2);
  static const faint = Color(0xFF65708F);
}

class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 8,
    this.borderColor = AppColors.border,
    this.color = AppColors.panel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color borderColor;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 26,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
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
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
        ],
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
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ],
            ],
          ),
        ),
        ?action,
      ],
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
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: filled
              ? AppColors.primary
              : AppColors.panelHigh.withValues(alpha: 0.84),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: filled ? AppColors.primary : AppColors.borderBright,
          ),
          boxShadow: filled
              ? const [
                  BoxShadow(
                    color: Color(0x553D37D8),
                    blurRadius: 22,
                    offset: Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SmallBadge extends StatelessWidget {
  const SmallBadge({super.key, required this.label, this.active = false});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active
            ? AppColors.primary.withValues(alpha: 0.95)
            : AppColors.panelHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: active ? Colors.white : AppColors.muted,
            fontWeight: FontWeight.w700,
          ),
        ),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 54,
                height: 40,
                child: PosterArt(
                  coverUrl: subject.bannerUrl ?? subject.coverUrl,
                  title: subject.title,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subject.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subject.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              Text(
                trailing!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({required this.active, this.bottomPlayer});

  final ChromeDestination active;
  final Widget? bottomPlayer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 136,
      decoration: const BoxDecoration(
        color: Color(0xE80A0E18),
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 18),
          const _LogoMark(),
          const SizedBox(height: 18),
          for (final item in _primaryDestinations)
            _NavItem(item: item, active: item == active),
          const Spacer(),
          if (bottomPlayer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: bottomPlayer!,
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({required this.active});

  final ChromeDestination active;

  @override
  Widget build(BuildContext context) {
    final items = _mobileDestinations(active);
    return AppPanel(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      radius: 12,
      child: SizedBox(
        height: 56,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fits = constraints.maxWidth >= items.length * 44;
            if (fits) {
              return Row(
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
              );
            }
            return ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (context, index) => const SizedBox(width: 2),
              itemBuilder: (context, index) {
                final item = items[index];
                return _BottomNavItem(
                  item: item,
                  active: item == active,
                  width: 48,
                  onTap: () => _go(context, item),
                );
              },
            );
          },
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
    this.width,
  });

  final ChromeDestination item;
  final bool active;
  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: width,
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                item.icon,
                size: 22,
                color: active ? AppColors.primary : AppColors.muted,
              ),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: active ? AppColors.text : AppColors.muted,
                  fontWeight: active ? FontWeight.w900 : FontWeight.w700,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: InkWell(
        onTap: () => _go(context, item),
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: active ? AppColors.primary.withValues(alpha: 0.28) : null,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? AppColors.primary : Colors.transparent,
            ),
            boxShadow: active
                ? const [
                    BoxShadow(
                      color: Color(0x663F35FF),
                      blurRadius: 18,
                      offset: Offset(0, 7),
                    ),
                  ]
                : null,
          ),
          child: SizedBox(
            height: 42,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  item.icon,
                  size: 20,
                  color: active ? Colors.white : AppColors.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: active ? Colors.white : AppColors.muted,
                      fontWeight: active ? FontWeight.w900 : FontWeight.w700,
                    ),
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

const _primaryDestinations = [
  ChromeDestination.home,
  ChromeDestination.anime,
  ChromeDestination.schedule,
  ChromeDestination.series,
  ChromeDestination.movie,
  ChromeDestination.favorite,
  ChromeDestination.download,
  ChromeDestination.history,
  ChromeDestination.settings,
];

List<ChromeDestination> _mobileDestinations(ChromeDestination active) {
  final items = <ChromeDestination>[
    ChromeDestination.home,
    ChromeDestination.anime,
    ChromeDestination.series,
    ChromeDestination.movie,
    ChromeDestination.history,
    ChromeDestination.favorite,
    ChromeDestination.settings,
  ];
  if (active == ChromeDestination.schedule ||
      active == ChromeDestination.download) {
    items.insert(2, active);
  }
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
    final compact = width < 760;
    final showAccountTools = width >= 1400;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 14 : 24, 12, compact ? 14 : 20, 8),
      child: Row(
        children: [
          if (onBack != null) ...[
            _TopIcon(icon: Icons.arrow_back, tooltip: '返回', onTap: onBack),
            const SizedBox(width: 10),
          ],
          if (showSearch)
            Flexible(
              flex: 5,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? 999 : 520),
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: onSearch,
                    style: const TextStyle(color: AppColors.text),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: compact
                          ? null
                          : const Padding(
                              padding: EdgeInsets.only(right: 10),
                              child: SmallBadge(label: '⌘ K'),
                            ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 56,
                        minHeight: 30,
                      ),
                      hintText: '搜索番剧、剧集、电影、演员',
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: Text(
                title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (showSearch) const Spacer(),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          if (showAccountTools) ...[
            const SizedBox(width: 14),
            const _TopIcon(icon: Icons.notifications_none, tooltip: '通知'),
            const SizedBox(width: 10),
            const _AvatarChip(),
            const SizedBox(width: 18),
            const Icon(Icons.remove, size: 18, color: AppColors.muted),
            const SizedBox(width: 18),
            const Icon(Icons.crop_square, size: 16, color: AppColors.muted),
            const SizedBox(width: 18),
            const Icon(Icons.close, size: 18, color: AppColors.muted),
          ],
        ],
      ),
    );
  }
}

class _TopIcon extends StatelessWidget {
  const _TopIcon({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.panelHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: SizedBox(
            width: 40,
            height: 38,
            child: Icon(icon, size: 20, color: AppColors.text),
          ),
        ),
      ),
    );
  }
}

class _AvatarChip extends StatelessWidget {
  const _AvatarChip();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/profile'),
      borderRadius: BorderRadius.circular(20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircleAvatar(
            radius: 17,
            backgroundColor: AppColors.primary,
            child: Text(
              'A',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '夜未央',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.keyboard_arrow_down, color: AppColors.muted),
        ],
      ),
    );
  }
}

class _LogoMark extends StatelessWidget {
  const _LogoMark();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Color(0x552D77FF),
              blurRadius: 22,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.asset(
            'assets/brand/anime_logo_app_icon.png',
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}

void _go(BuildContext context, ChromeDestination item) {
  GoRouter.of(context).go(item.route);
}
