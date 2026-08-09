import 'dart:async';

import 'package:anime/src/accounts/account_controller.dart';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/settings/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'home preferences keep personalized recommendations on for old JSON',
    () {
      final legacy = HomePreferences.fromJson({
        'defaultTab': AnimeHomeTab.browse.name,
      });
      expect(legacy.defaultTab, AnimeHomeTab.browse);
      expect(legacy.personalizedRecommendations, isTrue);

      final disabled = legacy.copyWith(personalizedRecommendations: false);
      expect(disabled.personalizedRecommendations, isFalse);
      expect(
        HomePreferences.fromJson(disabled.toJson()).personalizedRecommendations,
        isFalse,
      );
    },
  );

  test('loads and persists independent account settings scopes', () async {
    final storage = _MemorySettingsStorage({
      AccountController.settingsKeyFor('account-a', 'playback'):
          const PlaybackSettings(speed: 1.5).toJson(),
      AccountController.settingsKeyFor('account-a', 'appearance'):
          const AppearanceSettings(compactMode: true).toJson(),
      AccountController.settingsKeyFor('account-a', 'misc'): const MiscSettings(
        keepScreenOn: false,
      ).toJson(),
      AccountController.settingsKeyFor(
        'account-a',
        'services',
      ): const ExternalServiceSettings(
        playbackBackendEndpoint: 'https://settings-a.example',
      ).toJson(),
    });
    final published = <SettingsSnapshot>[];
    final keepScreenOn = <bool>[];
    final serviceChanges = <ExternalServicesChange>[];
    final controller = SettingsController(
      storage: storage,
      publishSnapshot: published.add,
      applyKeepScreenOn: (enabled) async => keepScreenOn.add(enabled),
      onExternalServicesChanged: (change) async {
        serviceChanges.add(change);
      },
    );

    var snapshot = controller.loadForAccount(
      accountId: 'account-a',
      contextVersion: 1,
    );
    expect(snapshot.playback.speed, 1.5);
    expect(snapshot.appearance.compactMode, isTrue);
    expect(snapshot.misc.keepScreenOn, isFalse);
    expect(snapshot.services.playbackBackendEnabled, isTrue);
    expect(snapshot.services.tmdbEnabled, isFalse);
    await controller.applyRuntimeEffects();
    expect(keepScreenOn, [false]);

    await controller.updatePlayback(snapshot.playback.copyWith(speed: 1.75));
    await controller.updateAppearance(
      snapshot.appearance.copyWith(darkMode: false),
    );
    expect(published.last.playback.speed, 1.75);
    expect(published.last.appearance.darkMode, isFalse);
    expect(
      (storage.values[AccountController.settingsKeyFor('account-a', 'playback')]
          as Map)['speed'],
      1.75,
    );

    snapshot = controller.loadForAccount(
      accountId: 'account-b',
      contextVersion: 2,
    );
    expect(snapshot.playback.speed, const PlaybackSettings().speed);
    expect(snapshot.appearance.compactMode, isFalse);
    await controller.updateHomePreferences(
      const HomePreferences(defaultTab: AnimeHomeTab.browse),
    );
    expect(
      storage.values[AccountController.settingsKeyFor(
        'account-b',
        'homePreferences',
      )],
      isNotNull,
    );

    snapshot = controller.loadForAccount(
      accountId: 'account-a',
      contextVersion: 3,
    );
    expect(snapshot.playback.speed, 1.75);
    expect(snapshot.appearance.darkMode, isFalse);
    expect(serviceChanges, isEmpty);
  });

  test(
    'stale settings writes cannot apply cross-account side effects',
    () async {
      final storage = _MemorySettingsStorage();
      final keepScreenOn = <bool>[];
      final serviceChanges = <ExternalServicesChange>[];
      final controller = SettingsController(
        storage: storage,
        publishSnapshot: (_) {},
        applyKeepScreenOn: (enabled) async => keepScreenOn.add(enabled),
        onExternalServicesChanged: (change) async {
          serviceChanges.add(change);
        },
      );
      controller.loadForAccount(accountId: 'account-a', contextVersion: 1);

      final miscGate = storage.blockNextWrite();
      final staleMisc = controller.updateMisc(
        const MiscSettings(keepScreenOn: false),
      );
      await miscGate.started.future;
      controller.loadForAccount(accountId: 'account-b', contextVersion: 2);
      miscGate.release.complete();
      await staleMisc;
      expect(keepScreenOn, isEmpty);

      final serviceGate = storage.blockNextWrite();
      final staleServices = controller.updateServices(
        controller.snapshot.services.copyWith(
          playbackBackendEndpoint: 'https://stale-settings.example',
        ),
      );
      await serviceGate.started.future;
      controller.loadForAccount(accountId: 'account-a', contextVersion: 3);
      serviceGate.release.complete();
      await staleServices;
      expect(serviceChanges, isEmpty);

      await controller.updateServices(
        controller.snapshot.services.copyWith(
          playbackBackendEndpoint: 'https://current-settings.example',
        ),
      );
      expect(serviceChanges, hasLength(1));
      expect(serviceChanges.single.playbackBackendChanged, isTrue);
      expect(serviceChanges.single.metadataChanged, isFalse);

      final orderedWriteGate = storage.blockNextWrite();
      final firstPlaybackWrite = controller.updatePlayback(
        controller.snapshot.playback.copyWith(speed: 1.25),
      );
      await orderedWriteGate.started.future;
      final secondPlaybackWrite = controller.updatePlayback(
        controller.snapshot.playback.copyWith(speed: 1.75),
      );
      await Future<void>.delayed(Duration.zero);
      orderedWriteGate.release.complete();
      await Future.wait([firstPlaybackWrite, secondPlaybackWrite]);
      expect(
        (storage.values[AccountController.settingsKeyFor(
              'account-a',
              'playback',
            )]
            as Map)['speed'],
        1.75,
      );

      final denied = SettingsController.normalizeServices(
        const ExternalServiceSettings(
          playbackBackendEndpoint: 'http://192.168.1.20:8080',
          playbackBackendSelfHosted: true,
        ),
      );
      expect(denied.playbackBackendEnabled, isFalse);
      expect(denied.allowInsecurePlaybackBackend, isFalse);
      final confirmed = SettingsController.normalizeServices(
        const ExternalServiceSettings(
          playbackBackendEndpoint: 'http://192.168.1.20:8080',
          playbackBackendSelfHosted: true,
          allowInsecurePlaybackBackend: true,
        ),
      );
      expect(confirmed.playbackBackendEnabled, isTrue);
      expect(confirmed.allowInsecurePlaybackBackend, isTrue);
    },
  );

  test(
    'selected settings journal before persistence and remote apply has no echo',
    () async {
      final storage = _MemorySettingsStorage();
      final playbackMutations = <PlaybackSettings>[];
      final appearanceMutations = <AppearanceSettings>[];
      final controller = SettingsController(
        storage: storage,
        publishSnapshot: (_) {},
        applyKeepScreenOn: (_) async {},
        onExternalServicesChanged: (_) async {},
        syncPlayback: (accountId, contextVersion, settings) async {
          expect(accountId, 'account-a');
          expect(contextVersion, 4);
          expect(
            storage.values[AccountController.settingsKeyFor(
              'account-a',
              'playback',
            )],
            isNull,
          );
          playbackMutations.add(settings);
          return true;
        },
        syncAppearance: (accountId, contextVersion, settings) async {
          expect(accountId, 'account-a');
          expect(contextVersion, 4);
          expect(
            storage.values[AccountController.settingsKeyFor(
              'account-a',
              'appearance',
            )],
            isNull,
          );
          appearanceMutations.add(settings);
          return true;
        },
      );
      controller.loadForAccount(accountId: 'account-a', contextVersion: 4);

      await controller.updatePlayback(const PlaybackSettings(speed: 1.5));
      await controller.updateAppearance(
        const AppearanceSettings(compactMode: true),
      );
      expect(playbackMutations, hasLength(1));
      expect(appearanceMutations, hasLength(1));

      await controller.applyRemotePlayback(const PlaybackSettings(speed: 2));
      await controller.applyRemoteAppearance(
        const AppearanceSettings(reduceMotion: true),
      );
      expect(playbackMutations, hasLength(1), reason: 'pull must not echo');
      expect(appearanceMutations, hasLength(1), reason: 'pull must not echo');
      expect(controller.snapshot.playback.speed, 2);
      expect(controller.snapshot.appearance.reduceMotion, isTrue);
    },
  );
}

final class _WriteGate {
  final started = Completer<void>();
  final release = Completer<void>();
}

final class _MemorySettingsStorage implements SettingsStorage {
  _MemorySettingsStorage([Map<String, Object?>? seed]) : values = {...?seed};

  final Map<String, Object?> values;
  _WriteGate? _nextGate;

  _WriteGate blockNextWrite() {
    final gate = _WriteGate();
    _nextGate = gate;
    return gate;
  }

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    final gate = _nextGate;
    _nextGate = null;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    values[key] = value;
  }
}
