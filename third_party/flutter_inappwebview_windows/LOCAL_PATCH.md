# Local Windows WebView fork record

## Upstream baseline

- Package: `flutter_inappwebview_windows` `0.6.0` from pub.dev.
- Repository: `pichillilorenzo/flutter_inappwebview`.
- Upstream tag: `v6.1.5`.
- Upstream commit: `f67ae1f34868c7660c16a2473f53a7a7bfb6f784`.
- License: Apache-2.0; the unmodified upstream license is retained in `LICENSE`.

The pub.dev `0.6.0` package is the byte-level comparison baseline. The tag and
commit identify the corresponding upstream repository state; do not replace
this directory with the current upstream branch without a fresh review.

## Local behavioral patches

The upstream `0.6.0` plugin destroys a headless WebView and its method-channel
delegate from inside that delegate's active `dispose` callback. On Windows this
can raise an access violation in `flutter_inappwebview_windows_plugin.dll`.

This copy defers the actual map erase to a private Win32 message window, so the
method callback returns before the C++ object and channel delegate are freed.
Keep the repeated Windows integration test passing when updating this package.

It also retains the compositor reference created by `InAppWebViewManager`,
matching the upstream fix for `RaiseFailFastException` / `Unknown Hard Error`
during DLL process detach after CoreMessaging has already shut down.

Functional changes are limited to:

- `headless_in_app_webview_manager.{h,cpp}`: add a message-only Win32 window,
  queue headless WebView IDs, and erase them after the method callback returns.
- `headless_webview_channel_delegate.cpp`: acknowledge `dispose` before
  scheduling the deferred erase.
- `in_app_webview_manager.cpp`: retain the compositor reference needed during
  DLL shutdown.
- `windows/CMakeLists.txt`: define the Microsoft STL compatibility macro for
  the upstream WinRT experimental-coroutine dependency so the fork continues
  to build with MSVC 14.51 and newer toolchains.

The remaining differences from the pub.dev archive remove trailing whitespace
only and do not change behavior.

## Update procedure

1. Resolve the intended upstream version and commit, then update this baseline
   section before changing code.
2. Compare the pristine pub.dev package with this directory using
   `git diff --no-index <pub-cache-package> third_party/flutter_inappwebview_windows`.
3. Reapply or retire each functional patch explicitly; never copy the fork over
   a new upstream version without reviewing the complete diff and license.
4. Run `flutter pub get`, `flutter analyze`, `flutter build windows`, and
   `integration_test/animeko_webview_sniffer_integration_test.dart` on Windows.
   The integration test must complete repeated create/dispose/cleanup cycles.
5. Record the new upstream version, commit, local file list, and verification in
   this file and `docs/engineering-goal-progress.md`.
