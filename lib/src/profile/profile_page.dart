import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../accounts/local_account_repository.dart';
import '../app/anime_app.dart';
import '../catalog/catalog_page.dart';
import '../data/anime_controller.dart';
import '../data/media_download_task.dart';
import '../domain/anime_models.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/app_navigation.dart';
import '../shared_ui/poster_card.dart';
import '../shared_ui/settings_ui.dart';
import '../sync/sync_controller.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final compact = MediaQuery.sizeOf(context).width < 760;
        return AppChrome(
          active: ChromeDestination.favorite,
          showSearch: false,
          title: '个人中心',
          onBack: () => safeNavigateBack(context),
          rightRail: _ProfileRightRail(state: state),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 24,
              compact ? 0 : 6,
              compact ? 14 : 0,
              120,
            ),
            children: [
              _ProfileBanner(state: state),
              SizedBox(height: compact ? 12 : 16),
              _ProfilePlaylistSection(state: state),
              SizedBox(height: compact ? 12 : 16),
              _ProfileShortcutSection(state: state),
              SizedBox(height: compact ? 12 : 16),
              _HistoryStrip(entries: state.history),
              SizedBox(height: compact ? 12 : 16),
              _DownloadStrip(entries: state.offlineTasks),
            ],
          ),
        );
      },
    );
  }
}

String _profileSyncStatus(SyncStatus status) => switch (status.phase) {
  SyncPhase.localOnly => '仅本机',
  SyncPhase.checking => '检查中',
  SyncPhase.pending => '待同步',
  SyncPhase.synced => '已同步',
  SyncPhase.offline => '离线缓存',
  SyncPhase.expired => '登录失效',
  SyncPhase.error => '需重试',
};

