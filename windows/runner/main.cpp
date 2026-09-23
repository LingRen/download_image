#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"download_image", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // 模板默认把窗口放在 (10, 10)，基本等于屏幕左上角：任务栏置顶或高缩放的窄屏上，
  // 标题栏会被顶部的系统栏压住。这里在 Show() 之前把它挪到工作区居中；窗口比工作区
  // 还大时先收缩到工作区尺寸，否则居中会让顶部反而超出工作区。
  RECT work_area;
  RECT frame;
  if (SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0) &&
      GetWindowRect(window.GetHandle(), &frame)) {
    const int work_width = work_area.right - work_area.left;
    const int work_height = work_area.bottom - work_area.top;
    const int width = std::min<int>(frame.right - frame.left, work_width);
    const int height = std::min<int>(frame.bottom - frame.top, work_height);

    SetWindowPos(window.GetHandle(), nullptr,
                 work_area.left + (work_width - width) / 2,
                 work_area.top + (work_height - height) / 2, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
