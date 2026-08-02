# Zeluna Engineering Goal Progress

## Background

本文件记录 Zeluna 从当前快速播放基线推进到产品级工程状态的可复现证据。AniCh 材料仅用于理解架构思路；项目不得依赖 AniCh API，也不得保存其真实播放 URL、域名池、Cookie 或采样结果。

## Baseline

- Branch: `codex/media-player-overhaul`
- Starting HEAD: `53872d3cb167e068c37069502b97f06cad414d05`
- Current HEAD: latest completed implementation slice `c2aa973` (use `git rev-parse HEAD` for the progress-only commit that follows)
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

Status: completed

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

### PlaybackDiscoveryController

Audit:

- Backend route loading, the 900 ms backend/rule hedge, rule route loading, progressive client verification, source merging, single-backup preparation, line-update streams, short-lived backend caching, and detail-page prefetch were still concentrated in `AnimeController`.
- Account safety relied on scattered aggregate-controller checks. A late shared backend result, rule result, client probe, or prefetch needed one domain-owned account/settings generation before it could publish or populate a reusable cache.
- The progressive stream checked cancellation inside each probe but could still emit a synthetic `complete` update after a cancelled probe returned.

Changes:

- Added an independent `PlaybackDiscoveryController` owning backend/rule repository orchestration, hedged quick lookup, bounded progressive verification, deterministic source merging, cancellation, scoped single-flight requests, short-lived cache entries, startup ranking, backup preparation, and history-aware prefetch.
- Account id, account context version, controller epoch, normalized backend endpoint, backend kind, subject, episode, and lookup mode now scope backend reuse. Account, rule, backend-setting, credential, and disposal invalidation reject late results before cache writes or stream publication.
- `AnimeController` retains the existing player/download/catalog API as compatibility delegates and fell from 2,129 to 1,653 lines. Repository construction and resolver access are explicit typed ports; Riverpod dependencies are captured before disposal rather than read inside lifecycle callbacks.
- Cancellation now stops the progressive stream before its final completion event, so a late verifier cannot publish after the caller has cancelled.

Tests:

- Added six direct controller regressions covering old-account late backend results, old-account late rule results, same-episode cross-account cache isolation, cancellation after a late probe, progressive completion order, account-switch prefetch invalidation, and backend-setting cache invalidation (the first test covers both late backend publication and scoped cache reuse).
- Playback/controller/rule/backend/player focused regressions: 163 passed, 23 intentionally skipped, 0 failed.
- Full `flutter test --reporter expanded`: 574 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Full Dart format check, staged `git diff --check`, and the repository security gate passed.

Builds: not run for this behavior-preserving domain slice. Android, Windows, and Web builds remain mandatory before G6 is marked completed.

Commit: `98d8ec8 refactor: split playback discovery controller`

Remaining domain, in required order: Sync.

Remaining risks:

- Backend and rule repository factories remain compatibility ports in `AnimeController`; the PlaybackDiscovery owner now controls their asynchronous lifecycle and publication. Provider-interface restructuring remains G7 work.
- The four required materials remain `total=4`, `read=4`, `skipped=0`. AniCh reports and the VOD JSON were used only to compare architecture and historical route-shape ideas; no production API, sampled endpoint, private implementation, token, DRM, membership, CAPTCHA, or access-control bypass was used.
- No production backend, account, secret, signing material, real device, or release configuration changed in this slice.

### SyncController

Audit:

- `LibraryController` already exposed an explicit history-sync port, but `AnimeController` still owned its account check, current settings lookup, external repository access, and lifecycle. The compatibility repository currently returns only the public-collection setting and does not implement durable cloud synchronization.
- An independent Sync owner was still needed before G10 can safely add persistent offline mutations. The G6 extraction must not mislabel the current placeholder as server push/pull, idempotency, tombstones, or conflict resolution.

Changes:

- Added an independent `SyncController` owning account/context scope, ordered compatibility history uploads, a bounded 10-second operation timeout, optional-failure isolation, settings enablement, queue settlement, and late-result rejection.
- Account activation now configures Sync from the explicit account session event before loading the new Library scope. Account quiescence waits both local Library writes and Sync work; setting changes update Sync without giving it ownership of settings persistence.
- `LibraryController` keeps local favorites/history/following persistence and hands only a typed captured mutation context to Sync. `AnimeController` no longer reads account state, current aggregate state, or the external repository inside the history callback.
- Durable mutations, stable client mutation IDs, schemas, acknowledgements, pull revisions, tombstones, two-device conflict policy, migration, and the server API remain explicitly unimplemented until G10.

Tests:

- Added five direct regressions covering disabled sync, serialized upload order, queued/late old-account rejection, setting invalidation, and bounded timeout/failure isolation.
- Sync, Library, Account, Settings, and credential-provider focused regressions: 28 passed, 0 failed.
- Full `flutter test --reporter expanded`: 579 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Full Dart format check, staged `git diff --check`, and the repository security gate passed.

Builds: recorded in the G6 final acceptance below.

Commit: `8d15b2a refactor: split sync controller`

G6 final acceptance (2026-08-02):

- Ownership audit passed for Account, Settings, Sources, Downloads, Library, Catalog, PlaybackDiscovery, and Sync. `AnimeController` retains application composition, compatibility API delegates, repository factories, metadata/external playback ports, and aggregate snapshot publication; it no longer owns those domains' persistence, queues, caches, cancellation state, or mutation generations.
- Account switching is coordinated through `AccountScopeActivation` with monotonic context versions and explicit per-domain `loadForAccount` calls. Each extracted controller has direct account-scope and late-result regressions, and the fully split client suite passed 579 tests with 26 intentional skips.
- `flutter build apk --debug --suppress-analytics` passed. Artifact: `build/app/outputs/flutter-apk/app-debug.apk`, 268,924,837 bytes, SHA-256 `F1D7281D654147CD2BE9F867DD91E0785796AE285BF24E7FF2D8BC759F17EE4F`.
- `flutter build web --release --suppress-analytics` passed, including the Wasm dry run. Artifact: `build/web/main.dart.js`, 4,845,987 bytes, SHA-256 `E997ECEB8B930331A5DEA3844E55724FB8B01AC892221239C56275AA7B880493`.
- `flutter build windows --release --suppress-analytics` passed. Artifact: `build/windows/x64/runner/Release/Zeluna.exe`, 158,208 bytes, SHA-256 `2814F973D704BE8D76230EF5790EF91D9DE0ECE2F6C7D8A0E17173B29DE9A9FC`; compiled payload `data/app.so`, 13,550,512 bytes, SHA-256 `F16E8C3DB319356A805BADD7EF2D9709904D96B1679546009BFF5A9B6E192B95`.
- Windows still reports the previously documented upstream WebView CMake `CMP0175` developer warning; it did not fail the Release build. G6 did not access signing material, produce a signed release package, use a real account, or change production.

