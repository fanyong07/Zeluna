import 'package:media_kit/media_kit.dart';

/// Rechecks playback ownership after acquiring media-kit's native command lock.
Future<void> playNativeIfCurrent(
  Player player, {
  required bool Function() isCurrent,
}) async {
  final platform = player.platform;
  if (platform is! NativePlayer) {
    if (isCurrent()) await player.play();
    return;
  }
  await NativePlayer.lock.synchronized(() async {
    // Resolve initialization before granting play, not while permission is stale.
    await platform.waitForPlayerInitialization;
    await platform.waitForVideoControllerInitializationIfAttached;
    if (!isCurrent()) return;
    // We already own the non-reentrant native lock.
    await platform.play(synchronized: false);
  });
}
