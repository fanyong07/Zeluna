# Zeluna Engineering Goal Progress

## Background

本文件记录 Zeluna 从当前快速播放基线推进到产品级工程状态的可复现证据。AniCh 材料仅用于理解架构思路；项目不得依赖 AniCh API，也不得保存其真实播放 URL、域名池、Cookie 或采样结果。

## Baseline

- Branch: `codex/media-player-overhaul`
- Starting HEAD: `53872d3cb167e068c37069502b97f06cad414d05`
- Current HEAD: latest completed implementation slice `6df6e52` (use `git rev-parse HEAD` for the progress-only commit that follows)
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

### Full-read inventory (2026-08-02)

| Material | Exists | Bytes | Lines | Parse/read result |
| --- | --- | ---: | ---: | --- |
| `CODEX_ZELUNA_ENGINEERING_SPEC.md` | yes | 49,249 | 2,339 | strict UTF-8, fully read |
| `AniCh-1.5.21-reverse-report.md` | yes | 21,367 | 480 | strict UTF-8, fully read |
| `AniCh-video-sources-and-instant-play.md` | yes | 24,959 | 628 | strict UTF-8, fully read |
| `vod_sources_sample.json` | yes | 914,486 | 21,343 | strict UTF-8 and JSON parse passed; 15 top-level entries, 79 samples, 1,076 line items |

Inventory result: `total=4`, `read=4`, `skipped=0`. The hashes above were recomputed from the complete byte streams. The AniCh reports and JSON remain historical architecture evidence only: no production API was called, and no sampled endpoint, private implementation, access token, or fixed real route was copied into Zeluna.

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

Status: completed

Audit:

- Classified every external request as `accountBackend`, `officialPlaybackBackend`, `selfHostedPlaybackBackend`, `rulePage`, `mediaResource`, or `metadataApi`; production call sites no longer obtain an untyped default client.
- Audited redirects, DNS results, literal addresses, TLS, credentials, cancellation, timeouts, decompressed response limits, HLS children, offline downloads, Android manifests, and self-hosted HTTP configuration.
- The final raw download client was replaced after the initial G3 audit. Single-file, playlist, variant, audio, map, and segment requests now share the same public-only transport boundary.

Changes:

- Added typed request policies with HTTPS requirements, public-address checks before connection, TLS verification, direct connections, timeouts, decompressed-body limits, API redirect rejection, and sensitive-header rejection on cleartext HTTP.
- Public media requests use explicit redirect handling. Every hop is revalidated and cross-origin Authorization, Cookie, token, API-key, secret, signature, and credential headers are removed before the next request.
- HLS manifests and every child resource repeat the public-network check. Offline downloads retain cancellation, Range/If-Range, resume validation, and streaming I/O while using a separate bounded 64 GiB response ceiling instead of the 512 KiB playback-probe limit.
- Clash-style synthetic DNS compatibility is restricted to trusted HTTPS hostname resolution and backend-confirmed media; arbitrary private, metadata, special-purpose, and literal benchmark addresses remain blocked outside that narrow media case.
- Account, official playback, self-hosted playback, rule import/runtime, metadata, danmaku, Kazumi, TVBox/XBPQ, M3U, external-source, and offline-download transports now use an explicit policy or dedicated public-only implementation.
- Self-hosted HTTP is disabled by default, requires advanced mode plus a second risk confirmation, is visibly marked insecure, can be disabled again, and never carries cloud-account credentials.
- Android main/release manifests deny cleartext globally. Debug permits cleartext only for `localhost` and `10.0.2.2`; release uses system trust anchors and does not trust user certificates.

Tests:

- Network regressions cover service classification, HTTPS/credential rules, private and special addresses, DNS-rebinding connection checks, redirects, decompressed limits, header stripping, Fake-IP compatibility, HLS private children, and full-download streams larger than the playback-probe limit.
- Account, catalog/playback, rule import/runtime, metadata, danmaku, Kazumi, TVBox/XBPQ, external-source, self-hosted warning, and download pause/resume/cancel tests cover the migrated call sites.
- `flutter test --reporter expanded`: 502 passed, 26 intentionally skipped, 0 failed.
- `python -m unittest discover -s tests -q` (from `server`): 80 passed.
- `flutter analyze --suppress-analytics`: no issues.
- Dart format and `git diff --check` passed. The sensitive-filename scan found only the tracked `server/.env.example` template; the strong-secret marker scan found no files.