class _ProfileBanner extends StatelessWidget {
  const _ProfileBanner({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final hero = state.homeFeed.hero;
    return SizedBox(
      height: compact ? 128 : 176,
      child: AppPanel(
        padding: EdgeInsets.zero,
        borderColor: Theme.of(context).colorScheme.outline,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterArt(
                coverUrl: hero.bannerUrl,
                fallbackCoverUrl: hero.coverUrl,
                title: state.profile.nickname,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppOverlays.heroLeadingSoft,
                ),
              ),
              Padding(
                padding: EdgeInsets.all(compact ? 16 : 24),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: compact ? 34 : 48,
                      backgroundColor: AppColors.primary,
                      child: Text(
                        state.profile.avatarText,
                        style:
                            (compact
                                    ? Theme.of(context).textTheme.headlineMedium
                                    : Theme.of(context).textTheme.displaySmall)
                                ?.copyWith(
                                  color: AppColors.theaterInk,
                                  fontWeight: FontWeight.w900,
                                ),
                      ),
                    ),
                    SizedBox(width: compact ? 14 : 24),
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
                                  style:
                                      (compact
                                              ? Theme.of(
                                                  context,
                                                ).textTheme.titleLarge
                                              : Theme.of(
                                                  context,
                                                ).textTheme.headlineMedium)
                                          ?.copyWith(
                                            color: AppColors.theaterInk,
                                            fontWeight: FontWeight.w900,
                                          ),
                                ),
                              ),
                              if (!compact) ...[
                                const SizedBox(width: 10),
                                SmallBadge(
                                  label: state.accountSession.isSignedIn
                                      ? '云端账号'
                                      : '游客',
                                  active: state.accountSession.isSignedIn,
                                ),
                              ],
                            ],
                          ),
                          SizedBox(height: compact ? 4 : 8),
                          Text(
                            state.accountSession.isSignedIn
                                ? 'UID ${state.profile.uid} · ${state.accountSession.current!.email}'
                                : '游客空间 · 登录后可使用独立收藏和历史',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: AppColors.theaterMuted,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          if (!compact) ...[
                            const SizedBox(height: 10),
                            Text(
                              '在浩瀚的星海之中，总有一束光是为你而亮。',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: AppColors.theaterInk),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (!compact) ...[
                      _BannerMetric(
                        label: '追番',
                        value: '${state.following.length}',
                      ),
                      _BannerMetric(
                        label: '收藏',
                        value: '${state.favorites.length}',
                      ),
                      _BannerMetric(
                        label: '历史',
                        value: '${state.history.length}',
                      ),
                    ],
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
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(color: context.ink),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
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
    final compact = MediaQuery.sizeOf(context).width < 760;
    final entries = state.following.take(8).toList(growable: false);
    return AppPanel(
      child: Column(
        children: [
          SectionTitle(
            title: '我的追番',
            action: entries.isEmpty
                ? null
                : TextButton(
                    onPressed: () => context.push('/profile/following'),
                    child: Text('全部 ${state.following.length} ›'),
                  ),
          ),
          SizedBox(height: compact ? 10 : 14),
          if (entries.isEmpty)
            const _InlineEmpty('还没有追番，在详情页点击“追番”后会显示在这里')
          else
            SizedBox(
              height: compact ? 124 : 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final subject = entries[index].subject;
                  return _PlaylistCard(
                    title: subject.title,
                    subject: subject,
                    onTap: () => _openDetail(context, subject),
                  );
                },
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemCount: entries.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.title,
    required this.subject,
    required this.onTap,
  });

  final String title;
  final AnimeSubject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return SizedBox(
      width: compact ? 150 : 170,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AppPanel(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                PosterArt(
                  coverUrl: subject.bannerUrl,
                  fallbackCoverUrl: subject.coverUrl,
                  title: title,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(gradient: AppOverlays.mediaCaption),
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
                          color: AppColors.theaterInk,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '已加入追番 · 打开详情',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.theaterMuted,
                        ),
                      ),
                    ],
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

class _ProfileShortcutSection extends StatelessWidget {
  const _ProfileShortcutSection({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return AppPanel(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        children: [
          const SectionTitle(title: '我的内容'),
          SizedBox(height: compact ? 10 : 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = compact
                  ? 2
                  : (constraints.maxWidth / 168).floor().clamp(3, 6);
              final shortcuts = [
                _ShortcutTile(
                  icon: state.accountSession.isSignedIn
                      ? Icons.account_circle
                      : Icons.login_rounded,
                  title: '账号管理',
                  value: state.accountSession.isSignedIn ? '已登录' : '登录 / 注册',
                  onTap: () => context.push('/profile/account'),
                ),
                _ShortcutTile(
                  icon: Icons.bookmark_border,
                  title: '追番列表',
                  value: '${state.following.length}',
                  onTap: () => context.push('/profile/following'),
                ),
                _ShortcutTile(
                  icon: Icons.favorite,
                  title: '全部收藏',
                  value: '${state.favorites.length}',
                  onTap: () => context.push('/profile/favorites'),
                ),
                _ShortcutTile(
                  icon: Icons.history,
                  title: '观看记录',
                  value: '${state.history.length}',
                  onTap: () => _scrollToHistory(context),
                ),
                _ShortcutTile(
                  icon: Icons.download_done,
                  title: '下载管理',
                  value: '${state.offlineTasks.length}',
                  onTap: () => context.push('/profile/offline'),
                ),
                _ShortcutTile(
                  icon: Icons.subtitles,
                  title: '弹幕设置',
                  value: '过滤',
                  onTap: () => context.push('/profile/danmaku'),
                ),
                _ShortcutTile(
                  icon: Icons.play_circle_outline,
                  title: '播放设置',
                  value: '偏好',
                  onTap: () => context.push('/settings/playback'),
                ),
                _ShortcutTile(
                  icon: Icons.rss_feed,
                  title: '扩展来源',
                  value: '${state.rulePlugins.customRules.length}',
                  onTap: () => context.push('/profile/rules'),
                ),
              ];
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: compact ? 8 : 12,
                crossAxisSpacing: compact ? 8 : 12,
                childAspectRatio: compact ? 2.65 : 2.15,
                children: shortcuts,
              );
            },
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
    final compact = MediaQuery.sizeOf(context).width < 760;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 10,
            vertical: compact ? 9 : 8,
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: compact ? 22 : 20),
              SizedBox(width: compact ? 9 : 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (compact
                                  ? Theme.of(context).textTheme.labelLarge
                                  : Theme.of(context).textTheme.labelSmall)
                              ?.copyWith(
                                color: context.ink,
                                fontWeight: FontWeight.w900,
                                height: 1.0,
                              ),
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.inkMuted,
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

class _HistoryStrip extends StatefulWidget {
  const _HistoryStrip({required this.entries});

  final List<LibraryEntry> entries;

  @override
  State<_HistoryStrip> createState() => _HistoryStripState();
}

class _HistoryStripState extends State<_HistoryStrip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final visibleEntries = _expanded ? entries : entries.take(6).toList();
    return AppPanel(
      key: AppChrome.profileHistorySectionKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '历史记录',
            action: entries.length <= 6
                ? null
                : TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? '收起历史' : '全部历史 ›'),
                  ),
          ),
          const SizedBox(height: 14),
          if (entries.isEmpty)
            _InlineEmpty('暂无观看历史')
          else if (_expanded)
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.maxWidth / 214).floor().clamp(
                  2,
                  6,
                );
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: visibleEntries.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.92,
                  ),
                  itemBuilder: (context, index) =>
                      _HistoryCard(entry: visibleEntries[index]),
                );
              },
            )
          else
            SizedBox(
              height: 98,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: visibleEntries.length,
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _HistoryCard(entry: visibleEntries[index]),
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
    final progress = _entryProgress(entry);
    return SizedBox(
      width: 190,
      child: InkWell(
        onTap: () => _playEntry(context, entry),
        borderRadius: BorderRadius.circular(8),
        child: AppPanel(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                PosterArt(
                  coverUrl: entry.subject.bannerUrl,
                  fallbackCoverUrl: entry.subject.coverUrl,
                  title: entry.title,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(gradient: AppOverlays.mediaCaption),
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
                          color: AppColors.theaterInk,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.episode?.displayTitle ??
                            (entry.note.isEmpty ? '详情页' : entry.note),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.theaterMuted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (progress != null) ...[
                        const SizedBox(height: 5),
                        LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(3),
                          backgroundColor: AppColors.theaterFaint,
                          color: AppColors.primary,
                        ),
                      ],
                    ],
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

class _DownloadStrip extends StatelessWidget {
  const _DownloadStrip({required this.entries});

  final List<MediaDownloadTask> entries;

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

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.entry});

  final MediaDownloadTask entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = entry.status == MediaDownloadTaskStatus.completed
        ? 1.0
        : entry.progress;
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
                coverUrl: entry.subject.bannerUrl,
                fallbackCoverUrl: entry.subject.coverUrl,
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
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${entry.statusLabel} · ${_downloadSizeText(entry)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.inkMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: Theme.of(context).colorScheme.outlineVariant,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: entry.isPlayable ? '播放本地文件' : '查看下载任务',
            onPressed: entry.isPlayable
                ? () => _playDownloadTask(context, ref, entry)
                : () => context.push('/profile/offline'),
            icon: Icon(
              entry.isPlayable
                  ? Icons.play_arrow_rounded
                  : Icons.chevron_right_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

class DownloadManagementPage extends ConsumerWidget {
  const DownloadManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final tasks = state.offlineTasks;
        final compact = MediaQuery.sizeOf(context).width < 760;
        return AppChrome(
          active: ChromeDestination.download,
          showSearch: false,
          title: '离线缓存',
          onBack: () => safeNavigateBack(context, fallbackRoute: '/profile'),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 24,
              compact ? 0 : 6,
              compact ? 14 : 24,
              120,
            ),
            child: tasks.isEmpty
                ? const EmptyState(
                    icon: Icons.inbox_outlined,
                    compact: true,
                    title: '还没有下载任务',
                    message: '在详情页点击下载后，任务会显示在这里。',
                  )
                : ListView.separated(
                    itemCount: tasks.length + 1,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return AppPanel(
                          child: SectionTitle(
                            title: '全部下载',
                            subtitle: '${tasks.length} 个离线任务，可在这里暂停、继续或删除',
                            icon: Icons.download_for_offline_outlined,
                          ),
                        );
                      }
                      return _DownloadTaskCard(task: tasks[index - 1]);
                    },
                  ),
          ),
        );
      },
    );
  }
}

