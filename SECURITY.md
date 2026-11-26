# Security policy

## Scope

Security fixes must preserve Zeluna's public-only network boundary, account
scope, rule permissions, download integrity checks, and privacy lifecycle. The
repository does not contain production credentials, user databases, signing
material, or fixed third-party media routes.

The supported security baseline is the latest commit on the protected default
branch and the release commit named by its release notes. Older builds may not
receive fixes.

## Report privately

Do not open a public issue for an unpatched vulnerability. Use a private GitHub
Security Advisory or another private channel to the repository maintainers.
Include the affected commit/version, a minimal reproduction, impact, and any
safe logs needed to reproduce it. Redact passwords, verification codes, bearer
tokens, cookies, signed media URLs, personal email addresses, and production
identifiers before sending a report.

The maintainer will acknowledge a report when it is received, reproduce it in
a non-production fixture where possible, and publish a fix or mitigation with
the release notes. Do not test against production accounts, providers, or
infrastructure without explicit authorization.

## Safe disclosure rules

- Never bypass DRM, membership, CAPTCHA, rate limits, or access controls.
- Never upload private rule code, provider cookies, real media URLs, or tokens.
- Request IDs and anonymous playback attempt IDs are safe correlation values;
  they do not authorize access and should still be treated as support data.
- Run the repository security and dependency gates before sharing a patch.
