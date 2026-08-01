import 'dart:async';

import '../../data/playback_source_repository.dart';
import '../../rules/rule_playback_resolver.dart';

/// Owns mutable line-selection state and all asynchronous lookup handles.
final class PlaybackLineController {
  final Set<String> failedLineIds = <String>{};
  final Map<String, int> failureCounts = <String, int>{};
  String? preferredProviderId;
  StreamSubscription<PlaybackLineLookupUpdate>? lookupSubscription;
  RulePlaybackCancellationToken? lookupCancellationToken;
  RulePlaybackCancellationToken? backupLookupCancellationToken;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void clearFailures() {
    failedLineIds.clear();
    failureCounts.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    lookupCancellationToken?.cancel();
    lookupCancellationToken = null;
    backupLookupCancellationToken?.cancel();
    backupLookupCancellationToken = null;
    final subscription = lookupSubscription;
    lookupSubscription = null;
    if (subscription != null) await subscription.cancel();
    clearFailures();
  }
}
