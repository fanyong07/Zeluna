import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/anime4k_shader_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Expected chains in stage order, written without the `Anime4K_` prefix and
/// `.glsl` suffix for legibility.
///
/// Transcribed from upstream's shipped templates
/// (`md/Template/GLSL_Windows_{High,Low}-end/input.conf`) and independently
/// confirmed by measuring AniCh 1.5.23 on Android: the shader files were made
/// unreadable so mpv logged the chain it tried to open, in order.
///
/// Note A+A restores again *before* the AutoDownscalePre pair while B+B and C+A
/// restore *after* it. That asymmetry is upstream's own.
const _quality = <Anime4KMode, String>{
  Anime4KMode.a: 'Clamp_Highlights|Restore_CNN_VL|Upscale_CNN_x2_VL|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_M',
  Anime4KMode.b: 'Clamp_Highlights|Restore_CNN_Soft_VL|Upscale_CNN_x2_VL|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_M',
  Anime4KMode.c: 'Clamp_Highlights|Upscale_Denoise_CNN_x2_VL|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_M',
  Anime4KMode.aa: 'Clamp_Highlights|Restore_CNN_VL|Upscale_CNN_x2_VL|'
      'Restore_CNN_M|AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_M',
  Anime4KMode.bb: 'Clamp_Highlights|Restore_CNN_Soft_VL|Upscale_CNN_x2_VL|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Restore_CNN_Soft_M|'
      'Upscale_CNN_x2_M',
  Anime4KMode.ca: 'Clamp_Highlights|Upscale_Denoise_CNN_x2_VL|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Restore_CNN_M|Upscale_CNN_x2_M',
};

const _balance = <Anime4KMode, String>{
  Anime4KMode.a: 'Clamp_Highlights|Restore_CNN_M|Upscale_CNN_x2_M|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_S',
  Anime4KMode.b: 'Clamp_Highlights|Restore_CNN_Soft_M|Upscale_CNN_x2_M|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_S',
  Anime4KMode.c: 'Clamp_Highlights|Upscale_Denoise_CNN_x2_M|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_S',
  Anime4KMode.aa: 'Clamp_Highlights|Restore_CNN_M|Upscale_CNN_x2_M|'
      'Restore_CNN_S|AutoDownscalePre_x2|AutoDownscalePre_x4|Upscale_CNN_x2_S',
  Anime4KMode.bb: 'Clamp_Highlights|Restore_CNN_Soft_M|Upscale_CNN_x2_M|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Restore_CNN_Soft_S|'
      'Upscale_CNN_x2_S',
  Anime4KMode.ca: 'Clamp_Highlights|Upscale_Denoise_CNN_x2_M|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4|Restore_CNN_S|Upscale_CNN_x2_S',
};

/// The efficiency tier has no upstream counterpart. It runs at S with no
/// secondary size, so every stage that would use one is dropped -- which
/// collapses the doubled modes onto their single-pass form. Measured for both
/// Mode A and Mode A+A on AniCh.
const _efficiency = <Anime4KMode, String>{
  Anime4KMode.a: 'Clamp_Highlights|Restore_CNN_S|Upscale_CNN_x2_S|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4',
  Anime4KMode.b: 'Clamp_Highlights|Restore_CNN_Soft_S|Upscale_CNN_x2_S|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4',
  Anime4KMode.c: 'Clamp_Highlights|Upscale_Denoise_CNN_x2_S|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4',
  Anime4KMode.aa: 'Clamp_Highlights|Restore_CNN_S|Upscale_CNN_x2_S|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4',
  Anime4KMode.bb: 'Clamp_Highlights|Restore_CNN_Soft_S|Upscale_CNN_x2_S|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4',
  Anime4KMode.ca: 'Clamp_Highlights|Upscale_Denoise_CNN_x2_S|'
      'AutoDownscalePre_x2|AutoDownscalePre_x4',
};

List<String> _expand(String compact) => compact
    .split('|')
    .map((name) => 'Anime4K_$name.glsl')
    .toList(growable: false);