Remaining risks:

- Current history sync remains a no-op compatibility adapter controlled by `publicCollectionSyncEnabled`; it is not evidence of cloud synchronization. G10 must implement and verify the complete client/server lifecycle without syncing downloads, cookies, headers, API keys, bearer tokens, temporary media URLs, or untrusted-rule secrets.
- No production account, external collection, cloud mutation, server schema, production service, secret, signing material, or release configuration changed in this slice.

## G7 Server architecture

Status: completed

### Application lifecycle and shared dependencies

Audit:

- `server.main` was a 1,794-line module that constructed FastAPI, duplicated database-session dependencies, owned admin/legacy guards, registered every modern and legacy route, and used deprecated `@app.on_event` startup/shutdown decorators.
- The production JSON account router defined a second `get_session`, while the modern app and legacy routes depended on the copy in `main`. Baseline server validation from the correct `server` working directory was 93 passed, 5 warnings, and 3 subtests passed; four warnings came from the deprecated event decorators.

Changes:

- Added `server.app.create_app` as the application metadata, CORS, and production account-router composition boundary.
- Added shared `server.dependencies` ownership for database sessions, fail-closed admin authorization, and the default-disabled legacy account guard. Both modern account and existing main routes now use the same dependency object, preserving test overrides.
- Replaced deprecated startup/shutdown events with one async FastAPI lifespan. Database initialization, scheduler startup, seed compatibility, and ordered scheduler/service/resolver shutdown preserve the previous behavior, with cleanup in `finally` after scheduler startup.
- Legacy route implementations still reside in `main`, but direct regression proves `/login` returns 404 when the legacy account flag is disabled. No legacy route was enabled or added.

Tests:

- Added four structure regressions covering shared session dependency identity, app metadata/CORS/account-router composition, default legacy 404 behavior, and ordered lifespan startup/shutdown.
- App/account/playback route focused suite: 9 passed, 0 failed.
- Full server suite: 97 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed. The four FastAPI `on_event` deprecation warnings are gone.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, and the repository security gate passed. The repository's 43 pre-existing Ruff-format differences were not bulk-reformatted into this slice; new files were formatted directly.

Commit: `18fbc8e refactor: own server app lifecycle`

### Modern v3 router isolation

Audit:

- The modern status, catalog, playback, and administrative refresh routes were still implemented at the end of `server.main`. That kept public route composition coupled to the retained 1.x/2.x compatibility surface and made route-level authorization or contract testing depend on the 1,765-line module.
- Baseline focused app/playback validation was 6 passed and 0 failed. The existing quick-playback test patches `server.main.playback_service.quick_lines`, so the extraction had to preserve the shared singleton rather than construct a router-local service.

Changes:

- Added explicit `server.routers.health`, `catalog`, `playback`, and `admin` modules and registered them through `server.app.create_app`. Existing v3 URLs, query constraints, response shapes, stable-ID checks, and the shared database dependency remain unchanged.
- The modern admin router applies the existing fail-closed `require_admin` dependency to the entire route group. Direct regression proves the refresh endpoint is undiscoverable without configuration, rejects an incorrect token, and accepts the configured header.
- Router modules reference the existing catalog and playback singleton objects. The compatibility patch through `server.main.playback_service` still controls the same object, and no duplicate v3 route remains in `main`.
- `server.main` is now 1,648 lines. Retained legacy/community/compatibility routes remain isolated follow-up work; none was enabled, removed, or behaviorally changed in this slice.
- The four-material inventory remains `total=4`, `read=4`, `skipped=0`. This slice used only the recorded architecture and security constraints: it did not call an AniCh production API, copy private code or protocols, import sampled routes, retain tokens, or bypass DRM, membership, CAPTCHA, or access controls.

Tests:

- Added route-composition regressions for module ownership/OpenAPI registration, catalog content-type normalization and validation, and fail-closed/authorized-with-correct-token administrative behavior.
- Focused modern route/app/playback suite: 10 passed, 0 failed.
- Full server suite: 101 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, and the repository security gate passed. OpenAPI contained 68 paths with no duplicates.

Commits:

- `8669047 refactor: split modern server routers`
- `1cea5ee test: reject invalid modern admin token`

### Retained admin route isolation

Audit:

- Five retained scraper/scheduler/metadata management endpoints were still declared in `server.main`, each repeating the admin dependency. They had no direct route regressions even though they can trigger scans and metadata synchronization.
- The retained endpoints already used the same fail-closed dependency as the modern refresh route. This slice preserves their paths and operations while moving authorization ownership to one router-level boundary.

Changes:

- Moved `/admin/scrapers`, `/admin/scrapers/search`, `/admin/scan`, `/admin/sync/metadata`, and `/admin/stats` into `server.routers.admin` alongside `/admin/v3/playback/refresh`.
- The unified admin router applies `require_admin` to all six endpoints. `server.main` now defines no `/admin/*` path and no longer imports the admin dependency or the unused metadata-sync service alias.
- Preserved response fields, query parsing, scheduler/scraper/metadata singleton ownership, and endpoint documentation. `server.main` is now 1,563 lines.

Tests:

- Added route ownership plus retained scan regressions proving an incorrect token returns 404 and the configured token forwards the normalized content-type list exactly once.
- Focused app/admin/playback suite: 11 passed, 0 failed.
- Full server suite: 102 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, and the repository security gate passed. OpenAPI still contained 68 paths, including all six admin paths, with no duplicates.

Commit: `ec6fbb7 refactor: isolate server admin routes`

### Legacy account router isolation

Audit:

- Six retained protobuf account endpoints and their request/user helpers were still mixed into `server.main`. Production configuration already keeps them disabled because the old registration flow does not enforce the modern email-delivery boundary.
- Only the compatibility routes use the legacy account request parser and user response mapping. The binary protobuf response helper is also used by retained catalog/community routes and therefore needed a small shared compatibility module.

Changes:

- Added `server.routers.legacy_account` for `/login`, `/code`, `/register`, `/user/check`, `/change_password`, and `/init`. One router-level `require_legacy_account_api` dependency keeps every endpoint at 404 unless the explicit compatibility flag is enabled.
- Added `server.legacy_protocol` for the retained field parser, user mapping, and binary response wrapper. `server.main` imports only the binary wrapper required by its remaining compatibility routes.
- Registered the legacy router through `server.app.create_app`, removed the six route implementations and account-only authentication/database imports from `main`, and preserved the shared database dependency for test and application overrides.
- This extraction does not authorize or enable the legacy account API, change the modern `/api/v1/auth/*` system, send email, create a real account, or alter production configuration. `server.main` is now 1,329 lines.