Builds:

- `flutter build apk --debug --suppress-analytics` passed. Artifact: `build/app/outputs/flutter-apk/app-debug.apk`, 235,860,214 bytes, SHA-256 `6857D641CCDAD1AAD8A551C7531F5FD98C679DDC6218F2135CF14EE528EC15CA`.
- Release manifest processing reached the packaged-manifest output. Main, merged, and packaged release manifests all contain `usesCleartextTraffic="false"` and `networkSecurityConfig="@xml/network_security_config"`.
- No signed release package was created and no signing material was read; signed cross-platform release gates remain G13/G14 work.

Commits:

- `f8c42ad security: enforce typed network policies`
- `1c02a08 security: gate self-hosted HTTP access`
- `78b1152 security: deny Android release cleartext`
- `e159987 security: harden untrusted network transports`
- `a8f6583 security: secure default media clients`
- `c590fb2 security: harden media download transport`

Remaining risks:

- Native Android/Windows clients validate the actual DNS-selected connection address. A browser controls Web DNS and sockets, so Web can enforce URI, scheme, literal-host, redirect, header, timeout, and response limits but cannot independently re-check the browser's resolved socket address.
- Synthetic-DNS media compatibility intentionally permits the benchmark range only after a trusted media path identifies it; this exception remains covered by negative private-network regressions and must not be generalized.
- Android real-device cleartext and DNS-rebinding acceptance remains a G13/G14 release gate; G3 validated policy code, manifests, packaged manifest output, tests, and the Debug APK.

## G4 CI and repository gates

Status: completed

Changes:

- Added one pinned `Quality Gates` workflow for Flutter formatting, analysis and tests; Android Debug; Windows Release plus the real WebView lifecycle integration test; Web Release; Python/Alembic/Ruff/pip-audit; and repository supply-chain checks.
- Added Dependabot for GitHub Actions, pub, and Python dependencies. Third-party Actions are pinned by commit and workflow permissions are read-only.
- Replaced the parallel Python requirements files with a single committed `server/uv.lock`; CI installs with `uv sync --frozen --all-groups`.
- Added repeatable Alembic migration coverage for empty, legacy, current, cached, incompatible, backed-up, pragma-preserving, and repeated-run database states.
- Added repository artifact scanning that rejects real environment files, private keys, signing material, databases/backups, cookies, tokens, and strong secret markers without reading allowed local private files.
- Added Dart and Python license allow-list checks, Python vulnerability auditing, dependency advisory checks, and deterministic Flutter/Python CycloneDX SBOM generation.
- Recorded the vendored Windows WebView fork's package, upstream tag/commit, Apache-2.0 license, behavioral patch list, and update procedure.
- Built the locked `jsf` Linux shared library before VM tests so Linux exercises Drpy instead of silently skipping its native runtime. Made the playback hedge regression tolerant of the intended concurrent fallback while still proving that the backend candidate is probed only once.
- Added the Microsoft STL compatibility definition required by MSVC 14.51 to the local WebView fork and recorded it in the fork patch manifest.

Validation:

- Local `flutter test --reporter compact`: 502 passed, 26 intentionally skipped, 0 failed.
- Local `flutter analyze --suppress-analytics`: no issues; tracked Dart formatting and `git diff --check` passed.
- Local server suite: 93 tests plus 3 subtests passed; focused Alembic suite: 9 passed; Ruff, compileall, pip-audit, secret scan, Dart/Python license checks, and both SBOM generators passed.
- Local Android Debug, Web Release, and Windows Release builds passed. Windows WebView integration: 2 passed.
- `actionlint` 1.7.12 passed before the first remote run; the final workflow was then parsed and fully exercised by GitHub Actions.
- GitHub Actions Run `30702578325` completed successfully on commit `473e6aa`: Flutter, Android, Windows/WebView, Web, Python/Alembic, and supply-chain jobs all passed. The Linux JavaScript runtime build and the Windows MSVC 14.51 build both passed in their target environments.

