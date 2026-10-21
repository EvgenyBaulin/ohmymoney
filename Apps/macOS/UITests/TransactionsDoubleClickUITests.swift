import XCTest

/// The double click that hung the window of Transactions on 19.09, by hand and in every shape,
/// in «Операции» of the main window where the table lives now: a plain operation, a split, a part
/// of a split, the header of a day; with the editor closed and with it already open
/// (`TransactionsLayoutTests` covers the same ground without a click). And ⌘⇧T's item of the
/// Window menu brings that screen, not a window of its own.
///
/// Written to be run by the owner with `make test-ui`: it needs the automation mode and
/// Accessibility for the runner, which only the owner can grant.
///
/// Two rules came out of the run of 21.09, and every UI test of the app keeps them:
///
/// * a window is never addressed through `app.windows.firstMatch`. That is a query, not a
///   window, and it resolves anew at every use — once Transactions was in front, the «main»
///   window of this file was Transactions, and the test closed it and then blamed the app.
/// * a row is never addressed through `transactions.row.single`. That identifier names a
///   **kind** of row (`TransactionsTable.DescriptionCell`), so it matches every plain
///   operation on screen and XCUITest refuses to act on an ambiguous query. The window is
///   read once as a snapshot and the row is clicked by its frame.
@MainActor
final class TransactionsDoubleClickUITests: XCTestCase {
  /// The identifier SwiftUI gave the window of Transactions, after its scene: there must be no
  /// such window any more.
  private static let transactionsWindow = "transactions"

  override func setUp() {
    continueAfterFailure = false
  }

  func testEveryKindOfDoubleClickLeavesTheAppAlive() throws {
    let app = launch()
    XCTAssertTrue(mainWindow(app).waitForExistence(timeout: 120), "no main window")

    let transactions = openTransactions(app)
    // The window must not widen to make room for the editor: AppKit never shrinks a window
    // back, so one double click would leave it wide for good.
    let width = transactions.frame.width

    // A plain operation, with the inspector closed.
    doubleClickRow("transactions.row.single", in: transactions, app)
    expectInspector(in: transactions, app)
    XCTAssertEqual(
      transactions.frame.width, width, accuracy: 1,
      "the window grew for the editor")

    // Another operation while the inspector is open: the window rearranges both columns.
    doubleClickRow("transactions.row.single", nth: 1, in: transactions, app)
    expectInspector(in: transactions, app)
    XCTAssertEqual(
      transactions.frame.width, width, accuracy: 1, "the window grew on the second operation")

    // A split, when this month has one on screen. The window opens on this month, and the
    // generated history puts a split here and there — one at a fixed day from its start, the
    // rest by chance — so whether there is one depends on the day the test is run, and the
    // test must not fail on a date (the run of 23.09: none in 49 operations).
    if rowFrame("transactions.row.split", in: transactions) != nil {
      doubleClickRow("transactions.row.split", in: transactions, app)
      expectInspector(in: transactions, app)
      XCTAssertEqual(
        transactions.frame.width, width, accuracy: 1, "the window grew on a split")
    }

    // A part of a split opens the operation it belongs to — when a split is unfolded and a
    // part is on screen at all. The table lists them folded, so usually there is none.
    if rowFrame("transactions.row.part", in: transactions) != nil {
      doubleClickRow("transactions.row.part", in: transactions, app)
      expectInspector(in: transactions, app)
    }

    // The header of a day carries no operation: nothing opens, and nothing breaks.
    let header = transactions.outlines.containing(
      NSPredicate(format: "identifier BEGINSWITH 'transactions.row.'")
    ).firstMatch.outlineRows.element(boundBy: 0)
    header.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).doubleClick()
    XCTAssertEqual(app.state, .runningForeground)

