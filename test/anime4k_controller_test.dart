import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/anime4k/anime4k_controller.dart';
import 'package:anime/src/player/anime4k_shader_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shader apply owns quality to balanced fallback state', () async {
    final harness = _Anime4KHarness(failTiers: {Anime4KTier.quality});
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_enabledSettings());

    await controller.settled;

    expect(harness.installedTiers, [Anime4KTier.quality, Anime4KTier.balanced]);
    expect(controller.activeTier, Anime4KTier.balanced);
    expect(controller.isActive, isTrue);
    expect(controller.statusMessage, contains('降为标准'));
    expect(controller.displayStatus?.title, '超分运行中');
  });

  test('shader log and sustained overload step down one tier', () async {
    final harness = _Anime4KHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_enabledSettings());
    await controller.settled;
    expect(controller.activeTier, Anime4KTier.quality);

    controller.handlePlayerLog(prefix: 'vo/gpu', text: 'shader compile failed');
    await controller.settled;
    expect(controller.activeTier, Anime4KTier.balanced);

    controller.updatePlaybackState(playing: true, buffering: false);
    await controller.samplePerformance();
    harness.incrementCounters(5);
    await controller.samplePerformance();
    harness.incrementCounters(5);
    await controller.samplePerformance();
    await controller.settled;
    expect(controller.activeTier, Anime4KTier.performance);
  });

  test(
    'measured frame rate refreshes the active tier and display status',
    () async {
      final harness = _Anime4KHarness()..properties['estimated-vf-fps'] = '60';
      final controller = harness.controller();
      addTearDown(controller.dispose);
      controller
        ..updateVideoDimensions(width: 1280, height: 720)
        ..updateViewport(const Size(1920, 1080))
        ..applySettings(_enabledSettings());
      await controller.settled;
      expect(controller.activeTier, Anime4KTier.quality);

      await controller.refreshFrameRate(usesWebPlayer: false);
      await controller.settled;

      expect(controller.activeSelection?.sourceFramesPerSecond, 60);
      expect(controller.activeTier, Anime4KTier.balanced);
      expect(controller.displayStatus?.detail, contains('60fps'));
    },
  );

  test('video reset invalidates a late frame rate read', () async {
    final frameRate = Completer<String>();
    final harness = _Anime4KHarness(
      propertyOverride: (property) {
        if (property == 'estimated-vf-fps') return frameRate.future;
        return null;
      },
    );
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_enabledSettings());
    await controller.settled;

    final pending = controller.refreshFrameRate(usesWebPlayer: false);
    controller.resetVideo();
    frameRate.complete('60');
    await pending;
    expect(controller.activeSelection?.sourceFramesPerSecond, 0);
  });

  test('dispose rejects late shader completion', () async {
    final install = Completer<Anime4KShaderPipeline>();
    final harness = _Anime4KHarness(
      installOverride: (profile, tier, customShaders) => install.future,
      performanceSampleInterval: const Duration(milliseconds: 5),
    );
    final controller = harness.controller();
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_enabledSettings());
    final notificationsBeforeDispose = notifications;
    controller.dispose();

    install.complete(
      const Anime4KShaderPipeline(
        profile: Anime4KProfile.clear,
        tier: Anime4KTier.quality,
        assetPaths: [],
        installedPaths: ['Anime4K_Test.glsl'],
      ),
    );
    await controller.settled;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.isDisposed, isTrue);
    expect(controller.activeSelection, isNull);
    expect(notifications, notificationsBeforeDispose);
  });

  test('dispose cancels the controller-owned performance timer', () async {
    final harness = _Anime4KHarness(
      performanceSampleInterval: const Duration(milliseconds: 5),
    );
    final controller = harness.controller();
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_enabledSettings());
    await controller.settled;
    controller.updatePlaybackState(playing: true, buffering: false);

    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(harness.performancePropertyReads, greaterThan(0));
    controller.dispose();
    final readsAfterDispose = harness.performancePropertyReads;
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(harness.performancePropertyReads, readsAfterDispose);
  });
}

PlaybackSettings _enabledSettings() {
  return const PlaybackSettings(
    superResolution: true,
    superResolutionProfile: 'clear',
  );
}

typedef _PropertyOverride = FutureOr<String>? Function(String property);

final class _Anime4KHarness {
  _Anime4KHarness({
    this.failTiers = const {},
    this.propertyOverride,
    this.installOverride,
    this.performanceSampleInterval = const Duration(hours: 1),
  });

  final Set<Anime4KTier> failTiers;
  final _PropertyOverride? propertyOverride;
  final Anime4KPipelineInstaller? installOverride;
  final Duration performanceSampleInterval;
  final List<Anime4KTier> installedTiers = [];
  int performancePropertyReads = 0;
  final Map<String, String> properties = {
    'scale': 'ewa_lanczossharp',
    'glsl-shaders': '',
    'vo-drop-frame-count': '0',
    'mistimed-frame-count': '0',
    'delayed-frame-count': '0',
  };

  Anime4KController controller() {
    return Anime4KController(
      platform: TargetPlatform.windows,
      getProperty: (property) async {
        if (property == 'vo-drop-frame-count' ||
            property == 'mistimed-frame-count' ||
            property == 'delayed-frame-count') {
          performancePropertyReads++;
        }
        final override = propertyOverride?.call(property);
        if (override != null) return await override;
        return properties[property] ?? '';
      },
      setProperty: (property, value) async => properties[property] = value,
      installPipeline: installOverride ?? _install,
      resolveSupport: () => const Anime4KPlatformSupport.supported(),
      performanceSampleInterval: performanceSampleInterval,
    );
  }

  Future<Anime4KShaderPipeline> _install(
    Anime4KProfile profile,
    Anime4KTier tier,
    List<String> customShaders,
  ) async {
    installedTiers.add(tier);
    if (failTiers.contains(tier)) throw StateError('tier failed');
    final path = 'C:\\Anime4K_${tier.settingValue}.glsl';
    return Anime4KShaderPipeline(
      profile: profile,
      tier: tier,
      assetPaths: const [],
      installedPaths: [path],
    );
  }

  void incrementCounters(int delta) {
    for (final property in const [
      'vo-drop-frame-count',
      'mistimed-frame-count',
      'delayed-frame-count',
    ]) {
      properties[property] = (int.parse(properties[property]!) + delta)
          .toString();
    }
  }
}
