# Zeluna Engineering Goal Progress

## Background

本文件记录 Zeluna 从当前快速播放基线推进到产品级工程状态的可复现证据。AniCh 材料仅用于理解架构思路；项目不得依赖 AniCh API，也不得保存其真实播放 URL、域名池、Cookie 或采样结果。

## Baseline

- Branch: `codex/media-player-overhaul`
- Starting HEAD: `53872d3cb167e068c37069502b97f06cad414d05`
- Current HEAD: latest completed implementation stage `5ec8ec1` (use `git rev-parse HEAD` for the progress-only commit that follows)
- Started at: `2026-08-01T16:37:02+08:00`
- Production baseline reported at start: `53872d3`（本 Goal 不自动部署生产环境）

### Input evidence

| Material | SHA-256 |
| --- | --- |
| Engineering goal prompt | `C2E69A995128D0DDE21D8FAD6F85DE54465C18219A41B0037D098A36D5AEA6CA` |
| Zeluna engineering specification | `14B761C0050406881BA99D8DBFF1A38261906000C7BE41EFB9459D41143D4C1D` |
| AniCh instant-play analysis | `BC2A28F33590DD398C30904F5EB107FF2272575177267C3C819B87817BEDC370` |
| AniCh VOD sample | `125198C91FAAF3D52149DF682CAAA6B19E08972F49B0742949E18F8F3BF38855` |
| AniCh reverse report | `AD1F53877440F85960B7286FB08568639AF1EF12E3E0F0BC7F25ACE045E53B6A` |

### Initial validation

- Flutter focused playback tests: 109 passed.
- Server focused tests: 39 passed.
- Commands:
  - `flutter test test/anime_controller_playback_hedge_test.dart test/playback_line_display_test.dart test/rule_playback_resolver_test.dart test/zeluna_backend_playback_repository_test.dart test/playback_prefetch_cache_test.dart --reporter compact`
  - `python -m unittest tests.test_aggregator tests.test_v3_services -q` (from `server`)

## Scope and rules

- Follow stages G0 through G14 in order and keep one auditable commit per coherent stage.
- Preserve current fast playback behavior; do not tune playback concurrency or ranking without regression evidence.
- Never commit secrets, production databases, real signed media URLs, third-party cookies, packet captures, or private signing material.
- Production deployment, account operations, destructive migrations, and other external state changes require separate authorization.

## G0 Fast-start freeze

Status: completed

Audit:

- Confirmed that both Python and Dart classifiers treated the first `mdat` as tail-moov.
- This misclassified fragmented MP4 (`moof -> mdat`) and incomplete byte ranges.
- Existing tests already protect stale-cache immediate return, quick/full refresh separation, single-flight refresh, prefetch reuse, tail-moov fallback behavior, playback progress retention, first-frame/stall/recovery conditions, and HLS first-segment verification.

Changes:

- Python and Dart now classify classic MP4 only from provable `moov`/`mdat` ordering.
- Fragmented samples containing `styp`/`moof`, incomplete tail evidence, and unknown containers remain `unknown`.
- Client verification preserves an already-known startup profile when its own sample is inconclusive.
- Playback prefetch writes are guarded by cancellation and account-context revision.

Tests:

- MP4 matrix covers fast-start, tail-moov, fragmented MP4, `moof -> mdat`, incomplete Range, unknown container, HLS, and DASH.
- Database round-trip preserves `startup_profile` and `startup_latency_ms`.
- Explicit regressions cover cancelled prefetch writeback, account-switch isolation, stable equal-score ordering, quick/full separation, stale cache, single-flight, tail-moov fallback, and prefetch reuse.
- `flutter test --reporter compact`: 458 passed, 26 intentionally skipped.
- `python -m unittest discover -s tests -q`: 74 passed.
- `flutter analyze`: no issues.
- `git diff --check`: passed.

Builds: deferred to the cross-platform release gates in G13/G14; G0 changes no build or signing configuration.

Commit: `3a1c5ec test: freeze fast-start playback behavior`

Remaining risks:

- Deterministic tests do not measure current third-party network quality; that evidence belongs to release/production acceptance.
- Playback ranking and concurrency parameters are frozen after this stage unless a reproducible regression requires a change.