    let cancel = inspectorCancel(in: transactions)
    cancel.click()
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertEqual(
      transactions.frame.width, width, accuracy: 1, "the window kept the inspector's room")
  }

  /// The item of the Window menu (⌘⇧T) opens no window: the main window shows «Операции».
  func testTheMenuItemShowsOperationsInTheMainWindow() throws {
    let app = launch()
    let main = mainWindow(app)
    XCTAssertTrue(main.waitForExistence(timeout: 120), "no main window")
    let transactions = openTransactions(app)
    XCTAssertEqual(transactions.identifier, main.identifier, "not the main window")
    XCTAssertFalse(
      app.windows[Self.transactionsWindow].exists, "a window of Transactions opened")
    XCTAssertTrue(
      main.textFields["transactions.search"].waitForExistence(timeout: 20),
      "the search of «Операции» is not in the main window")
    XCTAssertEqual(app.state, .runningForeground)
  }

  // MARK: - Helpers

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--data-set", "ui-test", "--generate", "2",
      "-app.language", "en", "-AppleLanguages", "(en)",
      "-ApplePersistenceIgnoreState", "YES", "--no-reminders",
    ]
    app.launch()
    return app
  }

  /// The main window by what only it holds — the entry line — never by `firstMatch`, which is
  /// whichever window happens to be in front, and never by its title, which carries the DEBUG
  /// and data-set badges (`OhMyMoneyApp.windowTitle`).
  private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
    app.windows.containing(.textField, identifier: "entry.line").firstMatch
  }

  /// «Операции» of the main window, from the item of the Window menu that opened the window of
  /// Transactions until 1.9: the main window comes forward on its table.
  private func openTransactions(_ app: XCUIApplication) -> XCUIElement {
    let menu = app.menuBars.menuBarItems["Window"]
    menu.click()
    menu.menuItems["Transactions"].click()
    let window = mainWindow(app)
    XCTAssertTrue(
      window.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH 'transactions.row.'")
      ).firstMatch.waitForExistence(timeout: 30), "no table of «Операции» in the main window")
    return window
  }

  private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return !element.exists
  }

  /// One row of a kind, from one snapshot of the window.
  ///
  /// The identifier names the kind of row, not the row, so a query for it matches every plain
  /// operation on screen and XCUITest refuses to resolve it («Multiple matching elements
  /// found», the run of 21.09). Walking elements one by one over a full table takes minutes,
  /// so the whole window is read once and walked here.
  ///
  /// Only a row in the clear counts: a day header floats over the top of the table and the
  /// selection bar over its bottom, and a click there lands on them.
  private func rowFrame(_ kind: String, nth: Int = 0, in window: XCUIElement) -> CGRect? {
    guard let snapshot = try? window.snapshot() else { return nil }
    let matches = Self.nodes(in: snapshot) { $0.identifier == kind }
    guard !matches.isEmpty, let table = Self.tableOutline(snapshot) else { return nil }
    let top = table.frame.minY + 44
    let bottom = table.frame.maxY - 88
    guard bottom > top else { return matches.first?.frame }
    let inTheClear = matches.filter { $0.frame.minY >= top && $0.frame.maxY <= bottom }
    return inTheClear.indices.contains(nth) ? inTheClear[nth].frame : nil
  }

  private static func nodes(
    in node: XCUIElementSnapshot, where matches: (XCUIElementSnapshot) -> Bool
  ) -> [XCUIElementSnapshot] {
    (matches(node) ? [node] : []) + node.children.flatMap { nodes(in: $0, where: matches) }
  }

  /// The outline of the table: the sidebar of the main window is an outline too, without rows
  /// of operations.
  private static func tableOutline(_ node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
    if node.elementType == .outline,
      !nodes(in: node, where: { $0.identifier.hasPrefix("transactions.row.") }).isEmpty
    {
      return node
    }
    for child in node.children {
      if let found = tableOutline(child) { return found }
    }
    return nil
  }

  /// By the point, not by the element: XCUITest calls a row under a floating day header of a
  /// `Table` «not hittable» although it is drawn in full (the first `make test-ui`, 19.09).
  /// The frame comes from the window's own coordinate space.
  private func doubleClickRow(
    _ kind: String, nth: Int = 0, in window: XCUIElement, _ app: XCUIApplication
  ) {
    var frame = rowFrame(kind, nth: nth, in: window)
    let deadline = Date().addingTimeInterval(20)
    while frame == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
      frame = rowFrame(kind, nth: nth, in: window)
    }
    guard let frame else { return XCTFail("no \(kind) row in the clear") }
    let origin = window.frame.origin
    window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
      .doubleClick()
    XCTAssertEqual(app.state, .runningForeground, "the app died on the click")
  }

  /// «Cancel», not «Save»: at the default size the editor's last button can fall past the
  /// right edge of a small screen, and XCUITest then does not list it. By identifier, not by
  /// its caption: every confirmation of this window has a «Cancel» too.
  private func inspectorCancel(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .button).matching(identifier: "editor.cancel").firstMatch
  }

  private func expectInspector(in window: XCUIElement, _ app: XCUIApplication) {
    XCTAssertTrue(
      inspectorCancel(in: window).waitForExistence(timeout: 20), "the inspector did not open")
    XCTAssertEqual(app.state, .runningForeground)
  }
}
