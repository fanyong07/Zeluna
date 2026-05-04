import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/poster_card.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '个人中心',
          onBack: () => Navigator.of(context).pop(),
          rightRail: _ProfileRightRail(state: state),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 120),
            children: [
              _ProfileBanner(state: state),
              const SizedBox(height: 16),
              _ProfilePlaylistSection(state: state),
              const SizedBox(height: 16),
              _ProfileShortcutSection(state: state),
              const SizedBox(height: 16),
              _HistoryStrip(entries: state.history),
              const SizedBox(height: 16),
              _DownloadStrip(entries: state.offlineTasks),
            ],
          ),
        );
      },
    );
  }
}

class _ProfileBanner extends StatelessWidget {
  const _ProfileBanner({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    final hero = state.homeFeed.hero;
    return SizedBox(
      height: 176,
      child: AppPanel(
        padding: EdgeInsets.zero,
        borderColor: AppColors.borderBright,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterArt(
                coverUrl: hero.bannerUrl ?? hero.coverUrl,
                title: state.profile.nickname,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xEE060912), Color(0x66060912)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: AppColors.primary,
                      child: Text(
                        state.profile.avatarText,
                        style: Theme.of(context).textTheme.displaySmall
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  state.profile.nickname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(
                                        color: AppColors.text,
                                        fontWeight: FontWeight.w900,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              const SmallBadge(label: '年度大会员', active: true),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'UID ${state.profile.uid} · 浓度 ${state.profile.density} · 硬币 ${state.profile.coins}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: AppColors.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '在浩瀚的星海之中，总有一束光是为你而亮。',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: AppColors.text),
                          ),
                        ],
                      ),
                    ),
                    _BannerMetric(
                      label: '片单',
                      value: '${state.favorites.length + 24}',
                    ),
                    _BannerMetric(
                      label: '收藏',
                      value: '${state.favorites.length + 156}',
                    ),
                    _BannerMetric(
                      label: '关注',
                      value: '${state.following.length + 36}',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BannerMetric extends StatelessWidget {
  const _BannerMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _ProfilePlaylistSection extends StatelessWidget {
  const _ProfilePlaylistSection({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    final subjects = [
      state.homeFeed.hero,
      ...state.homeFeed.recommended,
      ...state.homeFeed.recent,
    ];
    return AppPanel(
      child: Column(
        children: [
          SectionTitle(
            title: '我的片单',
            action: TextButton(
              onPressed: () => context.push('/profile/following'),
              child: const Text('全部 24 ›'),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _CreatePlaylistCard(
                    onTap: () => context.push('/profile/home-settings'),
                  );
                }
                final subject = subjects[index % subjects.length];
                final labels = ['年度必看', '治愈系动画', '科幻电影精选', '异世界冒险', '悬疑推理'];
                return _PlaylistCard(
                  title: labels[(index - 1) % labels.length],
                  count: 12 + index * 3,
                  subject: subject,
                );
              },
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemCount: subjects.isEmpty ? 1 : 6,
            ),
          ),
        ],
      ),
    );
  }
}

class _CreatePlaylistCard extends StatelessWidget {
  const _CreatePlaylistCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 150,
        child: AppPanel(
          padding: const EdgeInsets.all(14),
          color: AppColors.panelHigh,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add, color: AppColors.primary, size: 34),
              const SizedBox(height: 12),
              Text(
                '新建片单',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '创建专属片单',
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

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.title,
    required this.count,
    required this.subject,
  });

  final String title;
  final int count;
  final AnimeSubject subject;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      child: AppPanel(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterArt(
                coverUrl: subject.bannerUrl ?? subject.coverUrl,
                title: title,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xEE060912)],
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$count 部',
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
      ),
    );
  }
}

