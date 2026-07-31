import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class AppFullscreenController {
  AppFullscreenController() {
    _subscription = web.document.documentElement?.onFullscreenChange.listen((
      _,
    ) {
      if (!_changes.isClosed) _changes.add(_isEnabledSync);
    });
  }

  final _changes = StreamController<bool>.broadcast();
  StreamSubscription<web.Event>? _subscription;

  Stream<bool> get changes => _changes.stream;

  bool get _isEnabledSync => web.document.fullscreenElement != null;

  Future<bool> setEnabled(bool enabled) async {
    try {
      if (enabled) {
        final root = web.document.documentElement;
        if (root == null) return false;
        await root.requestFullscreen().toDart;
      } else if (_isEnabledSync) {
        await web.document.exitFullscreen().toDart;
      }
    } catch (_) {
      return false;
    }
    return _isEnabledSync == enabled;
  }

  Future<bool> isEnabled() async => _isEnabledSync;

  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_changes.close());
  }
}
