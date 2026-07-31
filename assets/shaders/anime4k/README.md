# Anime4K GLSL shaders

These shaders are used by the native `media_kit`/libmpv player through mpv's
`glsl-shaders` property. Web playback does not load them.

Source: https://github.com/bloc97/Anime4K (v4 shader set, commit
`7684e9586f8dcc738af08a1cdceb024cc184f426`)

License: MIT. Each shader contains the upstream license header.

Player modes:

- Auto: selects Low-resolution repair, Natural soft, or Animation clear from
  the source dimensions, aspect ratio, and actual enlargement ratio. Ordinary
  720p sources keep the softer Mode B pipeline, while substantially enlarged
  legacy 4:3 animation uses the more visible Mode A line reconstruction.
- Animation clear: restores blurred line art before CNN upscaling.
- Natural soft: uses the soft restoration model to avoid harsh outlines.
- Low-resolution repair: denoises 480p/low-bitrate sources while upscaling.
- Strong enhancement: adds the second restoration pass only at 2x or higher.
- Advanced: lets the user compose shaders from the packaged catalog.

Each automatic mode also selects a Performance, Balanced, or Quality tier from
the platform, output size, scale ratio, and detected frame rate. The player
falls back to a lighter tier when the active renderer starts dropping frames.

The older monolithic v3.2 shader remains packaged only for upgrade
compatibility and is no longer selected by the player.