class _DownloadTaskCard extends ConsumerWidget {
  const _DownloadTaskCard({required this.task});

  final MediaDownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = task.status == MediaDownloadTaskStatus.completed
        ? 1.0
        : task.progress;
    final statusColor = switch (task.status) {
      MediaDownloadTaskStatus.completed => AppStatusColors.available,
      MediaDownloadTaskStatus.failed => AppStatusColors.failed,
      MediaDownloadTaskStatus.cancelled => context.inkMuted,
      MediaDownloadTaskStatus.paused => AppStatusColors.probing,
      _ => AppColors.primary,
    };
    return AppPanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: SizedBox(
              width: 116,
              height: 68,
              child: PosterArt(
                coverUrl: task.subject.bannerUrl,
                fallbackCoverUrl: task.subject.coverUrl,
                title: task.title,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      task.statusLabel,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  [
                    if (task.providerName?.trim().isNotEmpty == true)
                      task.providerName!,
                    _downloadSizeText(task),
                    if (task.message.trim().isNotEmpty) task.message.trim(),
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.inkMuted,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: Theme.of(context).colorScheme.outlineVariant,
                  color: statusColor,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _DownloadTaskActions(task: task),
        ],
      ),
    );
  }
}

class _DownloadTaskActions extends ConsumerWidget {
  const _DownloadTaskActions({required this.task});

