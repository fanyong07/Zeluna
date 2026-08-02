import 'dart:async';

import '../domain/anime_models.dart';

typedef SyncHistoryUploader =
    Future<bool> Function(
      AnimeSubject subject,
      AnimeEpisode? episode,
      ExternalServiceSettings services,
    );
typedef SyncContextGuard = bool Function(int contextVersion);

/// Owns the lifecycle of the current compatibility sync side effect.
///
/// Durable offline mutations, idempotency keys, tombstones, pull revisions,
/// and conflict resolution intentionally remain G10 work. This controller
/// gives that future protocol one account-scoped owner without moving local
/// library persistence or external-service settings into the Sync domain.
final class SyncController {
  SyncController({
    required SyncHistoryUploader uploadHistory,
    required SyncContextGuard isContextCurrent,
    this.operationTimeout = const Duration(seconds: 10),
  }) : assert(operationTimeout > Duration.zero),
       _uploadHistory = uploadHistory,
       _isContextCurrent = isContextCurrent;

  final SyncHistoryUploader _uploadHistory;
  final SyncContextGuard _isContextCurrent;
  final Duration operationTimeout;

  String? _accountId;
  var _contextVersion = 0;
  var _scopeEpoch = 0;
  var _loaded = false;
  var _disposed = false;
  ExternalServiceSettings _services = const ExternalServiceSettings();
  Future<void> _operationQueue = Future<void>.value();

  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;

  void loadForAccount({
    required String? accountId,
    required int contextVersion,
    required ExternalServiceSettings services,
  }) {
    _ensureNotDisposed();
    _accountId = accountId;
    _contextVersion = contextVersion;
    _services = services;
    _scopeEpoch++;
    _loaded = true;
  }

  void applyServices(
    ExternalServiceSettings services, {
    required int contextVersion,
  }) {
    final scope = _scope();
    if (scope.contextVersion != contextVersion || !_isCurrent(scope)) return;
    final syncEnabledChanged =
        _services.publicCollectionSyncEnabled !=
        services.publicCollectionSyncEnabled;
    _services = services;
    if (syncEnabledChanged) _scopeEpoch++;
  }

  Future<bool> syncHistory({
    required String? accountId,
    required int contextVersion,
    required AnimeSubject subject,
    required AnimeEpisode? episode,
  }) {
    final scope = _scope();
    if (scope.accountId != accountId ||
        scope.contextVersion != contextVersion ||
        !_isCurrent(scope) ||
        !_services.publicCollectionSyncEnabled) {
      return Future<bool>.value(false);
    }
    final services = _services;
    final completer = Completer<bool>();
    final operation = _operationQueue.then((_) async {
      if (!_isCurrent(scope)) {
        completer.complete(false);
        return;
      }
      var acknowledged = false;
      try {
        acknowledged = await _uploadHistory(
          subject,
          episode,
          services,
        ).timeout(operationTimeout);
      } catch (_) {
        // Optional sync must not turn an already-persisted local mutation into
        // a user-visible failure. G10 will retain retryable mutations durably.
      }
      completer.complete(_isCurrent(scope) && acknowledged);
    });
    _operationQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return completer.future;
  }

  Future<void> settle() => _operationQueue;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    _scopeEpoch++;
  }

  _SyncScope _scope() {
    _ensureNotDisposed();
    if (!_loaded) throw StateError('Sync controller is not configured.');
    return _SyncScope(
      accountId: _accountId,
      contextVersion: _contextVersion,
      epoch: _scopeEpoch,
    );
  }

  bool _isCurrent(_SyncScope scope) =>
      !_disposed &&
      _loaded &&
      scope.accountId == _accountId &&
      scope.contextVersion == _contextVersion &&
      scope.epoch == _scopeEpoch &&
      _isContextCurrent(scope.contextVersion);

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('Sync controller is disposed.');
  }
}

final class _SyncScope {
  const _SyncScope({
    required this.accountId,
    required this.contextVersion,
    required this.epoch,
  });

  final String? accountId;
  final int contextVersion;
  final int epoch;
}
