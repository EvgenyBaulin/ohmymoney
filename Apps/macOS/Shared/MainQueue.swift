import Foundation

/// Work that must not run inside the callback that asked for it.
///
/// AppKit warns — and says it will assert one day — when an app does something reentrant inside
/// an `NSTableView` delegate callback. A double click in the table is such a callback, and
/// opening the inspector from it changes the window's state while the table is still in the
/// middle of handling the click. The work is handed to the next turn of the main queue instead:
/// by then the table has finished with the click.
@MainActor
enum MainQueue {
  /// Runs the work on the next turn of the main queue, never inside the current callback.
  static func afterCallback(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
  }
}
