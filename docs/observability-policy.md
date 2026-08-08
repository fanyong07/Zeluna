# Zeluna observability policy

## Goals

Observability must tell maintainers whether a failure is in metadata, source
discovery, route verification, CDN transfer, or decoding without collecting a
user's content or credentials. The policy covers the client playback timeline
and the server request layer.

## Event contract

The client `PlaybackPerformanceTrace` emits a bounded timeline with:

- anonymous `attempt_id` and monotonic elapsed time;
- playback lifecycle events such as request, lookup, candidate, first frame,
  buffering, recovery, and final failure;
- fixed dimensions: platform, format, provider, cache state, verification
  state, and error category when available.

The server emits a generated `X-Request-ID` for every HTTP response and logs
only method, matched route template, status, duration, and that request ID.
Aggregate health counters contain total requests, error count, status classes,
fixed method buckets, bounded latency buckets, and process uptime.

## Redaction and limits

No event or log may contain a full URL, query string, signed media route,
cookie, authorization header, private rule header, token, password, email,
account identifier, title, or user-authored text. URL-shaped strings and
credential-like field names are dropped. Client traces are capped at 128 events
per attempt; server dimensions are fixed to prevent unbounded cardinality.

The server counters are process-local and reset on restart. They are not an
account database, are not synced, and are not exported as user data. The current
build has no remote telemetry vendor or automatic crash upload.

## Support and incident handling

When a user shares diagnostics, ask for the app version, platform, timestamp,
request ID, attempt ID, and the redacted error category. Never request a token,
cookie, password, signed URL, private rule, or production database. Reproduce
with synthetic fixtures, rotate any accidentally disclosed credential, and
record only aggregate impact in an incident note.

Changes to fields, sinks, retention, remote transport, or consent require an
update to this policy, a focused regression, and a release-note entry.
