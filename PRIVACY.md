# Privacy policy

This document describes the data boundaries implemented by the current Zeluna
client and server. It is an engineering policy, not a promise that a future
deployment may change without updating the policy and release notes.

## Data used and why

- An account email is used for registration, login, verification, and account
  recovery. Passwords are verified server-side and are never logged or stored
  in plaintext.
- The client keeps account-scoped library, history, settings, downloads, and
  sync state locally. Session tokens are kept in platform secure storage.
- Cloud sync accepts only the six allowlisted local-first record families:
  favorites, following, settings, history, playback position, and tombstones.
  Downloaded media, cookies, private rule headers, signed URLs, and external
  service credentials never enter sync.
- Source requests are untrusted network operations governed by the rule and
  public-network policies. A rule's cookies and temporary headers are scoped to
  its session and are not written to logs or cloud data.

## Playback diagnostics

The client playback trace uses an anonymous `attempt_id` and bounded timing,
format, cache, provider, and outcome fields. The server request layer adds a
short-lived `request_id` and process-local aggregate counters. Diagnostics do
not contain titles, account IDs, email, passwords, tokens, cookies, private
headers, or full signed media URLs. URL-shaped values are redacted.

The current build does not upload playback traces or crash logs to a telemetry
vendor. Local debug output is bounded and can be disabled by its owner. Any
future remote diagnostics must be opt-in, documented here, and covered by a
new retention and deletion review.

## Retention and deletion

- Access sessions expire after the configured 30-day lifetime; expired sessions
  and 10-minute verification codes are removed by the bounded privacy job.
- A confirmed cloud-account deletion freezes login, revokes sessions, and gives
  the owner a seven-day cancellation period. Finalization erases private
  library/history/interactions, sync records, sessions, verification artifacts,
  and the account.
- Authored public threads, comments, danmaku, and public thread images are
  retained as anonymous public content under the confirmed product policy.
  Author links and direct-reply labels owned by the deleted account are
  anonymized; unrelated users with the same nickname are not rewritten.
- Process-local observability counters reset on restart and contain no
  per-account rows. No production migration, deletion, or export is performed
  by repository tests or local builds.

Users may export the authenticated account data through the in-app export
action. Export files are created at the user's chosen local path and are not
uploaded by Zeluna.
