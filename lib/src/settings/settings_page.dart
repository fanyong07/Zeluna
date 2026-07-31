import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../player/anime4k_shader_manager.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/settings_ui.dart';
import '../shared_ui/app_navigation.dart';

class SettingsHubPage extends ConsumerWidget {
  const SettingsHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final compact = MediaQuery.sizeOf(context).width < 760;
        final tiles = [
          _SettingsHubTile(
            icon: Icons.video_file_outlined,
            title: '打开媒体',
            value: '本地 / 直链',
            onTap: () => context.push('/player/open'),
          ),
          _SettingsHubTile(
            icon: Icons.download_done,
            title: '下载管理',
            value: '${state.offlineTasks.length}',
            onTap: () => context.push('/profile/offline'),
          ),
          _SettingsHubTile(
            icon: Icons.subtitles,
            title: '弹幕设置',
            value: state.danmaku.enabled ? '开启' : '关闭',
            onTap: () => context.push('/profile/danmaku'),
          ),
          _SettingsHubTile(
            icon: Icons.play_circle_outline,
            title: '播放设置',
            value: '偏好',
            onTap: () => context.push('/settings/playback'),
          ),
          _SettingsHubTile(
            icon: Icons.dns_outlined,
            title: '在线服务',
            value: state.services.playbackBackendEnabled ? '已连接' : '未连接',
            onTap: () => context.push('/settings/services/playback'),
          ),
        ];
        return AppChrome(
          active: ChromeDestination.settings,
          showSearch: false,
          title: '设置',
          rightRail: _SettingsHubRail(state: state),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 24,
              compact ? 0 : 6,
              compact ? 14 : 0,
              120,
            ),
            children: [
              if (!compact) ...[
                AppPanel(
                  borderColor: Theme.of(context).colorScheme.outline,
                  child: const Row(
                    children: [
                      Icon(Icons.settings_outlined, color: AppColors.primary),
                      SizedBox(width: 10),
                      Expanded(
                        child: SectionTitle(
                          title: '设置',
                          subtitle: '播放、资源、缓存和弹幕统一管理',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  if (compact) {
                    return AppPanel(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < tiles.length; i++) ...[
                            tiles[i],
                            if (i != tiles.length - 1)
                              const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    );
                  }
                  final columns = constraints.maxWidth >= 1080
                      ? 4
                      : constraints.maxWidth >= 760
                      ? 3
                      : 2;
                  return GridView.count(
                    crossAxisCount: columns,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 2.5,
                    children: tiles,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsHubTile extends StatelessWidget {
  const _SettingsHubTile({
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
      child: AppPanel(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 12 : 16,
        ),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary, size: compact ? 24 : 30),
            SizedBox(width: compact ? 12 : 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (compact
                                ? Theme.of(context).textTheme.titleSmall
                                : Theme.of(context).textTheme.titleMedium)
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w900,
                            ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (compact) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: context.inkFaint,
                size: 22,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsHubRail extends StatelessWidget {
  const _SettingsHubRail({required this.state});

  final AnimeState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 6, 20, 24),
      children: [
        AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '当前状态'),
              const SizedBox(height: 14),
              _SettingsHubRailLine(
                label: '在线内容',
                value: state.services.playbackBackendEnabled ? '已连接' : '未连接',
              ),
              _SettingsHubRailLine(
                label: '下载任务',
                value: '${state.offlineTasks.length}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(title: '说明'),
              SizedBox(height: 12),
              _SettingsHubNote(text: '番剧、电视剧和电影的资料与播放由在线服务统一提供'),
              _SettingsHubNote(text: '日常使用无需自行添加或配置播放来源'),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsHubRailLine extends StatelessWidget {
  const _SettingsHubRailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SmallBadge(label: value, active: true),
        ],
      ),
    );
  }
}

class _SettingsHubNote extends StatelessWidget {
  const _SettingsHubNote({required this.text});

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

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        return PlaybackSettingsView(
          settings: state.settings,
          onChanged: (settings) => ref
              .read(animeControllerProvider.notifier)
              .updateSettings(settings),
          onBack: () => safeNavigateBack(context, fallbackRoute: '/profile'),
        );
      },
    );
  }
}

class PlaybackSettingsView extends StatelessWidget {
  const PlaybackSettingsView({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onBack,
    this.compact = false,
    this.subject,
    this.episode,
    this.line,
    this.playbackMessage,
    this.superResolutionStatus,
  });

  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings> onChanged;
  final VoidCallback onBack;
  final bool compact;
  final AnimeSubject? subject;
  final AnimeEpisode? episode;
  final PlaybackLine? line;
  final String? playbackMessage;
  final Widget? superResolutionStatus;

  @override
  Widget build(BuildContext context) {
    final narrow = compact || MediaQuery.sizeOf(context).width < 620;
    final superResolutionSupport = Anime4KShaderManager.currentPlatformSupport;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            narrow ? 12 : 28,
            0,
            narrow ? 12 : 28,
            compact ? 28 : 48,
          ),
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingsTitle(onBack: onBack, compact: compact),
                    if (compact) ...[
                      SettingsDisclosure(
                        icon: Icons.info_outline_rounded,
                        title: '播放信息',
                        subtitle: '查看当前内容与播放状态',
                        child: _PlaybackInfoContent(
                          subject: subject,
                          episode: episode,
                          line: line,
                          playbackMessage: playbackMessage,
                          showTitle: false,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SettingsDisclosure(
                      icon: Icons.keyboard_alt_outlined,
                      title: '按键说明',
                      subtitle: '查看并管理播放器键盘操作',
                      child: _ShortcutHelpContent(
                        settings: settings,
                        onChanged: onChanged,
                        showTitle: false,
                      ),
                    ),
                    const SizedBox(height: 22),
                    _SettingsSection(
                      icon: Icons.volume_up_outlined,
                      title: '声音',
                      subtitle: '调整播放器的额外音量增益',
                      child: _VolumeCard(
                        settings: settings,
                        onChanged: onChanged,
                      ),
                    ),
                    _SettingsSection(
                      icon: Icons.tune_rounded,
                      title: '画面与速度',
                      subtitle: '实时调整画质、显示比例和播放速度',
                      child: SettingsCard(
                        children: [
                          SettingsSwitchRow(
                            title: '超分辨率',
                            subtitle: superResolutionSupport.supported
                                ? '使用 Anime4K 实时增强画面清晰度'
                                : (superResolutionSupport.reason ??
                                      '当前设备不支持实时超分'),
                            value: settings.superResolution,
                            onChanged: superResolutionSupport.supported
                                ? (value) => onChanged(
                                    settings.copyWith(superResolution: value),
                                  )
                                : null,
                          ),
                          if (settings.superResolution &&
                              superResolutionSupport.supported &&
                              superResolutionStatus != null)
                            superResolutionStatus!,
                          if (settings.superResolution &&
                              superResolutionSupport.supported)
                            SettingsChoiceRow<String>(
                              presentation: compact
                                  ? SettingsChoicePresentation.inline
                                  : SettingsChoicePresentation.sheet,
                              title: '超分模式',
                              subtitle: _superResolutionProfileDescription(
                                settings.superResolutionProfile,
                              ),
                              value: settings.superResolutionProfile,
                              options: const [
                                'auto',
                                'clear',
                                'soft',
                                'low_resolution',
                                'strong',
                                'advanced',
                              ],
                              labelOf: _superResolutionProfileLabel,
                              onChanged: (value) => onChanged(
                                settings.copyWith(
                                  superResolutionProfile: value,
                                ),
                              ),
                            ),
                          if (settings.superResolution &&
                              superResolutionSupport.supported &&
                              settings.superResolutionProfile == 'advanced')
                            _Anime4KShaderPicker(
                              selected: settings.superResolutionCustomShaders,
                              onChanged: (value) => onChanged(
                                settings.copyWith(
                                  superResolutionCustomShaders: value,
                                ),
                              ),
                            ),
                          SettingsChoiceRow<String>(
                            presentation: compact
                                ? SettingsChoicePresentation.inline
                                : SettingsChoicePresentation.sheet,
                            title: '画面尺寸',
                            subtitle: '选择视频在播放器中的显示方式',
                            value: settings.videoScale,
                            options: const [
                              '适应',
                              '铺满',
                              '拉伸',
                              '16:9',
                              '4:3',
                              '原始',
                            ],
                            labelOf: (value) => value,
                            onChanged: (value) =>
                                onChanged(settings.copyWith(videoScale: value)),
                          ),
                          SettingsChoiceRow<double>(
                            presentation: compact
                                ? SettingsChoicePresentation.inline
                                : SettingsChoicePresentation.sheet,
                            title: '播放速度',
                            subtitle: '立即应用到当前播放内容',
                            value: settings.speed,
                            options: const [
                              0.5,
                              0.75,
                              1.0,
                              1.25,
                              1.5,
                              2.0,
                              3.0,
                            ],
                            labelOf: _speedLabel,
                            onChanged: (value) =>
                                onChanged(settings.copyWith(speed: value)),
                          ),
                        ],
                      ),
                    ),
                    _SettingsSection(
                      icon: Icons.fast_forward_rounded,
                      title: '进度跳转',
                      subtitle: '设置播放器每次快退和快进的时长',
                      child: SettingsCard(
                        children: [
                          SettingsChoiceRow<int>(
                            presentation: compact
                                ? SettingsChoicePresentation.inline
                                : SettingsChoicePresentation.sheet,
                            title: '快退时间',
                            subtitle: '每次快退操作跳过的时长',
                            value: settings.rewindSeconds,
                            options: const [5, 10, 15, 30, 60, 90],
                            labelOf: (value) => '$value 秒',
                            onChanged: (value) => onChanged(
                              settings.copyWith(rewindSeconds: value),
                            ),
                          ),
                          SettingsChoiceRow<int>(
                            presentation: compact
                                ? SettingsChoicePresentation.inline
                                : SettingsChoicePresentation.sheet,
                            title: '快进时间',
                            subtitle: '每次快进操作跳过的时长',
                            value: settings.forwardSeconds,
                            options: const [5, 10, 15, 30, 60, 90],
                            labelOf: (value) => '$value 秒',
                            onChanged: (value) => onChanged(
                              settings.copyWith(forwardSeconds: value),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _SettingsSection(
                      icon: Icons.playlist_play_rounded,
                      title: '播放行为',
                      subtitle: '管理连续播放、失败恢复和全屏行为',
                      child: SettingsCard(
                        children: [
                          SettingsSwitchRow(
                            title: '自动续播',
                            subtitle: '当前内容结束后自动播放下一集',
                            value: settings.autoNext,
                            onChanged: (value) =>
                                onChanged(settings.copyWith(autoNext: value)),
                          ),
                          SettingsSwitchRow(
                            title: '失败时自动换线',
                            subtitle: '播放失败时自动尝试其他可用线路',
                            value: settings.autoSwitchLine,
                            onChanged: (value) => onChanged(
                              settings.copyWith(autoSwitchLine: value),
                            ),
                          ),
                          SettingsSwitchRow(
                            title: '自动全屏',
                            subtitle: '首次进入播放页面时自动切换全屏',
                            value: settings.autoFullscreen,
                            onChanged: (value) => onChanged(
                              settings.copyWith(autoFullscreen: value),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTitle extends StatelessWidget {
  const _SettingsTitle({
    required this.onBack,
    required this.compact,
    this.title = '播放设置',
    this.subtitle = '调整画面、声音和播放器行为',
  });

  final VoidCallback onBack;
  final bool compact;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(0, compact ? 8 : 14, 0, compact ? 12 : 20),
      child: Row(
        children: [
          if (!compact) ...[
            IconButton.filledTonal(
              key: const ValueKey('playback_settings_back'),
              tooltip: '返回',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: context.ink,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
                  ),
                ],
              ],
            ),
          ),
          if (compact)
            IconButton(
              key: const ValueKey('playback_settings_close'),
              tooltip: '关闭',
              onPressed: onBack,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(icon, size: 19, color: context.inkMuted),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: context.ink,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _PlaybackInfoContent extends StatelessWidget {
  const _PlaybackInfoContent({
    required this.subject,
    required this.episode,
    required this.line,
    required this.playbackMessage,
    this.showTitle = true,
  });

  final AnimeSubject? subject;
  final AnimeEpisode? episode;
  final PlaybackLine? line;
  final String? playbackMessage;
  final bool showTitle;

  String get _contentTitle {
    final title = subject?.title.trim();
    final episodeText = episode == null ? '' : ' · 第${episode!.number}集';
    if (title == null || title.isEmpty) return '未选择内容$episodeText';
    return '$title$episodeText';
  }

  @override
  Widget build(BuildContext context) {
    final rows = <_InfoPair>[
      _InfoPair('内容', _contentTitle),
      _InfoPair('清晰度', _textOrFallback(line?.quality)),
      _InfoPair('格式', _textOrFallback(line?.format)),
      _InfoPair('状态', _playbackStatusText(line, playbackMessage)),
      _InfoPair('延迟', _latencyText(line?.latency)),
      _InfoPair('大小', _textOrFallback(line?.sizeLabel)),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(18, showTitle ? 16 : 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) ...[
            Text(
              '播放信息',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: context.ink,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      row.label,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: context.inkFaint),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: context.inkMuted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ShortcutHelpContent extends StatelessWidget {
  const _ShortcutHelpContent({
    required this.settings,
    required this.onChanged,
    this.showTitle = true,
  });

  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings> onChanged;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final enabled = settings.keyboardShortcutsEnabled;
    return Padding(
      padding: EdgeInsets.fromLTRB(6, showTitle ? 14 : 6, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '按键说明',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: context.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  enabled ? '已启用' : '已关闭',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: enabled ? context.inkMuted : context.inkFaint,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          SettingsSwitchRow(
            title: '启用键盘控制',
            subtitle: '允许桌面端播放器响应键盘操作',
            value: enabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(keyboardShortcutsEnabled: value)),
          ),
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          _ShortcutControlRow(
            keys: const ['Space', 'K'],
            title: '播放与暂停',
            subtitle: '切换当前内容的播放状态',
            value: settings.shortcutPlayPause,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(shortcutPlayPause: value)),
          ),
          _ShortcutControlRow(
            keys: const ['←', '→'],
            title: '快退与快进',
            subtitle:
                '每次跳转 ${settings.rewindSeconds} / ${settings.forwardSeconds} 秒',
            value: settings.shortcutSeek,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(shortcutSeek: value)),
          ),
          _ShortcutControlRow(
            keys: const ['↑', '↓'],
            title: '音量调节',
            subtitle: '提高或降低播放器音量',
            value: settings.shortcutVolume,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(shortcutVolume: value)),
          ),
          _ShortcutControlRow(
            keys: const ['F'],
            title: '全屏切换',
            subtitle: '进入或退出全屏播放',
            value: settings.shortcutFullscreen,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(shortcutFullscreen: value)),
          ),
          _ShortcutControlRow(
            keys: const ['M'],
            title: '静音',
            subtitle: '切换静音和恢复声音',
            value: settings.shortcutMute,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(shortcutMute: value)),
          ),
          _ShortcutControlRow(
            keys: const ['R'],
            title: '重载线路',
            subtitle: '重新连接当前播放线路',
            value: settings.shortcutReload,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(shortcutReload: value)),
          ),
          _ShortcutReferenceRow(
            keys: const ['Esc'],
            title: '关闭面板或退出全屏',
            enabled: enabled,
          ),
        ],
      ),
    );
  }
}

class _ShortcutControlRow extends StatelessWidget {
  const _ShortcutControlRow({
    required this.keys,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final List<String> keys;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.48,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? () => onChanged(!value) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              SizedBox(
                width: 96,
                child: Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [for (final keyLabel in keys) _KeyCap(keyLabel)],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: context.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: context.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                key: ValueKey('shortcut_switch_$title'),
                value: value,
                onChanged: enabled ? onChanged : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutReferenceRow extends StatelessWidget {
  const _ShortcutReferenceRow({
    required this.keys,
    required this.title,
    required this.enabled,
  });

  final List<String> keys;
  final String title;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Wrap(
                spacing: 5,
                children: [for (final keyLabel in keys) _KeyCap(keyLabel)],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: context.inkMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.inkFaint),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: context.ink,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _InfoPair {
  const _InfoPair(this.label, this.value);

  final String label;
  final String value;
}

String _textOrFallback(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '未知';
  return text;
}

String _playbackStatusText(PlaybackLine? line, String? playbackMessage) {
  final message = playbackMessage?.trim();
  if (line == null) return message?.isNotEmpty == true ? message! : '等待选线';
  final lineMessage = line.message?.trim();
  if (!line.available) {
    return lineMessage?.isNotEmpty == true ? lineMessage! : '不可用';
  }
  if ((line.url ?? '').trim().isEmpty) {
    return lineMessage?.isNotEmpty == true ? lineMessage! : '未返回播放地址';
  }
  return message?.isNotEmpty == true ? message! : '可播放';
}

String _latencyText(Duration? value) {
  if (value == null) return '未知';
  return '${value.inMilliseconds} ms';
}

class _VolumeCard extends StatelessWidget {
  const _VolumeCard({required this.settings, required this.onChanged});

  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '音量增强',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: context.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Text(
                      '+${(settings.volumeBoost * 100).round()}%',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: context.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('volume_boost_reset'),
                  tooltip: '恢复默认',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      onChanged(settings.copyWith(volumeBoost: 0.26)),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            Slider(
              key: const ValueKey('volume_boost_slider'),
              value: settings.volumeBoost,
              min: 0,
              max: 1,
              onChanged: (value) =>
                  onChanged(settings.copyWith(volumeBoost: value)),
            ),
            Row(
              children: [
                Text(
                  '不增强',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: context.inkFaint),
                ),
                const Spacer(),
                Text(
                  '最高 +100%',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: context.inkFaint),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ServiceSettingsPage extends ConsumerWidget {
  const ServiceSettingsPage({super.key, required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final settings = state.services;
        final controller = ref.read(animeControllerProvider.notifier);
        return Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 12, 120),
                  children: [
                    _SettingsTitle(
                      onBack: () =>
                          safeNavigateBack(context, fallbackRoute: '/settings'),
                      compact: false,
                      title: '外部服务',
                      subtitle: '管理资料来源与第三方接口',
                    ),
                    const SizedBox(height: 12),
                    ...switch (kind) {
                      'sync' => _syncSourceCards(settings, controller),
                      'subtitles' => _subtitleSourceCards(settings, controller),
                      'danmaku' => _danmakuSourceCards(
                        settings,
                        controller,
                        context,
                      ),
                      'playback' => _playbackSourceCards(
                        settings,
                        controller,
                        context,
                      ),
                      _ => [
                        const _InfoCard(
                          title: '未知设置',
                          lines: ['这个入口暂时没有对应配置。'],
                        ),
                      ],
                    },
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: BackPill(
                      onBack: () =>
                          safeNavigateBack(context, fallbackRoute: '/settings'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _syncSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    return [
      const _InfoCard(
        title: '观看记录 / 片单 / 评分',
        lines: ['免登录只能读取公开数据；写入云端历史一定需要账号授权。', '当前支持公开片单读取和本机播放记录，不需要授权配置。'],
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          SettingsSwitchRow(
            title: '启用公开收藏同步',
            value: settings.publicCollectionSyncEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(publicCollectionSyncEnabled: value),
            ),
          ),
          SettingsSwitchRow(
            title: '自动记录播放历史',
            value: settings.publicCollectionSyncEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(publicCollectionSyncEnabled: value),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _playbackSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
    BuildContext context,
  ) {
    final endpoint = settings.playbackBackendEndpoint.trim();
    return [
      const _InfoCard(
        title: '在线内容服务',
        lines: [
          '番剧、电视剧和电影的资料与播放地址由在线服务提供；服务不可用时会明确提示。',
          '地址只接受网页链接（http 或 https），不要填写账号、密码或带额外参数的链接。',
        ],
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          SettingsSwitchRow(
            title: '使用在线服务',
            subtitle: endpoint.isEmpty ? '请先填写服务地址' : endpoint,
            value: settings.playbackBackendEnabled,
            onChanged: (value) {
              if (value && endpoint.isEmpty) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('请先填写服务地址')));
                return;
              }
              controller.updateServices(
                settings.copyWith(playbackBackendEnabled: value),
              );
            },
          ),
          SettingsActionRow(
            title: '服务地址',
            subtitle: endpoint.isEmpty ? '未配置' : endpoint,
            onTap: () =>
                _showPlaybackBackendEditor(context, settings, controller),
          ),
        ],
      ),
    ];
  }

  List<Widget> _subtitleSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    return [
      const _InfoCard(
        title: '字幕源：Bilibili 公开字幕',
        lines: [
          '通过 B 站公开番剧搜索匹配 season/episode，再读取播放器公开字幕列表。',
          '不需要 API Key；没有官方字幕或需要登录权限时会显示未匹配。',
        ],
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          SettingsSwitchRow(
            title: '启用 Bilibili 字幕',
            value: settings.bilibiliSubtitleEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(bilibiliSubtitleEnabled: value),
            ),
          ),
          SettingsSwitchRow(
            title: '自动匹配字幕',
            value: settings.autoMatchSubtitle,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(autoMatchSubtitle: value),
            ),
          ),
          SettingsChoiceRow<String>(
            title: '默认字幕语言',
            value: settings.subtitleLanguage,
            options: const ['zh-CN', 'zh-TW', 'ja-JP', 'en-US'],
            labelOf: (value) => value,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(subtitleLanguage: value),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _danmakuSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
    BuildContext context,
  ) {
    return [
      const _InfoCard(
        title: '弹幕源：弹弹play / Bilibili / 自建弹幕库',
        lines: [
          '弹弹play 使用官方开放平台按番名和集数匹配弹幕库，需要填写 AppId 和 AppSecret。',
          '通过 B 站公开番剧搜索匹配当前集 cid，再读取公开弹幕 XML。',
          '自建弹幕库仍保留为用户自己的接口补充。',
        ],
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          SettingsSwitchRow(
            title: '启用弹弹play弹幕',
            subtitle: settings.dandanplayAppId.trim().isEmpty
                ? '需要填写开放平台 AppId / AppSecret'
                : '已配置开放平台凭证',
            value: settings.dandanplayDanmakuEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(dandanplayDanmakuEnabled: value),
            ),
          ),
          SettingsActionRow(
            title: '弹弹play开放平台',
            subtitle: settings.dandanplayAppId.trim().isEmpty
                ? '未填写'
                : settings.dandanplayAppId,
            onTap: () => _showDandanplayEditor(context, settings, controller),
          ),
          SettingsSwitchRow(
            title: '启用 Bilibili 弹幕',
            value: settings.bilibiliDanmakuEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(bilibiliDanmakuEnabled: value),
            ),
          ),
          SettingsSwitchRow(
            title: '启用自建弹幕库',
            value: settings.customDanmakuEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(customDanmakuEnabled: value),
            ),
          ),
          SettingsActionRow(
            title: '自建接口地址',
            subtitle: settings.customDanmakuEndpoint.isEmpty
                ? '未填写'
                : settings.customDanmakuEndpoint,
            onTap: () => _showEndpointEditor(context, settings, controller),
          ),
          SettingsSwitchRow(
            title: '弹幕时间轴同步',
            value: settings.danmakuTimelineSync,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(danmakuTimelineSync: value),
            ),
          ),
        ],
      ),
    ];
  }

  void _showDandanplayEditor(
    BuildContext context,
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    final appId = TextEditingController(text: settings.dandanplayAppId);
    final appSecret = TextEditingController(text: settings.dandanplayAppSecret);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: appId,
                  decoration: const InputDecoration(labelText: 'AppId'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: appSecret,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'AppSecret'),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () {
                    controller.updateServices(
                      settings.copyWith(
                        dandanplayAppId: appId.text.trim(),
                        dandanplayAppSecret: appSecret.text.trim(),
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEndpointEditor(
    BuildContext context,
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    final text = TextEditingController(text: settings.customDanmakuEndpoint);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  decoration: const InputDecoration(labelText: '自建弹幕接口地址'),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () {
                    controller.updateServices(
                      settings.copyWith(
                        customDanmakuEndpoint: text.text.trim(),
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPlaybackBackendEditor(
    BuildContext context,
    ExternalServiceSettings settings,
    AnimeController controller,
  ) {
    final text = TextEditingController(text: settings.playbackBackendEndpoint);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('playback_backend_endpoint_field'),
                  controller: text,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'https://api.example.com',
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  key: const ValueKey('save_playback_backend_endpoint'),
                  onPressed: () {
                    final value = text.text.trim().replaceFirst(
                      RegExp(r'/+$'),
                      '',
                    );
                    final uri = Uri.tryParse(value);
                    final valid =
                        value.isEmpty ||
                        (uri != null &&
                            uri.hasAuthority &&
                            (uri.scheme == 'http' || uri.scheme == 'https') &&
                            uri.userInfo.isEmpty &&
                            uri.query.isEmpty &&
                            uri.fragment.isEmpty);
                    if (!valid) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请输入有效的 HTTP 或 HTTPS 地址')),
                      );
                      return;
                    }
                    controller.updateServices(
                      settings.copyWith(
                        playbackBackendEndpoint: value,
                        playbackBackendEnabled: value.isEmpty
                            ? false
                            : settings.playbackBackendEnabled,
                      ),
                    );
                    Navigator.of(sheetContext).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: context.ink,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  line,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.inkMuted,
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _superResolutionProfileLabel(String value) {
  return Anime4KProfile.fromSetting(value).label;
}

String _superResolutionProfileDescription(String value) {
  return Anime4KProfile.fromSetting(value).description;
}

class _Anime4KShaderPicker extends StatelessWidget {
  const _Anime4KShaderPicker({required this.selected, required this.onChanged});

  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final validCount = selected
        .where(Anime4KShaderManager.availableShaderFileNames.contains)
        .length;
    return InkWell(
      key: const ValueKey('setting_choice_高级着色器'),
      onTap: () => _showPicker(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '高级着色器',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      validCount == 0 ? '尚未选择' : '已选择 $validCount 个',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: validCount == 0
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$validCount/${Anime4KShaderManager.availableShaderFileNames.length}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
                size: 21,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPicker(BuildContext context) async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) {
        final chosen = selected
            .where(Anime4KShaderManager.availableShaderFileNames.contains)
            .toSet();
        return StatefulBuilder(
          builder: (context, setModalState) {
            final categories = <String, List<String>>{};
            for (final shader
                in Anime4KShaderManager.availableShaderFileNames) {
              categories
                  .putIfAbsent(
                    Anime4KShaderManager.shaderCategory(shader),
                    () => <String>[],
                  )
                  .add(shader);
            }
            return FractionallySizedBox(
              heightFactor: 0.9,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '高级着色器',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        TextButton(
                          onPressed: chosen.isEmpty
                              ? null
                              : () => setModalState(chosen.clear),
                          child: const Text('清空'),
                        ),
                        const SizedBox(width: 6),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(
                            Anime4KShaderManager.availableShaderFileNames
                                .where(chosen.contains)
                                .toList(growable: false),
                          ),
                          child: Text('完成 (${chosen.length})'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        for (final category in categories.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                            child: Text(
                              category.key,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          for (final shader in category.value)
                            CheckboxListTile(
                              value: chosen.contains(shader),
                              title: Text(
                                Anime4KShaderManager.shaderLabel(shader),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onChanged: (enabled) => setModalState(() {
                                if (enabled == true) {
                                  chosen.add(shader);
                                } else {
                                  chosen.remove(shader);
                                }
                              }),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (result != null) onChanged(result);
  }
}

String _speedLabel(double value) {
  if (value == 1) return '1.0x';
  var text = value.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0$'), '');
  text = text.replaceFirst(RegExp(r'\.0$'), '');
  return '${text}x';
}
