import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/anime4k_shader_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K platform support', () {
    test('never advertises real-time shaders on web', () {
      final support = Anime4KShaderManager.platformSupport(
        isWeb: true,
        platform: TargetPlatform.windows,
      );

      expect(support.supported, isFalse);
      expect(support.reason, contains('网页版'));
    });

    test('supports native media_kit platforms but not Fuchsia', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(
          Anime4KShaderManager.platformSupport(
            isWeb: false,
            platform: platform,
          ).supported,
          isTrue,
        );
      }
      expect(
        Anime4KShaderManager.platformSupport(
          isWeb: false,
          platform: TargetPlatform.fuchsia,
        ).supported,
        isFalse,
      );
    });
  });

  group('Anime4K profiles', () {
    test('pipelines contain ordered, non-duplicated v4 shaders', () {
      for (final profile in const [
        Anime4KProfile.clear,
        Anime4KProfile.soft,
        Anime4KProfile.lowResolution,
        Anime4KProfile.strong,
      ]) {
        final assets = Anime4KShaderManager.pipelineFor(profile).assetPaths;
        expect(assets, isNotEmpty);
        expect(assets.toSet(), hasLength(assets.length));
        expect(assets.first, endsWith('Anime4K_Clamp_Highlights.glsl'));
      }

      final balanced = Anime4KShaderManager.pipelineFor(
        Anime4KProfile.clear,
      ).assetPaths;
      expect(balanced, contains(endsWith('Anime4K_Restore_CNN_M.glsl')));
      expect(balanced, contains(endsWith('Anime4K_Upscale_CNN_x2_M.glsl')));

      final quality = Anime4KShaderManager.pipelineFor(
        Anime4KProfile.strong,
        tier: Anime4KTier.quality,
      ).assetPaths;
      expect(quality, contains(endsWith('Anime4K_Restore_CNN_L.glsl')));
      expect(quality, contains(endsWith('Anime4K_Upscale_CNN_x2_L.glsl')));
    });

    test('advanced profile keeps only known shaders in safe catalog order', () {
      final pipeline = Anime4KShaderManager.pipelineFor(
        Anime4KProfile.advanced,
        customShaderNames: const [
          'missing.glsl',
          'Anime4K_Upscale_CNN_x2_M.glsl',
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Upscale_CNN_x2_M.glsl',
        ],
      );

      expect(pipeline.assetPaths, [
        endsWith('Anime4K_Clamp_Highlights.glsl'),
        endsWith('Anime4K_Upscale_CNN_x2_M.glsl'),
      ]);
    });

    test('uses mpv path-list separator for the target OS', () {
      const paths = <String>['first.glsl', 'second.glsl'];
      expect(
        Anime4KShaderManager.buildMpvShaderList(
          paths,
          platform: TargetPlatform.windows,
        ),
        'first.glsl;second.glsl',
      );
      expect(
        Anime4KShaderManager.buildMpvShaderList(
          paths,
          platform: TargetPlatform.android,
        ),
        'first.glsl:second.glsl',
      );
    });

    test('automatic mode selects a content and enlargement aware pipeline', () {
      Anime4KSelection selection(
        int sourceHeight, {
        required int displayHeight,
      }) {
        final sourceWidth = (sourceHeight * 16 / 9).round();
        return Anime4KShaderManager.select(
          requestedProfile: Anime4KProfile.automatic,
          platform: TargetPlatform.windows,
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          displayWidth: (displayHeight * 16 / 9).round(),
          displayHeight: displayHeight,
        );
      }

      expect(
        selection(480, displayHeight: 720).resolvedProfile,
        Anime4KProfile.lowResolution,
      );
      expect(
        selection(720, displayHeight: 720).resolvedProfile,
        Anime4KProfile.soft,
      );
      expect(
        selection(720, displayHeight: 1080).resolvedProfile,
        Anime4KProfile.soft,
      );
      final enlargedLegacyFourThree = Anime4KShaderManager.select(
        requestedProfile: Anime4KProfile.automatic,
        platform: TargetPlatform.windows,
        sourceWidth: 960,
        sourceHeight: 736,
        displayWidth: 1409,
        displayHeight: 1080,
        sourceFramesPerSecond: 25,
      );
      expect(enlargedLegacyFourThree.scaleFactor, closeTo(1.467, 0.001));
      expect(enlargedLegacyFourThree.resolvedProfile, Anime4KProfile.clear);
      expect(enlargedLegacyFourThree.tier, Anime4KTier.quality);
      expect(enlargedLegacyFourThree.expectsUpscale, isTrue);
      expect(enlargedLegacyFourThree.frameRateLabel, '25fps');
      expect(
        enlargedLegacyFourThree.resolutionDescription(),
        '片源 960×736 → 超分至 1409×1080',
      );
      expect(
        selection(1080, displayHeight: 1440).resolvedProfile,
        Anime4KProfile.clear,
      );
      expect(selection(1080, displayHeight: 1440).tier, Anime4KTier.quality);
    });

    test('reports whether Anime4K upscale passes are expected to execute', () {
      final sameSize = Anime4KShaderManager.select(
        requestedProfile: Anime4KProfile.clear,
        platform: TargetPlatform.windows,
        sourceWidth: 1920,
        sourceHeight: 1080,
        displayWidth: 1920,
        displayHeight: 1080,
      );
      final enlarged = Anime4KShaderManager.select(
        requestedProfile: Anime4KProfile.clear,
        platform: TargetPlatform.windows,
        sourceWidth: 1920,
        sourceHeight: 1080,
        displayWidth: 2560,
        displayHeight: 1440,
      );
      final reducedDisplay = Anime4KShaderManager.select(
        requestedProfile: Anime4KProfile.clear,
        platform: TargetPlatform.windows,
        sourceWidth: 1920,
        sourceHeight: 1080,
        displayWidth: 1080,
        displayHeight: 608,
      );

      expect(sameSize.expectsUpscale, isFalse);
      expect(sameSize.resolvedProfile.restoresWithoutScaling, isTrue);
      expect(enlarged.expectsUpscale, isTrue);
      expect(reducedDisplay.expectsUpscale, isFalse);
      expect(
        reducedDisplay.resolutionDescription(),
        '片源 1920×1080 · 显示区域 1080×608 · 仅画质修复',
      );
      expect(enlarged.resolutionDescription(), '片源 1920×1080 → 超分至 2560×1440');
      expect(
        reducedDisplay.resolutionDescription(previewingOriginal: true),
        '片源 1920×1080 · 显示区域 1080×608 · 原画',
      );
    });

    test('strong mode only uses its secondary pass at 2x or higher', () {
      Anime4KSelection strongSelection({required int displayWidth}) {
        return Anime4KShaderManager.select(
          requestedProfile: Anime4KProfile.strong,
          platform: TargetPlatform.windows,
          sourceWidth: 1280,
          sourceHeight: 720,
          displayWidth: displayWidth,
          displayHeight: (displayWidth * 9 / 16).round(),
        );
      }

      final belowTwoX = strongSelection(displayWidth: 1920);
      final atTwoX = strongSelection(displayWidth: 2560);

      expect(belowTwoX.scaleFactor, 1.5);
      expect(belowTwoX.usesSecondaryPass, isFalse);
      expect(belowTwoX.pipelineProfile, Anime4KProfile.clear);
      expect(belowTwoX.activeModeLabel, '强力增强（当前倍率采用单次增强）');
      expect(atTwoX.scaleFactor, 2.0);
      expect(atTwoX.usesSecondaryPass, isTrue);
      expect(atTwoX.pipelineProfile, Anime4KProfile.strong);

      final belowTwoXPipeline = Anime4KShaderManager.pipelineFor(
        belowTwoX.pipelineProfile,
        tier: belowTwoX.tier,
      );
      final atTwoXPipeline = Anime4KShaderManager.pipelineFor(
        atTwoX.pipelineProfile,
        tier: atTwoX.tier,
      );
      expect(
        belowTwoXPipeline.assetPaths.where(
          (path) => path.contains('Restore_CNN_'),
        ),
        hasLength(1),
      );
      expect(
        atTwoXPipeline.assetPaths.where(
          (path) => path.contains('Restore_CNN_'),
        ),
        hasLength(2),
      );
    });

    test('initial quality tier respects high frame-rate budgets', () {
      Anime4KSelection selection({
        required TargetPlatform platform,
        required Anime4KProfile profile,
        required double fps,
        int displayWidth = 1920,
        int displayHeight = 1080,
      }) {
        return Anime4KShaderManager.select(
          requestedProfile: profile,
          platform: platform,
          sourceWidth: 1280,
          sourceHeight: 720,
          displayWidth: displayWidth,
          displayHeight: displayHeight,
          sourceFramesPerSecond: fps,
        );
      }

      expect(
        selection(
          platform: TargetPlatform.windows,
          profile: Anime4KProfile.clear,
          fps: 24,
        ).tier,
        Anime4KTier.quality,
      );
      final desktop60 = selection(
        platform: TargetPlatform.windows,
        profile: Anime4KProfile.clear,
        fps: 59.94,
      );
      expect(desktop60.tier, Anime4KTier.balanced);
      expect(desktop60.frameRateLabel, '59.94fps');
      expect(
        selection(
          platform: TargetPlatform.windows,
          profile: Anime4KProfile.strong,
          fps: 60,
        ).tier,
        Anime4KTier.performance,
      );
      expect(
        selection(
          platform: TargetPlatform.android,
          profile: Anime4KProfile.strong,
          fps: 60,
        ).tier,
        Anime4KTier.performance,
      );
    });

    test('frame-rate parsing rejects unusable mpv values', () {
      expect(Anime4KShaderManager.parseFrameRate('59.940'), 59.94);
      expect(Anime4KShaderManager.parseFrameRate(24), 24);
      expect(Anime4KShaderManager.parseFrameRate('N/A'), isNull);
      expect(Anime4KShaderManager.parseFrameRate('0'), isNull);
      expect(Anime4KShaderManager.parseFrameRate('1000'), isNull);
    });

    test('settings migrate missing and invalid profile to automatic', () {
      expect(
        PlaybackSettings.fromJson(const {}).superResolutionProfile,
        'auto',
      );
      expect(
        PlaybackSettings.fromJson(const {
          'superResolutionProfile': 'unknown',
        }).superResolutionProfile,
        'auto',
      );
      expect(
        PlaybackSettings.fromJson(const {
          'superResolutionProfile': 'performance',
        }).superResolutionProfile,
        'low_resolution',
      );
      expect(
        PlaybackSettings.fromJson(const {
          'superResolutionProfile': 'quality',
        }).superResolutionProfile,
        'clear',
      );
      const settings = PlaybackSettings(
        superResolution: true,
        superResolutionProfile: 'advanced',
        superResolutionCustomShaders: [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Upscale_CNN_x2_M.glsl',
        ],
      );
      final restored = PlaybackSettings.fromJson(settings.toJson());
      expect(restored.superResolutionProfile, 'advanced');
      expect(
        restored.superResolutionCustomShaders,
        settings.superResolutionCustomShaders,
      );
    });
  });

  group('Anime4K mpv runtime', () {
    test(
      'falls back to a lighter profile and restores previous shaders',
      () async {
        final properties = <String, String>{
          'scale': 'bicubic',
          'glsl-shaders': 'user-shader.glsl',
        };
        final installed = <Anime4KTier>[];

        final runtime = Anime4KMpvRuntime(
          platform: TargetPlatform.windows,
          installPipeline: (profile, tier, _) async {
            installed.add(tier);
            return _installedPipeline(profile, tier: tier);
          },
          getProperty: (property) async => properties[property] ?? '',
          setProperty: (property, value) async {
            if (value.contains('_L.glsl')) {
              throw StateError('GPU rejected the high-quality shaders');
            }
            properties[property] = value;
          },
        );

        final result = await runtime.enable(
          Anime4KProfile.clear,
          requestedTier: Anime4KTier.quality,
        );

        expect(result.enabled, isTrue);
        expect(result.activeProfile, Anime4KProfile.clear);
        expect(result.activeTier, Anime4KTier.balanced);
        expect(result.usedFallback, isTrue);
        expect(installed, [Anime4KTier.quality, Anime4KTier.balanced]);
        expect(properties['glsl-shaders'], contains('Restore_CNN_M.glsl'));

        await runtime.disable();
        expect(properties['glsl-shaders'], 'user-shader.glsl');
      },
    );

    test('runtime shader failure continues below the active profile', () async {
      final properties = <String, String>{
        'scale': 'bicubic',
        'glsl-shaders': '',
      };
      final installed = <Anime4KTier>[];
      final runtime = Anime4KMpvRuntime(
        platform: TargetPlatform.android,
        installPipeline: (profile, tier, _) async {
          installed.add(tier);
          return _installedPipeline(profile, tier: tier);
        },
        getProperty: (property) async => properties[property] ?? '',
        setProperty: (property, value) async => properties[property] = value,
      );

      expect(
        (await runtime.enable(
          Anime4KProfile.clear,
          requestedTier: Anime4KTier.quality,
        )).activeTier,
        Anime4KTier.quality,
      );
      installed.clear();
      final fallback = await runtime.enable(
        Anime4KProfile.clear,
        requestedTier: Anime4KTier.quality,
        skipTier: Anime4KTier.quality,
      );

      expect(fallback.activeTier, Anime4KTier.balanced);
      expect(installed, [Anime4KTier.balanced]);
      expect(properties['glsl-shaders'], contains(':'));
      expect(properties['glsl-shaders'], isNot(contains(';')));
    });

    test('restores ordinary playback when every profile is rejected', () async {
      final properties = <String, String>{
        'scale': 'bicubic',
        'glsl-shaders': 'before.glsl',
      };
      final runtime = Anime4KMpvRuntime(
        platform: TargetPlatform.windows,
        installPipeline: (profile, tier, _) async =>
            _installedPipeline(profile, tier: tier),
        getProperty: (property) async => properties[property] ?? '',
        setProperty: (property, value) async {
          if (value.contains('Anime4K_')) return;
          properties[property] = value;
        },
      );

      final result = await runtime.enable(
        Anime4KProfile.clear,
        requestedTier: Anime4KTier.quality,
      );

      expect(result.enabled, isFalse);
      expect(result.failures, hasLength(3));
      expect(properties['glsl-shaders'], 'before.glsl');
    });

    test(
      'temporarily restores original shaders for visual comparison',
      () async {
        final properties = <String, String>{
          'scale': 'bicubic',
          'glsl-shaders': 'before.glsl',
        };
        final runtime = Anime4KMpvRuntime(
          platform: TargetPlatform.windows,
          installPipeline: (profile, tier, _) async =>
              _installedPipeline(profile, tier: tier),
          getProperty: (property) async => properties[property] ?? '',
          setProperty: (property, value) async => properties[property] = value,
        );

        await runtime.enable(
          Anime4KProfile.soft,
          requestedTier: Anime4KTier.balanced,
        );
        final enhanced = properties['glsl-shaders'];
        expect(enhanced, contains('Restore_CNN_Soft_M.glsl'));

        await runtime.setPreviewOriginal(true);
        expect(properties['glsl-shaders'], 'before.glsl');
        expect(runtime.previewingOriginal, isTrue);

        await runtime.setPreviewOriginal(false);
        expect(properties['glsl-shaders'], enhanced);
        expect(runtime.previewingOriginal, isFalse);
      },
    );
  });
}

Anime4KShaderPipeline _installedPipeline(
  Anime4KProfile profile, {
  Anime4KTier tier = Anime4KTier.balanced,
}) {
  final pipeline = Anime4KShaderManager.pipelineFor(profile, tier: tier);
  return pipeline.withInstalledPaths(
    pipeline.assetPaths
        .map((asset) => 'C:/shader/${asset.split('/').last}')
        .toList(),
  );
}
