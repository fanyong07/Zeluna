import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app/anime_app.dart';
import 'src/app/deferred_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Hive.initFlutter('anime');
  runApp(const ProviderScope(child: AnimeApp()));
  // Kicks off after runApp so first paint never waits on the ~8MB of
  // emphasis fonts; FontLoader reflows text when each family lands.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(loadDeferredFonts());
  });
}
