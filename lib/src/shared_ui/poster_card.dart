import 'package:flutter/material.dart';

import '../domain/anime_models.dart';

class PosterCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF101522),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF20283C)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PosterArt(
                      coverUrl: landscape
                          ? subject.bannerUrl ?? subject.coverUrl
                          : subject.coverUrl,
                      title: subject.title,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x22000000),
                            Color(0x22060912),
                            Color(0xDD060912),
                          ],
                        ),
                      ),
                    ),
                    if ((badge ?? subject.status).isNotEmpty)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: _Pill(text: badge ?? subject.status),
                      ),
                    if (subject.ratingScore != null)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: _RatingBadge(
                          score: subject.ratingScore!.toStringAsFixed(1),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            subject.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: const Color(0xFFE9ECF8),
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                        ?trailing,
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subject.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF9DA7C2),
                        height: 1.1,
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

class PosterArt extends StatelessWidget {
  const PosterArt({super.key, required this.coverUrl, required this.title});

  final String? coverUrl;
  final String title;

  @override
  Widget build(BuildContext context) {
    final demoColor = _demoColor(coverUrl);
    if (coverUrl != null && coverUrl!.startsWith('http')) {
      return Image.network(
        coverUrl!,
        fit: BoxFit.cover,
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _FallbackPoster(
            color: demoColor,
            title: title,
            showTitle: false,
          );
        },
        errorBuilder: (context, error, stackTrace) =>
            _FallbackPoster(color: demoColor, title: title),
      );
    }
    return _FallbackPoster(color: demoColor, title: title);
  }

  Color _demoColor(String? value) {
    if (value != null && value.startsWith('demo:')) {
      final hex = value.substring(5);
      return Color(int.tryParse(hex, radix: 16) ?? 0xFF30374D);
    }
    return const Color(0xFF30374D);
  }
}

class _FallbackPoster extends StatelessWidget {
  const _FallbackPoster({
    required this.color,
    required this.title,
    this.showTitle = true,
  });

  final Color color;
  final String title;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final base = const Color(0xFF101522);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: base,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(color.withValues(alpha: 0.45), base),
            const Color(0xFF060912),
          ],
        ),
      ),
      child: Center(
        child: showTitle
            ? Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
              )
            : const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
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
        color: const Color(0xE8101522),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFF334064)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 13, color: Color(0xFFFFB35C)),
            const SizedBox(width: 2),
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
