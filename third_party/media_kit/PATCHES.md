# Zeluna local media_kit 1.2.6 patch

## Provenance and scope

- Upstream repository: <https://github.com/media-kit/media-kit>.
- Exact published package: <https://pub.dev/packages/media_kit/versions/1.2.6>.
- Imported from the already-installed `hosted/pub.dev/media_kit-1.2.6` package,
  not a moving Git branch. The global Pub cache is not modified.
- Published archive SHA-256, as recorded by the original application lockfile:
  `ae9e79597500c7ad6083a3c7b7b7544ddabfceacce7ae5c9709b0ec16a5d6643`.
- Original `lib/src/player/native/player/real.dart` SHA-256:
  `6286405e40d9102a7fbca968eb23a313a0735ce40355caa779f4767b06f8e032`.
- Original `pubspec.yaml` SHA-256:
  `baede349813578fd5c7f63b9883d520c09d66572ec93aaadafeb05f00ef0fbe3`.
- Application source context supplied for this investigation: `769ee519`.
  This is the application HEAD, not a claim about the upstream package Git SHA.
- Retained: `lib/`, `assets/web/`, original `pubspec.yaml`, `LICENSE`,
  `README.md`, and `CHANGELOG.md`. The original published metadata is unchanged;
  its promotional screenshot references are retained but their images are not
  vendored. No upstream examples, CI/tests, cache, build output or native binary
  is imported. Focused local tests live in the application test directory.
- Package version stays `1.2.6`; the investigation used app `1.3.1+87`, and
  the patch ships with app `1.4.0+88`. The root dependency override selects this
  directory without upgrading native/video dependencies.
- MIT license and original notices are retained. The package also retains its
  existing embedded FFI/isolate source notices without changing their licenses.

### Embedded FFI license restoration (2026-11-07)

The five Dart files under `lib/ffi/` retain Dart project copyright headers.
`lib/ffi/README.txt` identifies their upstream as `ffi 1.2.1`; that code uses
BSD-3-Clause, not the top-level media_kit MIT license. The upstream media_kit
package omitted the BSD license text referenced by those headers. This local
fork restores it as `lib/ffi/LICENSE`, and the root `THIRD_PARTY_NOTICES.md`
reproduces the full text because that notices file is already bundled with the
application. The original top-level MIT `LICENSE` and all embedded code remain
unchanged by this notice-only correction.

Verified public provenance:

- Version metadata: <https://pub.dev/api/packages/ffi/versions/1.2.1>.
- Exact archive: <https://pub.dev/api/archives/ffi-1.2.1.tar.gz>.
- Archive SHA-256 (downloaded bytes equal the registry metadata):
  `13a6ccf6a459a125b3fcdb6ec73bd5ff90822e071207c663bfd1f70062d51d18`.
- Original archive `LICENSE` SHA-256:
  `0371d1da6a57fb791db29d29b95333429205f51f3cb2eb3a0c12d91838a38744`.
- Restored `lib/ffi/LICENSE` SHA-256:
  `efa31b5ac790016736fa9761642b0af16d37cd4fb483de2905adb5258cb89722`.
  The sole text normalization removes the trailing space on the first line;
  copyright, conditions and disclaimer are unchanged.
- Corresponding version-tag text:
  <https://raw.githubusercontent.com/dart-lang/ffi/v1.2.1/LICENSE>.

The embedded code is media_kit's adapted copy, not claimed to be a byte-identical
copy of the ffi archive: `ffi.dart` matches; the other files retain upstream
media_kit import/API adjustments. This restoration does not upgrade ffi, alter
the runtime patch, change dependency-gate policy, or claim that the generated
package-level SBOM inventories every embedded source component.

### Import whitespace normalization

The import removes one trailing-space-only line in
`lib/src/player/native/core/initializer_native_callable.dart` and one extra blank
line at EOF in `lib/ffi/README.txt` so the newly tracked snapshot passes Git's
whitespace check. No executable statements change in these two files.

## Defect and minimal ownership fix

The published native `_screenshot` used
`calloc.allocate(args.join().length)` for `char **argv`. This is a byte count
based on command text, not the size of the pointer array. The normal arguments
`['screenshot-raw', 'video']` request 19 bytes. Two pointer entries plus the
required NULL terminator need 24 bytes on a 64-bit ABI (12 on a 32-bit ABI).
The `subtitles` variant requests 23 bytes and is also short on 64-bit. Zeroed
allocator memory is not a substitute for reserving a complete final pointer;
libmpv's terminator read can cross the allocation boundary.