Tests:

- Added regressions proving all six legacy account paths return 404 by default, the router runs only with the explicit flag, the retained protobuf field mapping is unchanged, and binary responses keep `application/octet-stream`.
- Focused legacy/app/admin/playback suite: 14 passed, 0 failed.
- Full server suite: 105 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, and the repository security gate passed. OpenAPI still contained 68 paths with all six legacy account paths and no duplicates.

Commit: `7cf3e1b refactor: isolate legacy account router`

### Legacy configuration endpoint closure

Audit:

- `/check/api` was a public historical client-configuration endpoint in `server.main`. It returned `PUBLIC_BASE_URL` together with hard-coded third-party danmaku, update, and proxy addresses copied from the retained compatibility shape.
- The current Flutter catalog/playback/account clients use the Zeluna v3 and `/api/v1/auth/*` contracts and do not call `/check/api`. Only the production launcher comment referenced it.
- Keeping the fixed values public conflicted with the four-material safety boundary: historical AniCh evidence must not become a fixed real route catalog or third-party configuration source.

Changes:

- Added a default-false `LEGACY_CONFIG_API_ENABLED` setting and fail-closed dependency, documented in `.env.example` and `server/DEPLOY.md`.
- Moved `/check/api` into `server.routers.legacy_config`. It returns 404 unless explicitly enabled; enabled compatibility responses keep the old keys but contain only the configured Zeluna `PUBLIC_BASE_URL`, with every third-party API/update/proxy field empty and proxy lists empty.
- Removed the hard-coded external addresses from `server.main` and updated the production launcher documentation. This slice did not contact any listed service, add a sampled route, or change production configuration. `server.main` is now 1,312 lines.

Tests:

- Added regressions for default 404 behavior, explicit compatibility enablement, the sanitized response shape, and router ownership.
- Focused config/app/admin/playback suite: 14 passed, 0 failed.
- Full server suite: 107 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, and the repository security gate passed. OpenAPI still contained 68 paths, exactly one `/check/api`, and no duplicates.

Commit: `760a371 security: close legacy config endpoint`

### v2 compatibility router isolation

Audit:

- Five retained `/api/v2/*` catalog, episode, playback-cache, home, and resolver routes remained at the end of `server.main`. Current Zeluna catalog/playback clients use v3, while a server regression still exercises the v2 VOD cache contract.
- Existing tests patch `server.main.aggregator.resolve_verified_lines`; the extraction therefore had to keep the same shared aggregator singleton rather than construct a router-local backend.

Changes:

- Added `server.routers.compat_v2` for `/api/v2/search`, `/api/v2/episodes/{subject_id}`, `/api/v2/vod/{subject_id}`, `/api/v2/home`, and `/api/v2/resolve`.
- Preserved query defaults, response fields, six-hour cache behavior, cached headers, write-failure isolation, aggregator/resolver singleton ownership, and public compatibility status. No route was enabled, disabled, or redirected in this slice.
- Removed v2-only cache imports and logging ownership from `server.main`. The main lifecycle still closes the same aggregator and resolver objects, and compatibility patches through `server.main.aggregator` continue to work. `server.main` is now 1,158 lines.

Tests:

- Added explicit router ownership, empty-resolver no-network behavior, and shared-aggregator regressions; the existing two-request v2 VOD cache test remained unchanged.
- Focused v2/app/playback suite: 9 passed, 0 failed.
- Full server suite: 109 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, and the repository security gate passed. OpenAPI still contained 68 paths, all five v2 paths, and no duplicates.

Commit: `98e769e refactor: isolate v2 compatibility router`

### Legacy media router and duplicate-route removal

Audit:

- Runtime route enumeration found two `GET /vod/{id}/{episode}` registrations in `server.main`. Starlette matched the earlier database-episode handler; the later scraper handler was unreachable even though OpenAPI collapsed both into one path and hid the duplicate.
- Other repeated path names (`/danmaku`, `/comment`, and `/comment/like`) use distinct HTTP methods and are valid method/path pairs.
- The previously reachable VOD behavior returns the stored episode identity/title and decoded local `vod_url`. Removing the dead scraper registration therefore must preserve that exact contract rather than activate the unreachable implementation.

Changes:

- Added `server.routers.legacy_media` for the retained bangumi list/tag/latest/detail/episodes/related endpoints and the one reachable legacy VOD endpoint.
- Moved the shared bangumi protobuf mapping into `server.legacy_protocol`, preserving remaining compatibility callers through an alias in `main`.
- Removed the unreachable second VOD registration and its now-unused scraper-registry import. No scraper call, production API, fixed route, or sampled source was substituted for the live database contract. `server.main` is now 903 lines.

Tests:

- Added an in-memory database regression for the previously reachable legacy VOD response, explicit single-registration ownership, and a whole-app method-plus-path uniqueness check that cannot be fooled by OpenAPI path folding.
- Focused legacy-media/app/playback suite: 10 passed, 0 failed.
- Full server suite: 112 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, and the repository security gate passed. The flattened runtime table contained 75 method/path pairs with no duplicates.

Commit: `36f462b refactor: isolate legacy media routes`

### Legacy community thread router isolation

Audit:

- Twelve retained thread feed/tag/detail/collection/like routes were interleaved with media, search, and comment implementations in `server.main`.
- Public feed/detail responses use the historical protobuf shape, while collection/like status is readable without login but all mutations and personal lists require the existing `_` token header. The extraction could not weaken that split.

Changes:

- Added `server.routers.legacy_community` for `/latest`, `/tags`, `/t/*`, `/r/*` thread/detail/collection/like routes, and `/action/collects/{type}`.
- Consolidated the repeated thread-card mapping inside the router while preserving image selection, count fields, pagination, tag filtering, response formats, shared session dependency, and existing authentication behavior.
- Removed thread-only collection/like model imports from `server.main`. Comment routes and search remain separate follow-up slices. `server.main` is now 670 lines.

Tests:

- Added an in-memory public feed regression for the binary response contract and an unauthenticated boundary regression proving status remains `false` while collection mutation remains 401.
- Focused community/app suite: 8 passed, 0 failed.
- Full server suite: 114 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, the repository security gate, and the whole-app method/path uniqueness regression passed. The runtime table remains 75 unique method/path pairs.

Commit: `aa261c0 refactor: isolate legacy community routes`

