import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Loads the heavy emphasis/display fonts after the first frame.
///
/// Mobile platforms (Android/iOS) rely on system CJK fonts to avoid loading
/// ~8.2 MB of extra TTF faces right after cold start (which spikes memory and
/// stalls the UI thread on mid/low-end phones).
Future<void> loadDeferredFonts() {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    return Future<void>.value();
  }

  Future<void> load(String family, String asset) async {
    try {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    } catch (_) {
      // The fallback chains in AppTypography keep text legible if a deferred
      // font fails to arrive (offline PWA cold cache, disk trouble).
    }
  }

  return Future.wait([
    load('NotoSansSC', 'assets/fonts/NotoSansSC-600.ttf'),
    load('NotoSerifSC', 'assets/fonts/NotoSerifSC-SemiBold.ttf'),
  ]).then((_) {});
}