Commits:

- `c4d8a18 build: lock server dependencies with uv`
- `f454c61 ci: add cross-platform quality gates`
- `411dded docs: record Windows WebView fork provenance`
- `cd966f5 style: enforce tracked Dart formatting`
- `473e6aa ci: fix cross-platform quality gates`

Remaining risks:

- The Windows build still reports upstream CMake `CMP0175` and third-party compiler warnings. They do not fail the build or tests, but should be re-evaluated when the vendored WebView baseline is upgraded.
- G4 validates unsigned/debug development artifacts and release compilation only. Signing identity, installer/package production, real-device acceptance, provenance publication, and production deployment remain G13/G14 work; no signing material was read or committed.

## G5 Player architecture

Status: completed

Changes:

- Reduced `PlayerPage` from the G0 baseline of 7,130 lines to 2,310 lines. The page now composes player services, renders state, wires player/page lifecycle events, and dispatches user input instead of owning every playback subsystem.
- Added an explicit playback-session state machine for idle, discovery, opening, buffering, playback, pause, recovery, failure, completion, and disposal, with ordered events for lookup, verification, first frame, timeouts, failures, line/episode changes, seeking, lifecycle changes, and playback completion.
- Moved line inventory, quick lookup, progressive lookup, single-backup preparation, request serials, cancellation tokens, stream subscription, and scan progress into `PlaybackLineRepository`. Selection preference, failure quarantine, loaded-media preservation, and next-line choice are owned by `PlaybackLineController`; concurrent recovery, same-line retry, backup scheduling, and stall state are owned by `PlaybackRecoveryController`.
- Moved media-kit objects, native subscriptions, delayed resume seeking, and first-frame soft/hard timeout polling into the native video controller. Web player commands and soft/hard startup watchdogs are owned by the Web video controller. Stale opens, replacement watchdogs, first-frame progress, and disposal all invalidate delayed callbacks.
- Moved gesture focus/chrome timers, Anime4K shader queue/degradation/performance sampling, danmaku requests/local timers, subtitle player callbacks, and their disposal boundaries into dedicated controllers.
- Split the player canvas, chrome, panels, mobile layout, and desktop layout into focused `part` files while preserving the existing page API and visual behavior.

Tests:

- Regression coverage includes first frame, native resume seeking, automatic line switching, one same-line retry, soft and hard timeout, stall watchdog, manual alternative selection, episode changes, Web autoplay rejection, Anime4K degradation, parallel danmaku, subtitles, disposal without late callbacks, account-context changes, application foreground/background, and performance-event ordering.
- `flutter test --reporter json`: 544 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart formatting and `git diff --check` passed.
- Replaced the playback-hedge test's wall-clock race with an explicit rule-resolution gate; the test now deterministically exercises the intended client-probe-first branch under parallel load.

Builds:

- `flutter build apk --debug --suppress-analytics` passed. Artifact: `build/app/outputs/flutter-apk/app-debug.apk`, 268,863,539 bytes, SHA-256 `7F81607E2AAD9A22ABD608525D9966FD9E73CA548549F2ACBF831A115E8DE8AC`.
- `flutter build web --release --suppress-analytics` passed. `build/web/main.dart.js` is 4,780,243 bytes, SHA-256 `BF72ACA0541DDCF9B510DC3B5CFF4BE54B9853C406F17E53365CC9511E5FEB99`.
- `flutter build windows --release --suppress-analytics` passed. Artifact: `build/windows/x64/runner/Release/Zeluna.exe`; compiled Dart payload `data/app.so` is 13,370,288 bytes.

Commits:

