import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The settings window was 620 × 420 points and could not be made larger: the list of
/// categories was read through a slot, and every row added to a tab pushed the rest below the
/// fold. It opens larger now, and can be made larger still.
@MainActor
final class SettingsWindowSizeTests: XCTestCase {
  private func host() -> NSHostingView<some View> {
    let deps = AppDependencies.forTests(AppEnvironment())
    return NSHostingView(
      rootView: AppScenes.root(deps, window: .settings, launches: false) { SettingsView(deps: $0) })
  }

  func testTheSettingsOpenAtTheirIdealSizeAndNeverSmallerThanTheMinimum() {
    let view = host()
    let ideal = view.intrinsicContentSize
    XCTAssertGreaterThanOrEqual(ideal.width, SettingsView.idealSize.width)
    XCTAssertGreaterThanOrEqual(ideal.height, SettingsView.idealSize.height)
    XCTAssertGreaterThan(SettingsView.idealSize.width, 620, "no larger than before")
    XCTAssertGreaterThan(SettingsView.idealSize.height, 420, "no taller than before")
    XCTAssertLessThanOrEqual(
      SettingsView.idealSize.width, 1024, "wider than the smallest screen the app is tested on")
    XCTAssertLessThanOrEqual(SettingsView.idealSize.height, 700)
  }

  /// Made larger by hand, the window gives the room to the sections instead of centring a fixed box;
  /// made smaller, it stops at the minimum.
  func testTheTabsTakeTheRoomOfTheWindowDownToTheMinimum() {
    let deps = AppDependencies.forTests(AppEnvironment())
    let controller = NSHostingController(
      rootView: AppScenes.root(deps, window: .settings, launches: false) { SettingsView(deps: $0) })

    let large = controller.sizeThatFits(in: CGSize(width: 960, height: 760))
    XCTAssertEqual(large.width, 960, accuracy: 1, "the tabs kept a fixed width in a wider window")
    XCTAssertEqual(large.height, 760, accuracy: 1, "the tabs kept a fixed height in a taller one")

    let small = controller.sizeThatFits(in: CGSize(width: 300, height: 200))
    XCTAssertGreaterThanOrEqual(small.width, SettingsView.minimumSize.width)
    XCTAssertGreaterThanOrEqual(small.height, SettingsView.minimumSize.height)
  }

  /// The window of the Settings scene itself, opened the way ⌘, opens it. The Settings scene
  /// gave its window no corner to drag, whatever `windowResizability` said, and the sizes of
  /// the content above said nothing about that. Now it can be dragged larger, keeps the size it
  /// was given when another section is chosen, and stops at the minimum.
  ///
  /// The window keeps its frame and its tab in the defaults of the test host, which are the
  /// owner's Debug ones: whatever the test changed there is put back.
  func testTheSettingsWindowCanBeMadeLargerAndKeepsItsMinimum() throws {
    try TestEnvironment.requireScreen(width: 900)
    let defaults = UserDefaults.standard
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let kept = defaults.persistentDomain(forName: domain) ?? [:]
    let before = Set(NSApp.windows.map(ObjectIdentifier.init))

    // The item of the application menu with ⌘, — what the keys press.
    let menu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu, "no application menu")
    let index = try XCTUnwrap(
      menu.items.firstIndex { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command },
      "no item with ⌘, in \(menu.items.map(\.title))")
    menu.performActionForItem(at: index)
    var opened: NSWindow?
    let deadline = Date().addingTimeInterval(5)
    while opened == nil, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      opened = NSApp.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.isVisible
          && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
      }
    }
    let window = try XCTUnwrap(opened, "no settings window opened")
    defer {
      window.close()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      Self.putBack(kept, in: defaults, domain: domain)
    }

    XCTAssertTrue(window.styleMask.contains(.resizable), "the settings window has no corner")
    let content = try XCTUnwrap(window.contentView)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.width, SettingsView.minimumSize.width)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.height, SettingsView.minimumSize.height)
    XCTAssertGreaterThanOrEqual(content.frame.width, SettingsView.minimumSize.width)
    XCTAssertGreaterThanOrEqual(content.frame.height, SettingsView.minimumSize.height)

    // The larger size needs a screen that holds it with the title bar and the tabs above it:
    // on CI's 1024 × 768 screen the window stops at 677 points of content, the screen's limit
    // and not the window's.
    let larger = CGSize(width: 880, height: 700)
    let chrome = CGSize(
      width: window.frame.width - content.frame.width,
      height: window.frame.height - content.frame.height)
    try TestEnvironment.requireScreen(
      width: larger.width + chrome.width, height: larger.height + chrome.height, for: window)
    // Where the window is and what its screen shows, so a red log says which one stopped it.
    let room = {
      "window \(window.frame), screen visible \(window.screen?.visibleFrame ?? .zero)"
    }

    window.setContentSize(larger)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(content.frame.width, 880, accuracy: 1, "not made wider; \(room())")
    XCTAssertEqual(content.frame.height, 700, accuracy: 1, "not made taller; \(room())")

    // Another section: SwiftUI lays the window out again, and the corner and the size stay.
    let navigation = SettingsNavigation.shared
    let shown = navigation.section
    defer { navigation.section = shown }
    navigation.section = navigation.section == .accounts ? .backups : .accounts
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    XCTAssertTrue(window.styleMask.contains(.resizable), "another section took the corner away")
    XCTAssertEqual(
      content.frame.width, 880, accuracy: 1, "another section shrank the window; \(room())")
    XCTAssertEqual(
      content.frame.height, 700, accuracy: 1, "another section shrank the window; \(room())")
  }

  /// The domain as it was: a key the test added goes, a key it changed or removed gets its
  /// value back.
  private static func putBack(_ kept: [String: Any], in defaults: UserDefaults, domain: String) {
    let now = defaults.persistentDomain(forName: domain) ?? [:]
    for key in now.keys where kept[key] == nil { defaults.removeObject(forKey: key) }
    for (key, old) in kept where !((now[key] as AnyObject?)?.isEqual(old) ?? false) {
      defaults.set(old, forKey: key)
    }
  }
}
