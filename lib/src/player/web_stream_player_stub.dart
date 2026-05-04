import 'package:flutter/widgets.dart';

bool get supportsWebStreamPlayer => false;

bool shouldUseWebStreamPlayer(String url) => false;

class WebStreamPlayer extends StatelessWidget {
  const WebStreamPlayer({
    super.key,
    required this.url,
    this.forceHls = false,
    this.onReady,
    this.onError,
    this.onPosition,
  });

  final String url;
  final bool forceHls;
  final VoidCallback? onReady;
  final VoidCallback? onError;
  final ValueChanged<Duration>? onPosition;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
