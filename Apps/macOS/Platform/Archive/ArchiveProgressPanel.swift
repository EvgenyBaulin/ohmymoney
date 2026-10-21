import AppKit

/// The small panel that says an archive is being written or opened while the work runs away
/// from the main thread: the key derivation alone takes about a second in a release build,
/// longer in Debug, and up to a minute for a header written elsewhere that asks for the most
/// iterations the format accepts. The app keeps drawing meanwhile; the panel says why nothing
/// has happened yet, and one archive operation at a time is let through (`isShowing`).
///
/// It sits as a sheet on the window in front, so that window takes no clicks until the work is
/// done; with no window it stands alone in the middle of the screen.
@MainActor
final class ArchiveProgressPanel {
  /// Whether an archive is being written or opened right now. The File menu and a double click
  /// in Finder start nothing while it is.
  private(set) static var isShowing = false

  private let panel: NSPanel

  private init(words: String) {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
      styleMask: [.titled], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 24, height: 24))
    spinner.style = .spinning
    spinner.controlSize = .regular
    spinner.startAnimation(nil)
    let label = NSTextField(wrappingLabelWithString: words)
    label.frame = NSRect(x: 56, y: 16, width: 248, height: 40)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
    content.addSubview(spinner)
    content.addSubview(label)
    panel.contentView = content
  }

  /// Shows the panel with `words` and returns it, to be closed when the work is done.
  static func show(_ words: String) -> ArchiveProgressPanel {
    let shown = ArchiveProgressPanel(words: words)
    isShowing = true
    if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
      window.beginSheet(shown.panel)
    } else {
      shown.panel.center()
      shown.panel.makeKeyAndOrderFront(nil)
    }
    return shown
  }

  func close() {
    if let parent = panel.sheetParent {
      parent.endSheet(panel)
    } else {
      panel.orderOut(nil)
    }
    Self.isShowing = false
  }
}
