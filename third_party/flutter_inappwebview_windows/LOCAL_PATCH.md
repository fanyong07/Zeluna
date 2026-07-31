# Local Windows headless WebView fix

The upstream `0.6.0` plugin destroys a headless WebView and its method-channel
delegate from inside that delegate's active `dispose` callback. On Windows this
can raise an access violation in `flutter_inappwebview_windows_plugin.dll`.

This copy defers the actual map erase to a private Win32 message window, so the
method callback returns before the C++ object and channel delegate are freed.
Keep the repeated Windows integration test passing when updating this package.

It also retains the compositor reference created by `InAppWebViewManager`,
matching the upstream fix for `RaiseFailFastException` / `Unknown Hard Error`
during DLL process detach after CoreMessaging has already shut down.