### Legacy comment router isolation

Audit:

- Five retained comment operations (list, publish, replies, like, and unlike) remained in `server.main` after thread extraction.
- Comment lists/replies allow anonymous reads and optionally report the authenticated user's like state. Publishing and like mutations require the existing `_` token header, duplicate likes are idempotent, and unlike keeps the stored count at or above zero.

Changes:

- Added `server.routers.legacy_comments` and moved all `/comment*` operations into it with the shared session/authentication objects.
- Consolidated repeated user/content/like-state mapping without changing ordering, pagination, fallback anonymous user shape, JSON content decoding, response fields, or mutation commits.
- Removed comment-only model imports from `server.main`. `server.main` is now 489 lines.

Tests:

- Added in-memory regressions proving anonymous comment reads remain available, anonymous publishing remains 401, authenticated unlike succeeds, and a zero like count is never decremented below zero.
- Focused comments/app suite: 8 passed, 0 failed.
- Full server suite: 116 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, the repository security gate, and method/path uniqueness regression passed. The runtime table remains 75 unique pairs.

Commit: `b402219 refactor: isolate legacy comment routes`

### Legacy library router isolation

Audit:

- Six retained danmaku and bangumi-collection operations remained in `server.main`. Danmaku lists are public protobuf reads, while posting requires authentication; collection status is anonymously readable, while create/update/cancel/list require authentication.
- Repeated collection changes update the one existing user/subject row. This local database behavior is not cloud synchronization and must not be presented as G10 work.

Changes:

- Added `server.routers.legacy_library` for GET/POST `/danmaku`, bangumi collection status/change/cancel, and `/action/collect/{type}`.
- Preserved protobuf fields, ordering/pagination, anonymous status shapes, the existing `_` token header, collection update semantics, and shared session/authentication objects.
- Removed route-only time/auth/delete/model imports from `server.main`. No cloud queue, remote mutation, account migration, or production data operation was added. `server.main` is now 307 lines.

Tests:

- Added in-memory regressions proving anonymous danmaku reads remain binary and available, anonymous danmaku writes remain 401, and two collection changes for one account/subject leave one row with the latest type.
- Focused library/app suite: 8 passed, 0 failed.
- Full server suite: 118 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, the repository security gate, and method/path uniqueness regression passed. The runtime table remains 75 unique pairs.

Commit: `2c599d7 refactor: isolate legacy library routes`

### Legacy lookup router isolation

Audit:

- Eight retained character, person, picture-search, and bangumi-search operations remained in `server.main`. They preserve a mix of JSON and protobuf compatibility contracts and use only the shared database session dependency.
- The application factory already owned router composition, so moving these handlers removes the final direct business-route definitions from `server.main` without changing public paths or response formats.

Changes:

- Added `server.routers.legacy_lookup` for character/person lists and details, related bangumi lookup, picture search, and bangumi search.
- Preserved lookup filters, ordering/pagination limits, protobuf content type, JSON field shapes, 404 behavior, and shared session dependency.
- Updated playback tests to import the shared dependency from `server.dependencies`. `server.main` now contains lifecycle, application composition, and compatibility seed orchestration only; it is 160 lines and owns no direct business route.

Tests:

- Added in-memory regressions proving character detail and missing-person JSON behavior and the binary bangumi-search contract.
- Focused lookup/app/playback suite: 11 passed, 0 failed.
- Full server suite: 121 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, staged `git diff --check`, the repository security gate, and route uniqueness checks passed. The runtime table has 75 flattened routes and 79 unique method/path pairs, with 0 duplicates.

Commit: `f52fabf refactor: isolate legacy lookup routes`

### Startup demo mutation removal

Audit:

- The remaining startup helper inserted a fixed sample catalog and fixed public media URLs into every empty database.
- The same helper also looked up a historical fixed-email demo identity and deleted it during ordinary startup. That implicit account deletion was an irreversible data mutation and is not an acceptable cleanup or migration boundary.

Changes:

- Removed runtime demo catalog/thread/character seeding and all fixed sample media URLs from application startup.
- Removed the automatic historical demo-account deletion. Existing databases and accounts are left untouched; any later cleanup must use an explicit, reviewed migration or operator action with the required data authority.
- `server.main` now contains only lifecycle ordering and application construction. It is 28 lines, owns no business routes, and performs no seed/account mutation after schema verification and scheduler startup.

Tests:

- Updated lifecycle ordering coverage and added a regression that rejects restoration of the removed startup seed hook.
- Focused app-structure suite: 8 passed, 0 failed.
- Full server suite: 122 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, `git diff --check`, the repository security gate, forbidden seed-reference scan, and route uniqueness checks passed. The runtime table remains 75 flattened routes and 79 unique method/path pairs, with 0 duplicates.
- No database file, production environment, account, secret, or external media endpoint was opened or changed during this slice.

Commit: `3a71f7e refactor: remove startup demo mutations`

### Provider contract and registry

Audit:

- `BaseScraper` supplied a concrete inheritance base, but aggregation still constructed and closed implementations directly and had no validated provider registration or non-sensitive metadata contract.
- The existing source inventory is compatibility orchestration and may contain internal adapter/site labels. It is not a safe provider metadata interface and must not be expanded to include endpoints, request headers, cookies, or tokens.

Changes:

- Added a structural `MediaProvider` protocol plus `ProviderRegistry`, `RegisteredProvider`, and immutable `ProviderMetadata` types.
- Registration now rejects invalid/duplicate IDs, unsupported content types or capabilities, incomplete adapters, control characters, endpoint-like display names, and common private metadata markers.
- `ContentAggregator` registers aggregate and crawler adapters through the validated registry, delegates ordered close ownership to it, and exposes a metadata tuple containing only stable ID, family, display name, content types, and capabilities. No route publishes provider endpoints or request internals.

Tests:

- Added contract regressions for safe metadata shape, private/incomplete registration rejection, unique default aggregate registrations, and registry-owned shutdown. Constructors were exercised without invoking provider search/detail/resolve or any external network request.
- Focused provider/aggregator/v3-services suite: 47 passed, 3 subtests passed, 0 failed.
- Full server suite: 125 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, `git diff --check`, and the repository security gate passed.

Commit: `17ae385 refactor: define server provider contracts`

### Playback provider activation governance

Audit:

- A static, value-preserving scan found 69 URL literals across 19 server Python files. The highest concentrations remain in legacy MacCMS, common-VOD, HTML-site, and TVBox adapters. No URL was requested or probed during this audit.
- Before this slice the global aggregator constructed and actively selected every bundled playback adapter, and the generic M3U8 search fallback was reachable by default. Fixed server-side adapter configuration therefore implied outbound runtime authority without an explicit operator allowlist.

