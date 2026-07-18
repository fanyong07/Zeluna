import 'package:flutter/widgets.dart';

bool get supportsWebStreamPlayer => false;

bool shouldUseWebStreamPlayer(String url) => false;

class WebStreamPlayerController {
  void play() {}

  void pause() {}

  void seek(Duration position) {}
}

class WebStreamPlayer extends StatelessWidget {
  const WebStreamPlayer({
    super.key,
    required this.url,
    required this.playing,
    required this.volume,
    required this.position,
    this.rate = 1,
    this.headers = const {},
    this.controller,
    this.forceHls = false,
    this.onReady,
    this.onError,
    this.onPosition,
    this.onDuration,
    this.onPlaying,
  });

  final String url;
  final bool playing;
  final double volume;
  final Duration position;
  final double rate;
  final Map<String, String> headers;
  final WebStreamPlayerController? controller;
  final bool forceHls;
  final VoidCallback? onReady;
  final VoidCallback? onError;
  final ValueChanged<Duration>? onPosition;
  final ValueChanged<Duration>? onDuration;
  final ValueChanged<bool>? onPlaying;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
