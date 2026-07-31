#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_HEADLESS_IN_APP_WEBVIEW_MANAGER_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_HEADLESS_IN_APP_WEBVIEW_MANAGER_H_

#include <flutter/method_channel.h>
#include <map>
#include <string>
#include <vector>
#include <wil/com.h>
#include <winrt/base.h>

#include "../flutter_inappwebview_windows_plugin.h"
#include "../types/channel_delegate.h"
#include "headless_in_app_webview.h"

namespace flutter_inappwebview_plugin
{
  class HeadlessInAppWebViewManager : public ChannelDelegate
  {
  public:
    static inline const std::string METHOD_CHANNEL_NAME = "com.pichillilorenzo/flutter_headless_inappwebview";

    const FlutterInappwebviewWindowsPlugin* plugin;
    std::map<std::string, std::unique_ptr<HeadlessInAppWebView>> webViews;

    HeadlessInAppWebViewManager(const FlutterInappwebviewWindowsPlugin* plugin);
    ~HeadlessInAppWebViewManager();

    void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    void run(const flutter::EncodableMap* arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
    void scheduleDispose(const std::string& id);
  private:
    static inline const UINT WM_DISPOSE_HEADLESS_WEBVIEW = WM_APP + 0x351;

    WNDCLASS windowClass_ = {};
    HWND cleanupWindow_ = nullptr;
    std::vector<std::string> pendingDisposals_;

    static LRESULT CALLBACK CleanupWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
    void drainPendingDisposals();
  };
}
#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_HEADLESS_IN_APP_WEBVIEW_MANAGER_H_
