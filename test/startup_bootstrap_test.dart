import 'dart:async';
import 'dart:io';

import 'package:anime/main.dart';
import 'package:anime/src/app/anime_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('branded splash paints while runtime initialization is pending', (
    tester,
  ) async {
    final initialization = Completer<void>();

    await tester.pumpWidget(
      ZelunaBootstrap(initializeRuntime: () => initialization.future),
    );
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(AnimeApp), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('zeluna-startup-image')),
      findsOneWidget,
    );
  });

  test('Android launcher paints native artwork before warming Flutter', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final splashActivity = File(
      'android/app/src/main/kotlin/app/anime/anime/SplashActivity.kt',
    ).readAsStringSync();

    final splashIndex = manifest.indexOf('android:name=".SplashActivity"');
    final mainIndex = manifest.indexOf('android:name=".MainActivity"');
    final launcherIndex = manifest.indexOf('android.intent.category.LAUNCHER');
    expect(splashIndex, greaterThanOrEqualTo(0));
    expect(launcherIndex, greaterThan(splashIndex));
    expect(launcherIndex, lessThan(mainIndex));
    expect(
      splashActivity,
      allOf(
        contains('setContentView(splashView)'),
        contains('ImageView.ScaleType.CENTER_CROP'),
        contains('splashView.post { startFlutterEngine() }'),
        contains('postDelayed(runnable, nativeSplashDurationMillis)'),
        contains('CachedEngineIntentBuilder'),
      ),
    );
  });
}