  final MediaDownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(animeControllerProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (task.isPlayable)
          IconButton(
            tooltip: '播放本地文件',
            onPressed: () => _playDownloadTask(context, ref, task),
            icon: const Icon(Icons.play_arrow_rounded),
          ),
        if (task.isActive)
          IconButton(
            tooltip: '暂停',
            onPressed: () => controller.pauseDownload(task.id),
            icon: const Icon(Icons.pause_rounded),
          ),
        if (task.status == MediaDownloadTaskStatus.paused ||
            task.status == MediaDownloadTaskStatus.failed ||
            task.status == MediaDownloadTaskStatus.cancelled)
          IconButton(
            tooltip: task.downloadedBytes > 0 ? '继续下载' : '重新下载',
            onPressed: () => controller.resumeDownload(task.id),
            icon: const Icon(Icons.refresh_rounded),
          ),
        if (task.isActive || task.status == MediaDownloadTaskStatus.paused)
          IconButton(
            tooltip: '取消下载',
            onPressed: () => controller.cancelDownload(task.id),
            icon: const Icon(Icons.close_rounded),
          ),
        IconButton(
          tooltip: task.isPlayable ? '删除下载文件' : '移除任务',
          onPressed: () async {
            final confirmed = await _confirmRemoveDownload(context, task);
            if (!confirmed) return;
            await controller.removeDownload(task.id);
          },
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    );
  }
}

