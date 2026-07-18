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
      for (final profile in Anime4KProfile.values) {
        final assets = Anime4KShaderManager.pipelineFor(profile).assetPaths;
        expect(assets, isNotEmpty);
        expect(assets.toSet(), hasLength(assets.length));
        expect(assets.first, endsWith('Anime4K_Clamp_Highlights.glsl'));
      }

      final balanced = Anime4KShaderManager.pipelineFor(
        Anime4KProfile.balanced,
      ).assetPaths;
      expect(balanced, contains(endsWith('Anime4K_Restore_CNN_M.glsl')));
      expect(balanced, contains(endsWith('Anime4K_Upscale_CNN_x2_M.glsl')));

      final quality = Anime4KShaderManager.pipelineFor(
        Anime4KProfile.quality,
      ).assetPaths;
      expect(quality, contains(endsWith('Anime4K_Restore_CNN_VL.glsl')));
      expect(quality, contains(endsWith('Anime4K_Upscale_CNN_x2_VL.glsl')));
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

    test('settings migrate missing and invalid profile to balanced', () {
      expect(
        PlaybackSettings.fromJson(const {}).superResolutionProfile,
        'balanced',
      );
      expect(
        PlaybackSettings.fromJson(const {
          'superResolutionProfile': 'unknown',
        }).superResolutionProfile,
        'balanced',
      );
      const settings = PlaybackSettings(
        superResolution: true,
        superResolutionProfile: 'quality',
      );
      expect(
        PlaybackSettings.fromJson(settings.toJson()).superResolutionProfile,
        'quality',
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
        final installed = <Anime4KProfile>[];

        final runtime = Anime4KMpvRuntime(
          platform: TargetPlatform.windows,
          installPipeline: (profile) async {
            installed.add(profile);
            return _installedPipeline(profile);
          },
          getProperty: (property) async => properties[property] ?? '',
          setProperty: (property, value) async {
            if (value.contains('_VL.glsl')) {
              throw StateError('GPU rejected the high-quality shaders');
            }
            properties[property] = value;
          },
        );

        final result = await runtime.enable(Anime4KProfile.quality);

        expect(result.enabled, isTrue);
        expect(result.activeProfile, Anime4KProfile.balanced);
        expect(result.usedFallback, isTrue);
        expect(installed, [Anime4KProfile.quality, Anime4KProfile.balanced]);
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
      final installed = <Anime4KProfile>[];
      final runtime = Anime4KMpvRuntime(
        platform: TargetPlatform.android,
        installPipeline: (profile) async {
          installed.add(profile);
          return _installedPipeline(profile);
        },
        getProperty: (property) async => properties[property] ?? '',
        setProperty: (property, value) async => properties[property] = value,
      );

      expect(
        (await runtime.enable(Anime4KProfile.quality)).activeProfile,
        Anime4KProfile.quality,
      );
      installed.clear();
      final fallback = await runtime.enable(
        Anime4KProfile.quality,
        skipProfile: Anime4KProfile.quality,
      );

      expect(fallback.activeProfile, Anime4KProfile.balanced);
      expect(installed, [Anime4KProfile.balanced]);
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
        installPipeline: (profile) async => _installedPipeline(profile),
        getProperty: (property) async => properties[property] ?? '',
        setProperty: (property, value) async {
          if (value.contains('Anime4K_')) return;
          properties[property] = value;
        },
      );

      final result = await runtime.enable(Anime4KProfile.quality);

      expect(result.enabled, isFalse);
      expect(result.failures, hasLength(3));
      expect(properties['glsl-shaders'], 'before.glsl');
    });
  });
}

Anime4KShaderPipeline _installedPipeline(Anime4KProfile profile) {
  final pipeline = Anime4KShaderManager.pipelineFor(profile);
  return pipeline.withInstalledPaths(
    pipeline.assetPaths
        .map((asset) => 'C:/shader/${asset.split('/').last}')
        .toList(),
  );
}