## G1 Stable identity and migration

Status: completed

Audit:

- Audited Dart/Python hash APIs, time/random IDs, short hashes, and array-index-derived identities across client and server sources.
- Persisted or API-visible subject, episode, playback-line, download-task, rule, repository, direct-media, and fallback display identities now use deterministic inputs. Python's process-randomized `hash()` and the known Dart `hashCode`, 32-bit FNV, timestamp, and array-index identity paths were removed.
- Remaining `hashCode`/`identityHashCode`/short-hash uses are limited to in-process maps, cancellation namespaces, visual danmaku lanes, display aliases, or deterministic daily sorting; player-created local/network lines and local danmaku IDs are session-only and are not persisted.
- Hive inventory contains four dynamic JSON boxes and no registered binary adapters: `anime.settings.v2`, `anime.library.v2`, `anime.accounts.v1`, and `anime.search.v1`. The identity migration schema is version 1 and operates only on identity-bearing rule/settings and library records. Account records already use persisted account/cloud IDs, while search history contains account-scoped strings and requires no media-identity rewrite.

Changes:

- Added matching Dart and Python `v1` identity primitives using UTF-8, SHA-256, framed components, and positive 63-bit integer derivation.
- Canonical URL identity lowercases scheme/host, removes only default ports and fragments, and preserves signed query order. Access-affecting headers enter a fingerprint; Cookie, Authorization, token, secret, and key values never enter an ID in plaintext.
- Added stable/legacy compatibility fields to subjects, episodes, downloads, rules, and rule repositories. Imported Animeko rule IDs no longer depend on array position and retain their old IDs as aliases.
- Replaced unstable identities in backend catalog/playback results, server fallback display IDs, rule playback lines, direct media, external subjects, downloads, manual rules, clipboard repositories, and danmaku cache keys.
- Added startup migration for global, guest, and account-scoped favorites, following, history/progress, image favorites, downloads, feedback subjects, metadata caches, and rule state. Each key uses one atomic Hive write followed by a resumable checkpoint marker.
- Duplicate records merge deterministically; the newest playback progress wins, completed/local download data wins, all old IDs and download paths are retained, and short-lived remote URLs/headers are removed so downloads resolve fresh playback credentials.
- Unconvertible records or malformed rule state remain byte-for-byte unchanged and are recorded in the migration marker. No box is cleared and no downloaded file is deleted.

Tests:

- Shared Dart/Python vectors cover digest bytes, canonical subjects/episodes, signed query order, sensitive header fingerprints, playback lines, downloads, rules, and 63-bit integers.
- Migration regressions cover deterministic duplicate merge, legacy alias/path preservation, account isolation, interruption after data write, idempotent resume, malformed whole-key retention, and position-dependent Animeko rule migration.
- Account migration tests verify the new stable download ID and preservation of the old `guest-download` alias.
- `flutter test --reporter compact`: 468 passed, 26 intentionally skipped.
- `python -m unittest discover -s tests -q`: 80 passed.
- `flutter analyze --suppress-analytics`: no issues.
- Dart format check, Python compile check, `git diff --check`, staged secret scan, and real-URL scan passed.

Builds: deferred to G13/G14; G1 changes no signing or packaging configuration.

Commits:

- `3250701 refactor: introduce stable identity primitives`
- `ce3d7ba migration: migrate persisted media identities`

Remaining risks:

- Migration behavior is verified against deterministic Hive fixtures and restart simulation; no private user Hive database was read or copied for this stage.
- Retained malformed legacy keys are reported in the marker but do not yet have a user-facing repair screen; privacy-safe reporting belongs to G12.
- Cross-platform signed release builds and rollback packaging remain G13/G14 gates.

## G2 Rule security

Status: completed

Audit:

- All imported rules, remote repositories, legacy rules, scripts, page URLs, and media URLs are treated as untrusted input. Only bundled rules declared in the local repository may retain `official` trust.
- Imported `official` and `communitySigned` claims cannot self-elevate trust. Without a configured trusted signature verifier, they are downgraded to `untrusted`, disabled by default, and require an explicit permission approval before use.
- Audited rule navigation, redirects, media probing, custom headers, cookies, enable/install paths, and Windows/native WebView lifecycle against the G2 permission boundary.

