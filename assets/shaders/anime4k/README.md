# Anime4K GLSL shaders

Loaded by the native `media_kit`/libmpv player through mpv's `glsl-shaders`
property. Web playback does not use them.

Source: https://github.com/bloc97/Anime4K (v4 shader set, commit
`7684e9586f8dcc738af08a1cdceb024cc184f426`)

License: MIT, except `Anime4K_AutoDownscalePre_x2.glsl` and
`Anime4K_AutoDownscalePre_x4.glsl`, which upstream released into the public
domain (Unlicense). Every file keeps its own upstream header.

## How the player picks a chain

Two independent choices, both the user's:

- **Tier** sets the CNN size. `quality` = VL with an M second pass, `balance` =
  M with an S second pass, `efficiency` = S with no second pass. `custom` skips
  the built-in chains and runs whatever the user assembled.
- **Mode** sets the chain shape: A, B, C and their stronger variants A+A, B+B,
  C+A. A targets 1080p sources, B targets 720p, C targets 480p and undamaged
  images.

`quality` and `balance` reproduce upstream's shipped High-end and Low-end
templates exactly, stage for stage. `efficiency` has no upstream counterpart:
dropping the second pass also drops the extra restore stage, so at that tier the
doubled modes collapse onto their single-pass form.

The tier the user picks is the tier that runs. There is no automatic downgrade
by platform, resolution, or frame rate, and no fallback to a lighter tier when a
chain fails to load -- a failure disables the feature and says so, because
silently substituting a weaker chain makes the setting a lie.

`test/anime4k_shader_manager_test.dart` pins every mode × tier chain against
upstream's templates, including the deliberate asymmetry where A+A restores
before the AutoDownscalePre pair while B+B and C+A restore after it.

## Catalog

All 49 shaders ship so the custom tier can offer the full set, including ones no
built-in chain uses: the GAN variants, the bilateral denoisers, the line
Darken/Thin passes, and `Anime4K_Upscale_Original_x2.glsl` (the v3.2-era
non-CNN upscaler).