class _ProfileRightRail extends StatelessWidget {
  const _ProfileRightRail({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    final finished = state.history.where(_isFinishedEntry).length;
    final latest = state.history.isEmpty ? null : state.history.first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '观看概览'),
              const SizedBox(height: 14),
              _HistoryStatRow(label: '观看记录', value: '${state.history.length}'),
              _HistoryStatRow(label: '已看完', value: '$finished'),
              _HistoryStatRow(
                label: '最近观看',
                value: latest == null ? '暂无' : latest.subject.title,
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
                title: '观看记录',
                value: '${state.history.length}',
                onTap: () => _scrollToHistory(context),
              ),
              _RailAction(
                icon: Icons.bookmark_border,
                title: '追番列表',
                value: '${state.following.length}',
                onTap: () => context.push('/profile/following'),
              ),
              _RailAction(
                icon: Icons.favorite_border,
                title: '收藏列表',
                value: '${state.favorites.length}',
                onTap: () => context.push('/profile/favorites'),
              ),
              _RailAction(
                icon: Icons.feedback_outlined,
                title: '反馈记录',
                value: '${state.feedbacks.length}',
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
              const SectionTitle(title: '账号与数据'),
              const SizedBox(height: 12),
              _DeviceRow(
                icon: Icons.devices_rounded,
                title: '当前设备',
                status: state.accountSession.isSignedIn
                    ? _profileSyncStatus(state.syncStatus)
                    : '游客空间',
              ),
              const SizedBox(height: 8),
              Text(
                state.accountSession.isSignedIn
                    ? '收藏、追番、历史、播放位置和选定偏好会先写入本机，再按当前账号同步；下载文件和私密来源配置始终留在本机。'
                    : '登录或创建云端账号后，可在安卓和 Windows 使用同一邮箱；本机资料会按账号隔离。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
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
                  color: context.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              value,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.inkMuted,
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
          Icon(icon, color: context.inkMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            status,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: status == '在线' || status == '已登录'
                  ? AppColors.success
                  : context.inkMuted,
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
          ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
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
    this.active = ChromeDestination.favorite,
    this.clearKey,
    this.playEntries = false,
  });

  final String title;
  final String emptyTitle;
  final String emptyMessage;
  final List<LibraryEntry> Function(AnimeState state) entriesOf;
  final ChromeDestination active;
  final String? clearKey;
  final bool playEntries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final entries = entriesOf(state);
        return _ProfileScaffold(
          title: title,
          active: active,
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
              ? EmptyState(
                  icon: Icons.inbox_outlined,
                  compact: true,
                  title: emptyTitle,
                  message: emptyMessage,
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
                  itemCount: entries.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) => _LibraryTile(
                    entry: entries[index],
                    onTap: playEntries
                        ? () => _playEntry(context, entries[index])
                        : () => _openDetail(context, entries[index].subject),
                    trailingIcon: playEntries
                        ? Icons.play_arrow_rounded
                        : Icons.chevron_right_rounded,
                  ),
                ),
        );
      },
    );
  }
}

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final entries = state.history;
        return AppChrome(
          active: ChromeDestination.history,
          showSearch: false,
          title: '历史记录',
          onBack: () => safeNavigateBack(context),
          trailing: entries.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空历史',
                  onPressed: () => ref
                      .read(animeControllerProvider.notifier)
                      .clearLibrary('history'),
                  icon: const Icon(Icons.delete_outline),
                ),
          rightRail: _HistoryRightRail(entries: entries),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 0, 120),
            child: entries.isEmpty
                ? const EmptyState(
                    icon: Icons.inbox_outlined,
                    compact: true,
                    title: '还没有观看记录',
                    message: '从详情页播放任意一集后，这里会记录番剧和集数。',
                  )
                : _HistoryList(entries: entries),
          ),
        );
      },
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.entries});

  final List<LibraryEntry> entries;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: entries.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return AppPanel(
            child: SectionTitle(
              title: '全部历史',
              subtitle: '${entries.length} 条观看记录，点击任意记录继续播放',
              icon: Icons.history_rounded,
            ),
          );
        }
        final entry = entries[index - 1];
        return _HistoryListTile(entry: entry);
      },
    );
  }
}

