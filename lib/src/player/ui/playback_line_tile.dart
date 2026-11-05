import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/anime_models.dart';
import '../playback_line_display.dart';

/// Semantic metric colors deliberately stay independent of the selected route.
/// The darker light-theme shades also remain readable on a white surface.
abstract final class PlaybackLineTileColors {
  static Color latency(PlaybackLineLatencyBand band, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (band) {
      PlaybackLineLatencyBand.fast =>
        dark ? const Color(0xFF70DB91) : const Color(0xFF176B32),
      PlaybackLineLatencyBand.moderate =>
        dark ? const Color(0xFFE6C86E) : const Color(0xFF7A5900),
      PlaybackLineLatencyBand.slow =>
        dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E),
      PlaybackLineLatencyBand.unknown => unknown(brightness),
    };
  }

  static Color size(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF7EB6FF)
      : const Color(0xFF1558A6);

  static Color resolution(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFFC5A0FF)
      : const Color(0xFF713F9C);

  static Color unknown(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFFA6A6A6)
      : const Color(0xFF626262);
}

/// Shared flat route row for detail pages and both player layouts.
///
/// [onTap] is the route-selection action. URL inspection/copy and local query
/// have their own gesture targets and never invoke it. [index] is zero-based.
class PlaybackLineTile extends StatelessWidget {
  const PlaybackLineTile({
    super.key,
    required this.line,
    this.selected = false,
    this.runtimeFailed = false,
    this.onTap,
    this.index,
    this.compact = false,
    this.onQueryLocally,
    this.showLocalQuery = false,
  });

