import Foundation

/// The frames AppKit saved for the Transactions, Analytics and Reports windows, removed once
/// so the sizes the windows have now apply.
///
/// SwiftUI gives a `Window` its `defaultSize` only when AppKit has no frame saved for it.
/// At first the three windows were placeholders of 900 × 532, and a Mac that opened them then
/// keeps that frame in the app's defaults: the windows came back too narrow for their table and
/// their toolbar — the period behind », the time of the table cut to «1…», the amount past
/// the edge (the live run of 19 September). At the first launch after the update, before any
/// window is made, their frames and the widths of their sidebars are removed and a flag says
/// so: a size the owner gives a window afterwards is kept. The columns of the Transactions
/// table go with them: the table keeps the width of every column it has laid out
/// (`transactions.columns`), and widths kept for the old order would bring its overflow
/// back. The test host never does it — a test run leaves the owner's defaults as they were.
enum WindowFrames {
  /// Set once the frames are gone.
  static let resetFlag = "windows.m5FramesReset"

  /// The secondary windows, by the ids of their scenes.
  static let windows = LaunchOptions.Window.allCases.map(\.rawValue)

  /// Kept by a window for its content rather than by AppKit for its frame.
  static let contentKeys = ["transactions.columns"]

  /// What AppKit keeps for a window: its frame and, for a `NavigationSplitView`, the widths of
  /// its columns.
  static func keys(of window: String) -> [String] {
    [
      "NSWindow Frame \(window)",
      "NSSplitView Subview Frames \(window), SidebarNavigationSplitView",
    ]
  }

  /// Removes the saved frames the first time it is called on `defaults`, and never again.
  /// Returns whether it removed them this time.
  @discardableResult
  static func resetOnce(in defaults: UserDefaults) -> Bool {
    guard !defaults.bool(forKey: resetFlag) else { return false }
    for key in windows.flatMap(keys(of:)) + contentKeys {
      defaults.removeObject(forKey: key)
    }
    defaults.set(true, forKey: resetFlag)
    return true
  }
}