- `a276742 refactor: add playback session state machine`
- `78c2fe0 refactor: own native player resources`
- `ad98d52 refactor: own web player startup lifecycle`
- `454b723 refactor: own playback recovery timers`
- `24524e7 refactor: own playback line lookup resources`
- `b3d1034 refactor: own player gesture resources`
- `0142a0e refactor: own danmaku resources`
- `178215f refactor: own subtitle player callbacks`
- `8b1739d refactor: own anime4k runtime lifecycle`
- `59c997c refactor: split player ui modules`
- `23c38fb refactor: own native resume seeking`
- `3d1b5ef refactor: own playback recovery state`
- `9915af3 refactor: own playback line selection`
- `656bf7b test: remove playback hedge timing race`
- `8b885a2 refactor: own playback line discovery`
- `357a427 refactor: own playback startup watchdogs`

Remaining risks:

- Windows still reports the upstream WebView CMake `CMP0175` developer warning recorded in G4; it does not fail the Release build.
- G5 validates deterministic controller behavior and development/release compilation. Real-device playback, signed release artifacts, installer/package production, and production deployment remain G13/G14 gates; no signing material was read and no production environment was changed.

## G6 Client domain architecture

Status: in_progress

### AccountController

Audit:

- Account lifecycle ownership was concentrated in `AnimeController`: the local repository, active account, serialized operation queue, session restore, registration migration, credential migration, deletion recovery, and account-context revision all shared the aggregate controller's mutable state.
- Account changes also need explicit ports into settings/library scope loading, download quiescence and cleanup, credential selection, and playback/source cache invalidation. Those cross-domain effects cannot be silently removed while the remaining G6 domains still use the compatibility controller.

Changes:

- Added an independent `AccountController` that owns local/cloud account state, monotonic context revisions, serialized operations, startup recovery, registration/login/logout, profile/password flows, guest-data and secure-credential migration, account deletion, and retryable cleanup.
- Kept account-scoped settings/library migration deterministic and resumable. The controller still preserves pending non-secret markers on secure-store failure, never clears a Hive box, and deletes only paths already recorded for the account being removed.
- `AnimeController` now exposes the existing public account API as a compatibility adapter. Typed callbacks isolate the still-unmigrated Settings and Downloads domains, apply account-scoped state, quiesce active downloads, clear stale playback/source caches, and publish session/profile changes.
- Preserved the zero-version account-context behavior used by lightweight test adapters that override `AnimeController.build`, while production context ownership remains in `AccountController`.
- Reduced `AnimeController` from 4,400 to 4,074 lines after this first G6 domain slice.

Tests:

- Added a direct ownership regression proving that concurrent account changes serialize through one queue, scope activations receive monotonic revisions, profile changes persist to the selected account, sign-out invalidates the old context, and cross-domain callbacks run in order.
- Existing regressions continue to cover first-account guest import, account isolation, concurrent login ordering, password reset, interrupted registration, Bangumi/TMDB credential migration retries, stale credential rejection after account switching, deletion interruption/recovery, account UI, cloud/local repositories, download scope, and playback hedge behavior.
- Focused account/cross-domain suite: 41 passed, 0 failed.
- `catalog_page_test.dart`: 20 passed, 2 intentionally skipped, 0 failed after retaining compatibility for build-overriding test controllers.
- Full `flutter test --reporter json`: 545 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart format, staged `git diff --check`, and the repository security gate passed.

Builds: not run for this behavior-preserving domain slice. Android, Windows, and Web builds remain mandatory before G6 is marked completed.

Commit: `6f0f9ba refactor: split account controller`

Remaining domains, in required order: Sources, Downloads, Library, Catalog, PlaybackDiscovery, Sync.

Remaining risks:

- Account scope activation still calls compatibility adapters inside `AnimeController`; those adapters will shrink as Settings, Sources, Downloads, Library, Catalog, and PlaybackDiscovery acquire their own owners.
- Real signed-device and production account acceptance remains G13/G14 work. No signing material, production secret, real user database, or production environment was accessed.

### SettingsController

Audit:

- Playback, home, appearance, danmaku, miscellaneous, external-service, network, advanced-mode, and security-related settings were parsed, published, persisted, and given runtime side effects directly inside `AnimeController`.
- Concurrent settings writes had no explicit owner or ordering guarantee. Account changes flushed Hive but could not await a newly scheduled settings write before migrating or loading a different account scope.
- The previous external-service change signature omitted playback-backend endpoint and trust-mode fields, so changing the backend could leave prefetched lines from the old endpoint in memory.