  final PlaybackLine line;
  final bool selected;
  final bool runtimeFailed;
  final VoidCallback? onTap;
  final int? index;
  final bool compact;
  final VoidCallback? onQueryLocally;
  final bool showLocalQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final muted = PlaybackLineTileColors.unknown(brightness);
    final accent = theme.colorScheme.primary;
    final provider = playbackLineProviderLabel(line);
    final title = playbackLineTitleLabel(line);
    final url = playbackLineMediaUrl(line);
    final pendingResolver =
        line.clientResolver != null ||
        line.diagnosticStatus == PlaybackDiscoveryStatus.clientResolverRequired;
    // Do not let a pending chapter task masquerade as a playable media route.
    final routeTap = pendingResolver ? null : onTap;
    final failed =
        runtimeFailed ||
        (!line.available &&
            !line.requiresClientProbe &&
            !pendingResolver &&
            line.diagnosticStatus != PlaybackDiscoveryStatus.searching &&
            line.diagnosticStatus != PlaybackDiscoveryStatus.matched);
    final status = runtimeFailed
        ? '播放失败 · 可重试'
        : !line.available
        ? playbackLineFailureLabel(line)
        : null;
    final textStyle =
        theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12);
    final metricStyle = textStyle.copyWith(fontWeight: FontWeight.w700);
    final showTitle =
        title.isNotEmpty &&
        title != provider &&
        title != line.url?.trim() &&
        !RegExp(r'^(?:聚合)?线路\s*\d*$').hasMatch(title);

    return Material(
      key: ValueKey('line-surface-${line.id}'),
      color: selected
          ? accent.withValues(
              alpha: brightness == Brightness.dark ? 0.13 : 0.08,
            )
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: selected
            ? BorderSide(color: accent.withValues(alpha: 0.55))
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('route-tap-${line.id}'),
        onTap: routeTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 8 : 11,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (index != null)
                    Text(
                      '${index! + 1}',
                      key: ValueKey('line-index-${line.id}'),
                      style: textStyle.copyWith(color: muted),
                      semanticsLabel: '第 ${index! + 1} 条线路',
                    ),
                  Text(
                    provider,
                    key: ValueKey('line-name-${line.id}'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (selected)
                    Text(
                      '当前',
                      key: ValueKey('line-selected-${line.id}'),
                      style: textStyle.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                ],
              ),
              if (showTitle)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    title,
                    key: ValueKey('line-title-${line.id}'),
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle.copyWith(color: muted),
                  ),
                ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 12,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    playbackLineLatencyLabel(line),
                    key: ValueKey('line-latency-${line.id}'),
                    semanticsLabel: '延迟：${playbackLineLatencyLabel(line)}',
                    style: metricStyle.copyWith(
                      color: PlaybackLineTileColors.latency(
                        playbackLineLatencyBand(line),
                        brightness,
                      ),
                    ),
                  ),
                  Text(
                    playbackLineSizeLabel(line),
                    key: ValueKey('line-size-${line.id}'),
                    semanticsLabel: '视频大小：${playbackLineSizeLabel(line)}',
                    style: metricStyle.copyWith(
                      color: playbackLineHasKnownSize(line)
                          ? PlaybackLineTileColors.size(brightness)
                          : muted,
                    ),
                  ),
                  Text(
                    playbackLineResolutionLabel(line),
                    key: ValueKey('line-resolution-${line.id}'),
                    semanticsLabel: '分辨率：${playbackLineResolutionLabel(line)}',
                    style: metricStyle.copyWith(
                      color: playbackLineHasKnownResolution(line)
                          ? PlaybackLineTileColors.resolution(brightness)
                          : muted,
                    ),
                  ),
                  Text(
                    playbackLineFormatLabel(line),
                    key: ValueKey('line-format-${line.id}'),
                    style: textStyle.copyWith(color: muted),
                  ),
                ],
              ),
              if (status != null && status != playbackLineLatencyLabel(line))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    status,
                    key: ValueKey('line-status-${line.id}'),
                    style: textStyle.copyWith(
                      color: failed
                          ? PlaybackLineTileColors.latency(
                              PlaybackLineLatencyBand.slow,
                              brightness,
                            )
                          : muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (url == null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    playbackSourceStateExplanation(line),
                    key: ValueKey('line-explanation-${line.id}'),
                    style: textStyle.copyWith(color: muted),
                  ),
                )
              else ...[
                const SizedBox(height: 4),
                Text(
                  url,
                  key: ValueKey('line-url-${line.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle.copyWith(color: muted),
                  semanticsLabel: '视频 URL：$url',
                ),
                Wrap(
                  spacing: 4,
                  runSpacing: 0,
                  children: [
                    TextButton.icon(
                      key: ValueKey('view-line-url-${line.id}'),
                      onPressed: () => _showUrl(context, url),
                      style: _urlButtonStyle(muted),
                      icon: const Icon(Icons.link_rounded, size: 16),
                      label: const Text('完整 URL'),
                    ),
                    TextButton.icon(
                      key: ValueKey('copy-line-url-${line.id}'),
                      onPressed: () => _copyUrl(context, url),
                      style: _urlButtonStyle(muted),
                      icon: const Icon(Icons.copy_rounded, size: 15),
                      label: const Text('复制 URL'),
                    ),
                  ],
                ),
              ],
              if (line.queryLocation.isNotEmpty && line.queried == true)
                Text(
                  line.queryLocation == 'local'
                      ? '搜索与解析：本机网络'
                      : line.queryLocation == 'hybrid'
                      ? '搜索：VPS · 媒体解析：本机网络'
                      : '搜索与解析：VPS',
                  key: ValueKey('line-query-location-${line.id}'),
                  style: textStyle.copyWith(color: muted),
                ),
              if (showLocalQuery)
                TextButton.icon(
                  key: ValueKey('local-query-${line.id}'),
                  onPressed: onQueryLocally,
                  icon: const Icon(Icons.devices_rounded, size: 16),
                  label: const Text('本机重查（本集）'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  ButtonStyle _urlButtonStyle(Color color) => TextButton.styleFrom(
    foregroundColor: color,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    minimumSize: const Size(48, 40),
    tapTargetSize: MaterialTapTargetSize.padded,
    textStyle: const TextStyle(fontSize: 12),
  );

  Future<void> _copyUrl(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('已复制完整 URL')));
  }

  void _showUrl(BuildContext context, String url) {
    final muted = PlaybackLineTileColors.unknown(Theme.of(context).brightness);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: ValueKey('line-url-dialog-${line.id}'),
        title: const Text('完整视频 URL'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              url,
              key: ValueKey('line-full-url-${line.id}'),
              style: TextStyle(color: muted, fontSize: 13),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            key: ValueKey('copy-full-line-url-${line.id}'),
            onPressed: () => _copyUrl(context, url),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('复制 URL'),
          ),
          TextButton(
            key: ValueKey('close-line-url-${line.id}'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