void _expectChains(Anime4KTier tier, Map<Anime4KMode, String> expected) {
  for (final entry in expected.entries) {
    expect(
      entry.key.fileNames(tier),
      _expand(entry.value),
      reason: '${tier.settingValue} / ${entry.key.settingValue}',
    );
  }
}

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

  group('Anime4K chains', () {
    test('quality tier matches upstream High-end templates', () {
      _expectChains(Anime4KTier.quality, _quality);
    });

    test('balance tier matches upstream Low-end templates', () {
      _expectChains(Anime4KTier.balance, _balance);
    });

    test('efficiency tier drops every secondary-size stage', () {
      _expectChains(Anime4KTier.efficiency, _efficiency);
    });

    test('doubled modes collapse onto their single pass at efficiency', () {
      for (final pair in const [
        [Anime4KMode.aa, Anime4KMode.a],
        [Anime4KMode.bb, Anime4KMode.b],
        [Anime4KMode.ca, Anime4KMode.c],
      ]) {
        expect(
          pair[0].fileNames(Anime4KTier.efficiency),
          pair[1].fileNames(Anime4KTier.efficiency),
        );
      }
    });

    test('every built-in chain is clamped first and free of duplicates', () {
      for (final tier in const [
        Anime4KTier.quality,
        Anime4KTier.balance,
        Anime4KTier.efficiency,
      ]) {
        for (final mode in Anime4KMode.values) {
          final assets = Anime4KShaderManager.pipelineFor(
            tier,
            mode: mode,
          ).assetPaths;
          expect(assets, isNotEmpty);
          expect(assets.toSet(), hasLength(assets.length));
          expect(assets.first, endsWith('Anime4K_Clamp_Highlights.glsl'));
        }
      }
    });

    test('every referenced shader is a bundled asset', () {
      for (final tier in const [
        Anime4KTier.quality,
        Anime4KTier.balance,
        Anime4KTier.efficiency,
      ]) {
        for (final mode in Anime4KMode.values) {
          for (final name in mode.fileNames(tier)) {
            expect(
              Anime4KShaderManager.availableShaderFileNames,
              contains(name),
            );
          }
        }
      }
    });

    test('custom tier has no built-in pipeline', () {
      expect(
        () => Anime4KMode.a.fileNames(Anime4KTier.custom),
        throwsArgumentError,
      );
    });

    test('custom tier keeps only known shaders in catalog order', () {
      final pipeline = Anime4KShaderManager.pipelineFor(
        Anime4KTier.custom,
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
  });

  group('Anime4K settings', () {
    test('migrates the legacy profile values onto tiers', () {
      expect(Anime4KTier.fromSetting('performance'), Anime4KTier.efficiency);
      expect(Anime4KTier.fromSetting('balanced'), Anime4KTier.balance);
      expect(Anime4KTier.fromSetting('advanced'), Anime4KTier.custom);
      for (final legacy in const ['auto', 'clear', 'soft', 'strong']) {
        expect(Anime4KTier.fromSetting(legacy), Anime4KTier.quality);
      }
      expect(Anime4KTier.fromSetting(null), Anime4KTier.quality);
      expect(Anime4KTier.fromSetting('nonsense'), Anime4KTier.quality);
    });

    test('every mode explains its trade-off distinctly', () {
      final details = <String>{};
      for (final mode in Anime4KMode.values) {
        expect(mode.bestFor, isNotEmpty);
        expect(mode.upside, isNotEmpty);
        // The downside matters most: a wrong mode degrades the picture rather
        // than merely costing frames, so it must never be blank.
        expect(mode.downside, isNotEmpty);
        expect(mode.detailedDescription, contains(mode.bestFor));
        expect(mode.detailedDescription, contains(mode.downside));
        details.add(mode.detailedDescription);
      }
      expect(details, hasLength(Anime4KMode.values.length));
    });

    test('every tier explains what it costs', () {
      final descriptions = <String>{};
      for (final tier in Anime4KTier.values) {
        expect(tier.label, isNotEmpty);
        expect(tier.description, isNotEmpty);
        descriptions.add(tier.description);
      }
      expect(descriptions, hasLength(Anime4KTier.values.length));
    });

    test('falls back to mode A for unknown mode values', () {
      for (final mode in Anime4KMode.values) {
        expect(Anime4KMode.fromSetting(mode.settingValue), mode);
      }
      expect(Anime4KMode.fromSetting(null), Anime4KMode.a);
      expect(Anime4KMode.fromSetting('zz'), Anime4KMode.a);
    });

    test('PlaybackSettings round-trips the tier and mode', () {
      const settings = PlaybackSettings(
        superResolution: true,
        superResolutionTier: 'balance',
        superResolutionMode: 'bb',
      );
      final restored = PlaybackSettings.fromJson(settings.toJson());

      expect(restored.superResolution, isTrue);
      expect(restored.superResolutionTier, 'balance');
      expect(restored.superResolutionMode, 'bb');
    });

    test('defaults to the strongest tier with mode A', () {
      const settings = PlaybackSettings();
      expect(settings.superResolutionTier, 'quality');
      expect(settings.superResolutionMode, 'a');
    });

    test('reads a stored legacy superResolutionProfile key', () {
      final restored = PlaybackSettings.fromJson(const {
        'superResolution': true,
        'superResolutionProfile': 'performance',
      });

      expect(restored.superResolutionTier, 'efficiency');
      expect(restored.superResolutionMode, 'a');
    });

    test('rejects out-of-vocabulary stored values', () {
      final restored = PlaybackSettings.fromJson(const {
        'superResolutionTier': 'turbo',
        'superResolutionMode': 'q',
      });

      expect(restored.superResolutionTier, 'quality');
      expect(restored.superResolutionMode, 'a');
    });
  });

  group('Anime4K selection', () {
    Anime4KSelection selection({
      required int displayWidth,
      required int displayHeight,
      Anime4KTier tier = Anime4KTier.quality,
      Anime4KMode mode = Anime4KMode.a,
    }) {
      return Anime4KSelection(
        tier: tier,
        mode: mode,
        sourceWidth: 1920,
        sourceHeight: 1080,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
      );
    }

    test('reports enlargement only past the AutoDownscalePre threshold', () {
      // AutoDownscalePre_x2 only engages above 1.2x, per its own //!WHEN guard.
      expect(
        selection(displayWidth: 1920, displayHeight: 1080).expectsUpscale,
        isFalse,
      );
      expect(
        selection(displayWidth: 2560, displayHeight: 1440).expectsUpscale,
        isTrue,
      );
      expect(
        selection(displayWidth: 1080, displayHeight: 608).expectsUpscale,
        isFalse,
      );
    });

    test('describes the resolution change and the active chain', () {
      final enlarged = selection(displayWidth: 2560, displayHeight: 1440);
      expect(enlarged.resolutionDescription(), '片源 1920×1080 → 超分至 2560×1440');
      expect(enlarged.activeModeLabel, '模式A · 质量');

      final sameSize = selection(
        displayWidth: 1920,
        displayHeight: 1080,
        tier: Anime4KTier.balance,
        mode: Anime4KMode.ca,
      );
      expect(
        sameSize.resolutionDescription(),
        '片源 1920×1080 · 显示区域 1920×1080 · 画质修复',
      );
      expect(sameSize.activeModeLabel, '模式C+A · 均衡');
      expect(
        sameSize.resolutionDescription(previewingOriginal: true),
        '片源 1920×1080 · 显示区域 1920×1080 · 原画',
      );
    });

    test('labels the custom tier without a mode', () {
      final custom = selection(
        displayWidth: 2560,
        displayHeight: 1440,
        tier: Anime4KTier.custom,
      );
      expect(custom.activeModeLabel, '高级 · 自定义组合');
    });

    test('reports unknown dimensions instead of guessing', () {
      const unknown = Anime4KSelection(
        tier: Anime4KTier.quality,
        mode: Anime4KMode.a,
        sourceWidth: 0,
        sourceHeight: 0,
        displayWidth: 0,
        displayHeight: 0,
      );
      expect(unknown.hasKnownDimensions, isFalse);
      expect(unknown.scaleFactor, 1);
      expect(unknown.resolutionDescription(), '正在识别片源尺寸');
    });
  });
}
