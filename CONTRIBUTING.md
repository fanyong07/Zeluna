# Contributing to Zeluna

## Before changing code

Read the nearest project rules, the engineering specification, and the current
progress checkpoint. Keep a change focused on one stage or one bug. Preserve
unrelated working-tree changes; never reset, clean, or overwrite another
contributor's files.

## Security and source boundaries

Do not commit passwords, tokens, cookies, signed media URLs, private signing
files, production databases, packet captures, or real user exports. AniCh
reports and the VOD sample are historical architecture references only: do not
call their production APIs, copy private code/protocols, import fixed routes,
or bypass DRM, membership, CAPTCHA, or access controls.

## Required checks

From the repository root, run the applicable commands before committing:

```text
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --suppress-analytics
flutter test --reporter compact
uv run --project server python tool/ci/repository_gate.py --root .
uv run --project server python tool/ci/dependency_gate.py --root .
```

For server changes, also run compileall, pytest, Ruff, and strict pip-audit
from `server`. For platform changes, run the relevant Android, Windows, and
Web builds. Record failures and environment limits honestly; do not disable a
security check or use an unbounded timeout to claim success.

## Commits and review

Use the `codex/` branch prefix for local work and one auditable commit per
coherent stage. Explain migrations, recovery behavior, privacy impact, and
remaining risks. Account operations, credentials, production deployment,
irreversible data changes, and release signing require explicit authorization.