Changes:

- Added `PLAYBACK_PROVIDER_IDS` as a normalized, deduplicated server environment allowlist. The real global aggregator passes the configured set explicitly and defaults to an empty set; unknown IDs fail startup instead of being ignored.
- Added `M3U8_SEARCH_ENABLED`, defaulting to false. Search, parallel/progressive discovery, detail lookup, episode resolution, home feeds, source inventory/placeholders, and generic resolver fallback all enforce their respective activation gates.
- Provider metadata now reports the safe enabled/disabled state. Disabled adapters remain inspectable and closable but receive no search/detail/resolve/latest call. Test/custom aggregator injection retains an explicit all-enabled default so contract tests do not depend on process environment.
- Updated `.env.example` with fail-closed empty provider selection and disabled resolver search. No production environment was changed; later deployment/release acceptance must deliberately approve and configure the provider IDs required for that environment.

Tests:

- Added regressions for allowlist normalization, unknown-ID rejection, metadata enabled state, and a zero-authority aggregator. All aggregate/crawler search, detail, resolve, latest, progressive, and resolver methods were instrumented to fail if called; every disabled path remained uncalled.
- Focused provider/aggregator/v3-services suite: 50 passed, 3 subtests passed, 0 failed.
- Full server suite: 128 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, `git diff --check`, repository security gate, and route uniqueness checks passed. The runtime route table remains 75 flattened routes and 79 unique method/path pairs, with 0 duplicates.
- Static post-change runtime evidence: 0 globally enabled providers, 0 source-inventory entries, resolver search false, and 0 audit network calls.

Commit: `1b995a9 feat: govern playback provider activation`

### Catalog repository isolation

Audit:

- `CatalogService` mixed metadata-provider orchestration with SQLAlchemy queries, JSON cache decoding, row upserts, and transaction commits for `CatalogSubject`.
- Search, home, and detail cache behavior already had stable freshness/completeness rules; the boundary needed to preserve those rules and one-row-per-stable-ID updates without changing provider calls or public responses.

Changes:

- Added a `CatalogRepository` protocol, immutable cache/write records, and `SqlCatalogRepository` under `server.repositories`.
- Moved cached search/home/detail queries, malformed-cache filtering, stable-row upsert, and commit ownership into the SQL repository. `CatalogService` now creates one repository per request scope and retains only cache-policy, stable-identity normalization, provider orchestration, and result mapping.
- Repository injection allows catalog service tests to prove cache-first behavior without a SQL implementation or provider network request. No schema, migration, TTL, ranking, provider endpoint, or response contract changed.

Tests:

- Added in-memory repository regressions for insert/update idempotency, search/home/detail round trips, malformed metadata filtering, and service-level repository injection with a network handler that fails if called.
- Focused catalog repository/v3-services suite: 25 passed, 0 failed.
- Full server suite: 131 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, `git diff --check`, and the repository security gate passed. Direct select/execute/scalar/add/commit operations in `server.catalog` are now zero.

Commit: `5c4bb8d refactor: isolate catalog persistence`

### Playback cache repository isolation

Audit:

- `PlaybackService` directly selected and decoded `PlaybackCache`, called the database upsert helper, and selected the oldest cache rows for scheduled refresh.
- Cache freshness, partial/negative/stale TTLs, signed-line expiry filtering, inventory completion, and playable-line policy belong to the service and must remain unchanged; row retrieval/upsert/ordering belong to persistence.

Changes:

- Added `PlaybackRepository`, immutable `PlaybackCacheEntry`, and `SqlPlaybackRepository` with cache get/upsert/oldest operations.
- Injected the repository factory into `PlaybackService`. Cache policy remains in the service, while SQL selection, conflict-safe upsert, and oldest-row ordering now stay behind the repository boundary.
- No cache schema, TTL, line-count definition, refresh concurrency, ranking, provider activation, or public response changed.

Tests:

- Added in-memory repository regressions for conflict-safe update and oldest ordering, plus service injection coverage for cache hit decoding and available-line write counts.
- Focused playback repository/cache/v3-services suite: 25 passed, 0 failed.
- Full server suite: 133 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, `git diff --check`, and the repository security gate passed.

Commit: `12cee7b refactor: isolate playback cache persistence`

### Playback binding and health repository isolation

Audit:

- `PlaybackService` still directly selected and mutated `SourceBinding` and `SourceHealth` rows, including binding upserts, long-term counters, consecutive-failure state, latency EMA, and transaction commits.
- Ranking, TTL, source matching, error classification, circuit thresholds, single-flight refresh, and recovery-probe decisions are service policy and had to remain unchanged while persistence became replaceable.

Changes:

- Extended `PlaybackRepository` with immutable binding/health records, write/observation contracts, and SQL load/upsert/atomic-health operations.
- `PlaybackService` now maps source matches and normalized outcomes to repository records and performs no direct select/scalar/scalars/add/commit operation. It retains ranking, circuit timing, error-category selection, EMA coefficient, and deterministic-failure policy inputs.
- Preserved one-row-per-stable/source binding behavior, recoverable enabled state, success/failure counters, client-probe handling, deterministic-failure double increments, half-open cooldown recovery, and latency EMA.

Tests:

- Added repository regressions for binding update idempotency, freshness filtering, success/failure counter updates, deterministic failure weight, last-error state, and latency EMA. Added service-injection regressions proving binding loads/writes and normalized health observations use the repository boundary.
- Focused playback repository/v3-services suite: 26 passed, 0 failed.
- Full server suite: 135 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- `uv run ruff check server tests`, Python `compileall`, `git diff --check`, repository security gate, provider fail-closed check, and route uniqueness check passed. `server.playback` direct persistence operations are zero; the route table remains 75 flattened routes and 79 unique method/path pairs with 0 duplicates.

Commit: `e51c8c8 refactor: isolate playback health persistence`

### G7 completion verification

- Updated `server/DEPLOY.md` to document the empty provider allowlist, disabled resolver/precache defaults, and the G13/G14 deployment authority boundary. Removed stale 2026-07-28 production/source assertions that were not revalidated in this Goal.
- `flutter analyze --suppress-analytics`: 0 issues.
- Full Flutter suite: 579 passed, 26 skipped legacy/platform-conditional cases, 0 failed.
- Full server suite: 135 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Application lifecycle, routers, fail-closed admin/legacy surfaces, provider contracts and activation, catalog/playback repositories, runtime route uniqueness, repository security gate, compile checks, and cross-client v3 catalog/quick/full playback contracts all have direct regression evidence.
- The four-material inventory remains `total=4`, `read=4`, `skipped=0`. No AniCh production API, sampled endpoint, private implementation, token, DRM, membership, CAPTCHA, or access-control bypass was used. No production account, database, provider, environment, deployment, signing material, or release artifact was changed.
- Platform packaging/build and real-device/production-provider acceptance remain G13/G14 release gates; G7 changed only server architecture and cross-platform API compatibility, so no release artifact is claimed here.