Changes:

- Added an independent `SettingsController` with a typed `SettingsSnapshot`, account/context scope, defensive JSON restore, centralized service normalization, ordered persistence queue, and explicit ports for state publication, screen-wake behavior, and cache invalidation.
- Account activation now loads all six settings groups through the settings owner. Account changes await the settings write queue before migrating or swapping scope, while late writes continue targeting only the account captured when the user made the change.
- Miscellaneous and external-service side effects carry mutation and account-context guards, so an old account cannot toggle wake lock or invalidate a new account after a delayed write.
- Playback-backend endpoint, self-hosted mode, and insecure-HTTP confirmation now form a dedicated change signature. Backend changes clear only playback discovery caches; metadata cache refresh remains separately classified.
- `AnimeController` retains the public settings methods as compatibility delegates and fell from 4,074 to 3,959 lines.

Tests:

- Added direct regressions for account-scoped restore/persistence, deterministic normalization, insecure self-hosted confirmation, stale cross-account side-effect suppression, backend-change classification, and ordered writes.
- Settings, account switching, catalog/navigation, metadata credentials, playback backend, application rebuild, and chrome-layout focused regressions: 59 passed, 2 intentionally skipped, 0 failed.
- Full `flutter test --reporter json`: 547 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart format, staged `git diff --check`, and the repository security gate passed.

Builds: not run for this behavior-preserving domain slice. Android, Windows, and Web builds remain mandatory before G6 is marked completed.

Commit: `2a2e873 refactor: split settings controller`

Remaining risks:

- External-service cache invalidation still crosses compatibility ports into the future Catalog and PlaybackDiscovery controllers; no playback ranking or concurrency parameter changed.
- Sensitive third-party credentials remain in their existing dedicated stores or existing legacy model fields. G8/G10 must enforce final token lifecycle and sync exclusions without logging or migrating real secrets.

### SourceController

Audit:

- Rule installation, permission approval, repository refresh/import, source toggles, persistence, and XBPQ hydration were owned directly by `AnimeController`. Rule writes had no explicit serialized owner, while repository import and hydration used separate account checks and a global refresh counter.
- A repository refresh could retain URLs from an old account and, after an account switch, begin a later URL import in the new account. A scope transition could also overlap an old page mutation while the new source catalog was still loading.
- The bundled v3 `sources_catalog.json` is intentionally empty under the unified-backend product flow. This slice must preserve that boundary rather than silently restoring legacy third-party source inventory or startup hydration.

Changes:

- Added an independent `SourceController` owning rule inventory, repositories, trust and permission decisions, catalog enabled state, repository imports, hydration generations, account/context scope, and ordered persistence.
- Account-scope loading and rule/source mutations now share one serial queue. Loading marks the domain unavailable until the complete rules-plus-catalog snapshot is ready; queued old-scope actions fail instead of reading an old snapshot and writing it under a new account key.
- Slow URL imports capture their initiating scope outside the mutation queue and revalidate it before applying. Repository refresh never continues against the newly selected account, and completed old hydration results are discarded after a scope or source-generation change.
- Imported rules are always rewritten as `untrusted`, remain disabled, and cannot be enabled by individual or bulk switches until the current permission digest is explicitly approved. Content/permission changes still invalidate prior approvals through repository normalization.
- The local bundled catalog is loaded with account-scoped enabled overrides and synchronously bridged for inventory metrics, but no network hydration runs at startup. Production behavior remains an empty v3 source catalog unless a future audited catalog is deliberately shipped.
- `AnimeController` retains its public rule/source API as compatibility delegates, waits for source writes during account changes, and publishes source snapshots through a typed port. It fell from 3,959 to 3,566 lines.

Tests:

- Added six direct controller regressions for account-scoped restore, trust downgrade and bulk-enable blocking, stale slow-import rejection, stale hydration rejection, captured-scope write settlement, and mutation rejection during scope loading.
- Sources, rule security/import, account switching, permission UI, catalog/navigation, and source bridge focused regressions: 81 passed, 25 intentionally skipped, 0 failed.
- Full `flutter test --reporter compact`: 553 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart format, staged `git diff --check`, repository security gate, and staged strong-secret scan passed.

