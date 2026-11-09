import XCTest

/// What the end-to-end tests of the Mac window share: launching on a set of synthetic data,
/// the folder the app's file panels answer from (`--test-io`), pictures of the window as
/// attachments kept in the result bundle, and waiting for a condition.
@MainActor
class E2EMacTestCase: XCTestCase {
  /// The isolated set shared by the journeys; each launch can generate it anew.
  static let dataSet = "ui-test"

  override func setUp() {
    continueAfterFailure = false
  }

  /// The runner is sandboxed and cannot write into the app's container, so the files the app
  /// would ask a panel for travel in the arguments (`--test-io-file`).
  func makeApp(
    generate: String?, files: [String: String] = [:], extra: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    var arguments = ["--data-set", Self.dataSet]
    if let generate { arguments += ["--generate", generate] }
    for (name, text) in files {
      arguments += ["--test-io-file", "\(name)=\(Data(text.utf8).base64EncodedString())"]
    }
    arguments += [
      "--test-io",
      "-app.language", "en", "-AppleLanguages", "(en)",
      "-ApplePersistenceIgnoreState", "YES", "--no-reminders",
    ]
    app.launchArguments = arguments + extra
    return app
  }

  /// The main window: the one that holds the sidebar, which the form style of entry has too
  /// (it has no entry line). Never `windows.firstMatch`.
  func mainWindow(_ app: XCUIApplication) -> XCUIElement {
    app.windows.containing(.button, identifier: "sidebar.overview").firstMatch
  }

  func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// A section of the main window by its sidebar identifier: the View menu names it, and ⌘1 … ⌘9
  /// (the order of the sidebar) is the fallback. A click on a sidebar row finds no point to hit
  /// right after a launch, and a busy machine drops a key now and then, so the section is
  /// waited for.
  func click(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 60) {
    let order = [
      "overview", "operations", "planning", "calendar", "capital", "debts", "purchases",
      "analytics", "reports",
    ]
    let titles = [
      "Overview", "Transactions", "Planning", "Calendar", "Capital", "Debts", "Purchases",
      "Analytics", "Reports",
    ]
    let name = identifier.replacingOccurrences(of: "sidebar.", with: "")
    guard let index = order.firstIndex(of: name) else {
      XCTFail("no section \(identifier)")
      return
    }
    XCTAssertTrue(element(app, identifier).waitForExistence(timeout: timeout), "no \(identifier)")
    app.activate()
    _ = app.wait(for: .runningForeground, timeout: 10)
    let go = app.menuBars.menuBarItems["View"]
    if go.exists {
      go.click()
      let item = go.menus.menuItems[titles[index]]
      if item.waitForExistence(timeout: 5) {
        item.click()
        return
      }
      app.typeKey(.escape, modifierFlags: [])
    }
    app.typeKey(String(index + 1), modifierFlags: .command)
  }

  /// A picture of `window`, kept in the result bundle whether the test passes or not.
  func snapshot(_ name: String, of window: XCUIElement) {
    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The whole screen, to see what else is in front of the window.
  func snapshotScreen(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The accessibility tree as text, to read what a step saw when it failed.
  func dump(_ name: String, of app: XCUIApplication) {
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = "tree-" + name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// Picks a menu item of the menu bar.
  func choose(_ menu: String, _ item: String, in app: XCUIApplication) {
    app.menuBars.menuBarItems[menu].click()
    let entry = app.menuBars.menuItems[item]
    XCTAssertTrue(entry.waitForExistence(timeout: 5), "no \(item) in the \(menu) menu")
    entry.click()
  }
}
