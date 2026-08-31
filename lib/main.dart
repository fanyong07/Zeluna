import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app/anime_app.dart';
import 'src/app/deferred_fonts.dart';
import 'src/app/desktop_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Must run before the first frame so window_manager owns the window; see
  // initializeDesktopWindow for why fullscreen depends on it.
  await initializeDesktopWindow();
  runApp(const ZelunaBootstrap());
}

class ZelunaBootstrap extends StatefulWidget {
  const ZelunaBootstrap({
    super.key,
    this.initializeRuntime,
    this.minimumDisplayDuration = const Duration(milliseconds: 500),
  });

  final Future<void> Function()? initializeRuntime;
  final Duration minimumDisplayDuration;

  @override
  State<ZelunaBootstrap> createState() => _ZelunaBootstrapState();
}

class _ZelunaBootstrapState extends State<ZelunaBootstrap> {
  bool _ready = false;
  bool _initializing = false;
  Object? _initializationError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    if (_initializing) return;
    _initializing = true;
    final displayTimer = Stopwatch()..start();
    if (_initializationError != null && mounted) {
      setState(() => _initializationError = null);
    }

    try {
      await (widget.initializeRuntime?.call() ?? _initializeRuntime());
      final remaining = widget.minimumDisplayDuration - displayTimer.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      if (!mounted) return;
      setState(() => _ready = true);
      // The large emphasis fonts are intentionally loaded after the real app
      // takes over, so neither Android nor the branded splash waits on them.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(loadDeferredFonts());
      });
    } catch (error) {
      if (mounted) setState(() => _initializationError = error);
    } finally {
      _initializing = false;
    }
  }

  Future<void> _initializeRuntime() async {
    MediaKit.ensureInitialized();
    await Hive.initFlutter('anime');
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return const ProviderScope(child: AnimeApp());

    return MaterialApp(
      title: 'Zeluna',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Stack(
        children: [
          const ZelunaStartupView(),
          if (_initializationError != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: SafeArea(
                child: Center(
                  child: FilledButton.tonal(
                    onPressed: _initialize,
                    child: const Text('启动失败，点击重试'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