Builds: not run for this behavior-preserving domain slice. Android, Windows, and Web builds remain mandatory before G6 is marked completed.

Commit: `9d068ac refactor: split source controller`

Remaining domains, in required order: Downloads, Library, Catalog, PlaybackDiscovery, Sync.

Remaining risks:

- Source hydration requests are not forcibly cancelled at the transport layer when an account changes; generation and scope checks prevent their results from publishing or persisting. Transport cancellation remains a possible future optimization, not a correctness dependency.
- The intentionally empty bundled catalog means legacy catalog sources are not restored by this architecture refactor. User-imported rules remain available through the audited permission path, while live third-party source acceptance still requires deterministic fixtures or separately authorized real-network validation.
- No production environment, real user database, signing material, private credential, Cookie, or signed media URL was accessed.

### DownloadController

Audit:

- Download queueing, line resolution, retry, progress publication, Hive persistence, pause/resume/cancel, startup recovery, file cleanup, and account ownership were still implemented directly inside `AnimeController`.
- The stable persisted download ID also acted as the live service-control key and default filesystem name. A timed-out old-account run could therefore collide with a newer run for the same media even when controller state publication was guarded.
- Resolver, transport, progress, cleanup, and persistence completions all cross asynchronous account-switch boundaries. Each path needed an initiating scope rather than reading the active account after an await.

Changes:

- Added an independent `DownloadController` owning the queue, immutable task snapshot, ordered account-scoped persistence, resume/recovery, live-run registry, and managed-file cleanup. `AnimeController` keeps the existing UI API as a compatibility delegate and fell from 3,566 to 2,788 lines.
- Stable task IDs remain unchanged for migration and UI identity. Every live run receives separate control and hashed file IDs, preventing pause/cancel/default-path collisions between old and new runs of the same stable task.
- All resolver, progress, result, retry, cleanup, and write paths validate their captured account/context/epoch. Late old-scope results cannot publish or persist, and cleanup excludes paths currently owned by the selected account.
- Pause and cancel win over late backend completion. A late completed artifact after pause is removed instead of being silently promoted or left untracked; resolving-time deletion cannot resurrect a task.
- Account-deletion recovery now cancels downloads by both account ID and stable task ID. Existing persisted paths and startup migrations remain compatible and are never replaced merely by loading the controller.

Tests:

- Added six direct controller regressions covering old-account late results, identical task IDs across accounts, resolving-time deletion, pause/cancel late completion, startup recovery, and account-captured in-flight persistence.
- Download/account focused suite: 43 passed, 0 failed.
- Full `flutter test --reporter compact`: 559 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart format, staged `git diff --check`, and the repository security gate passed.

Builds: not run for this behavior-preserving domain slice. Android, Windows, and Web builds remain mandatory before G6 is marked completed.

Commit: `8e334d8 refactor: split download controller`

Remaining domains, in required order: Library, Catalog, PlaybackDiscovery, Sync.

Remaining risks:

- A transport that ignores pause may continue beyond the bounded account-quiesce wait, but run/file identities and scope guards prevent it from controlling or publishing into the new account. Native transport cancellation latency remains covered by G11 reliability and G14 platform acceptance.
- No playback ranking, source inventory, network policy, production environment, signing material, or real user data changed in this slice.

### LibraryController

Audit:

- Favorites, following, history, playback position, image favorites, and local feedback still read, published, and wrote account-scoped Hive keys directly through `AnimeController`.
- Individual calls captured an account before their write, but the domain had no shared mutation queue and account activation did not await outstanding library writes. Concurrent toggles could compute from the same snapshot, while a slow write or history side effect could complete across an account transition.
- Cloud product sync is not yet implemented. The existing public-collection history side effect must remain an explicit compatibility port rather than becoming hidden persistence inside the local library owner.

Changes:

