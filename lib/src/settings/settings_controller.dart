import 'package:hive_ce_flutter/hive_flutter.dart';

import '../accounts/account_controller.dart';
import '../core/network/network_security.dart';
import '../data/zeluna_backend_playback_repository.dart';
import '../domain/anime_models.dart';

abstract interface class SettingsStorage {
  Object? get(String key);

  Future<void> put(String key, Object? value);
}

final class HiveSettingsStorage implements SettingsStorage {
  const HiveSettingsStorage(this._box);

  final Box<dynamic> _box;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);
}

typedef SettingsSnapshotPublisher = void Function(SettingsSnapshot snapshot);
typedef KeepScreenOnApplier = Future<void> Function(bool enabled);
typedef ExternalServicesChangeHandler =
    Future<void> Function(ExternalServicesChange change);

final class SettingsSnapshot {
  const SettingsSnapshot({
    this.playback = const PlaybackSettings(),
    this.homePreferences = const HomePreferences(),
    this.appearance = const AppearanceSettings(),
    this.danmaku = const DanmakuSettings(),
    this.misc = const MiscSettings(),
    this.services = const ExternalServiceSettings(),
  });

  final PlaybackSettings playback;
  final HomePreferences homePreferences;
  final AppearanceSettings appearance;
  final DanmakuSettings danmaku;
  final MiscSettings misc;
  final ExternalServiceSettings services;

  SettingsSnapshot copyWith({
    PlaybackSettings? playback,
    HomePreferences? homePreferences,
    AppearanceSettings? appearance,
    DanmakuSettings? danmaku,
    MiscSettings? misc,
    ExternalServiceSettings? services,
  }) => SettingsSnapshot(
    playback: playback ?? this.playback,
    homePreferences: homePreferences ?? this.homePreferences,
    appearance: appearance ?? this.appearance,
    danmaku: danmaku ?? this.danmaku,
    misc: misc ?? this.misc,
    services: services ?? this.services,
  );
}

final class ExternalServicesChange {
  const ExternalServicesChange({
    required this.previous,
    required this.current,
    required this.accountId,
    required this.contextVersion,
  });

  final ExternalServiceSettings previous;
  final ExternalServiceSettings current;
  final String? accountId;
  final int contextVersion;

  bool get metadataChanged =>
      SettingsController.servicesSignature(previous) !=
      SettingsController.servicesSignature(current);

  bool get playbackBackendChanged =>
      SettingsController.playbackBackendSignature(previous) !=
      SettingsController.playbackBackendSignature(current);
}

/// Owns account-scoped user settings and their ordered persistence.
///
/// Platform effects and cache invalidation remain explicit callbacks so this
/// domain does not reach into playback, catalog, or UI state directly.
final class SettingsController {
  SettingsController({
    required SettingsStorage storage,
    required SettingsSnapshotPublisher publishSnapshot,
    required KeepScreenOnApplier applyKeepScreenOn,
    required ExternalServicesChangeHandler onExternalServicesChanged,
  }) : _storage = storage,
       _publishSnapshot = publishSnapshot,
       _applyKeepScreenOn = applyKeepScreenOn,
       _onExternalServicesChanged = onExternalServicesChanged;

  final SettingsStorage _storage;
  final SettingsSnapshotPublisher _publishSnapshot;
  final KeepScreenOnApplier _applyKeepScreenOn;
  final ExternalServicesChangeHandler _onExternalServicesChanged;

  SettingsSnapshot _snapshot = const SettingsSnapshot();
  String? _accountId;
  var _contextVersion = 0;
  var _loaded = false;
  var _miscMutation = 0;
  var _servicesMutation = 0;
  Future<void> _writeQueue = Future<void>.value();

  SettingsSnapshot get snapshot => _snapshot;
  String? get accountId => _accountId;
  int get contextVersion => _contextVersion;
  bool get isLoaded => _loaded;

  Future<void> settleWrites() => _writeQueue;

  SettingsSnapshot loadForAccount({
    required String? accountId,
    required int contextVersion,
  }) {
    _accountId = accountId;
    _contextVersion = contextVersion;
    _miscMutation++;
    _servicesMutation++;
    _snapshot = SettingsSnapshot(
      playback: _read(
        accountId,
        'playback',
        PlaybackSettings.fromJson,
        const PlaybackSettings(),
      ),
      homePreferences: _read(
        accountId,
        'homePreferences',
        HomePreferences.fromJson,
        const HomePreferences(),
      ),
      appearance: _read(
        accountId,
        'appearance',
        AppearanceSettings.fromJson,
        const AppearanceSettings(),
      ),
      danmaku: _read(
        accountId,
        'danmaku',
        DanmakuSettings.fromJson,
        const DanmakuSettings(),
      ),
      misc: _read(
        accountId,
        'misc',
        MiscSettings.fromJson,
        const MiscSettings(),
      ),
      services: normalizeServices(
        _read(
          accountId,
          'services',
          ExternalServiceSettings.fromJson,
          const ExternalServiceSettings(),
        ),
      ),
    );
    _loaded = true;
    return _snapshot;
  }

  Future<void> applyRuntimeEffects() async {
    _requireLoaded();
    final accountId = _accountId;
    final contextVersion = _contextVersion;
    final mutation = _miscMutation;
    if (!_isCurrent(accountId, contextVersion) || mutation != _miscMutation) {
      return;
    }
    await _applyKeepScreenOn(_snapshot.misc.keepScreenOn);
  }

