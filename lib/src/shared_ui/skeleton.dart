import 'package:flutter/material.dart';

import 'app_design.dart';

/// Breathing placeholder scaffolding shown while real content loads. Blocks
/// mirror the final layout so the page keeps its shape instead of jumping
/// from a centered spinner to a full grid.
class SkeletonPulse extends StatefulWidget {
  const SkeletonPulse({super.key, required this.child});

  final Widget child;

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      return Opacity(opacity: 0.72, child: widget.child);
    }
    if (!_controller.isAnimating) _controller.repeat(reverse: true);
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.5,
        end: 0.95,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = AppRadius.sm,
  });

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// Poster wall placeholder matching the live grid metrics.
class PosterGridSkeleton extends StatelessWidget {
  const PosterGridSkeleton({
    super.key,
    this.count = 12,
    this.padding = const EdgeInsets.fromLTRB(24, 12, 8, 24),
  });

  final int count;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.compact;
    return SkeletonPulse(
      child: GridView.builder(
        padding: padding,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: compact ? 232 : 188,
          mainAxisSpacing: compact ? 10 : 12,
          crossAxisSpacing: compact ? 10 : 12,
          childAspectRatio: compact ? 0.58 : 0.56,
        ),
        itemCount: count,
        itemBuilder: (context, index) => const _PosterCellSkeleton(),
      ),
    );
  }
}

class _PosterCellSkeleton extends StatelessWidget {
  const _PosterCellSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: SkeletonBox(width: double.infinity, radius: AppRadius.md),
        ),
        const SizedBox(height: 10),
        const SkeletonBox(width: 96, height: 13),
        const SizedBox(height: 6),
        const SkeletonBox(width: 64, height: 11),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Search results placeholder: scope chips strip plus a poster wall.
class SearchPageSkeleton extends StatelessWidget {
  const SearchPageSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 8, 4),
          child: SkeletonPulse(
            child: Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  const SkeletonBox(width: 64, height: 30, radius: 999),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        const Expanded(child: PosterGridSkeleton(count: 10)),
      ],
    );
  }
}

/// Detail tab body placeholder: rows of episode chips.
class DetailTabsSkeleton extends StatelessWidget {
  const DetailTabsSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(0, 16, 8, 24),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.7,
        ),
        itemCount: 12,
        itemBuilder: (context, index) =>
            const SkeletonBox(radius: AppRadius.md),
      ),
    );
  }
}
