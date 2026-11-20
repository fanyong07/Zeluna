/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'package:meta/meta.dart';

import 'package:media_kit/src/player/platform_player.dart';

void nativeEnsureInitialized({String? libmpv}) {}

class NativePlayer extends PlatformPlayer {
  NativePlayer({required super.configuration});

  /// Local native-only decoded-frame probe; web has no native frame to inspect.
  Future<bool> hasDecodedVideoFrame({bool synchronized = true}) async => false;

  /// Whether the [NativePlayer] is initialized for unit-testing.
  @visibleForTesting
  static bool test = false;
}