The shared `lib/src/player/native/utils/screenshot.dart` helper now uses typed
`allocator<Pointer<Utf8>>(args.length + 1)`, with production `allocator = calloc`
(i.e. `calloc<Pointer<Utf8>>(args.length + 1)`), and explicitly writes
`arr[args.length] = nullptr`. It is used by the real screenshot worker, not just
by a test implementation. UTF-8 arguments, argv and result storage have a
try/finally owner, including partial allocation and result-reader exceptions.
On a negative `mpv_command_ret` return code, no result is read and the public
screenshot returns null. Per the generated libmpv API contract, node contents
are freed only after a successful command; the result struct itself is always
freed. Successful JPEG, PNG and raw-BGRA output behavior is unchanged.

## Local decoded-frame probe

`NativePlayer.hasDecodedVideoFrame({bool synchronized = true})` is a local
native-only extension, with a false-returning web compilation stub. It is not
an upstream `Player` API addition. It uses the same fixed screenshot-raw helper
inside `compute`, checks an actual returned node map for positive width/height,
BGRA row stride, non-null data and sufficient byte extent, then returns only a
bool. It performs no JPEG/PNG encoding, no Dart pixel buffer allocation/copy,
and no transfer of frame bytes back to the calling isolate. A failed command
or absent/invalid frame returns false. It does not infer a decoded frame from
playback clocks, reported track dimensions or other metadata.

This still requests a raw frame from libmpv, which may require decoder/GPU work
and native memory. It is not a zero-cost readiness query. Calling frequency,
in-flight suppression and timeout handling belong to the application. Timing
out a caller's Future does not cancel the isolate or native command.

## Lock/lifecycle review (no lock rewrite)

The upstream `screenshot` wraps its async callback in the same static
`NativePlayer.lock` used by default `stop` and `dispose`. Returning the compute
Future from that callback retains the lock until the worker finishes;
`synchronized` 3.4.0+1 awaits the callback's Future before releasing the lock.
The new bool probe follows that exact pattern. The existing disposal guard,
initialization waits, stop/dispose flow and delayed native-handle destruction
are unchanged. Explicit `synchronized: false` callers still own serialization.
Hot-restart/native-reference cleanup and native operations outside that lock
are not newly covered by this patch. Existing global-lock contention can still
block other player operations for the duration of a native screenshot.

## Focused regression verification

From the application root:

```powershell
flutter pub get --offline
flutter test --no-pub test/media_kit_screenshot_allocation_test.dart
```

Tests exercise the actual helper with a recording/poisoning allocator and
post-allocation canaries: exact pointer-array allocation, explicit terminator,
both screenshot argument variants, command failure, command/reader/node-free
exceptions, each allocation failure, and cleanup without double frees. The
host pointer-slot count is also modeled for 32/64-bit ABI sizes (12/24 bytes).
The 32-bit size case is a layout model, not an ARMv7/native 32-bit execution.
Synthetic mpv node maps check the bool result reader, including missing data,
invalid dimensions/stride and insufficient bytes.

Observed local verification:

- `flutter pub get --offline`: success; every package version unchanged and
  lockfile content changed only in the media_kit entry (hosted to local path).
- Focused Flutter test command above: **21 tests passed** on the Windows x64
  host. No libmpv library or real video is required by those tests.
- Targeted `dart analyze` of the helper and test: **No issues found**. Including
  the existing real/stub player files produced only pre-existing upstream
  informational lints (doc comments and print calls), no errors or warnings.
- The JPEG/PNG/raw result-conversion body was compared with the installed
  upstream source and is byte-for-byte unchanged.
- All copied upstream files match their installed SHA-256 hashes except the
  intended real/stub player patches. The original global-cache source hash
  still matches the provenance hash above.

These focused tests do not execute libmpv or prove the reported physical
Android crash was caused by this defect. Subsequent application-level Android
API35 x86_64 Profile validation (null VO, locally generated raw AVI) passed
12 opens, 60 repeated bool probes, 12 JPEG screenshots and probe/stop/dispose
races; see `docs/android-stability-20261106.md` in the application. This checks
real libmpv ownership but not physical ARM GPU output. Further physical-device
validation remains required. API35 direct-surface behavior is not evidence that the physical
ARM screenshot path is safe. The unrelated upstream generated `size_t` alias
is fixed at `Uint64`; this patch leaves it unchanged, so full 32-bit binding/ABI
validation is a separate concern rather than a claim made by the argv tests.
