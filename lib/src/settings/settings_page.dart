import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/anime_app.dart';
import '../data/anime_controller.dart';
import '../domain/anime_models.dart';
import '../player/anime4k_shader_manager.dart';
import '../player/playback_line_display.dart';
import '../player/sleep_timer_controller.dart';
import '../shared_ui/app_chrome.dart';
import '../shared_ui/settings_ui.dart';
import '../shared_ui/app_navigation.dart';

final _dandanplayWebsiteUri = Uri.https('www.dandanplay.com', '/');

class SettingsHubPage extends ConsumerWidget {
  const SettingsHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncAnimeGate(
      builder: (context, state) {
        final compact = MediaQuery.sizeOf(context).width < 760;
        final scheme = Theme.of(context).colorScheme;
        final themeSummary = state.appearance.isMonochrome
            ? (state.appearance.pureBlackOled ? '黑白 · OLED' : '黑白极简')
            : '自定义主题色';
        final tiles = [
          _SettingsHubTile(
            icon: Icons.palette_outlined,
            accent: scheme.primary,
            title: '外观与主题',
            value: themeSummary,
            onTap: () => context.push('/profile/appearance'),
          ),
          _SettingsHubTile(
            icon: Icons.video_file_outlined,
            accent: context.gold,
            title: '打开媒体',
            value: '本地 / 直链',
            onTap: () => context.push('/player/open'),
          ),
          _SettingsHubTile(
            icon: Icons.download_done_rounded,
            accent: AppColors.success,
            title: '下载管理',
            value: '${state.offlineTasks.length}',
            onTap: () => context.push('/profile/offline'),
          ),
          _SettingsHubTile(
            icon: Icons.comment_outlined,
            accent: AppColors.violet,
            title: '弹幕显示',
            value: state.danmaku.enabled ? '开启' : '关闭',
            onTap: () => context.push('/profile/danmaku'),
          ),
          _SettingsHubTile(
            icon: Icons.hub_outlined,
            accent: AppColors.violet,
            title: '弹幕来源',
            value: _danmakuSourceSummary(state.services),
            onTap: () => context.push('/settings/services/danmaku'),
          ),
          _SettingsHubTile(
            icon: Icons.play_circle_outline_rounded,
            accent: scheme.primary,
            title: '播放设置',
            value: '偏好',
            onTap: () => context.push('/settings/playback'),
          ),
          if (!kIsWeb)
            _SettingsHubTile(
              icon: Icons.video_library_outlined,
              accent: AppColors.cyan,
              title: '媒体源',
              value: '私有媒体库',
              onTap: () => context.push('/settings/media-sources'),
            ),
          _SettingsHubTile(
            icon: Icons.rss_feed_rounded,
            accent: scheme.primary,
            title: '扩展来源',
            value: '自定义规则',
            onTap: () => context.push('/profile/rules'),
          ),
          _SettingsHubTile(
            icon: Icons.dns_outlined,
            accent: AppColors.success,
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
              compact ? 6 : 12,
              compact ? 14 : 20,
              120,
            ),
            children: [
              if (!compact) ...[
                const SectionTitle(
                  title: '设置中心',
                  subtitle: '主题配色、播放偏好、扩展来源与弹幕统一管理',
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

String _danmakuSourceSummary(ExternalServiceSettings settings) {
  final enabled = <bool>[
    settings.dandanplayDanmakuEnabled,
    settings.bilibiliDanmakuEnabled,
    settings.customDanmakuEnabled,
  ].where((value) => value).length;
  return enabled == 0 ? 'Zeluna' : 'Zeluna + $enabled 个';
}

class _SettingsHubTile extends StatelessWidget {
  const _SettingsHubTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.accent,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final scheme = Theme.of(context).colorScheme;
    final tint = accent ?? scheme.primary;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(
        alpha: context.isDarkMode ? 0.56 : 0.72,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.48)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 16,
            vertical: compact ? 12 : 15,
          ),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: tint.withValues(
                    alpha: context.isDarkMode ? 0.18 : 0.12,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: tint.withValues(
                      alpha: context.isDarkMode ? 0.34 : 0.22,
                    ),
                  ),
                ),
                child: SizedBox.square(
                  dimension: compact ? 38 : 42,
                  child: Icon(icon, color: tint, size: compact ? 20 : 22),
                ),
              ),
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
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (compact) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
                  size: 20,
                ),
              ],
            ],
          ),
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
              _SettingsHubNote(text: '在线服务提供番剧、电视剧和电影的资料，也可添加私有播放源'),
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
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
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
    this.currentPosition,
    this.totalDuration,
    this.readPosition,
    this.sleepTimer,
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
  final Duration? currentPosition;
  final Duration? totalDuration;
  final ValueGetter<Duration>? readPosition;
  final SleepTimerController? sleepTimer;

