import XCTest

/// Every window, one after another, the way the crash of 19.09 was found:
/// Analytics, Transactions and Reports from the Window menu, the period chooser of Analytics and Reports, the inspector of Transactions
/// opened by a double click, the sections of the main window ⌘1–⌘3, a resize and a close of
/// each window — and the app still running at the end. The ↓ panel of the entry line opens
/// and closes by × and by Esc. Same small set in English as `SelectionUndoUITests`.
///
/// Run with `make test-ui` after the other tests: it needs the automation mode and
/// Accessibility for the runner, which only the owner can grant.
@MainActor
final class WindowsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testEveryWindowOpensResizesAndClosesWithoutStoppingTheApp() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--data-set", "ui-test", "--generate", "2",
      "-app.language", "en", "-AppleLanguages", "(en)",
      "-ApplePersistenceIgnoreState", "YES", "--no-reminders",
    ]
    app.launch()
    // Never `app.windows.firstMatch`: that is a query and resolves to whichever window is in
    // front, so the line below would follow the last window opened. The main
    // window is the one that holds the entry line.
    let main = app.windows.containing(.textField, identifier: "entry.line").firstMatch
    XCTAssertTrue(main.waitForExistence(timeout: 120), "no main window")

    // The sections of the main window, back to Overview.
    for key in ["2", "3", "1"] {
      app.typeKey(key, modifierFlags: .command)
      XCTAssertEqual(app.state, .runningForeground)
    }

    // Analytics: the period chooser, then a resize.
    openWindow("Analytics", app: app)
    let analytics = app.windows["Analytics"]
    XCTAssertTrue(analytics.waitForExistence(timeout: 20), "no Analytics window")
    openPeriodChooser(in: analytics, app: app)
    resize(analytics, app)

    // Transactions: a double click on a row opens the inspector — the view that crashed.
    openWindow("Transactions", app: app)
    let transactions = app.windows["Transactions"]
    XCTAssertTrue(transactions.waitForExistence(timeout: 20), "no Transactions window")
    // The table has sections, so accessibility sees an outline; row 0 heads a day.
    let rows = transactions.outlines.firstMatch.outlineRows
    let row = rows.element(boundBy: 1)
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the table listed nothing")
    // By the point, not by the element: XCUITest calls the first row under a floating day
    // header of a `Table` «not hittable» although it is drawn in full (the first run of
    // `make test-ui`, 19.09).
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).doubleClick()
    // «Cancel», not «Save»: at the default size the inspector's last button can fall past the
    // right edge of a small screen, and XCUITest then does not list it. By its identifier,
    // not its caption: the confirmations of this window have a «Cancel» of their own.
    let cancel = transactions.descendants(matching: .button)
      .matching(identifier: "editor.cancel").firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the inspector did not open")
    XCTAssertEqual(app.state, .runningForeground)
    cancel.click()
    resize(transactions, app)

    // Reports: the period chooser, then a resize.
    openWindow("Reports", app: app)
    let reports = app.windows["Reports"]
    XCTAssertTrue(reports.waitForExistence(timeout: 20), "no Reports window")
    openPeriodChooser(in: reports, app: app)
    resize(reports, app)

    // Each window closes by its own close button, front to back; the app goes on.
    for window in [reports, transactions, analytics] {
      window.buttons[XCUIIdentifierCloseWindow].click()
      XCTAssertTrue(window.waitForNonExistence(timeout: 5), "a window did not close")
    }
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(main.exists)
  }

  func testTheDetailsPanelClosesByItsCrossAndByEscape() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--data-set", "ui-test", "--generate", "2",
      "-app.language", "en", "-AppleLanguages", "(en)",
      "-ApplePersistenceIgnoreState", "YES", "--no-reminders",
    ]
    app.launch()
    let line = app.textFields["entry.line"]
    XCTAssertTrue(line.waitForExistence(timeout: 120), "no entry line")
    let close = app.buttons["entry.details.close"]

    line.click()
    app.typeKey(.downArrow, modifierFlags: [])
    XCTAssertTrue(close.waitForExistence(timeout: 5), "↓ did not open the panel")
    close.click()
    XCTAssertTrue(close.waitForNonExistence(timeout: 5), "× did not close the panel")

    line.click()
    app.typeKey(.downArrow, modifierFlags: [])
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Esc did not close the panel")
  }

  /// A window by its item of the Window menu — the same item ⌘⇧T, ⌘⇧A or ⌘⇧R press
  /// (MenuTests checks the keys). A letter typed by the test would depend on the keyboard
  /// layout: with a Russian one, XCUITest finds no key for «a» and the shortcut never comes.
  private func openWindow(_ title: String, app: XCUIApplication) {
    app.menuBars.menuBarItems["Window"].click()
    let item = app.menuBars.menuItems[title]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(title) in the Window menu")
    item.click()
  }

  private func openPeriodChooser(in window: XCUIElement, app: XCUIApplication) {
    let button = window.buttons["period.choose"]
    XCTAssertTrue(button.waitForExistence(timeout: 20), "no period button")
    button.click()
    XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5), "no period chooser")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertEqual(app.state, .runningForeground)
  }

  /// The bottom-right corner is dragged 200 pt in, then 200 pt out again, and the width has to
  /// follow. Inwards it stops at the window's minimum — where an earlier run may have left it,
  /// since AppKit keeps the frame — so it is the drag outwards, from wherever the first one
  /// stopped, that has to move the edge by the drag. A check of «no wider than before» passed
  /// when the drag was ignored altogether (the corner missed, the window moved instead of
  /// resized). Out again also hands the next run the frame this one found.
  ///
  /// The app under test, handed in: `XCUIApplication()` made here would be another handle
  /// and its `state` would say nothing about the run.
  private func resize(_ window: XCUIElement, _ app: XCUIApplication) {
    let name = window.title
    let before = window.frame.width
    drag(cornerOf: window, by: CGVector(dx: -200, dy: -120))
    XCTAssertEqual(app.state, .runningForeground)
    let narrowed = window.frame.width
    XCTAssertLessThanOrEqual(narrowed, before, "\(name): the drag inwards widened the window")

    drag(cornerOf: window, by: CGVector(dx: 200, dy: 120))
    XCTAssertEqual(app.state, .runningForeground)
    let widened = window.frame.width
    XCTAssertEqual(
      widened - narrowed, 200, accuracy: 30,
      "\(name): the window did not follow the drag (\(before) → \(narrowed) → \(widened))")
  }

  /// Drags the bottom-right corner, just inside the frame, by `offset` — with the mouse:
  /// `click(forDuration:thenDragTo:)`. `press(forDuration:thenDragTo:)` is the touch gesture,
  /// and on the Mac it resized nothing: every window of this test stayed at its width through
  /// every run until the check above asked for the drag (the run of 24.09, 1100 → 1100 → 1100).
  private func drag(cornerOf window: XCUIElement, by offset: CGVector) {
    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(offset))
  }
}
