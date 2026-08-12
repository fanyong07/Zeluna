part of '../player_page.dart';

class _ResponsivePlayerLayout extends StatelessWidget {
  const _ResponsivePlayerLayout({
    required this.portrait,
    required this.player,
    required this.subject,
    required this.episodes,
    required this.episode,
    required this.line,
    required this.lines,
    required this.failedLineIds,
    required this.loadingLines,
    required this.onEpisodePanel,
    required this.onEpisodeSelected,
    required this.onLinePanel,
    required this.onLineSelected,
  });

  final bool portrait;
  final Widget player;
  final AnimeSubject subject;
  final List<AnimeEpisode> episodes;
  final AnimeEpisode episode;
  final PlaybackLine? line;
  final List<PlaybackLine> lines;
  final Set<String> failedLineIds;
  final bool loadingLines;
  final VoidCallback onEpisodePanel;
  final ValueChanged<AnimeEpisode> onEpisodeSelected;
  final VoidCallback onLinePanel;
  final ValueChanged<PlaybackLine> onLineSelected;

  @override
  Widget build(BuildContext context) {
    if (!portrait) return player;
    return ColoredBox(
      key: const ValueKey('portraitPlayerLayout'),
      color: AppColors.theaterBg,
      child: Column(
        children: [
          AspectRatio(
            key: const ValueKey('portraitPlayerVideo'),
            aspectRatio: 16 / 9,
            child: player,
          ),
          const Divider(height: 1, color: AppColors.theaterBorder),
          Expanded(
            child: _PortraitPlayerDetails(
              subject: subject,
              episodes: episodes,
              episode: episode,
              line: line,
              lines: lines,
              failedLineIds: failedLineIds,
              loadingLines: loadingLines,
              onEpisodePanel: onEpisodePanel,
              onEpisodeSelected: onEpisodeSelected,
              onLinePanel: onLinePanel,
              onLineSelected: onLineSelected,
            ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
bool usesMobilePlayerLayoutForSize(Size size, TargetPlatform platform) {
  final mobilePlatform =
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  // A portrait Android/iOS player is still a mobile surface on large-density
  // emulators and tablets.  Using only shortestSide here made MuMu portrait
  // windows fall through to the desktop chrome and cover the video with
  // every desktop control.
  if (mobilePlatform && size.height > size.width) return true;
  return size.width < 640 || (mobilePlatform && size.shortestSide < 600);
}

@visibleForTesting
bool usesCompactPlayerBottomControlsForSize(
  Size size,
  TargetPlatform platform,
) {
  return size.height > size.width &&
      usesMobilePlayerLayoutForSize(size, platform);
}

@visibleForTesting
bool usesPortraitPlayerPageLayoutForSize(
  Size size,
  TargetPlatform platform, {
  required bool fullscreen,
}) {
  return !fullscreen &&
      size.height > size.width &&
      usesMobilePlayerLayoutForSize(size, platform);
}

bool _isMobilePlayerLayout(BuildContext context) =>
    usesMobilePlayerLayoutForSize(
      MediaQuery.sizeOf(context),
      defaultTargetPlatform,
    );

@visibleForTesting
SafeArea buildPlayerSafeArea({
  required bool fullscreen,
  required Widget child,
}) {
  return SafeArea(
    left: !fullscreen,
    top: !fullscreen,
    right: !fullscreen,
    bottom: !fullscreen,
    child: child,
  );
}
