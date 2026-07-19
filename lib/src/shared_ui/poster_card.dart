import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/anime_models.dart';
import 'app_design.dart';

class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.subject,
    required this.onTap,
    this.trailing,
    this.badge,
    this.landscape = false,
  });

  final AnimeSubject subject;
  final VoidCallback onTap;
  final Widget? trailing;
  final String? badge;
  final bool landscape;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion ? Duration.zero : AppMotion.standard;
    final status = widget.badge ?? widget.subject.status;

    return Semantics(
      button: true,
      label: '查看${widget.subject.title}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: AnimatedScale(
          scale: _hovered ? 1.012 : 1,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                color: _hovered
                    ? scheme.primary.withValues(alpha: 0.58)
                    : scheme.outlineVariant,
              ),
              boxShadow: _hovered ? AppShadows.elevated : AppShadows.panel,
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (widget.landscape)
                            BackdropArt(
                              bannerUrl: widget.subject.bannerUrl,
                              posterUrl: widget.subject.coverUrl,
                              title: widget.subject.title,
                            )
                          else
                            PosterArt(
                              coverUrl: widget.subject.coverUrl,
                              title: widget.subject.title,
                            ),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: AppGradients.mediaScrim,
                            ),
                          ),
                          if (status.trim().isNotEmpty)
                            Positioned(
                              right: AppSpacing.sm,
                              top: AppSpacing.sm,
                              child: _MediaPill(text: status),
                            ),
                          if (widget.subject.ratingScore != null)
                            Positioned(
                              left: AppSpacing.sm,
                              bottom: AppSpacing.sm,
                              child: _RatingBadge(
                                score: widget.subject.ratingScore!
                                    .toStringAsFixed(1),
                              ),
                            ),
                          if (_hovered)
                            const Positioned.fill(
                              child: Center(child: _HoverPlayButton()),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Text(
                                  widget.subject.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        color: scheme.onSurface,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                              ),
                              if (widget.trailing != null) ...[
                                const SizedBox(width: AppSpacing.xs),
                                widget.trailing!,
                              ],
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            widget.subject.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.25,
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
        ),
      ),
    );
  }
}

class PosterArt extends StatelessWidget {
  const PosterArt({
    super.key,
    required this.coverUrl,
    required this.title,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.allowHtmlFallback = true,
  });

  final String? coverUrl;
  final String title;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final bool allowHtmlFallback;

  @override
  Widget build(BuildContext context) {
    final fallbackColor = _fallbackColor(coverUrl, title);
    final url = coverUrl?.trim() ?? '';
    if (_isNetworkUrl(url)) {
      return Image.network(
        url,
        fit: fit,
        alignment: alignment,
        filterQuality: FilterQuality.medium,
        webHtmlElementStrategy: allowHtmlFallback
            ? WebHtmlElementStrategy.fallback
            : WebHtmlElementStrategy.never,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return PosterPlaceholder(
            color: fallbackColor,
            title: title,
            loading: true,
          );
        },
        errorBuilder: (context, error, stackTrace) =>
            PosterPlaceholder(color: fallbackColor, title: title),
      );
    }
    return PosterPlaceholder(color: fallbackColor, title: title);
  }
}

class BackdropArt extends StatelessWidget {
  const BackdropArt({
    super.key,
    required this.bannerUrl,
    required this.posterUrl,
    required this.title,
  });

  final String? bannerUrl;
  final String? posterUrl;
  final String title;

  @override
  Widget build(BuildContext context) {
    final banner = bannerUrl?.trim() ?? '';
    if (_isNetworkUrl(banner)) {
      return PosterArt(
        coverUrl: _backdropUrl(banner),
        title: title,
        allowHtmlFallback: false,
      );
    }
    final poster = posterUrl?.trim() ?? '';
    if (!_isNetworkUrl(poster)) {
      return PosterArt(coverUrl: null, title: title);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Transform.scale(
            scale: 1.16,
            child: PosterArt(
              coverUrl: _backdropUrl(poster),
              title: title,
              allowHtmlFallback: false,
            ),
          ),
        ),
        const ColoredBox(color: Color(0x70070A11)),
        Align(
          alignment: Alignment.centerRight,
          child: FractionallySizedBox(
            widthFactor: 0.40,
            heightFactor: 0.90,
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: PosterArt(
                coverUrl: _backdropUrl(poster),
                title: title,
                fit: BoxFit.contain,
                alignment: Alignment.centerRight,
                allowHtmlFallback: false,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class PosterPlaceholder extends StatelessWidget {
  const PosterPlaceholder({
    super.key,
    required this.color,
    required this.title,
    this.loading = false,
  });

  final Color color;
  final String title;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              color.withValues(alpha: 0.52),
              scheme.surfaceContainer,
            ),
            scheme.surfaceContainerLowest,
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shortest = constraints.biggest.shortestSide;
          if (!shortest.isFinite || shortest <= 10) {
            return const SizedBox.shrink();
          }
          if (loading) {
            final indicatorSize = (shortest * 0.24).clamp(12.0, 24.0);
            return Center(
              child: SizedBox.square(
                dimension: indicatorSize,
                child: CircularProgressIndicator(
                  strokeWidth: indicatorSize < 18 ? 1.6 : 2.2,
                ),
              ),
            );
          }

          final showTitle =
              constraints.maxHeight >= 82 && constraints.maxWidth >= 72;
          final iconSize = (shortest * 0.30).clamp(14.0, 28.0);
          if (!showTitle) {
            return Center(
              child: Icon(
                Icons.movie_filter_rounded,
                size: iconSize,
                color: Colors.white.withValues(alpha: 0.68),
              ),
            );
          }
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.movie_filter_rounded,
                    size: iconSize,
                    color: Colors.white.withValues(alpha: 0.78),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HoverPlayButton extends StatelessWidget {
  const _HoverPlayButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.94),
        shape: BoxShape.circle,
        border: Border.all(color: scheme.onPrimary.withValues(alpha: 0.30)),
        boxShadow: AppShadows.primaryGlow,
      ),
      child: SizedBox.square(
        dimension: 46,
        child: Icon(
          Icons.play_arrow_rounded,
          color: scheme.onPrimary,
          size: 28,
        ),
      ),
    );
  }
}

class _MediaPill extends StatelessWidget {
  const _MediaPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.score});

  final String score;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.overlay,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.borderBright),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 14, color: AppColors.warning),
            const SizedBox(width: AppSpacing.xxs),
            Text(
              score,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isNetworkUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

String _backdropUrl(String value) {
  if (!kIsWeb || !_isNetworkUrl(value)) return value;
  return Uri.base
      .resolve('/media-proxy?url=${Uri.encodeQueryComponent(value)}')
      .toString();
}

Color _fallbackColor(String? value, String title) {
  if (value != null && value.startsWith('demo:')) {
    final hex = value.substring(5);
    return Color(int.tryParse(hex, radix: 16) ?? 0xFF3A4561);
  }
  const palette = <Color>[
    Color(0xFF292929),
    Color(0xFF343434),
    Color(0xFF3E3E3E),
    Color(0xFF242424),
    Color(0xFF484848),
    Color(0xFF303030),
  ];
  final hash = title.runes.fold<int>(0, (sum, rune) => sum + rune);
  return palette[hash.abs() % palette.length];
}
