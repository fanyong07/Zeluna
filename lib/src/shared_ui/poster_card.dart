import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/anime_models.dart';
import 'app_design.dart';

/// Whether a subject's rating deserves pixels. Backend fallbacks emit a
/// uniform 10.0 with no vote count; those placeholders stay hidden.
bool shouldShowPosterRating({double? score, int? ratingTotal}) {
  if (score == null || score <= 0 || score > 10) return false;
  if (score >= 10 && (ratingTotal == null || ratingTotal <= 0)) return false;
  return true;
}

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
                            _PosterCardBackdropArt(
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
                          Row(
                            children: [
                              if (shouldShowPosterRating(
                                score: widget.subject.ratingScore,
                                ratingTotal: widget.subject.ratingTotal,
                              )) ...[
                                Text(
                                  '★ ${widget.subject.ratingScore!.toStringAsFixed(1)}',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: context.isDarkMode
                                            ? AppColors.primary2
                                            : AppColors.accentDeep,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0,
                                      ),
                                ),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                              Expanded(
                                child: Text(
                                  widget.subject.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        height: 1.25,
                                      ),
                                ),
                              ),
                            ],
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
    this.fallbackCoverUrl,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.allowHtmlFallback = true,
  });

  final String? coverUrl;
  final String? fallbackCoverUrl;
  final String title;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final bool allowHtmlFallback;

  @override
  Widget build(BuildContext context) {
    final fallbackColor = _fallbackColor(coverUrl, title);
    final primaryUrl = coverUrl?.trim() ?? '';
    final secondaryUrl = fallbackCoverUrl?.trim() ?? '';
    final url = _isNetworkUrl(primaryUrl) ? primaryUrl : secondaryUrl;
    if (_isNetworkUrl(url)) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          final cacheWidth = _decodeDimension(
            constraints.hasBoundedWidth ? constraints.maxWidth : null,
            pixelRatio,
          );
          final cacheHeight = _decodeDimension(
            constraints.hasBoundedHeight ? constraints.maxHeight : null,
            pixelRatio,
          );
          final candidates = posterImageCandidates(
            url,
            targetPixelWidth: cacheWidth,
            webProxyBase: kIsWeb ? Uri.base : null,
            fallbackValues:
                _isNetworkUrl(primaryUrl) &&
                    _isNetworkUrl(secondaryUrl) &&
                    primaryUrl != secondaryUrl
                ? [secondaryUrl]
                : const [],
          );
          return _RetryingNetworkImage(
            urls: candidates,
            fit: fit,
            alignment: alignment,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            allowHtmlFallback: allowHtmlFallback,
            fallbackColor: fallbackColor,
            title: title,
          );
        },
      );
    }
    return PosterPlaceholder(color: fallbackColor, title: title);
  }
}

class _PosterCardBackdropArt extends StatelessWidget {
  const _PosterCardBackdropArt({
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
    final poster = posterUrl?.trim() ?? '';
    return PosterArt(
      coverUrl: _isNetworkUrl(banner) ? banner : null,
      fallbackCoverUrl: _isNetworkUrl(poster) ? poster : null,
      title: title,
      allowHtmlFallback: false,
    );
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
        coverUrl: banner,
        fallbackCoverUrl: _isNetworkUrl(posterUrl?.trim() ?? '')
            ? posterUrl!.trim()
            : null,
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
              coverUrl: poster,
              title: title,
              allowHtmlFallback: false,
            ),
          ),
        ),
        const ColoredBox(color: Color(0x701B1A18)),
        Center(
          child: FractionallySizedBox(
            widthFactor: 0.72,
            heightFactor: 0.86,
            child: PosterArt(
              coverUrl: poster,
              title: title,
              fit: BoxFit.contain,
              allowHtmlFallback: false,
            ),
          ),
        ),
      ],
    );
  }
}

class _RetryingNetworkImage extends StatefulWidget {
  const _RetryingNetworkImage({
    required this.urls,
    required this.fit,
    required this.alignment,
    required this.cacheWidth,
    required this.cacheHeight,
    required this.allowHtmlFallback,
    required this.fallbackColor,
    required this.title,
  });

  final List<String> urls;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool allowHtmlFallback;
  final Color fallbackColor;
  final String title;

  @override
  State<_RetryingNetworkImage> createState() => _RetryingNetworkImageState();
}

class _RetryingNetworkImageState extends State<_RetryingNetworkImage> {
  var _index = 0;
  var _advanceScheduled = false;

