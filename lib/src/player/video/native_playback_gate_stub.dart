import 'package:media_kit/media_kit.dart';

Future<void> playNativeIfCurrent(
  Player player, {
  required bool Function() isCurrent,
}) async {
  if (isCurrent()) await player.play();
}
