# Android playback startup acceleration — 2026-10-27

## Scope and acceptance

Reported scenario: Android, 《败犬女主太多了！》season 1 episode 1,
`bangumi:464376` / `tmdb:tv:241535`. Do not substitute season 2.
Improve real time-to-picture, not only API latency. No new sources are enabled;
no source permissions, TLS verification, public-address checks, user proxy,
backend credentials or production data are changed. This patch needs no backend deployment.

## Reproduced baseline

Same isolated Android 13/API 33 x86_64 device, production backend and native decoder:

- Installed v1.2.4, normal search/detail/play flow, fresh app process: lookup first
  returned empty at 12.7 s; expanded discovery opened a route at 25.4 s; timeout
  and retry; first-frame event at **65.6 s**. A later stall/retry was also recorded.
- Production PlayerPage integration, clean per-identity application state:
  Bangumi first-frame event **31.6 s**, TMDB **20.2 s**. Both eventually produced
  decoded image bytes and progressed at least five seconds.
- Independent bounded source checks on Android: 红牛、速博、光速、豪华、魔都、最大
  passed manifest/media probes in this observation. Only 红牛 and 速博 were also
  exercised in the isolated native-decoder diagnostic, with image capture and
  ten seconds of progress. These are observations, not permanent availability guarantees.

## Causes and bounded fixes

1. Detail prefetch and foreground Play shared the backend HTTP request but not
   the discovery/probe work. Two simultaneous callers independently probed the
   same candidates. Add in-flight sharing to the existing discovery controller,
   keyed by account/context/epoch, title, episode and preferred provider.
   Cancellation is per subscriber; the last subscriber or scope invalidation
   cancels the owned operation. No new persistent cache or global route state.
2. Old `zeluna:`-only checks omitted modern `aggregate.*` / `crawler.*` routes
   from detail-prefetch verification. Include current backend identities and
   registered inventory IDs. Fresh explicit server evidence may start playback
   without another blocking bulk probe; stale/client-required routes still need
   local validation. Never mark a raw candidate playable.
3. Known HLS/DASH URLs first fetched only 2 KB, then fetched the same manifest
   again. Request the existing bounded 512 KB manifest range on the first read.
   Binary segments still use the small sniff; key/segment checks remain mandatory.
   Opaque URLs still use signature detection and expanded-manifest fallback.
4. Android's relay created and closed a client for every request. Use bounded,
   per-open exclusive connection leases. Only fully consumed successful responses
   re-enter the idle pool. Cancelled/error/incomplete transfers close their own
   lease, not other transfers. Dispose revokes capabilities and closes all leases.
   Headers remain per request; redirects and cross-origin stripping are unchanged.
5. Next-episode route warmup used to start three seconds after first frame even
   with only about one second buffered. Defer it until the current episode has
   progressed 12 seconds and has 12 seconds of reserve; retry eligibility on
   normal progress. No hidden player or speculative segment downloading is added.

## Regression and device results before release packaging

- New tests went red on duplicate foreground/prefetch probes, omitted modern
  namespace prefetch, duplicate server-evidence checks, per-request client creation
  and double manifest requests; all were then fixed.
- Relay tests cover independent active leases, failed response retirement,
  dispose, silent-stream cancellation, Range, credential stripping and DNS policy.
- Production page after the changes: Bangumi first-frame event **11.25 s**, TMDB
  **3.17 s**; first screenshot-confirmed decoding at **14.43 s / 5.71 s**;
  both continued at least five seconds. One short initial buffering interval
  remained in each test. No startup retry occurred in that run.
- Relay-only before/after: 红牛 first decoded frame 8.67 -> 7.24 s;
  速博 8.44 -> 8.53 s (no improvement in that sample). Both continued playback.
  Client allocations for those windows fell from five to two. Do not claim the
  relay alone accounts for the complete end-to-end improvement.
- A diagnostic using isolated probe clients was evaluated but NOT adopted: the
  sample did not establish a reliable advantage over the existing provider wiring.
- Temporary timing prints and the diagnostic-only entrypoint are not shipped.
  The opt-in production test now reports screenshot-confirmed first-frame time
  separately from the combined lookup/decode/sustained duration.

## Reproduction and remaining boundaries

Use `flutter test integration_test/production_player_live_test.dart -d <device>
--dart-define=PRODUCTION_PLAYER_LIVE=true` for the real production pipeline.
Normal CI remains offline/deterministic. Artifacts and redacted measurements are
under `.codex_tmp/playback-speed-20261027` and the existing diagnostic log folder.

Release packaging must bind version **1.2.5+76**, exact Git HEAD, new Quality Gates
receipt and manifest. The final installed Release APK must be tested separately;
these debug integration results are not its acceptance. Previous v1.2.4 is immutable.
The historical sideload certificate is not a production/store signing identity.

External CDN load, ISP/region, physical Android devices and other episodes remain
outside this sample. No promise that all registered sources work or every start
is instantaneous. Inventory size, HTTP probe, first-frame event, decoded image,
sustained playback and release upload are distinct evidence levels.