  @override
  void didUpdateWidget(covariant _RetryingNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.urls, widget.urls)) {
      _index = 0;
      _advanceScheduled = false;
    }
  }

  void _tryNext(String failedUrl) {
    if (_advanceScheduled || _index >= widget.urls.length - 1) return;
    _advanceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentUrl = widget.urls[_index];
      setState(() {
        if (currentUrl == failedUrl && _index < widget.urls.length - 1) {
          _index++;
        }
        _advanceScheduled = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) {
      return PosterPlaceholder(
        color: widget.fallbackColor,
        title: widget.title,
      );
    }
    final safeIndex = _index.clamp(0, widget.urls.length - 1);
    final url = widget.urls[safeIndex];
    final hasFallback = safeIndex < widget.urls.length - 1;
    return Image.network(
      url,
      key: ValueKey(url),
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: FilterQuality.low,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      webHtmlElementStrategy: widget.allowHtmlFallback
          ? WebHtmlElementStrategy.fallback
          : WebHtmlElementStrategy.never,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        if (frame == null) {
          return PosterPlaceholder(
            color: widget.fallbackColor,
            title: widget.title,
            loading: true,
          );
        }
        if (MediaQuery.disableAnimationsOf(context)) return child;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: AppMotion.standard,
          curve: Curves.easeOut,
          child: child,
          builder: (context, opacity, child) =>
              Opacity(opacity: opacity, child: child),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        if (hasFallback) _tryNext(url);
        return PosterPlaceholder(
          color: widget.fallbackColor,
          title: widget.title,
          loading: hasFallback,
        );
      },
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
            return Center(
              child: Icon(
                Icons.image_outlined,
                size: (shortest * 0.28).clamp(14.0, 26.0),
                color: Colors.white.withValues(alpha: 0.62),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.76),
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
    );
  }
}

bool _isNetworkUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

int? _decodeDimension(double? logicalPixels, double pixelRatio) {
  if (logicalPixels == null ||
      !logicalPixels.isFinite ||
      logicalPixels <= 0 ||
      !pixelRatio.isFinite ||
      pixelRatio <= 0) {
    return null;
  }
  return (logicalPixels * pixelRatio).ceil().clamp(1, 2048);
}

@visibleForTesting
List<String> posterImageCandidates(
  String value, {
  int? targetPixelWidth,
  Uri? webProxyBase,
  Iterable<String> fallbackValues = const [],
}) {
  final source = value.trim();
  if (!_isNetworkUrl(source)) return const [];
  final upstream = <String>{};
  for (final rawValue in [source, ...fallbackValues]) {
    final candidate = rawValue.trim();
    if (!_isNetworkUrl(candidate)) continue;
    upstream.addAll(_sizedPosterCandidates(candidate, targetPixelWidth));
  }
  final upstreamList = upstream.toList(growable: false);
  if (webProxyBase == null) return upstreamList;

  final candidates = <String>{};
  for (final url in upstreamList) {
    candidates.add(_imageProxyUrl(url, webProxyBase));
  }
  for (final url in upstreamList) {
    candidates.add(url);
  }
  return candidates.toList(growable: false);
}

List<String> _sizedPosterCandidates(String value, int? targetPixelWidth) {
  final uri = Uri.tryParse(value);
  if (uri == null) return [value];
  final candidates = <String>{};
  final host = uri.host.toLowerCase();
  final width = targetPixelWidth ?? 400;

  if (host == 'lain.bgm.tv') {
    final coverAt = uri.path.indexOf('/pic/cover/');
    if (coverAt >= 0) {
      final coverPath = uri.path.substring(coverAt);
      final size = switch (width) {
        <= 200 => 200,
        <= 400 => 400,
        <= 600 => 600,
        _ => 800,
      };
      candidates.add(uri.replace(path: '/r/$size$coverPath').toString());
      if (size != 400) {
        candidates.add(uri.replace(path: '/r/400$coverPath').toString());
      }
    }
  } else if (host.endsWith('.anilist.co') || host == 'anilist.co') {
    final coverSize = RegExp(r'/cover/(?:medium|large)/');
    if (coverSize.hasMatch(uri.path)) {
      final preferred = width <= 360 ? 'medium' : 'large';
      final alternate = preferred == 'medium' ? 'large' : 'medium';
      candidates.add(
        uri
            .replace(
              path: uri.path.replaceFirst(coverSize, '/cover/$preferred/'),
            )
            .toString(),
      );
      candidates.add(
        uri
            .replace(
              path: uri.path.replaceFirst(coverSize, '/cover/$alternate/'),
            )
            .toString(),
      );
    }
  } else if (host == 'static.tvmaze.com') {
    final imageSize = RegExp(
      r'/uploads/images/(?:medium_portrait|original_untouched)/',
    );
    if (imageSize.hasMatch(uri.path)) {
      final preferred = width <= 420 ? 'medium_portrait' : 'original_untouched';
      final alternate = preferred == 'medium_portrait'
          ? 'original_untouched'
          : 'medium_portrait';
      candidates.add(
        uri
            .replace(
              path: uri.path.replaceFirst(
                imageSize,
                '/uploads/images/$preferred/',
              ),
            )
            .toString(),
      );
      candidates.add(
        uri
            .replace(
              path: uri.path.replaceFirst(
                imageSize,
                '/uploads/images/$alternate/',
              ),
            )
            .toString(),
      );
    }
  }

  candidates.add(value);
  return candidates.toList(growable: false);
}

String _imageProxyUrl(String value, Uri baseUri) {
  return baseUri
      .resolve('/image-proxy')
      .replace(queryParameters: {'url': value})
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
