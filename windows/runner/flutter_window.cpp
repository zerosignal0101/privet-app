#include "flutter_window.h"

#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Closes the window once the framework's exit cleanup has replied. Closing
// happens on error and on "not implemented" too, so a reply (or the safety
// timer) can never leave the user with an unclosable window.
class CloseOnReplyResult : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  explicit CloseOnReplyResult(std::function<void()> on_done)
      : on_done_(std::move(on_done)) {}
  void SuccessInternal(const flutter::EncodableValue*) override { on_done_(); }
  void ErrorInternal(const std::string&, const std::string&,
                     const flutter::EncodableValue*) override {
    on_done_();
  }
  void NotImplementedInternal() override { on_done_(); }

 private:
  std::function<void()> on_done_;
};

constexpr UINT_PTR kExitCleanupTimerId = 1;
constexpr int kExitCleanupTimeoutMs = 5000;

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Intercept the close button. The engine does not support cancelable app
  // exit on Windows (the WM_CLOSE interception was reverted upstream), so
  // onExitRequested is never called there and the daemon would keep running
  // after the app closes. Route the close through the framework instead:
  // first WM_CLOSE starts the cleanup and is swallowed; the window is closed
  // for real once the framework replies.
  if (message == WM_CLOSE) {
    if (!close_requested_) {
      RequestExit();
      return 0;
    }
    if (!close_authorized_) {
      // Cleanup still in progress — keep swallowing until it finishes.
      return 0;
    }
    // Cleanup finished; fall through to the default close path.
  }
  if (message == WM_TIMER && wparam == kExitCleanupTimerId) {
    // The framework never replied (engine busy/crashed): force the close so
    // the user is never stuck with an unclosable window.
    KillTimer(hwnd, kExitCleanupTimerId);
    close_requested_ = true;
    close_authorized_ = true;
    Destroy();
    return 0;
  }

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

void FlutterWindow::RequestExit() {
  close_requested_ = true;
  auto* engine =
      flutter_controller_ ? flutter_controller_->engine() : nullptr;
  if (engine == nullptr) {
    close_authorized_ = true;
    Destroy();
    return;
  }
  auto channel = flutter::MethodChannel<flutter::EncodableValue>(
      engine->messenger(), "privet/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel.InvokeMethod(
      "onWindowClose", nullptr,
      std::make_unique<CloseOnReplyResult>([this]() {
        // The framework finished its exit cleanup. Re-post the close now that
        // WM_CLOSE is authorized; this re-enters MessageHandler and falls
        // through to the default destroy path.
        close_authorized_ = true;
        PostMessage(GetHandle(), WM_CLOSE, 0, 0);
      }));
  // Safety net: if the framework never replies, close anyway after a timeout.
  SetTimer(GetHandle(), kExitCleanupTimerId, kExitCleanupTimeoutMs, nullptr);
}