Changes:

- Added a complete rule permission manifest covering stable identity, name/version/engine, content types, repository and content hash, signature/trust level, page and media domains, JavaScript, WebView sniffing, cookie policy, cleartext HTTP, custom Referer/Origin/User-Agent, and minimum core version.
- Persisted approvals bind the rule ID to its permission digest. Rule content or permission changes invalidate old approval; ordinary toggles, install flows, and bulk enable operations cannot bypass authorization.
- Added the enable-time permission dialog showing source, content hash, trust level, page/media domains, JavaScript, cookies, WebView, HTTP, and custom headers.
- Separated page and media domain capabilities and revalidated every redirect. Dangerous schemes, user-info URLs, localhost and `.local`, loopback/private/link-local/multicast/metadata addresses, unapproved domains, and lookalike suffixes are rejected.
- Cross-origin redirects strip sensitive headers. Rules cannot persist or inject Authorization, proxy credentials, host/connection framing headers, internal tokens, passwords, or other secret-bearing state.
- WebView JavaScript follows the manifest; popup, new-window, download, external application, device permission, file access, local-network escape, and release debugging paths are denied by default.
- Windows WebView2 tasks execute serially and clear cookies, LocalStorage, SessionStorage, IndexedDB, Service Workers, WebStorage, and cache before/after each task. Promise-based cleanup uses the asynchronous JavaScript API so completion is observed before reuse.

Tests:

- Manifest, trust downgrade, approval invalidation, permission UI, enable/install/bulk-enable gates, page/media domain separation, dangerous URL and lookalike rejection, redirect revalidation, header stripping, cookie scoping, and persistence-secret regressions are covered by Flutter tests.
- Windows WebView2 integration builds the real Windows test host, rejects loopback navigation over three consecutive tasks, and verifies cookie plus LocalStorage, SessionStorage, IndexedDB, and Service Worker cleanup.
- `flutter test --reporter compact`: 484 passed, 26 intentionally skipped.
- `python -m unittest discover -s tests -q` (from `server`): 80 passed.
- `flutter test integration_test/animeko_webview_sniffer_integration_test.dart -d windows --reporter compact`: 2 passed.
- `flutter analyze --suppress-analytics`: no issues.
- Dart format, `git diff --check`, sensitive filename scan, and strong secret marker scan passed.

Builds: the Windows integration host was built and executed for the WebView2 boundary. Full cross-platform signed release builds remain deferred to G13/G14; G2 changes no signing configuration.

Commits:

- `40e11c8 security: add rule permission manifests`
- `837eba5 security: sandbox rule webview sessions`
- `5ec8ec1 test: verify rule webview storage cleanup`

Remaining risks:

- Windows WebView2 still uses a shared platform CookieManager/profile. G2 provides serialized task execution plus aggressive pre/post-task cleanup, but does not claim true independent-profile isolation.
- `communitySigned` remains `untrusted` until a trusted-key signature verifier is implemented and configured; a rule-provided signature is never accepted by itself.
- Android real-device WebView integration was not executed in this stage. Native behavior is covered by shared policy code and Flutter regressions, with device acceptance retained for G13/G14.

## G3 Network security

Status: not_started

## G4 CI and repository gates

Status: not_started

## G5 Player architecture

Status: not_started

## G6 Client domain architecture

Status: not_started

## G7 Server architecture

Status: not_started

## G8 Account and session security

Status: not_started

## G9 Privacy lifecycle

Status: not_started

## G10 Cloud sync

Status: not_started

## G11 Offline downloads

Status: not_started

## G12 Observability and policy documentation

Status: not_started

## G13 Release governance

Status: not_started

## G14 Final acceptance

Status: not_started

## Acceptance principle

Only mark a stage complete when its implementation, tests, build evidence, commit, and remaining risks are recorded here. A passing HTTP status alone is not playback evidence; media validation must reach a valid manifest/container and a readable first media segment where applicable.
