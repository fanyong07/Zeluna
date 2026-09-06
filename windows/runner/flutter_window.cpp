#include "flutter_window.h"

#include <flutter/encodable_value.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kStorageChannelName[] = "app.anime.anime/storage";
constexpr char kWindowChannelName[] = "app.anime.anime/window";

bool RectEquals(const RECT& left, const RECT& right) {
  return left.left == right.left && left.top == right.top &&
         left.right == right.right && left.bottom == right.bottom;
}

bool SetWindowLongPtrChecked(HWND window, int index, LONG_PTR value) {
  ::SetLastError(ERROR_SUCCESS);
  const LONG_PTR previous = ::SetWindowLongPtr(window, index, value);
  return previous != 0 || ::GetLastError() == ERROR_SUCCESS;
}

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            size) != size) {
    return std::wstring();
  }
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  storage_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kStorageChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  storage_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "getAvailableBytes") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("storage_invalid_path", "A storage path is required.");
          return;
        }
        const auto path_it = arguments->find(flutter::EncodableValue("path"));
        if (path_it == arguments->end()) {
          result->Error("storage_invalid_path", "A storage path is required.");
          return;
        }
        const auto* path = std::get_if<std::string>(&path_it->second);
        const std::wstring wide_path =
            path == nullptr ? std::wstring() : Utf16FromUtf8(*path);
        if (wide_path.empty()) {
          result->Error("storage_invalid_path", "A storage path is required.");
          return;
        }
        ULARGE_INTEGER available_bytes{};
        if (!::GetDiskFreeSpaceExW(wide_path.c_str(), &available_bytes, nullptr,
                                   nullptr)) {
          result->Error("storage_query_failed",
                        "Available storage could not be read.");
          return;
        }
        result->Success(flutter::EncodableValue(
            static_cast<int64_t>(available_bytes.QuadPart)));
      });
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "isFullscreen") {
          result->Success(flutter::EncodableValue(IsFullscreen()));
          return;
        }
        if (call.method_name() == "setFullscreen") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (enabled == nullptr) {
            result->Error("window_invalid_fullscreen",
                          "A fullscreen state is required.");
            return;
          }
          if (*enabled) {
            EnterFullscreen();
          } else {
            ExitFullscreen();
          }
          // Return the real native state, not an internal requested-state flag.
          result->Success(flutter::EncodableValue(IsFullscreen()));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_.reset();
  }
  if (storage_channel_) {
    storage_channel_->SetMethodCallHandler(nullptr);
    storage_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::EnterFullscreen() {
  HWND window = GetHandle();
  if (window == nullptr) {
    return false;
  }
  if (IsFullscreen()) {
    return true;
  }

  fullscreen_original_style_ = ::GetWindowLongPtr(window, GWL_STYLE);
  fullscreen_original_ex_style_ = ::GetWindowLongPtr(window, GWL_EXSTYLE);
  if (!::GetWindowRect(window, &fullscreen_original_rect_)) {
    return false;
  }
  fullscreen_original_placement_ = {};
  fullscreen_original_placement_.length = sizeof(WINDOWPLACEMENT);
  if (!::GetWindowPlacement(window, &fullscreen_original_placement_)) {
    return false;
  }

  HMONITOR monitor =
      ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (monitor == nullptr || !::GetMonitorInfo(monitor, &monitor_info)) {
    return false;
  }

  fullscreen_state_saved_ = true;
  if (::IsIconic(window) || ::IsZoomed(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }

  const LONG_PTR fullscreen_style =
      fullscreen_original_style_ &
      ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW);
  const LONG_PTR fullscreen_ex_style =
      fullscreen_original_ex_style_ &
      ~static_cast<LONG_PTR>(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE |
                             WS_EX_CLIENTEDGE | WS_EX_STATICEDGE);
  const bool style_changed =
      SetWindowLongPtrChecked(window, GWL_STYLE, fullscreen_style);
  const bool ex_style_changed =
      SetWindowLongPtrChecked(window, GWL_EXSTYLE, fullscreen_ex_style);
  const RECT& monitor_rect = monitor_info.rcMonitor;
  const bool positioned =
      ::SetWindowPos(window, HWND_TOP, monitor_rect.left, monitor_rect.top,
                     monitor_rect.right - monitor_rect.left,
                     monitor_rect.bottom - monitor_rect.top,
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW) !=
      FALSE;

  if (!style_changed || !ex_style_changed || !positioned || !IsFullscreen()) {
    RestoreWindowState();
    return false;
  }
  return true;
}

bool FlutterWindow::ExitFullscreen() {
  if (!fullscreen_state_saved_) {
    return !IsFullscreen();
  }
  return RestoreWindowState();
}

bool FlutterWindow::IsFullscreen() {
  HWND window = GetHandle();
  if (window == nullptr) {
    return false;
  }

  const LONG_PTR style = ::GetWindowLongPtr(window, GWL_STYLE);
  if ((style & static_cast<LONG_PTR>(WS_CAPTION | WS_THICKFRAME)) != 0) {
    return false;
  }

  RECT window_rect{};
  if (!::GetWindowRect(window, &window_rect)) {
    return false;
  }
  HMONITOR monitor =
      ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (monitor == nullptr || !::GetMonitorInfo(monitor, &monitor_info)) {
    return false;
  }
  return RectEquals(window_rect, monitor_info.rcMonitor);
}

bool FlutterWindow::RestoreWindowState() {
  HWND window = GetHandle();
  if (window == nullptr || !fullscreen_state_saved_) {
    return false;
  }

  const bool style_restored = SetWindowLongPtrChecked(
      window, GWL_STYLE, fullscreen_original_style_);
  const bool ex_style_restored = SetWindowLongPtrChecked(
      window, GWL_EXSTYLE, fullscreen_original_ex_style_);
  const bool frame_refreshed =
      ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                         SWP_NOOWNERZORDER | SWP_FRAMECHANGED) != FALSE;

  WINDOWPLACEMENT placement = fullscreen_original_placement_;
  placement.length = sizeof(WINDOWPLACEMENT);
  const bool placement_restored =
      ::SetWindowPlacement(window, &placement) != FALSE;

  bool bounds_restored = true;
  if (placement.showCmd != SW_SHOWMAXIMIZED &&
      placement.showCmd != SW_SHOWMINIMIZED &&
      placement.showCmd != SW_MINIMIZE) {
    const RECT& rect = fullscreen_original_rect_;
    bounds_restored =
        ::SetWindowPos(window, nullptr, rect.left, rect.top,
                       rect.right - rect.left, rect.bottom - rect.top,
                       SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED) !=
        FALSE;
  } else if (placement.showCmd == SW_SHOWMAXIMIZED) {
    ::ShowWindow(window, SW_MAXIMIZE);
  }

  const bool restored = style_restored && ex_style_restored &&
                        frame_refreshed && placement_restored &&
                        bounds_restored && !IsFullscreen();
  if (restored) {
    fullscreen_state_saved_ = false;
  }
  return restored;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