- Added an independent `LibraryController` owning immutable favorites/history/following/image-favorite/feedback snapshots, deterministic limits and progress rules, account/context scope, serialized mutations, defensive restore, and local persistence.
- Account activation now waits for library mutations, loads the complete new-account snapshot before publishing it, and rejects queued old-scope mutations instead of allowing them to read or publish against the new account.
- History synchronization receives an explicit captured account/context value. The future Sync domain can replace this port without taking ownership of local Hive data or syncing downloads, credentials, headers, tokens, or temporary media URLs.
- `AnimeController` retains the existing library-facing API as compatibility delegates and fell from 2,788 to 2,675 lines.

Tests:

- Added four direct regressions covering concurrent mutation ordering, account isolation, captured-scope in-flight writes, playback-position persistence/near-complete reset, explicit history-sync context, and non-destructive malformed-row restore.
- Existing account migration/isolation, cross-source stable-identity deduplication, history UI, and account-context navigation regressions passed.
- Full `flutter test --reporter compact`: 563 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart format, staged `git diff --check`, and the repository security gate passed.

Builds: not run for this behavior-preserving domain slice. Android, Windows, and Web builds remain mandatory before G6 is marked completed.

Commit: `f5e70f5 refactor: split library controller`

Remaining domains, in required order: Catalog, PlaybackDiscovery, Sync.

Remaining risks:

- The existing optional public-collection history side effect remains a compatibility integration. General cloud mutation queues, idempotency, tombstones, and two-device conflict handling remain G6 Sync/G10 work and are not claimed complete here.
- No cloud schema, account credential, production service, playback behavior, source inventory, or signing configuration changed in this slice.

### CatalogController

Audit:

- Home feed restore/refresh, search, anime/series/movie discovery, category/tag filtering, weekly schedule grouping, detail loading/enrichment, selected-detail memory state, metadata deduplication, and four global Hive caches were still owned by `AnimeController`.
- Home and metadata refreshes used separate generation maps and a shared write queue, but account activation did not own those generations. Detail and refresh results therefore depended on scattered account checks rather than one domain scope.
- The old catalog cache signature covered metadata switches but omitted the unified playback/catalog backend endpoint. Changing backend hosts could leave the previous server's home/metadata cache eligible until another metadata setting changed.

Changes:

- Added an independent `CatalogController` owning home/detail snapshots, search/discovery orchestration, category/tag/schedule views, metadata enrichment flow, deterministic deduplication, cache TTL/sparsity policy, single-flight refreshes, ordered cache writes, and account/context/settings generations.
- Repository construction, public metadata enrichment, and playback prefetch remain explicit typed ports. Late search/detail/home/cache results from an old account or settings generation cannot publish into the selected account.
- Catalog cache signatures now bind both metadata settings and the normalized backend configuration. Settings invalidation waits for older cache writes before deletion, preventing an old slow write from recreating stale cache data after a backend change.
- Detail caching still hands episodes to the existing playback-prefetch compatibility port without moving ranking, probing, or cancellation into Catalog. Those responsibilities remain isolated for the next PlaybackDiscovery slice.
- `AnimeController` retains the existing catalog-facing API as delegates and fell from 2,675 to 2,129 lines.

Tests:

- Added five direct regressions covering old-account late detail, old-account late home refresh, backend-only cache invalidation, ordered slow-write invalidation, and stable direct-route identity with preferred Chinese metadata.
- Catalog/page/detail, backend repository, Bangumi/TMDB/Chinese metadata, search ranking, settings, and account-scope focused regressions: 83 passed, 2 intentionally skipped, 0 failed.
- Full `flutter test --reporter compact`: 568 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart format, staged `git diff --check`, and the repository security gate passed.

Builds: not run for this behavior-preserving domain slice. Android, Windows, and Web builds remain mandatory before G6 is marked completed.

Commit: `6df6e52 refactor: split catalog controller`

Remaining domains, in required order: PlaybackDiscovery, Sync.

Remaining risks:

- Backend repository construction and provider-specific detail enrichment remain compatibility adapters in `AnimeController`; the Catalog owner controls their lifecycle and publication, while later server/provider-interface work remains G7.
- No live third-party route, production API, account secret, production service, signing material, or release configuration was accessed or changed.

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