  @override
  Widget build(BuildContext context) {
    final narrow = compact || MediaQuery.sizeOf(context).width < 620;
    final superResolutionSupport = Anime4KShaderManager.currentPlatformSupport;
    return Scaffold(
      backgroundColor: compact ? Colors.transparent : null,
      body: SafeArea(
        left: !compact,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            compact ? 14 : (narrow ? 14 : 28),
            compact ? 4 : 0,
            compact ? 14 : (narrow ? 14 : 28),
            compact ? 24 : 48,
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
                      const SizedBox(height: 8),
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
                    SizedBox(height: compact ? 16 : 22),
                    _SettingsSection(
                      icon: Icons.volume_up_outlined,
                      title: '声音',
                      subtitle: '放大播放器的最大音量',
                      compact: compact,
                      child: _VolumeCard(
                        settings: settings,
                        onChanged: onChanged,
                      ),
                    ),
                    _SettingsSection(
                      icon: Icons.tune_rounded,
                      title: '画面与速度',
                      subtitle: '实时调整画质、显示比例和播放速度',
                      compact: compact,
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
                              title: '画质档位',
                              subtitle: _superResolutionTierDescription(
                                settings.superResolutionTier,
                              ),
                              value: settings.superResolutionTier,
                              options: const [
                                'quality',
                                'balance',
                                'efficiency',
                                'custom',
                              ],
                              labelOf: _superResolutionTierLabel,
                              descriptionOf: _superResolutionTierDescription,
                              onChanged: (value) => onChanged(
                                settings.copyWith(superResolutionTier: value),
                              ),
                            ),
                          // The mode picks the chain shape, so it is meaningless
                          // for the custom tier where the user builds the chain.
                          if (settings.superResolution &&
                              superResolutionSupport.supported &&
                              settings.superResolutionTier != 'custom')
                            SettingsChoiceRow<String>(
                              presentation: compact
                                  ? SettingsChoicePresentation.inline
                                  : SettingsChoicePresentation.sheet,
                              title: '超分模式',
                              subtitle: _superResolutionModeDescription(
                                settings.superResolutionMode,
                              ),
                              value: settings.superResolutionMode,
                              options: const ['a', 'b', 'c', 'aa', 'bb', 'ca'],
                              labelOf: _superResolutionModeLabel,
                              descriptionOf: _superResolutionModeDetail,
                              onChanged: (value) => onChanged(
                                settings.copyWith(superResolutionMode: value),
                              ),
                            ),
                          if (settings.superResolution &&
                              superResolutionSupport.supported &&
                              settings.superResolutionTier == 'custom')
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
                      compact: compact,
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
                      icon: Icons.skip_next_rounded,
                      title: '片头片尾跳过',
                      subtitle: '0 秒表示不跳过，片尾仅在自动续播时跳过',
                      compact: compact,
                      child: _SkipTimingControls(
                        key: ValueKey(subject?.identityKey),
                        settings: settings,
                        subjectKey: subject?.identityKey,
                        onChanged: onChanged,
                        currentPosition: currentPosition,
                        totalDuration: totalDuration,
                        readPosition: readPosition,
                      ),
                    ),
                    if (sleepTimer case final timer?)
                      _SettingsSection(
                        icon: Icons.bedtime_outlined,
                        title: '睡眠定时',
                        subtitle: '定时结束后暂停播放',
                        compact: compact,
                        child: ListenableBuilder(
                          listenable: timer,
                          builder: (context, _) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ChoiceChip(
                                    visualDensity: VisualDensity.compact,
                                    label: const Text('关闭'),
                                    selected: !timer.isActive,
                                    onSelected: (_) => timer.setOff(),
                                  ),
                                  ChoiceChip(
                                    visualDensity: VisualDensity.compact,
                                    label: const Text('播完本集'),
                                    selected:
                                        timer.mode ==
                                        SleepTimerMode.endOfEpisode,
                                    onSelected: (_) => timer.setEndOfEpisode(),
                                  ),
                                  for (final minutes in const [15, 30, 60])
                                    ChoiceChip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text('$minutes分钟'),
                                      selected:
                                          timer.countdownDuration ==
                                          Duration(minutes: minutes),
                                      onSelected: (_) => timer.startCountdown(
                                        Duration(minutes: minutes),
                                      ),
                                    ),
                                ],
                              ),
                              if (timer.isActive) ...[
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.bedtime_rounded,
                                      size: 14,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      timer.mode == SleepTimerMode.endOfEpisode
                                          ? '本集播完后自动暂停播放'
                                          : '将在 ${timer.badgeLabel} 后自动暂停播放',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    _SettingsSection(
                      icon: Icons.playlist_play_rounded,
                      title: '播放行为',
                      subtitle: '管理连续播放、失败恢复和全屏行为',
                      compact: compact,
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
                            title: '线路记忆',
                            subtitle: '记住每部作品的成功线路，并提前准备下一集线路',
                            value: settings.rememberLine,
                            onChanged: (value) => onChanged(
                              settings.copyWith(rememberLine: value),
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

class _SkipTimingControls extends StatefulWidget {
  const _SkipTimingControls({
    super.key,
    required this.settings,
    required this.subjectKey,
    required this.onChanged,
    required this.currentPosition,
    required this.totalDuration,
    required this.readPosition,
  });
  final PlaybackSettings settings;
  final String? subjectKey;
  final ValueChanged<PlaybackSettings> onChanged;
  final Duration? currentPosition, totalDuration;
  final ValueGetter<Duration>? readPosition;
  @override
  State<_SkipTimingControls> createState() => _SkipTimingControlsState();
}

class _SkipTimingControlsState extends State<_SkipTimingControls> {
  // A zero/zero override is not persisted; keep the editor open while entering it.
  late bool editingOverride = widget.settings.subjectSkipTimings.containsKey(
    widget.subjectKey,
  );

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final key = widget.subjectKey;
    final individual =
        key != null &&
        (editingOverride || settings.subjectSkipTimings.containsKey(key));
    final timing = individual
        ? settings.subjectSkipTimings[key] ?? const SkipTiming()
        : SkipTiming(
            introSeconds: settings.skipIntroSeconds,
            outroSeconds: settings.skipOutroSeconds,
          );
    void save({int? intro, int? outro}) {
      final value = SkipTiming(
        introSeconds: (intro ?? timing.introSeconds).clamp(0, 300),
        outroSeconds: (outro ?? timing.outroSeconds).clamp(0, 300),
      );
      widget.onChanged(
        individual
            ? settings.withSubjectSkip(key, value)
            : settings.copyWith(
                skipIntroSeconds: value.introSeconds,
                skipOutroSeconds: value.outroSeconds,
              ),
      );
    }

    String formatSeconds(int seconds) {
      if (seconds <= 0) return '不跳过';
      final mins = seconds ~/ 60;
      final secs = seconds % 60;
      return mins > 0
          ? '$mins:${secs.toString().padLeft(2, '0')} ($seconds 秒)'
          : '$seconds 秒';
    }

    Widget step(String label, int seconds, ValueChanged<int> change) {
      final colors = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        formatSeconds(seconds),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: seconds > 0
                              ? colors.primary
                              : colors.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: '$label减 5 秒',
                  onPressed: seconds > 0 ? () => change(seconds - 5) : null,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.remove_rounded),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: '$label加 5 秒',
                  onPressed: seconds < 300 ? () => change(seconds + 5) : null,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Duration position() =>
        widget.readPosition?.call() ?? widget.currentPosition!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (key != null)
          SettingsSwitchRow(
            title: '当前番剧单独设置',
            subtitle: individual ? '只影响这部番剧' : '使用全局默认，以下调整对所有番剧生效',
            value: individual,
            onChanged: (enabled) {
              setState(() => editingOverride = enabled);
              widget.onChanged(
                settings.withSubjectSkip(key, enabled ? timing : null),
              );
            },
          ),
        step('片头', timing.introSeconds, (v) => save(intro: v)),
        step('片尾', timing.outroSeconds, (v) => save(outro: v)),
        if (key != null && widget.currentPosition != null) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => save(intro: position().inSeconds),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
                icon: const Icon(Icons.flag_outlined, size: 15),
                label: const Text('以当前进度设为片头'),
              ),
              OutlinedButton.icon(
                onPressed:
                    (widget.totalDuration ?? Duration.zero) > Duration.zero
                    ? () => save(
                        outro: (widget.totalDuration! - position()).inSeconds,
                      )
                    : null,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
                icon: const Icon(Icons.skip_next_rounded, size: 16),
                label: const Text('以剩余时长设为片尾'),
              ),
            ],
          ),
        ],
      ],
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(0, compact ? 4 : 14, 0, compact ? 12 : 20),
      child: Column(
        children: [
          Row(
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
                      style:
                          (compact
                                  ? Theme.of(context).textTheme.titleMedium
                                  : Theme.of(context).textTheme.headlineSmall)
                              ?.copyWith(
                                color: context.ink,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.inkMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (compact)
                IconButton(
                  key: const ValueKey('playback_settings_close'),
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: onBack,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: scheme.onSurface,
                  ),
                ),
            ],
          ),
          if (compact) ...[
            const SizedBox(height: 8),
            Divider(
              height: 1,
              thickness: 0.75,
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ],
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
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 16 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            child: Row(
              children: [
                Icon(icon, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
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
  // Route failures through playbackLineFailureLabel instead of surfacing
  // line.message directly. The raw message is resolver-internal text -- things
  // like "HLS 子清单已经失效。" or "DASH 清单没有可验证的初始化或媒体分片。" --
  // and this status row is user-facing.
  if (!line.available) return playbackLineFailureLabel(line);
  if ((line.url ?? '').trim().isEmpty) return playbackLineFailureLabel(line);
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
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: dark ? 0.55 : 0.78),
          width: 0.75,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '音量增强',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: settings.volumeBoost > 0
                        ? scheme.primary.withValues(alpha: 0.14)
                        : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      '+${(settings.volumeBoost * 100).round()}%',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: settings.volumeBoost > 0
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
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
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
              ),
              child: Slider(
                key: const ValueKey('volume_boost_slider'),
                value: settings.volumeBoost,
                min: 0,
                max: 1,
                onChanged: (value) =>
                    onChanged(settings.copyWith(volumeBoost: value)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Text(
                    '0%',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: context.inkFaint),
                  ),
                  const Spacer(),
                  Text(
                    '+50%',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: context.inkFaint),
                  ),
                  const Spacer(),
                  Text(
                    '+100%',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: context.inkFaint),
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
                          lines: ['这个页面暂时没有可调整的设置。'],
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
    final selfHosted = settings.playbackBackendSelfHosted;
    final endpointUri = Uri.tryParse(endpoint);
    final cleartext = endpointUri?.scheme.toLowerCase() == 'http';
    final backendAllowed =
        endpointUri != null &&
        endpointUri.hasAuthority &&
        (endpointUri.scheme.toLowerCase() == 'https' ||
            (selfHosted && cleartext && settings.allowInsecurePlaybackBackend));
    final endpointLabel = endpoint.isEmpty
        ? '未配置'
        : selfHosted
        ? cleartext
              ? '自托管 HTTP（不安全） · $endpoint'
              : '自托管 HTTPS · $endpoint'
        : '官方 HTTPS · $endpoint';
    return [
      const _InfoCard(
        title: '在线内容服务',
        lines: [
          '番剧、电视剧和电影的资料与播放地址由在线服务提供；服务不可用时会明确提示。',
          '官方服务只接受 HTTPS；自托管 HTTP 仅在高级模式主动授权后可用，且不会携带云账号凭据。',
        ],
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          SettingsSwitchRow(
            title: '使用在线服务',
            subtitle: endpoint.isEmpty ? '请先填写服务地址' : endpointLabel,
            value: settings.playbackBackendEnabled,
            onChanged: (value) {
              if (value && !backendAllowed) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      endpoint.isEmpty ? '请先填写服务地址' : '当前服务地址未通过安全检查',
                    ),
                  ),
                );
                return;
              }
              controller.updateServices(
                settings.copyWith(playbackBackendEnabled: value),
              );
            },
          ),
          SettingsSwitchRow(
            title: '使用自托管服务（高级）',
            subtitle: selfHosted
                ? '地址由你维护；HTTPS 仍是推荐方式'
                : '关闭时使用 Zeluna 官方 HTTPS 服务',
            value: selfHosted,
            onChanged: (value) {
              controller.updateServices(
                settings.copyWith(
                  playbackBackendSelfHosted: value,
                  playbackBackendEndpoint: value
                      ? ''
                      : defaultPlaybackBackendEndpoint,
                  playbackBackendEnabled: value
                      ? false
                      : settings.playbackBackendEnabled,
                  allowInsecurePlaybackBackend: false,
                ),
              );
            },
          ),
          if (selfHosted)
            SettingsSwitchRow(
              title: '允许不安全 HTTP',
              subtitle: settings.allowInsecurePlaybackBackend
                  ? '已允许；流量可能被读取或篡改，且不会发送账号凭据'
                  : '默认关闭，仅为无法配置 HTTPS 的自托管服务保留',
              value: settings.allowInsecurePlaybackBackend,
              onChanged: (value) async {
                if (value && !await _confirmInsecurePlaybackBackend(context)) {
                  return;
                }
                controller.updateServices(
                  settings.copyWith(
                    allowInsecurePlaybackBackend: value,
                    playbackBackendEnabled: value || !cleartext
                        ? settings.playbackBackendEnabled
                        : false,
                  ),
                );
              },
            ),
          SettingsActionRow(
            title: '服务地址',
            subtitle: endpointLabel,
            onTap: () =>
                _showPlaybackBackendEditor(context, settings, controller),
          ),
        ],
      ),
    ];
  }

  Future<bool> _confirmInsecurePlaybackBackend(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('允许不安全 HTTP？'),
            content: const Text(
              'HTTP 流量可能被同一网络中的其他人读取或篡改。此模式只用于你主动配置的自托管服务，Zeluna 不会向它发送你的云账号登录凭据。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('confirm_insecure_playback_backend'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('仍然允许'),
              ),
            ],
          ),
        ) ??
        false;
  }

  List<Widget> _danmakuSourceCards(
    ExternalServiceSettings settings,
    AnimeController controller,
    BuildContext context,
  ) {
    return [
      const _InfoCard(
        title: '弹幕源：Zeluna / 弹弹play开放弹幕网络 / Bilibili / 自建弹幕库',
        lines: [
          'Zeluna 用户弹幕默认接入：游客可读取，登录后可发送，也可删除自己发送的弹幕。',
          '弹弹play开放弹幕网络由 Zeluna 服务端安全接入，客户端无需填写或保存开放平台密钥。',
          '通过 B 站公开番剧搜索匹配到对应分集，再读取该集的公开弹幕。',
          '你也可以填自己的弹幕接口，作为补充来源。',
        ],
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          SettingsSwitchRow(
            title: '启用弹弹play开放弹幕网络',
            subtitle: '由 Zeluna 服务端安全接入，无需填写密钥',
            value: settings.dandanplayDanmakuEnabled,
            onChanged: (value) => controller.updateServices(
              settings.copyWith(dandanplayDanmakuEnabled: value),
            ),
          ),
          SettingsActionRow(
            title: '弹弹play开放弹幕网络',
            subtitle: '官方网站：www.dandanplay.com',
            icon: Icons.open_in_new,
            onTap: () => _openDandanplayWebsite(context),
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

  Future<void> _openDandanplayWebsite(BuildContext context) async {
    var launched = false;
    try {
      launched = await launchUrl(
        _dandanplayWebsiteUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (launched || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('没有找到可以打开官网的应用')));
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
                    final isCleartext = uri?.scheme.toLowerCase() == 'http';
                    final valid =
                        value.isEmpty ||
                        (uri != null &&
                            uri.hasAuthority &&
                            (uri.scheme == 'http' || uri.scheme == 'https') &&
                            uri.userInfo.isEmpty &&
                            uri.query.isEmpty &&
                            uri.fragment.isEmpty &&
                            (!isCleartext ||
                                (settings.playbackBackendSelfHosted &&
                                    settings.allowInsecurePlaybackBackend)));
                    if (!valid) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            isCleartext
                                ? '请先开启“自托管服务”和“允许不安全 HTTP”'
                                : '请输入有效的 HTTPS 地址',
                          ),
                        ),
                      );
                      return;
                    }
                    controller.updateServices(
                      settings.copyWith(
                        playbackBackendEndpoint: value,
                        playbackBackendSelfHosted:
                            settings.playbackBackendSelfHosted ||
                            value != defaultPlaybackBackendEndpoint,
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

String _superResolutionTierLabel(String value) {
  return Anime4KTier.fromSetting(value).label;
}

String _superResolutionTierDescription(String value) {
  return Anime4KTier.fromSetting(value).description;
}

String _superResolutionModeLabel(String value) {
  return Anime4KMode.fromSetting(value).label;
}

String _superResolutionModeDescription(String value) {
  return Anime4KMode.fromSetting(value).description;
}

String _superResolutionModeDetail(String value) {
  return Anime4KMode.fromSetting(value).detailedDescription;
}

/// Shader picker for the custom tier.
///
/// Expands in place inside the settings panel rather than opening a bottom
/// sheet: the sheet covered the video, and on the desktop panel a modal for a
/// checkbox list was heavier than the choice warrants. Ticking a shader applies
/// it immediately, so there is no confirm button to reach for.
class _Anime4KShaderPicker extends StatefulWidget {
  const _Anime4KShaderPicker({required this.selected, required this.onChanged});

  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_Anime4KShaderPicker> createState() => _Anime4KShaderPickerState();
}

class _Anime4KShaderPickerState extends State<_Anime4KShaderPicker> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final validCount = widget.selected
        .where(Anime4KShaderManager.availableShaderFileNames.contains)
        .length;
    return Column(
      children: [
        InkWell(
          key: const ValueKey('setting_choice_高级着色器'),
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => setState(() => _expanded = !_expanded),
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
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          validCount == 0 ? '尚未选择' : '已选择 $validCount 个',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
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
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: AppMotion.quick,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant,
                      size: 21,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: AppMotion.quick,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? _buildShaderList(context)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  void _toggle(String shader, bool enabled) {
    final chosen = widget.selected
        .where(Anime4KShaderManager.availableShaderFileNames.contains)
        .toSet();
    if (enabled) {
      chosen.add(shader);
    } else {
      chosen.remove(shader);
    }
    // Emit in catalog order so the chain stays in a valid shader sequence
    // regardless of the order the user ticked things.
    widget.onChanged(
      Anime4KShaderManager.availableShaderFileNames
          .where(chosen.contains)
          .toList(growable: false),
    );
  }

  Widget _buildShaderList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = widget.selected
        .where(Anime4KShaderManager.availableShaderFileNames.contains)
        .toSet();
    final categories = <String, List<String>>{};
    for (final shader in Anime4KShaderManager.availableShaderFileNames) {
      categories
          .putIfAbsent(
            Anime4KShaderManager.shaderCategory(shader),
            () => <String>[],
          )
          .add(shader);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (chosen.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 8, 0),
                  child: TextButton(
                    onPressed: () => widget.onChanged(const []),
                    child: const Text('清空'),
                  ),
                ),
              ),
            for (final category in categories.entries) ...[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  14,
                  category.key == categories.keys.first && chosen.isEmpty
                      ? 12
                      : 6,
                  14,
                  2,
                ),
                child: Text(
                  category.key,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final shader in category.value)
                CheckboxListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  controlAffinity: ListTileControlAffinity.trailing,
                  value: chosen.contains(shader),
                  title: Text(
                    Anime4KShaderManager.shaderLabel(shader),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  onChanged: (enabled) => _toggle(shader, enabled == true),
                ),
            ],
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

String _speedLabel(double value) {
  if (value == 1) return '1.0x';
  var text = value.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0$'), '');
  text = text.replaceFirst(RegExp(r'\.0$'), '');
  return '${text}x';
}
