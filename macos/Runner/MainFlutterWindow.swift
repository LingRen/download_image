import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setFrame(Self.defaultFrame(for: self), display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// xib 里的默认 800x600 低于图片面板的停靠断点（900），启动时右侧面板不显示；而它的
  /// bottom-left 原点在高度不足 1577pt 的屏幕上还会把窗口顶到菜单栏底下。这里改成按屏幕
  /// 可见区域居中摆放 1200x800，可见区域不够大时自动收缩，保证顶部不被菜单栏压住。
  private static func defaultFrame(for window: NSWindow) -> NSRect {
    guard let screen = window.screen ?? NSScreen.main else {
      return window.frame
    }
    let visible = screen.visibleFrame
    let content = NSRect(
      x: 0,
      y: 0,
      width: min(1200, visible.width),
      height: min(800, visible.height)
    )
    var frame = window.frameRect(forContentRect: content)
    frame.origin = NSPoint(
      x: visible.midX - frame.width / 2,
      y: visible.midY - frame.height / 2
    )
    return frame
  }
}
