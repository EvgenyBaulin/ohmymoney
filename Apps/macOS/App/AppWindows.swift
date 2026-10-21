import AppCore
import AppKit
import SwiftUI

/// The windows of the app: none of them is ever a tab, a secondary window opens floating over a
/// main window in full screen, and closing the main window quits the app.
///
/// Every window is a window of its own (`tabbingMode = .disallowed`, and the system's automatic
/// tabbing is off for the whole app, so the Window and View menus carry no tab items).
/// Transactions, Analytics, Reports and Settings may stand over a main window in full screen,
/// in its Space (`.fullScreenAuxiliary`), and come to the Space the owner is in when they are
/// brought forward (`.moveToActiveSpace`) — at their own size, never larger than the screen.
/// Closing such a window returns to the window under it.
///
/// Nothing stays in the background: closing the main window quits «OhMyMoney» the way ⌘Q does,
/// whatever else is open, and so does closing the last window of the app. The quit goes
/// through `AppDelegate.applicationShouldTerminate`, which stops the pipeline, writes the copy
/// still waiting and closes the database before the process goes. The test host never quits.
@MainActor
enum AppWindows {
  /// What a window is to the app.
  enum Role: Equatable, Sendable {
    /// The window of the books; closing it quits.
    case main
    /// Transactions, Analytics or Reports; `scene` is the id of its scene.
    case secondary(scene: String)
    case settings
  }

  /// What the menu, the toolbar and the quit read of a window. Weak: a closed window goes.
  private final class Entry {
    weak var window: NSWindow?
    let role: Role
    var observer: NSObjectProtocol?

    init(window: NSWindow, role: Role) {
      self.window = window
      self.role = role
    }
  }

  private static var entries: [ObjectIdentifier: Entry] = [:]
  /// The quit has been asked for once; a window closing on the way out does not ask again.
  private static var quitRequested = false

  /// What closing the main window does: asks AppKit to quit. Never in the test host, whose
  /// tests close windows of the app all day. A test of the rule puts its own here.
  static var terminate: @MainActor () -> Void = {
    guard !AppEnvironment.isTestHost else { return }
    NSApp.terminate(nil)
  }

  /// Turns the system's automatic tabbing off for the whole app: no window merges into
  /// another, and AppKit leaves «Show Tab Bar», «Show All Tabs», «Merge All Windows» and
  /// «Move Tab to New Window» out of the menus. Before the menus and the first window are made.
  static func disallowTabs() {
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  // MARK: - Rules

  /// How a window joins the Spaces. The main window is the one that goes full screen; the
  /// others stand over it there, and come to the Space the owner is in when brought forward.
  nonisolated static func collectionBehavior(
    for role: Role, from current: NSWindow.CollectionBehavior
  ) -> NSWindow.CollectionBehavior {
    var behavior = current
    switch role {
    case .main:
      behavior.remove([.fullScreenAuxiliary, .fullScreenNone, .moveToActiveSpace])
      behavior.insert(.fullScreenPrimary)
    case .secondary, .settings:
      // The three full-screen kinds exclude each other, and so do the two Space moves.
      behavior.remove([.fullScreenPrimary, .fullScreenNone, .canJoinAllSpaces])
      behavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
    }
    return behavior
  }

  /// A frame moved and, only if it must, shrunk into `visible`: a window never opens larger
  /// than the screen or partly off it. A frame that fits stays exactly as it is.
  nonisolated static func fitting(_ frame: CGRect, in visible: CGRect) -> CGRect {
    guard !visible.isEmpty else { return frame }
    var fitted = frame
    fitted.size.width = min(frame.width, visible.width)
    fitted.size.height = min(frame.height, visible.height)
    fitted.origin.x = min(max(frame.minX, visible.minX), visible.maxX - fitted.width)
    fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
    return fitted
  }

  /// Whether closing a window quits the app: the main window always does; any other one when no
  /// other window of the app is left open.
  nonisolated static func quitsOnClose(_ closing: Role, othersOpen: [Role]) -> Bool {
    closing == .main || othersOpen.isEmpty
  }

  // MARK: - Windows

  /// Gives a window its role: no tabs, its Space behaviour, a frame that fits, and the quit on
  /// close. Marking the same window again changes nothing.
  static func mark(_ window: NSWindow, as role: Role) {
    window.tabbingMode = .disallowed
    window.collectionBehavior = collectionBehavior(for: role, from: window.collectionBehavior)
    let key = ObjectIdentifier(window)
    if entries[key]?.window !== window || entries[key]?.role != role {
      forget(key)
      let entry = Entry(window: window, role: role)
      entry.observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: nil
      ) { _ in
        MainActor.assumeIsolated { windowWillClose(key) }
      }
      entries[key] = entry
    }
    if role != .main { fitOnScreen(window) }
  }

