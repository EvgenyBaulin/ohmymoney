import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Whatever the settings open stands over the settings: a sheet of the settings window itself.
/// The starter set asked from «Основные» was a sheet of the main window, behind the settings and
/// out of sight. What shows itself in the main window — the guide's cards, «Показать, куда
/// нажимать» — brings the main window forward over the settings first.
@MainActor
final class SettingsWindowsTests: XCTestCase {
  private var windows: [NSWindow] = []

  override func tearDown() async throws {
    for window in windows { window.close() }
    windows = []
    SettingsStarterSet.shared.isUp = false
    StarterSetOffer.shared.isRequested = false
    AppWindows.forgetAll()
  }

  private static func wait(timeout: TimeInterval = 5, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
  }

  private func window(_ root: some View, size: CGSize) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: callers pass `AppScenes.root` (or a bare colour that reads nothing).
    window.contentViewController = NSHostingController(rootView: root)
    window.setContentSize(size)
    windows.append(window)
    return window
  }

  /// «Выбрать стартовый набор…» asks the settings' own sheet, not the main window's offer.
  func testTheStarterSetOfTheSettingsIsNotTheMainWindowsOffer() {
    SettingsStarterSet.shared.open()
    XCTAssertTrue(SettingsStarterSet.shared.isUp)
    XCTAssertFalse(
      StarterSetOffer.shared.isRequested, "the main window would show it behind the settings")
  }

  /// The starter set hangs on the settings window itself.
  func testTheStarterSetHangsOnTheSettingsWindow() throws {
    // A section that writes nothing on its own: the books of this test are not open.
    let navigation = SettingsNavigation.shared
    let kept = navigation.section
    defer { navigation.section = kept }
    navigation.section = .appearance
    let deps = AppDependencies.forTests(AppEnvironment())
    let settings = window(
      AppScenes.root(deps, window: .settings, launches: false) { SettingsView(deps: $0) },
      size: SettingsView.idealSize)
    settings.orderFront(nil)
    Self.wait { settings.isVisible }

    Self.wait(timeout: 1) { settings.attachedSheet != nil }
    XCTAssertNil(
      settings.attachedSheet,
      "a sheet before the starter set: \(Self.describe(settings.attachedSheet))")
    SettingsStarterSet.shared.open()
    Self.wait { settings.attachedSheet != nil }
    let sheet = try XCTUnwrap(settings.attachedSheet, "the starter set did not open over Settings")
    XCTAssertFalse(sheet is NSPanel, "an alert, not the starter set: \(Self.describe(sheet))")
    XCTAssertTrue(sheet.isVisible)
    XCTAssertEqual(AppDependencies.missingReaders, [], "the sheet went without the dependencies")

    SettingsStarterSet.shared.isUp = false
    Self.wait { settings.attachedSheet == nil }
    XCTAssertNil(settings.attachedSheet)
  }

  /// The guide shown from the Help menu while the settings stand in front: the main window comes
  /// forward first, then the guide shows itself in it.
  func testWhatShowsInTheMainWindowBringsItOverTheSettings() throws {
    let main = window(Color.clear, size: CGSize(width: 400, height: 300))
    let settings = window(Color.clear, size: CGSize(width: 300, height: 200))
    AppWindows.mark(main, as: .main)
    AppWindows.mark(settings, as: .settings)
    main.orderFront(nil)
    settings.orderFront(nil)
    Self.wait { settings.isVisible && main.isVisible }
    try XCTSkipUnless(
      AppWindows.isInFront(settings, of: main), "the windows of the test are not on screen")

    var shown = false
    AppWindows.intoMain {
      shown = AppWindows.isInFront(main, of: settings)
    }
    XCTAssertTrue(shown, "the guide was shown while the settings stood over the main window")
    XCTAssertTrue(AppWindows.isInFront(main, of: settings))
    XCTAssertTrue(settings.isVisible, "the settings were closed rather than left behind")
  }

  /// Every sheet a section of the settings asks is a sheet of the settings window: a section
  /// shows its editors with `.sheet` on itself, so the sheet hangs where the section is. The
  /// editor of a new bank, opened from «Счета», is one.
  func testANewBankOpensOverTheSettingsWindow() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let navigation = SettingsNavigation.shared
    let kept = navigation.section
    defer { navigation.section = kept }
    navigation.section = .accounts
    let deps = AppDependencies.forTests(AppEnvironment())
    let settings = window(
      AppScenes.root(deps, window: .settings, launches: false) { SettingsView(deps: $0) },
      size: SettingsView.idealSize)
    settings.orderFront(nil)
    let title = deps.environment.language("accounts.newBank", table: "Accounts")
    var button: AnyObject?
    Self.wait {
      button = settings.contentView.flatMap { root in
        Self.element(in: root) { node in
          node.accessibilityRole?() == .button
            && (node.accessibilityIdentifier?() == "accounts.newBank"
              || node.accessibilityLabel?() == title || node.accessibilityTitle?() == title)
        }
      }
      return button != nil
    }
    let found = try XCTUnwrap(button, "no «\(title)» in «Счета»")
    _ = found.accessibilityPerformPress?()
    Self.wait { settings.attachedSheet != nil }
    XCTAssertNotNil(settings.attachedSheet, "the new bank did not open over the settings")
  }

  /// Settings → «Счета» opened as an empty dark window with a lone «hide the sidebar» button in
  /// its corner (20.10): a `NavigationSplitView` that had folded its sidebar away. The sections
  /// stand beside the section chosen in a plain row, so there is nothing to fold and no toggle,
  /// and the section chosen is on screen.
  func testTheSettingsHaveNoSplitViewToFoldAndShowTheChosenSection() throws {
    let navigation = SettingsNavigation.shared
    let kept = navigation.section
    defer { navigation.section = kept }
    for section in [SettingsSection.accounts, .general] {
      navigation.section = section
      let deps = AppDependencies.forTests(AppEnvironment())
      let settings = window(
        AppScenes.root(deps, window: .settings, launches: false) { SettingsView(deps: $0) },
        size: SettingsView.idealSize)
      settings.orderFront(nil)
      Self.wait { settings.isVisible }
      settings.contentView?.layoutSubtreeIfNeeded()
      var queue: [NSView] = settings.contentView.map { [$0] } ?? []
      var splits = 0
      var sized = 0
      while !queue.isEmpty {
        let view = queue.removeFirst()
        if view is NSSplitView { splits += 1 }
        if view.frame.width > 300, view.frame.height > 300 { sized += 1 }
        queue.append(contentsOf: view.subviews)
      }
      XCTAssertEqual(splits, 0, "\(section): a split view can fold the sidebar away")
      XCTAssertGreaterThan(sized, 0, "\(section): the section has no room on screen")
      XCTAssertEqual(
        settings.title,
        deps.environment.language(section.titleKey, table: "Settings"),
        "the window is titled by the section chosen")
    }
  }

  private static func describe(_ window: NSWindow?) -> String {
    guard let window else { return "none" }
    var texts: [String] = []
    var queue: [NSView] = window.contentView.map { [$0] } ?? []
    while !queue.isEmpty {
      let view = queue.removeFirst()
      if let field = view as? NSTextField { texts.append(field.stringValue) }
      if let button = view as? NSButton { texts.append("[" + button.title + "]") }
      queue.append(contentsOf: view.subviews)
    }
    return "\(type(of: window)) \(texts)"
  }

  private static func element(
    in node: AnyObject, depth: Int = 0, where matches: (AnyObject) -> Bool
  ) -> AnyObject? {
    if matches(node) { return node }
    guard depth < 40 else { return nil }
    for child in node.accessibilityChildren?() ?? [] {
      if let found = element(in: child as AnyObject, depth: depth + 1, where: matches) {
        return found
      }
    }
    return nil
  }
}
