import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'supplemental_subtitle_controller.dart';

TextStyle _captionStyle(double size) => TextStyle(
  color: Colors.white,
  fontSize: size,
  height: 1.3,
  fontWeight: FontWeight.w600,
  fontFamily: 'NotoSansSC',
  fontFamilyFallback: const ['Noto Sans CJK JP', 'Yu Gothic UI', 'sans-serif'],
  shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
);

/// Same reserved strip is used by captions and both danmaku renderers.
Rect supplementalSubtitleBounds(
  Size size,
  SupplementalSubtitleController controller,
  TextScaler scaler, {
  bool controlsVisible = false,
  String text = '',
}) {
  final width = math.max(0.0, size.width - 32);
  final painter = TextPainter(
    text: TextSpan(
      text: text.isEmpty ? '字幕\n字幕' : text,
      style: _captionStyle(controller.fontSize),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    textScaler: scaler,
    maxLines: 6,
  )..layout(maxWidth: math.max(0.0, width - 16));
  final height = math.min(painter.height + 12, size.height * .55);
  painter.dispose();
  final inset = math.max(
    size.height * controller.verticalInset,
    controlsVisible ? (controller.top ? 60.0 : 100.0) : 12.0,
  );
  final top = (controller.top ? inset : size.height - inset - height).clamp(
    0.0,
    math.max(0.0, size.height - height),
  );
  return Rect.fromLTWH(16, top.toDouble(), width, height);
}

class SupplementalSubtitleOverlay extends StatelessWidget {
  const SupplementalSubtitleOverlay({
    super.key,
    required this.controller,
    required this.position,
    this.controlsVisible = false,
  });
  final SupplementalSubtitleController controller;
  final Duration position;
  final bool controlsVisible;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final text = controller.textAt(position);
      if (text.isEmpty) return const SizedBox.shrink();
      return IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bounds = supplementalSubtitleBounds(
              constraints.biggest,
              controller,
              MediaQuery.textScalerOf(context),
              controlsVisible: controlsVisible,
              text: text,
            );
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: bounds,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xB8000000),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        text,
                        key: const ValueKey('supplementalSubtitleText'),
                        textAlign: TextAlign.center,
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: _captionStyle(controller.fontSize),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );
}