class _ProfileShortcutSection extends StatelessWidget {
  const _ProfileShortcutSection({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        children: [
          const SectionTitle(title: '收藏'),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 6,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.15,
            children: [
              _ShortcutTile(
                icon: Icons.favorite,
                title: '全部收藏',
                value: '${state.favorites.length + 156}',
                onTap: () => context.push('/profile/following'),
              ),
              _ShortcutTile(
                icon: Icons.history,
                title: '观看记录',
                value: '${state.history.length}',
                onTap: () => context.push('/profile/history'),
              ),
              _ShortcutTile(
                icon: Icons.download_done,
                title: '下载管理',
                value: '${state.offlineTasks.length}',
                onTap: () => context.push('/profile/offline'),
              ),
              _ShortcutTile(
                icon: Icons.play_circle_outline,
                title: '播放设置',
                value: '偏好',
                onTap: () => context.push('/settings/playback'),
              ),
              _ShortcutTile(
                icon: Icons.subtitles,
                title: '弹幕设置',
                value: '过滤',
                onTap: () => context.push('/profile/danmaku'),
              ),
              _ShortcutTile(
                icon: Icons.palette,
                title: '外观设置',
                value: '深色',
                onTap: () => context.push('/profile/appearance'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.muted,
                        height: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({required this.entries});

  final List<LibraryEntry> entries;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        children: [
          SectionTitle(
            title: '历史记录',
            action: TextButton(
              onPressed: () => context.push('/profile/history'),
              child: const Text('全部历史 ›'),
            ),
          ),
          const SizedBox(height: 14),
          if (entries.isEmpty)
            _InlineEmpty('暂无观看历史')
          else
            SizedBox(
              height: 98,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entries.take(6).length,
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _HistoryCard(entry: entries[index]),
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry});

  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: AppPanel(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterArt(
                coverUrl: entry.subject.bannerUrl ?? entry.subject.coverUrl,
                title: entry.title,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xEE060912)],
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.subject.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    LinearProgressIndicator(
                      value: 0.32 + (entry.subject.id % 5) * 0.1,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(3),
                      backgroundColor: AppColors.border,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadStrip extends StatelessWidget {
  const _DownloadStrip({required this.entries});

  final List<LibraryEntry> entries;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        children: [
          SectionTitle(
            title: '下载管理',
            action: TextButton(
              onPressed: () => context.push('/profile/offline'),
              child: Text('全部下载 (${entries.length}) ›'),
            ),
          ),
          const SizedBox(height: 14),
          if (entries.isEmpty)
            _InlineEmpty('暂无离线缓存任务')
          else
            for (final entry in entries.take(2)) _DownloadRow(entry: entry),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.entry});

  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            height: 48,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: PosterArt(
                coverUrl: entry.subject.bannerUrl ?? entry.subject.coverUrl,
                title: entry.title,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 7),
                LinearProgressIndicator(
                  value: 0.42,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: AppColors.border,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
          IconButton(onPressed: () {}, icon: const Icon(Icons.pause)),
        ],
      ),
    );
  }
}

class _ProfileRightRail extends StatelessWidget {
  const _ProfileRightRail({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            children: [
              const SectionTitle(title: '观看时长统计'),
              const SizedBox(height: 18),
              SizedBox(
                width: 136,
                height: 136,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CircularProgressIndicator(
                      value: 0.72,
                      strokeWidth: 12,
                      backgroundColor: AppColors.border,
                      color: AppColors.primary,
                    ),
                    Center(
                      child: Text(
                        '${32 + state.history.length}\n小时',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: AppColors.text,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 16; i++) ...[
                    Expanded(
                      child: Container(
                        height: 18.0 + (i % 7) * 8,
                        decoration: BoxDecoration(
                          color: i == 13
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    if (i != 15) const SizedBox(width: 4),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            children: [
              const SectionTitle(title: '快捷操作'),
              const SizedBox(height: 12),
              _RailAction(
                icon: Icons.schedule,
                title: '稍后观看',
                value: '${state.history.length + 24}',
                onTap: () => context.push('/profile/history'),
              ),
              _RailAction(
                icon: Icons.bookmark_border,
                title: '想看列表',
                value: '${state.favorites.length + 56}',
                onTap: () => context.push('/profile/following'),
              ),
              _RailAction(
                icon: Icons.check_circle_outline,
                title: '已看完',
                value: '88',
                onTap: () => context.push('/profile/history'),
              ),
              _RailAction(
                icon: Icons.star_border,
                title: '评分记录',
                value: '36',
                onTap: () => context.push('/profile/feedback'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '设备同步'),
              const SizedBox(height: 12),
              _DeviceRow(
                icon: Icons.desktop_windows,
                title: 'Windows 桌面端',
                status: '本机',
              ),
              _DeviceRow(
                icon: Icons.phone_iphone,
                title: 'iPhone 14 Pro',
                status: '在线',
              ),
              _DeviceRow(
                icon: Icons.tablet_mac,
                title: 'iPad Air 5',
                status: '离线',
              ),
              const SizedBox(height: 8),
              Text(
                '云端同步已开启',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.greenAccent),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
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
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              value,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColors.muted,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.icon,
    required this.title,
    required this.status,
  });

  final IconData icon;
  final String title;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: AppColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            status,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: status == '在线' ? Colors.greenAccent : AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: Center(
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
        ),
      ),
    );
  }
}

class LibraryPage extends ConsumerWidget {
  const LibraryPage({
    super.key,
    required this.title,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.entriesOf,
    this.clearKey,
  });

  final String title;
  final String emptyTitle;
  final String emptyMessage;
  final List<LibraryEntry> Function(AnimeState state) entriesOf;
  final String? clearKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final entries = entriesOf(state);
        return _ProfileScaffold(
          title: title,
          action: clearKey == null || entries.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空',
                  onPressed: () => ref
                      .read(animeControllerProvider.notifier)
                      .clearLibrary(clearKey!),
                  icon: const Icon(Icons.delete_outline),
                ),
          child: entries.isEmpty
              ? _ProfileEmptyState(title: emptyTitle, message: emptyMessage)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
                  itemCount: entries.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      _LibraryTile(entry: entries[index]),
                ),
        );
      },
    );
  }
}

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  late final TextEditingController _nickname;

  @override
  void initState() {
    super.initState();
    _nickname = TextEditingController();
  }

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) {
        if (_nickname.text.isEmpty) _nickname.text = state.profile.nickname;
        return _ProfileScaffold(
          title: '账号管理',
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
            children: [
              _SettingsCard(
                children: [
                  _ReadonlyRow(title: 'UID', value: state.profile.uid),
                  _ReadonlyRow(title: '浓度', value: '${state.profile.density}'),
                  _ReadonlyRow(title: '硬币', value: '${state.profile.coins}'),
                ],
              ),
              const SizedBox(height: 12),
              _SettingsCard(
                children: [
                  SizedBox(
                    height: 78,
                    child: TextField(
                      controller: _nickname,
                      decoration: const InputDecoration(labelText: '本地昵称'),
                      onSubmitted: (_) => _saveProfile(state.profile),
                    ),
                  ),
                  _ActionRow(
                    icon: Icons.save_outlined,
                    title: '保存本地资料',
                    subtitle: '仅保存在本机，不接入登录账号',
                    onTap: () => _saveProfile(state.profile),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _saveProfile(UserProfileSettings profile) {
    ref
        .read(animeControllerProvider.notifier)
        .updateProfile(profile.copyWith(nickname: _nickname.text.trim()));
    _showToast(context, '账号资料已保存');
  }
}

class HomeSettingsPage extends ConsumerWidget {
  const HomeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) => _ProfileScaffold(
        title: '主页设置',
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
          children: [
            _SettingsCard(
              children: [
                for (final tab in AnimeHomeTab.values)
                  _RadioRow<AnimeHomeTab>(
                    title: tab.label,
                    value: tab,
                    groupValue: state.homePreferences.defaultTab,
                    onChanged: (value) => ref
                        .read(animeControllerProvider.notifier)
                        .updateHomePreferences(
                          state.homePreferences.copyWith(defaultTab: value),
                        ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final settings = state.appearance;
        final controller = ref.read(animeControllerProvider.notifier);
        return _ProfileScaffold(
          title: '外观设置',
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
            children: [
              _SettingsCard(
                children: [
                  _SwitchRow(
                    title: '跟随系统',
                    subtitle: '后续接浅色主题时会优先使用系统设置',
                    value: settings.followSystem,
                    onChanged: (value) => controller.updateAppearance(
                      settings.copyWith(followSystem: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '深色模式',
                    subtitle: '当前 AniCh 风格以暗色观影环境为主',
                    value: settings.darkMode,
                    onChanged: (value) => controller.updateAppearance(
                      settings.copyWith(darkMode: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '紧凑列表',
                    value: settings.compactMode,
                    onChanged: (value) => controller.updateAppearance(
                      settings.copyWith(compactMode: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '减少动效',
                    value: settings.reduceMotion,
                    onChanged: (value) => controller.updateAppearance(
                      settings.copyWith(reduceMotion: value),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class DanmakuSettingsPage extends ConsumerWidget {
  const DanmakuSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final settings = state.danmaku;
        final controller = ref.read(animeControllerProvider.notifier);
        return _ProfileScaffold(
          title: '弹幕设置',
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
            children: [
              _SettingsCard(
                children: [
                  _SwitchRow(
                    title: '启用弹幕',
                    value: settings.enabled,
                    onChanged: (value) => controller.updateDanmaku(
                      settings.copyWith(enabled: value),
                    ),
                  ),
                  _SliderRow(
                    title: '透明度',
                    value: settings.opacity,
                    min: 0.2,
                    max: 1,
                    label: '${(settings.opacity * 100).round()}%',
                    onChanged: (value) => controller.updateDanmaku(
                      settings.copyWith(opacity: value),
                    ),
                  ),
                  _SliderRow(
                    title: '字号',
                    value: settings.fontSize,
                    min: 12,
                    max: 28,
                    label: settings.fontSize.round().toString(),
                    onChanged: (value) => controller.updateDanmaku(
                      settings.copyWith(fontSize: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '屏蔽顶部弹幕',
                    value: settings.blockTop,
                    onChanged: (value) => controller.updateDanmaku(
                      settings.copyWith(blockTop: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '屏蔽滚动弹幕',
                    value: settings.blockScroll,
                    onChanged: (value) => controller.updateDanmaku(
                      settings.copyWith(blockScroll: value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _KeywordEditor(settings: settings),
            ],
          ),
        );
      },
    );
  }
}

class MiscSettingsPage extends ConsumerWidget {
  const MiscSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final settings = state.misc;
        final controller = ref.read(animeControllerProvider.notifier);
        return _ProfileScaffold(
          title: '其他设置',
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
            children: [
              _SettingsCard(
                children: [
                  _SwitchRow(
                    title: '自动检查更新',
                    value: settings.autoCheckUpdates,
                    onChanged: (value) => controller.updateMisc(
                      settings.copyWith(autoCheckUpdates: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '仅 Wi-Fi 缓存',
                    value: settings.wifiOnlyCache,
                    onChanged: (value) => controller.updateMisc(
                      settings.copyWith(wifiOnlyCache: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '播放时保持屏幕常亮',
                    value: settings.keepScreenOn,
                    onChanged: (value) => controller.updateMisc(
                      settings.copyWith(keepScreenOn: value),
                    ),
                  ),
                  _SwitchRow(
                    title: '保存崩溃日志',
                    subtitle: '仅本地记录，便于后续排查',
                    value: settings.saveCrashLog,
                    onChanged: (value) => controller.updateMisc(
                      settings.copyWith(saveCrashLog: value),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class VersionInfoPage extends StatelessWidget {
  const VersionInfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _ProfileScaffold(
      title: '版本信息',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
        children: const [
          _SettingsCard(
            children: [
              _ReadonlyRow(title: '应用', value: 'anime'),
              _ReadonlyRow(title: '版本', value: '1.0.0+1'),
              _ReadonlyRow(title: '元数据', value: 'Bangumi API'),
              _ReadonlyRow(title: '视频源', value: '待接入'),
              _ReadonlyRow(title: '播放结构', value: '按当前集单独返回线路'),
            ],
          ),
        ],
      ),
    );
  }
}

class FeedbackPage extends ConsumerStatefulWidget {
  const FeedbackPage({super.key, this.subject});

  final AnimeSubject? subject;

  @override
  ConsumerState<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends ConsumerState<FeedbackPage> {
  final _title = TextEditingController();
  final _content = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncAnimeGate(
      builder: (context, state) => _ProfileScaffold(
        title: '问题反馈',
        action: state.feedbacks.isEmpty
            ? null
            : IconButton(
                tooltip: '清空',
                onPressed: () => ref
                    .read(animeControllerProvider.notifier)
                    .clearLibrary('feedbacks'),
                icon: const Icon(Icons.delete_outline),
              ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
          children: [
            _SettingsCard(
              children: [
                SizedBox(
                  height: 74,
                  child: TextField(
                    controller: _title,
                    decoration: const InputDecoration(labelText: '标题'),
                  ),
                ),
                SizedBox(
                  height: 112,
                  child: TextField(
                    controller: _content,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: '反馈内容'),
                  ),
                ),
                _ActionRow(
                  icon: Icons.archive_outlined,
                  title: '保存到本地反馈箱',
                  subtitle: widget.subject == null
                      ? '不会联网发送'
                      : '关联：${widget.subject!.title}',
                  onTap: _submit,
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (state.feedbacks.isEmpty)
              const _ProfileEmptyState(
                title: '还没有反馈记录',
                message: '提交后会保存在本地，方便你后续整理问题。',
              )
            else
              for (final item in state.feedbacks) _FeedbackTile(item: item),
          ],
        ),
      ),
    );
  }

  void _submit() {
    if (_content.text.trim().isEmpty) {
      _showToast(context, '先写一点反馈内容');
      return;
    }
    ref
        .read(animeControllerProvider.notifier)
        .submitFeedback(
          title: _title.text,
          content: _content.text,
          subject: widget.subject,
        );
    _title.clear();
    _content.clear();
    _showToast(context, '已保存到本地反馈箱');
  }
}

class _BackPill extends StatelessWidget {
  const _BackPill({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: onBack,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE6252525),
          borderRadius: BorderRadius.circular(30),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 26, spreadRadius: 5),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.arrow_back, color: Colors.white70, size: 28),
              Text(
                '返回',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileScaffold extends StatelessWidget {
  const _ProfileScaffold({
    required this.title,
    required this.child,
    this.action,
  });

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      ?action,
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(
                child: _BackPill(onBack: () => Navigator.of(context).pop()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i != children.length - 1)
                const Divider(height: 1, color: Color(0xFF303030)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReadonlyRow extends StatelessWidget {
  const _ReadonlyRow({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: subtitle == null ? 62 : 78,
        child: Row(
          children: [
            Icon(icon, color: Colors.white70),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white54),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: subtitle == null ? 68 : 82,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white54),
                  ),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              label,
              textAlign: TextAlign.end,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _RadioRow<T> extends StatelessWidget {
  const _RadioRow({
    required this.title,
    required this.value,
    required this.groupValue,
    required this.onChanged,
  });

  final String title;
  final T value;
  final T groupValue;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(value),
      child: SizedBox(
        height: 62,
        child: RadioGroup<T>(
          groupValue: groupValue,
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Radio<T>(value: value),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryTile extends StatelessWidget {
  const _LibraryTile({required this.entry});

  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF202020),
        borderRadius: BorderRadius.circular(7),
      ),
      child: ListTile(
        minVerticalPadding: 12,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 54,
            height: 54,
            child: _PosterThumb(subject: entry.subject),
          ),
        ),
        title: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          entry.note.isEmpty
              ? '${entry.subject.year} · ${_formatDateTime(entry.updatedAt)}'
              : '${entry.note} · ${_formatDateTime(entry.updatedAt)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white60),
        ),
      ),
    );
  }
}

class _PosterThumb extends StatelessWidget {
  const _PosterThumb({required this.subject});

  final AnimeSubject subject;

  @override
  Widget build(BuildContext context) {
    final url = subject.coverUrl;
    if (url != null && url.startsWith('http')) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _FallbackThumb(title: subject.title),
      );
    }
    return _FallbackThumb(title: subject.title);
  }
}

class _FallbackThumb extends StatelessWidget {
  const _FallbackThumb({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF30374D)),
      child: Center(
        child: Text(
          String.fromCharCodes(title.runes.take(2)),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _ProfileEmptyState extends StatelessWidget {
  const _ProfileEmptyState({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.inbox_outlined,
                size: 42,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white60,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeywordEditor extends ConsumerStatefulWidget {
  const _KeywordEditor({required this.settings});

  final DanmakuSettings settings;

  @override
  ConsumerState<_KeywordEditor> createState() => _KeywordEditorState();
}

class _KeywordEditorState extends ConsumerState<_KeywordEditor> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.settings.blockKeywords.join('，'),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      children: [
        SizedBox(
          height: 78,
          child: TextField(
            controller: _controller,
            decoration: const InputDecoration(labelText: '屏蔽词，用逗号分隔'),
          ),
        ),
        _ActionRow(icon: Icons.save_outlined, title: '保存屏蔽词', onTap: _save),
      ],
    );
  }

  void _save() {
    final keywords = _controller.text
        .split(RegExp(r'[,，\n]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    ref
        .read(animeControllerProvider.notifier)
        .updateDanmaku(widget.settings.copyWith(blockKeywords: keywords));
    _showToast(context, '屏蔽词已保存');
  }
}

class _FeedbackTile extends StatelessWidget {
  const _FeedbackTile({required this.item});

  final LocalFeedback item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF202020),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                item.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (item.subject != null) item.subject!.title,
                  _formatDateTime(item.createdAt),
                ].join(' · '),
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDateTime(DateTime date) {
  if (date.millisecondsSinceEpoch <= 0) return '未知时间';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

void _showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
