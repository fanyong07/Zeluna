import 'dart:async';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/anime4k/anime4k_controller.dart';
import 'package:anime/src/player/anime4k_shader_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs exactly the tier and mode the user picked', () async {
    final harness = _Anime4KHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'bb'));

    await controller.settled;

    expect(harness.installed, [(Anime4KTier.quality, Anime4KMode.bb)]);
    expect(controller.activeTier, Anime4KTier.quality);
    expect(controller.activeMode, Anime4KMode.bb);
    expect(controller.isActive, isTrue);
    expect(controller.statusMessage, isNull);
    expect(controller.displayStatus?.title, '超分运行中');
    expect(controller.displayStatus?.detail, contains('模式B+B · 质量'));
  });

  test('a failed pipeline disables instead of weakening the chain', () async {
    final harness = _Anime4KHarness(failTiers: {Anime4KTier.quality});
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'a'));

    await controller.settled;

    // One attempt only: no balance/efficiency retry behind the user's back.
    expect(harness.installed, [(Anime4KTier.quality, Anime4KMode.a)]);
    expect(controller.activeTier, isNull);
    expect(controller.isActive, isFalse);
    expect(controller.statusMessage, contains('模式A · 质量'));
    expect(harness.properties['glsl-shaders'], '');
  });

  test('changing the tier reinstalls at the new tier', () async {
    final harness = _Anime4KHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'a'));
    await controller.settled;

    controller.applySettings(_settings(tier: 'efficiency', mode: 'a'));
    await controller.settled;

    expect(harness.installed, [
      (Anime4KTier.quality, Anime4KMode.a),
      (Anime4KTier.efficiency, Anime4KMode.a),
    ]);
    expect(controller.activeTier, Anime4KTier.efficiency);
  });

  test('reapplying identical settings does not reinstall', () async {
    final harness = _Anime4KHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'balance', mode: 'c'));
    await controller.settled;

    controller.applySettings(_settings(tier: 'balance', mode: 'c'));
    await controller.settled;

    expect(harness.installed, hasLength(1));
  });

  test('disabling restores the shader list mpv started with', () async {
    final harness = _Anime4KHarness()
      ..properties['glsl-shaders'] = 'preexisting.glsl';
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'a'));
    await controller.settled;
    expect(harness.properties['glsl-shaders'], isNot('preexisting.glsl'));

    controller.applySettings(const PlaybackSettings());
    await controller.settled;

    expect(harness.properties['glsl-shaders'], 'preexisting.glsl');
    expect(controller.activeSelection, isNull);
  });

  test('custom tier without shaders explains itself', () async {
    final harness = _Anime4KHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'custom', mode: 'a'));

    await controller.settled;

    expect(harness.installed, isEmpty);
    expect(controller.isActive, isFalse);
    expect(controller.statusMessage, contains('至少需要选择一个着色器'));
  });

  test('custom tier installs the chosen shaders', () async {
    final harness = _Anime4KHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(
        _settings(
          tier: 'custom',
          mode: 'a',
          customShaders: const ['Anime4K_Clamp_Highlights.glsl'],
        ),
      );

    await controller.settled;

    expect(harness.installed, [(Anime4KTier.custom, Anime4KMode.a)]);
    expect(harness.customShaders, ['Anime4K_Clamp_Highlights.glsl']);
    expect(controller.displayStatus?.detail, contains('高级 · 自定义组合'));
  });

  test('an unsupported platform reports rather than installing', () async {
    final harness = _Anime4KHarness(
      support: const Anime4KPlatformSupport.unsupported('测试平台不支持'),
    );
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'a'));

    await controller.settled;

    expect(harness.installed, isEmpty);
    expect(controller.statusMessage, '测试平台不支持');
  });

  test('original preview swaps the shader list both ways', () async {
    final harness = _Anime4KHarness()
      ..properties['glsl-shaders'] = 'preexisting.glsl';
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'a'));
    await controller.settled;
    final applied = harness.properties['glsl-shaders'];

    controller.setOriginalPreview(true);
    await controller.settled;
    expect(harness.properties['glsl-shaders'], 'preexisting.glsl');
    expect(controller.previewingOriginal, isTrue);
    expect(controller.isActive, isFalse);
    expect(controller.displayStatus?.title, '原画预览');

    controller.setOriginalPreview(false);
    await controller.settled;
    expect(harness.properties['glsl-shaders'], applied);
    expect(controller.isActive, isTrue);
  });

  test('dispose rejects a late shader completion', () async {
    final install = Completer<Anime4KShaderPipeline>();
    final harness = _Anime4KHarness(
      installOverride: (tier, mode, customShaders) => install.future,
    );
    final controller = harness.controller();
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'a'));
    final before = notifications;
    controller.dispose();

    install.complete(
      const Anime4KShaderPipeline(
        tier: Anime4KTier.quality,
        mode: Anime4KMode.a,
        assetPaths: [],
        installedPaths: ['Anime4K_Test.glsl'],
      ),
    );
    await controller.settled;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.isDisposed, isTrue);
    expect(controller.activeSelection, isNull);
    expect(notifications, before);
  });

  test('a rejected shader list counts as a failure', () async {
    // mpv can accept the property write yet not adopt the list.
    final harness = _Anime4KHarness(swallowShaderWrites: true);
    final controller = harness.controller();
    addTearDown(controller.dispose);
    controller
      ..updateVideoDimensions(width: 1280, height: 720)
      ..updateViewport(const Size(1920, 1080))
      ..applySettings(_settings(tier: 'quality', mode: 'a'));

    await controller.settled;

    expect(controller.isActive, isFalse);
    expect(controller.statusMessage, contains('无法运行'));
  });
}

PlaybackSettings _settings({
  required String tier,
  required String mode,
  List<String> customShaders = const [],
}) {
  return PlaybackSettings(
    superResolution: true,
    superResolutionTier: tier,
    superResolutionMode: mode,
    superResolutionCustomShaders: customShaders,
  );
}

final class _Anime4KHarness {
  _Anime4KHarness({
    this.failTiers = const {},
    this.installOverride,
    this.support = const Anime4KPlatformSupport.supported(),
    this.swallowShaderWrites = false,
  });

  final Set<Anime4KTier> failTiers;
  final Anime4KPipelineInstaller? installOverride;
  final Anime4KPlatformSupport support;

  /// Simulates mpv accepting the write but keeping its previous shader list.
  final bool swallowShaderWrites;

  final List<(Anime4KTier, Anime4KMode)> installed = [];
  List<String> customShaders = const [];
  final Map<String, String> properties = {
    'scale': 'ewa_lanczossharp',
    'glsl-shaders': '',
  };

  Anime4KController controller() {
    return Anime4KController(
      platform: TargetPlatform.windows,
      getProperty: (property) async => properties[property] ?? '',
      setProperty: (property, value) async {
        if (swallowShaderWrites && property == 'glsl-shaders') return;
        properties[property] = value;
      },
      installPipeline: installOverride ?? _install,
      resolveSupport: () => support,
    );
  }

  Future<Anime4KShaderPipeline> _install(
    Anime4KTier tier,
    Anime4KMode mode,
    List<String> names,
  ) async {
    installed.add((tier, mode));
    customShaders = names;
    if (failTiers.contains(tier)) throw StateError('tier failed');
    return Anime4KShaderPipeline(
      tier: tier,
      mode: mode,
      assetPaths: const [],
      installedPaths: ['C:\\Anime4K_${tier.settingValue}.glsl'],
    );
  }
}
