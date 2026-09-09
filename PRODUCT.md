# Zeluna Product

## Register

product

## Users

Viewers who browse and watch anime, series and movies on Windows, phones and tablets, using user-managed playback sources.

## Product Purpose

One calm, dependable place to discover a title, choose a working source and watch without losing playback progress or context.

## Brand Personality

Clear, calm, content-first. Use direct Chinese labels and a restrained theater environment; artwork and playback state carry the visual emphasis.

## Anti-references

Avoid decorative player chrome, crowded icon strips, inconsistent desktop/mobile controls, and hiding landscape features solely because the device is Android.

## Design Principles

- Reuse the established gallery/theater tokens and existing components.
- Keep desktop and landscape playback visually consistent; adapt spacing to width and retain touch gestures.
- Reserve simplified compact controls for portrait phones; keep full playback capabilities reachable in landscape.
- Show clear loading, source-failure and retry states without exposing internal provider details or credentials.
- Preserve existing accounts, settings and playback progress during iteration.

## Accessibility & Inclusion

Retain readable Chinese text, semantic tooltips, contrast, safe-area insets and usable touch targets; validate compact landscapes and increased text scaling. No formal accessibility certification is claimed.

Context: existing `.impeccable.md`, `lib/src/shared_ui/app_design.dart`, player components, and the user's 2026-09-09 request to reuse Windows player UI on Android landscape. No new visual theme or web live-mode setup is introduced.