## G8 Account and session security

Status: completed

### Strong account signing keys and JWT claim binding

Audit:

- The account signing key still defaulted to a repository-known historical placeholder, and token creation accepted missing, short, or low-diversity values. A deployment with incomplete environment configuration could therefore issue forgeable sessions instead of failing closed.
- New account tokens carried expiry, issued-at, user ID, and a unique token ID, but did not bind the token to the Zeluna issuer and client audience. Existing deployed sessions still require a bounded compatibility path while the migration proceeds.

Changes:

- Removed the default account signing key. Account cryptographic operations now require an independent value of at least 32 UTF-8 bytes with basic diversity and reject empty, short, repeated-character, and historical placeholder values.
- Registration-code requests validate the signing configuration before any mail-delivery attempt and return a controlled `503` when it is unavailable. No email, real account, database, or production environment was used.
- New JWTs now require issuer, audience, subject, expiry, issued-at, and unique-token claims. Decoding rejects wrong issuer/audience and only accepts a signature-valid legacy token when both issuer and audience claims are entirely absent, preserving a narrow migration window without weakening validation for new-format tokens.
- Deployment guidance now documents the fail-closed key requirements without exposing or generating signing material.

Tests:

- Focused account/session security suite: 16 passed, 0 failed.
- Full server suite: 140 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, the repository security gate, and staged `git diff --check` passed.

Commit: `024b688 security: require strong account signing keys`

Remaining risks:

- Client-address rate limiting still needs an explicit trusted-proxy boundary; forwarded headers must remain untrusted by default.
- Attempt tracking, verification-code consumption limits, login timing resistance, password-hash upgrades, and session lifecycle enforcement remain open G8 work.
- The four-material inventory remains `total=4`, `read=4`, `skipped=0`; AniCh materials and VOD samples were not used as live providers, fixed routes, credentials, private protocols, or access-control bypasses.

### Trusted proxy and bounded rate-limit state

Audit:

- Account rate limiting unconditionally accepted `X-Real-IP`. That assumption lived only in a comment and allowed direct clients or a misconfigured proxy chain to choose their limiter identity.
- The process-local attempt table had no key-capacity bound. Unique IP/email keys could grow memory indefinitely, and ordinary Uvicorn startup could apply its own proxy-header rewriting before the application policy ran.

Changes:

- Forwarded client addresses are now accepted only when the direct peer belongs to an explicitly configured `ACCOUNT_TRUSTED_PROXY_CIDRS` network. The default is empty and therefore ignores `X-Real-IP`; malformed, chained, and untrusted values fall back to the direct peer. IPv4-mapped IPv6 addresses are canonicalized before comparison.
- Both server launchers disable Uvicorn's implicit proxy-header processing. Production guidance requires the same `--no-proxy-headers` boundary for CLI launches and warns against broad/client networks in the trusted proxy list.
- Replaced the unbounded default dictionary with a capacity-bounded attempt store. It preserves active rate-limit keys, reclaims only expired buckets, and returns `429` for a new key when saturated instead of evicting a live restriction. The default hard cap is 10,000 keys and is configurable within bounded limits.
- The limiter remains a single-process fallback. Multi-instance deployments must enforce shared limits at the trusted gateway; this slice does not claim distributed enforcement.

Tests:

- Focused account security suite: 12 passed, 0 failed, including spoofed/untrusted headers, trusted IPv4/IPv6 forwarding, mapped addresses, malformed chains, capacity saturation, expiry reclamation, `Retry-After`, and production launcher configuration.
- Full server suite: 144 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, unstaged/staged `git diff --check`, and final diff scope passed.

Commit: `3832d90 security: harden account rate limiting`

Remaining risks:

- Verification-code consumption still needs email/purpose failure limiting that cannot be bypassed by rotating source addresses.
- Login timing resistance, legacy password-hash upgrade, and the full session expiry/revocation audit remain open G8 work.
- No production proxy, environment, account, database, secret, email delivery, or deployment was changed.

### Persistent verification-code failure budgets

Audit:

- Code-request endpoints limited sends by IP and email, but registration/password-reset consumption had no email-scoped failure budget. An attacker rotating client addresses could repeatedly guess a six-digit code during its ten-minute validity window.
- The verification row did not persist its purpose or failure count, so a secure budget could not survive process restarts or be enforced consistently across server instances sharing the database.

Changes:

- Verification rows now persist their `purpose` and `failed_attempts`. Consumption selects the newest live row for the email/purpose pair, compares the HMAC digest in constant time, atomically increments failures, and locks the code after five wrong guesses until its expiry.
- The budget is independent of source address, so rotating clients do not reset it. A locked code remains unusable even if the next guess is correct; explicitly requesting a fresh code replaces the old row and starts a new budget.
- Added reversible Alembic revision `0004_verification_code_attempts`. Existing rows are preserved byte-for-byte and marked `legacy` with zero failures rather than being guessed into a modern purpose. No migration was run against a production or user database.

Tests:

- Focused account and migration suite: 23 passed, 0 failed. Direct regressions cover rotating-client failures, fifth-attempt lockout, locked-correct rejection, fresh-code recovery, successful consumption cleanup, legacy-row preservation, schema-head verification, and migration downgrade paths.
- Full server suite: 146 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, staged `git diff --check`, and migration autogeneration consistency passed.

Commit: `79010fe security: limit verification code guesses`

Remaining risks:

- Login still needs timing-resistant handling for nonexistent users and safe upgrade of legacy password hashes.
- Session expiry cleanup, maximum-session concurrency, and password change/reset revocation semantics still require an explicit G8 audit.
- No production migration, account, database, secret, email delivery, environment, or deployment was changed.

### Timing-resistant login and password-hash upgrade

Audit:

- Modern and default-disabled legacy login returned immediately when no account row existed, while a real account performed bcrypt verification. That observable work difference could assist email/account enumeration despite the shared error response.
- Raw legacy bcrypt hashes remained valid for compatibility but were never upgraded after a successful login, leaving migrated accounts on the unversioned format indefinitely.

Changes:

