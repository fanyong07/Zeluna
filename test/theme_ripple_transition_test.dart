import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/theme/accent_color_picker.dart';
import 'package:anime/src/theme/theme_ripple_transition.dart';

class _RippleDemoHarness extends StatefulWidget {
  const _RippleDemoHarness({this.reduceMotion = false, this.captureSnapshot});

  final bool reduceMotion;
  final ThemeSnapshotCapturer? captureSnapshot;

  @override
  State<_RippleDemoHarness> createState() => _RippleDemoHarnessState();
}

class _RippleDemoHarnessState extends State<_RippleDemoHarness> {
  var _dark = true;
  var _appearance = const AppearanceSettings(darkMode: true);

  @override
  Widget build(BuildContext context) {
    return ThemeRippleHost(
      reduceMotion: widget.reduceMotion,
      captureSnapshot: widget.captureSnapshot,
      child: MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
        home: Scaffold(
          appBar: AppBar(
            actions: [
              Builder(
                builder: (btnContext) => IconButton(
                  key: const ValueKey<String>('toggle-theme-btn'),
                  icon: Icon(_dark ? Icons.light_mode : Icons.dark_mode),
                  onPressed: () {
                    final nextDark = !_dark;
                    final next = _appearance.copyWith(darkMode: nextDark);
                    ThemeRippleHost.runIfAvailable(
                      btnContext,
                      origin: ThemeRippleHost.globalCenterOf(btnContext),
                      accentColor: ThemeRippleHost.accentColorFor(
                        next,
                        dark: nextDark,
                      ),
                      nextIsDark: nextDark,
                      applyChange: () {
                        setState(() {
                          _dark = nextDark;
                          _appearance = next;
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_dark ? 'DARK_MODE' : 'LIGHT_MODE'),
                  ZelunaAccentColorPicker(
                    settings: _appearance,
                    onChanged: (next) {
                      setState(() => _appearance = next);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'ThemeRippleHost animates bidirectional 520ms ripple with halo and cleans up',
    (tester) async {
      await tester.pumpWidget(const _RippleDemoHarness());
      expect(find.text('DARK_MODE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsNothing,
      );

      // Dark -> Light outward ripple
      await tester.tap(find.byKey(const ValueKey<String>('toggle-theme-btn')));
      await tester.pump();
      expect(find.text('LIGHT_MODE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-halo')),
        findsOneWidget,
      );

      // Mid-animation at 260ms: overlay & halo remain active
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsOneWidget,
      );

      // Past 520ms: animation completes and snapshot overlay is removed
      await tester.pump(const Duration(milliseconds: 280));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsNothing,
      );

      // Light -> Dark outward ripple
      await tester.tap(find.byKey(const ValueKey<String>('toggle-theme-btn')));
      await tester.pump();
      expect(find.text('DARK_MODE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'ThemeRippleHost respects reduceMotion and skips ripple overlay',
    (tester) async {
      await tester.pumpWidget(const _RippleDemoHarness(reduceMotion: true));
      await tester.tap(find.byKey(const ValueKey<String>('toggle-theme-btn')));
      await tester.pump();
      expect(find.text('LIGHT_MODE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'ThemeRippleHost falls back cleanly when snapshot capture returns null',
    (tester) async {
      await tester.pumpWidget(
        _RippleDemoHarness(captureSnapshot: (_, _) => null),
      );
      await tester.tap(find.byKey(const ValueKey<String>('toggle-theme-btn')));
      await tester.pump();
      expect(find.text('LIGHT_MODE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Rapid double tap cleanly supersedes prior ripple without crashing',
    (tester) async {
      await tester.pumpWidget(const _RippleDemoHarness());
      await tester.tap(find.byKey(const ValueKey<String>('toggle-theme-btn')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('LIGHT_MODE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsOneWidget,
      );

      // Second tap mid-animation reverses cleanly back to dark
      await tester.tap(find.byKey(const ValueKey<String>('toggle-theme-btn')));
      await tester.pump();
      expect(find.text('DARK_MODE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('theme-ripple-overlay')),
        findsNothing,
      );
    },
  );

  testWidgets('ZelunaAccentColorPicker preset tap triggers ThemeRippleHost', (
    tester,
  ) async {
    await tester.pumpWidget(const _RippleDemoHarness());
    await tester.tap(find.text('樱花粉'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('theme-ripple-overlay')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('theme-ripple-overlay')),
      findsNothing,
    );
  });
}
