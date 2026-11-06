import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_update_controller.dart';

/// A non-modal notice never overlays playback. The opt-in startup request is
/// deferred until the first frame and a non-player route, not bootstrap I/O.
class AppUpdateHost extends ConsumerStatefulWidget {
  const AppUpdateHost({super.key, required this.router, required this.child});
  final GoRouter router;
  final Widget child;
  @override
  ConsumerState<AppUpdateHost> createState() => _AppUpdateHostState();
}

class _AppUpdateHostState extends ConsumerState<AppUpdateHost>
    with WidgetsBindingObserver {
  late AppUpdateController _controller;
  Timer? _startup;
  String? _dismissedVersion;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(appUpdateControllerProvider);
    WidgetsBinding.instance.addObserver(this);
    widget.router.routeInformationProvider.addListener(_routeChanged);
    _startup = Timer(const Duration(seconds: 3), _scheduleCheck);
  }

  String get _path => widget.router.routeInformationProvider.value.uri.path;
  bool get _playing => _path == '/player' || _path.startsWith('/player/');
  void _routeChanged() {
    if (mounted) setState(() {});
    _scheduleCheck();
  }

  void _scheduleCheck() {
    if (!mounted || _playing || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      if (!mounted || _playing) return;
      await _controller.maybeCheckAutomatically(
        canCheck: () => mounted && !_playing,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.onResumed());
      _scheduleCheck();
    }
  }

  @override
  void dispose() {
    _startup?.cancel();
    widget.router.routeInformationProvider.removeListener(_routeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final release = _controller.release;
      final show =
          !_playing &&
          _path != '/profile/version' &&
          release != null &&
          _dismissedVersion != '${release.version}+${release.buildNumber}' &&
          (_controller.phase == AppUpdatePhase.available ||
              _controller.phase == AppUpdatePhase.ready);
      return Stack(
        children: [
          child!,
          if (show)
            Positioned(
              left: 12,
              right: 12,
              top: MediaQuery.paddingOf(context).top + 8,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Material(
                    elevation: 4,
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 16,
                        top: 8,
                        bottom: 8,
                        right: 4,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '发现新版本 ${release.displayVersion}',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                widget.router.push('/profile/version'),
                            child: const Text('查看更新'),
                          ),
                          Semantics(
                            label: '稍后再说',
                            child: IconButton(
                              key: const ValueKey('dismiss_app_update'),
                              onPressed: () => setState(() {
                                _dismissedVersion =
                                    '${release.version}+${release.buildNumber}';
                              }),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