  /// The window of a role, while it is open.
  static func window(of role: Role) -> NSWindow? {
    entries.values.first { $0.role == role && $0.window != nil }?.window
  }

  /// The roles of the windows still open, the given one left out.
  static func openRoles(except key: ObjectIdentifier? = nil) -> [Role] {
    entries.filter { $0.key != key && $0.value.window != nil }.map(\.value.role)
  }

  /// ⌃⌘F: the main window goes into full screen and comes out of it again. Only the main window
  /// does — the others stand over it there (`collectionBehavior`) — so the target is the main
  /// window whichever window of the app is in front; nothing is open, nothing happens.
  @discardableResult
  static func toggleFullScreen() -> Bool {
    guard let main = window(of: .main) else { return false }
    main.toggleFullScreen(nil)
    return true
  }

  /// A main window in full screen, if there is one.
  static var mainInFullScreen: NSWindow? {
    entries.values.lazy.filter { $0.role == .main }.compactMap(\.window)
      .first { $0.styleMask.contains(.fullScreen) }
  }

  /// Opens a secondary window the way its menu item and its toolbar button do: a window open
  /// already comes forward — the same one, never a second — over the main window, in the Space
  /// the owner is in.
  static func open(_ scene: String, with openWindow: OpenWindowAction) {
    openWindow(id: scene)
    Task { @MainActor in
      // After SwiftUI has made the window or ordered it in.
      await Task.yield()
      bringForward(.secondary(scene: scene))
    }
  }

  /// Brings the window of a role forward, fitted to the screen; returns it, if it is open.
  @discardableResult
  static func bringForward(_ role: Role) -> NSWindow? {
    guard let window = window(of: role) else { return nil }
    mark(window, as: role)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    // In front of the other windows of the app even while another app is active.
    window.orderFront(nil)
    return window
  }

  /// Does what shows itself in the main window — the guide's cards, «Показать, куда нажимать» —
  /// with the main window brought forward first: asked while the settings or another window
  /// stood in front, it happened behind them, out of sight. The windows in front stay open,
  /// behind the main one.
  static func intoMain(_ action: () -> Void) {
    bringForward(.main)
    action()
  }

  /// Whether `window` stands in front of `other` among the app's windows on screen (the list of
  /// `NSApp.orderedWindows` goes from the front). False when either is not on screen.
  static func isInFront(_ window: NSWindow, of other: NSWindow) -> Bool {
    let ordered = NSApp.orderedWindows
    guard let front = ordered.firstIndex(of: window), let back = ordered.firstIndex(of: other)
    else { return false }
    return front < back
  }

  /// Shrinks and moves a window into the screen it opens on: the screen of a main window in
  /// full screen, else its own.
  private static func fitOnScreen(_ window: NSWindow) {
    let screen = mainInFullScreen?.screen ?? window.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let fitted = fitting(window.frame, in: visible)
    if fitted != window.frame { window.setFrame(fitted, display: false) }
  }

  private static func windowWillClose(_ key: ObjectIdentifier) {
    guard let entry = entries[key] else { return }
    let role = entry.role
    forget(key)
    guard !quitRequested, quitsOnClose(role, othersOpen: openRoles()) else { return }
    quitRequested = !AppEnvironment.isTestHost
    AppLog.info(
      "windows.closedQuits", .ui, "the window closed was the main or the last one",
      [LogPair("main", .flag(role == .main))])
    terminate()
  }

  private static func forget(_ key: ObjectIdentifier) {
    if let observer = entries[key]?.observer {
      NotificationCenter.default.removeObserver(observer)
    }
    entries[key] = nil
  }

  /// The app is quitting by any way — ⌘Q, the Dock, a relaunch, a closed window: the windows
  /// AppKit or SwiftUI may close on the way out ask for nothing more.
  static func noteQuitting() {
    if !AppEnvironment.isTestHost { quitRequested = true }
  }

  /// Forgets every window: for a test that marks windows of its own.
  static func forgetAll() {
    for key in Array(entries.keys) { forget(key) }
    quitRequested = false
  }
}

extension View {
  /// Gives the window this view is in its role (`AppWindows`).
  func appWindow(_ role: AppWindows.Role) -> some View {
    background(AppWindowMark(role: role))
  }
}

private struct AppWindowMark: NSViewRepresentable {
  let role: AppWindows.Role

  func makeNSView(context: Context) -> NSView { Anchor(role: role) }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class Anchor: NSView {
    let role: AppWindows.Role

    init(role: AppWindows.Role) {
      self.role = role
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      AppWindows.mark(window, as: role)
    }
  }
}
