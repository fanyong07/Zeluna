import 'dart:async';
import 'dart:io';

import 'package:anime/main.dart';
import 'package:anime/src/app/anime_app.dart';
import 'package:anime/src/data/anime_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _bootstrap(Future<void> Function() initialize) => ProviderScope(
  overrides: [animeControllerProvider.overrideWith(_PendingController.new)],
  child: ZelunaBootstrap(initializeRuntime: initialize),
);

void main() {
  testWidgets('startup stays plain while runtime initialization is pending', (
    tester,
  ) async {
    final initialization = Completer<void>();
    await tester.pumpWidget(_bootstrap(() => initialization.future));
    await tester.pump();

    expect(find.byType(AnimeApp), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('zeluna-startup-background')),
      findsOneWidget,
    );
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, const Color(0xFF14181D));
    await tester.pumpWidget(const SizedBox.shrink());
    initialization.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ready runtime enters the app without an artificial minimum wait',
    (tester) async {
      final initialization = Completer<void>();
      await tester.pumpWidget(_bootstrap(() => initialization.future));
      expect(find.byType(AnimeApp), findsNothing);
      initialization.complete();
      await tester.pump();
      // No 500 ms pump: completing initialization is sufficient.
      expect(find.byType(AnimeApp), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('failed initialization can be retried without showing artwork', (
    tester,
  ) async {
    var calls = 0;
    final retry = Completer<void>();
    await tester.pumpWidget(
      _bootstrap(() async {
        calls++;
        if (calls == 1) throw StateError('test initialization failure');
        await retry.future;
      }),
    );
    await tester.pump();
    expect(find.text('启动失败，点击重试'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('启动失败，点击重试'));
    await tester.pump();
    expect(calls, 2);
    expect(find.text('启动失败，点击重试'), findsNothing);
    retry.complete();
    await tester.pump();
    expect(find.byType(AnimeApp), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('Android keeps its launcher but uses the normal Flutter lifecycle', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final splash = File(
      'android/app/src/main/kotlin/app/anime/anime/SplashActivity.kt',
    ).readAsStringSync();
    final main = File(
      'android/app/src/main/kotlin/app/anime/anime/MainActivity.kt',
    ).readAsStringSync();
    final launcher = manifest.substring(
      manifest.indexOf('<activity'),
      manifest.indexOf('</activity>'),
    );
    expect(launcher, contains('android:name=".SplashActivity"'));
    expect(launcher, contains('android.intent.category.LAUNCHER'));
    expect(launcher, contains('io.flutter.embedding.android.NormalTheme'));
    expect(launcher, contains('android:theme="@style/LaunchTheme"'));
    expect(launcher, isNot(contains('android:noHistory="true"')));
    expect(splash, contains('class SplashActivity : MainActivity()'));
    expect(main, contains('open class MainActivity : FlutterActivity()'));
    for (final obsolete in [
      'ImageView',
      'postDelayed',
      'FlutterEngineCache',
      'startActivity(',
    ]) {
      expect(splash, isNot(contains(obsolete)));
    }
  });

  test(
    'both Android launch themes and Flutter bundle exclude startup artwork',
    () {
      for (final folder in ['drawable', 'drawable-v21']) {
        final background = File(
          'android/app/src/main/res/$folder/launch_background.xml',
        ).readAsStringSync();
        expect(background, contains('@color/zeluna_splash_background'));
        expect(background, isNot(contains('<bitmap')));
      }
      for (final folder in ['values-v31', 'values-night-v31']) {
        final theme = File(
          'android/app/src/main/res/$folder/styles.xml',
        ).readAsStringSync();
        expect(theme, contains('@drawable/launch_icon_empty'));
        expect(theme, isNot(contains('@mipmap/ic_launcher')));
      }
      final icon = File(
        'android/app/src/main/res/drawable/launch_icon_empty.xml',
      ).readAsStringSync();
      expect(icon, contains('@android:color/transparent'));
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, isNot(contains('assets/brand/splash/')));
      expect(
        File(
          'android/app/src/main/res/drawable-nodpi/zeluna_launch_background.png',
        ).existsSync(),
        isFalse,
      );
      // Keep the original source for the user's later replacement, not in the bundle.
      expect(
        File('assets/brand/splash/zeluna_android_splash.png').existsSync(),
        isTrue,
      );
    },
  );
}

class _PendingController extends AnimeController {
  @override
  Future<AnimeState> build() => Completer<AnimeState>().future;
}