- Added one process-initialized, random dummy `bcrypt-sha256` hash. Both login paths now perform exactly one current-cost bcrypt verification even when the account does not exist, while still returning the same invalid-credentials response.
- A successful login with a valid raw legacy bcrypt hash immediately rehashes the supplied password into the versioned `bcrypt-sha256` format. Wrong passwords never mutate the stored hash, and current-format accounts are not rehashed unnecessarily.
- The upgrade commits atomically with token issuance. A signing/configuration failure therefore cannot persist a partial password change.

Tests:

- Focused account/app-structure suite: 23 passed, 0 failed. Direct regressions prove missing-user dummy verification, wrong-password non-mutation, successful legacy-hash upgrade, and post-upgrade password verification.
- Full server suite: 148 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, staged `git diff --check`, and final diff scope passed.

Commit: `9eca4cb security: harden account password login`

Remaining risks:

- Session expiry cleanup, maximum-session concurrency, token-subject binding to stored sessions, and password change/reset revocation semantics remain to be audited before G8 can complete.
- Registration/code-request account-existence responses also require an enumeration review separate from login timing.
- No production account, password, hash, token, database, secret, environment, or deployment was accessed or changed.

### Persistent session lifecycle and revocation

Audit:

- Session rows stored only a token digest and creation time. Expired rows were removed only when that exact token reached the modern endpoint, while the default-disabled compatibility lookup trusted database presence without validating JWT expiry.
- The four-session cap had no deterministic tie-breaker and counted expired rows. Stored sessions were not explicitly bound to JWT subject/JTI/expiry metadata, and the compatibility login still stored newly issued bearer tokens in replayable plaintext.

Changes:

- Added shared session issuance and validation for modern and compatibility account paths. New rows store only the token digest plus JTI and expiry, reject mismatched user ID, subject, JTI, or expiry, and delete invalid/orphaned rows on access.
- Issuance removes expired known sessions before enforcing a deterministic newest-four limit using creation time plus row ID. Legacy rows retain zero/empty metadata during migration and are validated from their signed token before metadata is lazily bound.
- Compatibility login now uses the same digest-only storage and JWT validation. Raw historical rows remain readable only behind the existing default-disabled legacy-account flag and are still subject to signature/expiry checks.
- Password change keeps only the authenticated current session; password reset revokes every session. Token issuance, password-hash upgrade, session pruning, and account mutations share the caller transaction so partial security state is not committed.
- Added reversible Alembic revision `0005_account_session_metadata`; it preserves historical token rows with empty metadata for safe validation-on-use. No production migration was executed.

Tests:

- Focused account, migration, and app-structure suite: 36 passed, 0 failed. Regressions cover expired-row cleanup, deterministic latest-four enforcement, evicted-token rejection, stored expiry/JTI/subject binding, password-change current-session retention, password-reset all-session revocation, and historical-row preservation.
- Full server suite: 151 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, staged `git diff --check`, Alembic head/check/downgrade coverage, and final diff scope passed.

Commit: `b36a724 security: enforce account session lifecycle`

Remaining risks:

- Registration and verification-code request responses still require a final account-enumeration review before G8 completion.
- The narrow issuer-less legacy JWT compatibility window must be documented with an explicit removal gate; it was not broadened by this slice.
- No production session, account, database, migration, secret, environment, or deployment was accessed or changed.

### Account-enumeration response and legacy-token exit gate

Audit:

- Registration code requests returned `409` immediately for an existing email, and registration checked account existence before consuming a code. An unauthenticated caller could therefore distinguish registered addresses without proving mailbox ownership.
- Issuer-less legacy JWT acceptance was intentionally narrow but unconditional, with no deployment switch or dated removal condition.

Changes:

- Code requests now return the same `202` message for existing registration addresses, missing reset addresses, and deliverable requests. Existing registration addresses do not receive a new registration code, and registration validates email/purpose/code before exposing an account conflict.
- Added `LEGACY_JWT_COMPATIBILITY_ENABLED`. It defaults to `true` only for the migration window, rejects legacy tokens immediately when disabled, and deployment guidance requires disabling it after one maximum session lifetime (currently 30 days) from rollout.
- SMTP delivery remains synchronous, so response duration can differ between a suppressed and delivered message. This residual timing channel is documented; removing it correctly requires a durable asynchronous mail outbox, not a fixed delay or fabricated delivery result.

Tests:

- Focused server account/migration/app suite: 38 passed, 0 failed.
- Full server suite: 153 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Flutter account repository/controller/page contract suite: 18 passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, staged `git diff --check`, and final diff scope passed.

Commit: `dc8c4fe security: close account enumeration paths`

### G8 completion verification

- Full Flutter suite: 579 passed, 26 skipped legacy/platform-conditional cases, 0 failed.
- Flutter static analysis: 0 issues.
- Full server suite: 153 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Strong signing-key fail-closed behavior, issuer/audience claims, explicit legacy-token retirement, trusted-proxy boundaries, bounded request limiting, persistent verification failure budgets, timing-resistant login, safe legacy-password upgrade, digest-only sessions, expiry/JTI/subject binding, deterministic four-session enforcement, password-change/reset revocation, migrations, and client contracts all have direct regression evidence.
- The four-material inventory remains `total=4`, `read=4`, `skipped=0`. No AniCh production API, sampled route, private implementation/protocol, token, DRM, membership, CAPTCHA, or access-control bypass was used.
- No real mail was sent and no production account, password, token, database, migration, proxy, secret, environment, or deployment was accessed or changed. Platform release builds and real-device/production-account acceptance remain G13/G14 gates.
- Residual operational work is explicit rather than hidden: disable legacy JWT compatibility after the 30-day migration window; multi-instance deployments need gateway/shared rate limiting; a future durable mail outbox should remove the synchronous-delivery timing channel.

## G9 Privacy lifecycle

Status: in_progress

### Expired authentication artifact retention

Audit:

- Expired verification codes were replaced only when the same email requested another code. Expired session rows were cleaned for the current user during issuance or when the exact token was presented, leaving unrelated expired authentication artifacts without a shared lifecycle owner.
- The client action currently labelled as clearing account data intentionally removes only this device's scoped data and signs out; it does not delete the cloud account. A real cloud-erasure flow still needs an explicit policy for authored threads/comments/danmaku versus private library/history data and must not be silently substituted for local cleanup.

Changes:

- Added one privacy lifecycle helper that deletes only verification codes at or beyond expiry and session rows with a known positive expiry at or beyond the same cutoff. Active artifacts, zero-expiry legacy migration rows, and users are outside its deletion predicate.
- Code requests commit expired-artifact cleanup before any existence-suppressed early response or mail attempt. Session issuance uses the same helper in its existing transaction, replacing its narrower per-user session cleanup.
- No production cleanup, account deletion, migration, email delivery, or database operation was executed.

