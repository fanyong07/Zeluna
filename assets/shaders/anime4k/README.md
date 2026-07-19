# Anime4K GLSL shaders

These shaders are used by the native `media_kit`/libmpv player through mpv's
`glsl-shaders` property. Web playback does not load them.

Source: https://github.com/bloc97/Anime4K (v4 shader set, commit
`7684e9586f8dcc738af08a1cdceb024cc184f426`)

License: MIT. Each shader contains the upstream license header.

Profiles:

- Performance: a reduced Mode C pipeline intended as the mobile fallback.
- Balanced: the official v4 low-end Mode A pipeline.
- Quality: the official v4 high-end Mode A pipeline.

The older monolithic v3.2 shader remains packaged only for upgrade
compatibility and is no longer selected by the player.