  Future<void> updatePlayback(PlaybackSettings value) async {
    final scope = _scope();
    _publish(_snapshot.copyWith(playback: value));
    await _write(scope.accountId, 'playback', value.toJson());
  }

  Future<void> updateHomePreferences(HomePreferences value) async {
    final scope = _scope();
    _publish(_snapshot.copyWith(homePreferences: value));
    await _write(scope.accountId, 'homePreferences', value.toJson());
  }

  Future<void> updateAppearance(AppearanceSettings value) async {
    final scope = _scope();
    _publish(_snapshot.copyWith(appearance: value));
    await _write(scope.accountId, 'appearance', value.toJson());
  }

  Future<void> updateDanmaku(DanmakuSettings value) async {
    final scope = _scope();
    _publish(_snapshot.copyWith(danmaku: value));
    await _write(scope.accountId, 'danmaku', value.toJson());
  }

  Future<void> updateMisc(MiscSettings value) async {
    final scope = _scope();
    final mutation = ++_miscMutation;
    _publish(_snapshot.copyWith(misc: value));
    await _write(scope.accountId, 'misc', value.toJson());
    if (_isCurrent(scope.accountId, scope.contextVersion) &&
        mutation == _miscMutation) {
      await _applyKeepScreenOn(value.keepScreenOn);
    }
  }

  Future<void> updateServices(ExternalServiceSettings value) async {
    final scope = _scope();
    final mutation = ++_servicesMutation;
    final previous = _snapshot.services;
    final normalized = normalizeServices(value);
    final changed =
        servicesSignature(previous) != servicesSignature(normalized) ||
        playbackBackendSignature(previous) !=
            playbackBackendSignature(normalized);
    _publish(_snapshot.copyWith(services: normalized));
    await _write(scope.accountId, 'services', normalized.toJson());
    if (changed &&
        _isCurrent(scope.accountId, scope.contextVersion) &&
        mutation == _servicesMutation) {
      await _onExternalServicesChanged(
        ExternalServicesChange(
          previous: previous,
          current: normalized,
          accountId: scope.accountId,
          contextVersion: scope.contextVersion,
        ),
      );
    }
  }

  static ExternalServiceSettings normalizeServices(
    ExternalServiceSettings settings,
  ) {
    final backendConfigured =
        ZelunaBackendPlaybackRepository.normalizeBaseUrl(
          settings.playbackBackendEndpoint,
          service: playbackBackendService(settings),
          allowInsecureSelfHosted: settings.allowInsecurePlaybackBackend,
        ) !=
        null;
    return settings.copyWith(
      watchHubEnabled: false,
      mediaMetadataEnabled: true,
      tmdbEnabled: false,
      cinemetaEnabled: false,
      peerTubeEnabled: false,
      wikimediaCommonsEnabled: false,
      anilistEnabled: false,
      jikanEnabled: false,
      kitsuEnabled: false,
      bangumiEnabled: false,
      publicCollectionSyncEnabled: false,
      preferBangumiChinese: true,
      playbackBackendEnabled: backendConfigured,
      allowInsecurePlaybackBackend:
          settings.playbackBackendSelfHosted &&
          settings.allowInsecurePlaybackBackend,
    );
  }

  static NetworkServiceKind playbackBackendService(
    ExternalServiceSettings settings,
  ) => settings.playbackBackendSelfHosted
      ? NetworkServiceKind.selfHostedPlaybackBackend
      : NetworkServiceKind.officialPlaybackBackend;

  static String servicesSignature(ExternalServiceSettings services) => [
    services.mediaMetadataEnabled,
    services.tmdbEnabled,
    services.cinemetaEnabled,
    services.anilistEnabled,
    services.jikanEnabled,
    services.kitsuEnabled,
    services.bangumiEnabled,
    services.publicCollectionSyncEnabled,
    services.peerTubeEnabled,
    services.wikimediaCommonsEnabled,
    services.preferBangumiChinese,
  ].join(':');

  static String playbackBackendSignature(ExternalServiceSettings services) => [
    services.playbackBackendEnabled,
    services.playbackBackendEndpoint.trim(),
    services.playbackBackendSelfHosted,
    services.allowInsecurePlaybackBackend,
  ].join(':');

  T _read<T>(
    String? accountId,
    String key,
    T Function(Map<String, dynamic> json) fromJson,
    T fallback,
  ) {
    final value = _storage.get(
      AccountController.settingsKeyFor(accountId, key),
    );
    if (value is! Map) return fallback;
    try {
      return fromJson(value.cast<String, dynamic>());
    } catch (_) {
      return fallback;
    }
  }

  ({String? accountId, int contextVersion}) _scope() {
    _requireLoaded();
    return (accountId: _accountId, contextVersion: _contextVersion);
  }

  void _publish(SettingsSnapshot next) {
    _snapshot = next;
    _publishSnapshot(next);
  }

  Future<void> _write(String? accountId, String key, Object? value) {
    final write = _writeQueue.then(
      (_) =>
          _storage.put(AccountController.settingsKeyFor(accountId, key), value),
    );
    _writeQueue = write.then<void>((_) {}, onError: (_, _) {});
    return write;
  }

  bool _isCurrent(String? accountId, int contextVersion) =>
      _accountId == accountId && _contextVersion == contextVersion;

  void _requireLoaded() {
    if (!_loaded) throw StateError('SettingsController has not been loaded');
  }
}
