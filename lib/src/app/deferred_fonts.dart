import 'dart:async';

import 'package:flutter/services.dart';

/// Loads the heavy emphasis/display fonts after the first frame.
///
/// Only NotoSansSC w400 stays in the FontManifest, so it is the single font
/// the web engine blocks startup on. The SemiBold sans and the serif display
/// family arrive here; FontLoader emits a system-fonts change, so visible
/// text reflows to the richer faces automatically once each file lands.
Future<void> loadDeferredFonts() {
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
