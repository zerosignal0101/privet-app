#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Ask the framework to run its exit cleanup (stop the daemon unless the user
  // chose "Leave Daemon Running") before the window is allowed to close. The
  // engine does not support cancelable app exit on Windows (the WM_CLOSE
  // interception was reverted upstream), so the close is intercepted here and
  // routed through Dart via the "privet/window" method channel; the window only
  // closes once the framework replies (or the safety timer below fires).
  void RequestExit();

  // Set once the framework cleanup has been started; further WM_CLOSE messages
  // are swallowed until [close_authorized_] is set.
  bool close_requested_ = false;
  // Set once the framework cleanup has completed; WM_CLOSE may now proceed to
  // the default path (destroy window / quit).
  bool close_authorized_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