Tests:

- Focused privacy/account suite: 20 passed, 0 failed.
- Full server suite: 154 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, staged `git diff --check`, and final diff scope passed.

Commit: `4c23810 privacy: purge expired auth artifacts`

Remaining risks:

- Cleanup is currently activity-driven. A bounded scheduled retention job with observable last-run/count state remains required so an idle service does not retain expired artifacts indefinitely.
- Privacy export remains unimplemented.
- Permanent cloud-account erasure is not authorized by the existing local-cleanup UI and requires an explicit deletion/anonymization decision for public authored content before implementation. No real user data was changed.

### Scheduled authentication retention

Audit:

- Activity-driven cleanup could leave expired authentication artifacts indefinitely on an otherwise idle service. Retention also had no operator-visible last-run time or aggregate deletion counts.

Changes:

- The server scheduler now owns a delayed privacy-retention loop. It runs after a bounded configurable interval (default 24 hours, minimum 1, maximum 168), reuses the fail-narrow expired-artifact predicate, commits atomically, and is cancelled through the existing scheduler shutdown lifecycle.
- Scheduler stats expose only the last successful cleanup timestamp and aggregate verification-code/session counts. No email, account ID, token, code, IP address, or row content enters stats or logs.
- Failures log only the exception class and retry after one hour; they do not terminate other scheduler work or spin without a bound.

Tests:

- Focused privacy/scheduler/app lifecycle suite: 11 passed, 0 failed. Direct regressions cover aggregate-only stats, absence of identifiers, task registration, and cancellation.
- Full server suite: 156 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, staged `git diff --check`, and final diff scope passed.

Commit: `1a985f7 privacy: schedule auth retention cleanup`

Remaining risks:

- Privacy export remains the next non-destructive G9 slice.
- Permanent cloud deletion/anonymous-public-content policy still requires explicit user direction before an irreversible flow is implemented or exercised.
- No production scheduler, cleanup, account, database, environment, or deployment was changed.

### Authenticated account data export

Audit:

- The server had no data-subject export endpoint. Account data was split across profile fields, private collection/history rows, authored danmaku/threads/images/comments, and interaction tables, making a complete user-readable inventory impossible from the client.

Changes:

- Added authenticated `GET /api/v1/auth/privacy/export` with schema version 1 and deterministic ID ordering. Its explicit field allowlist covers every non-secret account profile field, private collections/history, authored danmaku/threads/images/comments, and thread/comment interactions belonging to the current user.
- The response is attachment-shaped JSON with `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`. It excludes password hashes, bearer/token digests, JTIs, verification codes, signing/configuration secrets, other users' profiles, and other users' authored content.
- The export is read-only and performs no database mutation. It is currently a synchronous authenticated API; a client-side save/share experience remains the next product slice, and very large future accounts may require an asynchronous bounded export job.

Tests:

- Focused privacy/account/app suite: 31 passed, 0 failed. Direct regression builds two isolated users and proves authentication, ownership filtering, complete profile/private/authored categories, attachment/no-cache headers, deterministic content, and absence of both users' hashes, bearer token, and every sampled other-user value.
- Full server suite: 157 passed, 1 third-party TestClient warning, 3 subtests passed, 0 failed.
- Ruff, Python `compileall`, repository security gate, staged `git diff --check`, and final diff scope passed.

Commit: `0a11fd2 privacy: export account data safely`

Remaining risks:

- Android/Windows/Web client save/share behavior and its platform-specific permissions remain unimplemented; the server contract is complete and read-only.
- Permanent cloud deletion/anonymous-public-content policy still requires explicit user direction before irreversible implementation or execution.
- No production export, account, database, secret, environment, or deployment was accessed or changed.

### Cross-platform account export save

Audit:

- The server export contract had no client entry point. Android, Windows, and Web therefore could not request and save the authenticated JSON export from the account page.
- Raising the account transport ceiling for export initially exposed session restore to the same 25 MiB ceiling. The final implementation keeps ordinary account responses at 1 MiB and grants the larger bound only to the export request.

Changes:

- Added the signed-in account-page action `导出我的账号数据`. It requests the authenticated schema-v1 export and saves `zeluna-account-data-YYYY-MM-DD.json` through the platform file picker; Web uses the picker download path, while Android and Windows use their native save path.
- Export reads are streamed into memory with both declared-length and incremental 25 MiB limits. Ordinary account calls retain a 1 MiB application limit. The existing account network policy still disables credential-bearing redirects and validates HTTPS/public destinations, and export success or failure does not remove the session token.
- The UI distinguishes a cancelled native save from a completed export, serializes the action through its existing busy state, and reports storage failures without exposing response content.

Tests:

- Focused account repository/page suite: 13 passed, 0 failed. Direct regressions cover authentication, schema validation, token retention, export oversize rejection, the ordinary 1 MiB session-response limit, redirect denial, and the signed-in UI entry point.
- Full `flutter test --reporter compact`: 582 passed, 26 intentionally skipped, 0 failed.
- `flutter analyze --suppress-analytics`: no issues. Dart format, `git diff --check`, and the repository security gate passed.
- Android Debug, Web Release (including Wasm dry run), and Windows Release builds passed. Artifacts: Android APK 268,932,934 bytes, SHA-256 `9ABE6BB99C573CBCC5424E62F703BBF10CD925C7D91F1CF5524F8F5FCB250E16`; Web `main.dart.js` 4,849,705 bytes, SHA-256 `30C547C7EE570D5E77403F522199B89AAD600BAD2F6B5279DB929E78A5F6E13A`; Windows `Zeluna.exe` 158,208 bytes, SHA-256 `2814F973D704BE8D76230EF5790EF91D9DE0ECE2F6C7D8A0E17173B29DE9A9FC`.

Commit: `c2aa973 privacy: save account exports on clients`

Remaining risks:

- Platform builds prove compile-time integration, not a real-device file-dialog acceptance run. Android, Windows, and browser save-dialog behavior remains a G13/G14 interactive acceptance item.
- A very large future account may need an asynchronous bounded export job; the current client intentionally rejects exports above 25 MiB.
- Permanent cloud deletion/anonymous-public-content policy still requires explicit user direction before irreversible implementation or execution.
- The four-material inventory remains `total=4`, `read=4`, `skipped=0`. No AniCh production API, sampled route, private implementation/protocol, token, DRM, membership, CAPTCHA, or access-control bypass was used. No production export, account, database, secret, environment, deployment, signing material, or release artifact was changed.

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
