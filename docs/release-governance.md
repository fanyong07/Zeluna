# Zeluna release governance

## Release gate

Release artifacts may be produced only from a commit with the pinned CI
workflow green: Flutter format/analyze/tests, Android/Windows/Web builds,
Windows WebView integration, server compile/pytest/Ruff/pip-audit, repository
security, dependency/license, and SBOM gates. A release candidate must also
record the four-material inventory (`total=4`, `read=4`, `skipped=0`).

The version comes from the single `version:` field in `pubspec.yaml`. Do not
hand-edit artifact names or inject a second version source. The release commit,
version, CI run, artifact sizes, and SHA-256 values are written by
`tool/create_release_manifest.ps1`.

## Platform packaging

1. Android: build the signed AAB/APK only with a private production keystore
   supplied outside the repository. `android/key.properties` and keystore files
   are ignored and must never be printed, committed, or uploaded in logs.
   `tool/check_release.ps1` must reject missing/placeholder/debug signing,
   stale artifacts, generic branding, and invalid manifests. The Android
   packaging helper emits a versioned filename, a `.sha256` sidecar, and the
   checksum in its output.
2. Windows: build `flutter build windows --release`, then use
   `tool/package_windows_release.ps1` to produce a versioned archive. The
   staging directory is disposable and must remain inside the project
   `release/` directory. The archive includes a small version/commit metadata
   file and the helper emits a `.sha256` sidecar.
3. Web: build `flutter build web --release` and publish the complete `build/web`
   directory as an immutable versioned archive. Serve it over HTTPS; do not
   open `index.html` directly as a production test.

After all artifacts exist, generate the manifest with explicit paths, for
example:

```powershell
powershell -ExecutionPolicy Bypass -File tool/create_release_manifest.ps1 -ArtifactPath build/app/outputs/bundle/release/app-release.aab,build/windows/x64/runner/Release/Zeluna.exe,build/web/main.dart.js
```

The command only reads artifacts and writes the manifest under `release/`; it
does not sign, upload, deploy, or delete anything.

## Provenance and rollback

Keep the manifest, CI run URL/ID, toolchain versions, release notes, and the
previous known-good manifest together. Publish checksums beside artifacts and
verify them after transfer. Roll back by switching the serving/package pointer
to the previous immutable artifact and re-running health, login, catalog,
playback, download, and privacy smoke checks. Never roll back by deleting a
user database or clearing cloud data.

## Required approvals and current blockers

- Production account operations, migration, deployment, email, irreversible
  deletion, and public release require separate authorization.
- The repository owner selected Apache License 2.0. Release artifacts must
  include `LICENSE` and preserve the independent notices and licenses recorded
  in `THIRD_PARTY_NOTICES.md`.
- The repository owner selected the historical Android Debug certificate only
  to preserve the signing identity of existing internal APKs. It is permitted
  for internal sideload and overwrite-install acceptance, but it is not a
  production/store signing identity and must never be presented as one.
- A public Android release remains blocked until a separately protected
  production signing identity is approved. The release checker continues to
  reject the historical compatibility certificate; this gate must not be
  disabled for publication.

## Branch and tag policy

Protect the default branch: require the pinned quality workflow, review, and no
force-push. Create a release tag only after the manifest and release notes are
reviewed. Tags should identify immutable commits; never rebuild a release from
an uncommitted or dirty checkout.