class _HistoryListTile extends StatelessWidget {
  const _HistoryListTile({required this.entry});

  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    final progress = _entryProgress(entry);
    return InkWell(
      onTap: () => _playEntry(context, entry),
      borderRadius: BorderRadius.circular(8),
      child: AppPanel(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SizedBox(
                width: 116,
                height: 68,
                child: PosterArt(
                  coverUrl: entry.subject.bannerUrl,
                  fallbackCoverUrl: entry.subject.coverUrl,
                  title: entry.title,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.subject.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: context.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    [
                      entry.episode?.displayTitle ?? '详情页',
                      if (entry.note.isNotEmpty) entry.note,
                      _formatDateTime(entry.updatedAt),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.inkMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(4),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.outlineVariant,
                      color: AppColors.primary,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.play_arrow_rounded, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

class _HistoryRightRail extends StatelessWidget {
  const _HistoryRightRail({required this.entries});

  final List<LibraryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final finished = entries.where(_isFinishedEntry).length;
    final latest = entries.isEmpty ? null : entries.first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '历史概览'),
              const SizedBox(height: 14),
              _HistoryStatRow(label: '总记录', value: '${entries.length}'),
              _HistoryStatRow(label: '已看完', value: '$finished'),
              _HistoryStatRow(
                label: '最近观看',
                value: latest == null ? '暂无' : latest.subject.title,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HistoryStatRow extends StatelessWidget {
  const _HistoryStatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.ink,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
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
            SettingsCard(
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
              SettingsCard(
                children: [
                  SettingsSwitchRow(
                    title: '跟随系统',
                    subtitle: '后续接浅色主题时会优先使用系统设置',
                    value: settings.followSystem,
                    onChanged: (value) => controller.updateAppearance(
                      settings.copyWith(followSystem: value),
                    ),
                  ),
                  SettingsSwitchRow(
                    title: '深色模式',
                    subtitle: '当前 AniCh 风格以暗色观影环境为主',
                    value: settings.darkMode,
                    onChanged: (value) => controller.updateAppearance(
                      settings.copyWith(darkMode: value),
                    ),
                  ),
                  SettingsSwitchRow(
                    title: '紧凑列表',
                    value: settings.compactMode,
                    onChanged: (value) => controller.updateAppearance(
                      settings.copyWith(compactMode: value),
                    ),
                  ),
                  SettingsSwitchRow(
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
              SettingsCard(
                children: [
                  SettingsSwitchRow(
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
                  SettingsSwitchRow(
                    title: '屏蔽顶部弹幕',
                    value: settings.blockTop,
                    onChanged: (value) => controller.updateDanmaku(
                      settings.copyWith(blockTop: value),
                    ),
                  ),
                  SettingsSwitchRow(
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
              SettingsCard(
                children: [
                  SettingsSwitchRow(
                    title: '播放时保持屏幕常亮',
                    subtitle: '已连接系统唤醒锁，播放和长视频观看时生效',
                    value: settings.keepScreenOn,
                    onChanged: (value) => controller.updateMisc(
                      settings.copyWith(keepScreenOn: value),
                    ),
                  ),
                  const SettingsReadonlyRow(
                    title: '离线下载',
                    value: '支持常见视频文件与未加密点播流',
                  ),
                  const SettingsReadonlyRow(title: '自动更新', value: '正式版发布后可开启'),
                  const SettingsReadonlyRow(title: '崩溃报告', value: '当前不上传隐私日志'),
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
      child: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final info = snapshot.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 120),
            children: [
              SettingsCard(
                children: [
                  SettingsReadonlyRow(
                    title: '应用',
                    value: info?.appName ?? 'Zeluna',
                  ),
                  SettingsReadonlyRow(
                    title: '版本',
                    value: info == null
                        ? '读取中…'
                        : '${info.version}+${info.buildNumber}',
                  ),
                  const SettingsReadonlyRow(
                    title: '内容资料',
                    value: '番剧 / 剧集 / 电影',
                  ),
                  const SettingsReadonlyRow(
                    title: '播放能力',
                    value: '在线播放 / 网络直链 / 本地文件',
                  ),
                  const SettingsReadonlyRow(
                    title: '播放器',
                    value: '进度条、倍速、弹幕与全屏控制',
                  ),
                ],
              ),
            ],
          );
        },
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
            SettingsCard(
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
                SettingsActionRow(
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
              const EmptyState(
                icon: Icons.inbox_outlined,
                compact: true,
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

class _ProfileScaffold extends StatelessWidget {
  const _ProfileScaffold({
    required this.title,
    required this.child,
    this.active = ChromeDestination.favorite,
    this.action,
  });

  final String title;
  final Widget child;
  final ChromeDestination active;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (desktop) _ProfileMiniRail(active: active),
            Expanded(
              child: Stack(
                children: [
                  Column(
                    children: [
                      SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => safeNavigateBack(
                                context,
                                fallbackRoute: '/profile',
                              ),
                              icon: const Icon(Icons.arrow_back),
                            ),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      color: context.ink,
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
                      child: BackPill(
                        onBack: () => safeNavigateBack(
                          context,
                          fallbackRoute: '/profile',
                        ),
                      ),
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

class _ProfileMiniRail extends StatelessWidget {
  const _ProfileMiniRail({required this.active});

  final ChromeDestination active;

  @override
  Widget build(BuildContext context) {
    final items = const [
      ChromeDestination.home,
      ChromeDestination.anime,
      ChromeDestination.favorite,
      ChromeDestination.settings,
    ];
    return Container(
      width: 72,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: IconButton(
                tooltip: item.label,
                onPressed: () => context.go(item.route),
                icon: Icon(
                  item.icon,
                  color: item == active ? AppColors.primary : context.inkMuted,
                ),
              ),
            ),
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
                color: context.ink,
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
              ).textTheme.titleMedium?.copyWith(color: context.inkMuted),
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
                    color: context.ink,
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
  const _LibraryTile({
    required this.entry,
    required this.onTap,
    required this.trailingIcon,
  });

  final LibraryEntry entry;
  final VoidCallback onTap;
  final IconData trailingIcon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
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
            style: TextStyle(color: context.ink, fontWeight: FontWeight.w800),
          ),
          subtitle: Text(
            entry.note.isEmpty
                ? '${entry.subject.year} · ${_formatDateTime(entry.updatedAt)}'
                : '${entry.note} · ${_formatDateTime(entry.updatedAt)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.inkMuted),
          ),
          trailing: Icon(trailingIcon, color: AppColors.primary),
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
    return PosterArt(
      coverUrl: subject.coverUrl,
      title: subject.title,
      fit: BoxFit.cover,
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
    return SettingsCard(
      children: [
        SizedBox(
          height: 78,
          child: TextField(
            controller: _controller,
            decoration: const InputDecoration(labelText: '屏蔽词，用逗号分隔'),
          ),
        ),
        SettingsActionRow(
          icon: Icons.save_outlined,
          title: '保存屏蔽词',
          onTap: _save,
        ),
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
          color: Theme.of(context).colorScheme.surfaceContainerLow,
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
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                item.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.inkMuted),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (item.subject != null) item.subject!.title,
                  _formatDateTime(item.createdAt),
                ].join(' · '),
                style: TextStyle(color: context.inkMuted),
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

Future<void> _playDownloadTask(
  BuildContext context,
  WidgetRef ref,
  MediaDownloadTask task,
) async {
  final line = task.localPlaybackLine;
  if (line == null) {
    _showToast(context, '本地文件尚不可播放');
    return;
  }
  final controller = ref.read(animeControllerProvider.notifier);
  final accountContextVersion = controller.accountContextVersion;
  final recorded = await controller.addHistory(
    task.subject,
    task.episode,
    expectedAccountContextVersion: accountContextVersion,
  );
  if (!context.mounted ||
      !recorded ||
      !controller.isAccountContextCurrent(accountContextVersion)) {
    return;
  }
  context.push(
    '/player',
    extra: PlaySessionRequest(
      subject: task.subject,
      episodes: [task.episode],
      episode: task.episode,
      initialLine: line,
      offlineOnly: true,
    ),
  );
}

Future<bool> _confirmRemoveDownload(
  BuildContext context,
  MediaDownloadTask task,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(task.isPlayable ? '删除本地文件？' : '移除下载任务？'),
      content: Text(
        task.isPlayable
            ? '将删除“${task.title}”的本地视频文件，此操作无法撤销。'
            : '将移除“${task.title}”并清理未完成的临时文件。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('保留'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认删除'),
        ),
      ],
    ),
  );
  return result ?? false;
}

String _downloadSizeText(MediaDownloadTask task) {
  final downloaded = _downloadBytesLabel(task.downloadedBytes);
  final units = task.totalUnits > 0
      ? '${task.completedUnits}/${task.totalUnits} 分片'
      : null;
  if (task.totalBytes <= 0) {
    return units == null ? downloaded : '$units · $downloaded';
  }
  final bytes = '$downloaded / ${_downloadBytesLabel(task.totalBytes)}';
  if (units != null && task.status != MediaDownloadTaskStatus.completed) {
    return '$units · $bytes';
  }
  return bytes;
}

String _downloadBytesLabel(int bytes) {
  if (bytes <= 0) return '0 KB';
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}

Future<void> _playEntry(BuildContext context, LibraryEntry entry) async {
  final ref = ProviderScope.containerOf(context, listen: false);
  final controller = ref.read(animeControllerProvider.notifier);
  final accountContextVersion = controller.accountContextVersion;
  var episode = entry.episode;
  var episodes = <AnimeEpisode>[];
  try {
    final detail = await controller.detail(entry.subject);
    episodes = detail.episodes;
    episode ??= episodes.firstOrNull;
  } on AccountException {
    return;
  } catch (_) {
    if (!controller.isAccountContextCurrent(accountContextVersion)) return;
    episode ??= entry.episode;
  }
  if (!context.mounted ||
      !controller.isAccountContextCurrent(accountContextVersion)) {
    return;
  }
  if (episode == null) {
    _showToast(context, '这条记录没有可继续播放的集数');
    _openDetail(context, entry.subject);
    return;
  }
  final recorded = await controller.addHistory(
    entry.subject,
    episode,
    expectedAccountContextVersion: accountContextVersion,
  );
  if (!context.mounted ||
      !recorded ||
      !controller.isAccountContextCurrent(accountContextVersion)) {
    return;
  }
  context.push(
    '/player',
    extra: PlaySessionRequest(
      subject: entry.subject,
      episodes: episodes.isEmpty ? [episode] : episodes,
      episode: episode,
    ),
  );
}

void _openDetail(BuildContext context, AnimeSubject subject) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (context) => DetailPage(subject: subject)));
}

void _scrollToHistory(BuildContext context) {
  final target = AppChrome.profileHistorySectionKey.currentContext;
  if (target == null) {
    context.go('/profile');
    return;
  }
  Scrollable.ensureVisible(
    target,
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutCubic,
    alignment: 0.08,
  );
}

double? _entryProgress(LibraryEntry entry) {
  final total = entry.subject.totalEpisodes;
  final number = entry.episode?.number ?? 1;
  if (total <= 0) return null;
  return (number / total).clamp(0.05, 1.0);
}

bool _isFinishedEntry(LibraryEntry entry) {
  final total = entry.subject.totalEpisodes;
  final number = entry.episode?.number ?? 0;
  return total > 0 && number >= total;
}

void _showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
