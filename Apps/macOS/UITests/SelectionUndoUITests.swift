import XCTest

/// The selection of Overview end to end: a click, a ⇧-click, a new
/// category through the selection bar, ⌘Z — and the rows are as they were. The app starts
/// on a small data set generated for the test (`--data-set ui-test --generate 2`), in
/// English, so the Debug database is never touched and the menu reads the same every time.
/// Two months, not one: Overview lists the previous month and this one, and a set of this
/// month alone would give it a day or two of rows on the 1st or the 2nd — too few to find
/// a pair in, whatever the code.
///
/// Run with `make test-ui`, never by `make test`: a UI test can stop on a system prompt.
/// On the main actor, where every call of XCUIApplication lives.
@MainActor
final class SelectionUndoUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testACategoryChangeOfTwoRowsIsTakenBackByOneUndo() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--data-set", "ui-test", "--generate", "2",
      "-app.language", "en", "-AppleLanguages", "(en)",
      "-ApplePersistenceIgnoreState", "YES", "--no-reminders",
    ]
    app.launch()

    // Never `app.windows.firstMatch`: that is whichever window is in front, and the rows, the
    // list and the snapshot below would follow it. The main window is the one that
    // holds the entry line, and the rows are its own.
    let main = app.windows.containing(.textField, identifier: "entry.line").firstMatch
    let rows = main.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'operation.'"))
    XCTAssertTrue(
      rows.element(boundBy: 1).waitForExistence(timeout: 120), "Overview listed no operations")

    // Another window in front while the rows are looked for, as a restored window or one the
    // app opens itself would stand: the search reads the main window all the same.
    openAnalytics(app)
    // Two neighbouring rows filed under ordinary categories: a reimbursement has none, and
    // nothing is moved out of a system one by hand.
    // The cards fill the top of the list, and the selection bar floats over its bottom: the
    // list is scrolled until a pair is in the clear band between them.
    let list = main.scrollViews.element(boundBy: 1)
    let band = (list.frame.minY + 40)...(list.frame.maxY - 90)
    var found = firstOrdinaryPair(in: main, within: band)
    // The main window stands behind Analytics now; its entry line brings it forward without
    // moving it. A scroll goes to the window under the pointer, and the clicks below need the
    // main window in front.
    main.textFields["entry.line"].click()
    for delta: CGFloat in [-250, -250, -250, 250, 250, 250, 250] where found == nil {
      list.scroll(byDeltaX: 0, deltaY: delta)
      found = firstOrdinaryPair(in: main, within: band)
    }
    let pair = try XCTUnwrap(found, "no two neighbouring ordinary rows in the clear")
    let first = rows.element(boundBy: pair)
    let second = rows.element(boundBy: pair + 1)
    let before = [first.value as? String, second.value as? String]

    first.click()
    XCUIElement.perform(withKeyModifiers: .shift) { second.click() }

    let change = app.descendants(matching: .any).matching(identifier: "selection.change")
      .firstMatch
    XCTAssertTrue(change.waitForExistence(timeout: 10), "no selection bar")
    change.click()
    let categoryItem = app.menuItems["Category…"]
    XCTAssertTrue(categoryItem.waitForExistence(timeout: 5))
    categoryItem.click()

    let picker = app.descendants(matching: .any).matching(identifier: "bulk.category.picker")
      .firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "no category popover")
    picker.click()
    let target = app.menuItems["Electronics"]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    target.click()
    app.descendants(matching: .any).matching(identifier: "bulk.category.apply").firstMatch
      .click()
    // A split or a row the change passes over asks first.
    let confirm = app.buttons["Apply"].firstMatch
    if confirm.waitForExistence(timeout: 3) { confirm.click() }

    XCTAssertTrue(
      waitUntil(15) { self.values(first, second) != before },
      "the category did not change: \(values(first, second))")
    XCTAssertTrue(values(first, second).contains { $0?.contains("Electronics") == true })

    // Edit → Undo, the item ⌘Z presses: a letter typed by the test would depend on the
    // keyboard layout (see WindowsUITests.openWindow).
    app.menuBars.menuBarItems["Edit"].click()
    let undo = app.menuBars.menuItems["Undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 5), "no Undo in the Edit menu")
    undo.click()

    XCTAssertTrue(
      waitUntil(15) { self.values(first, second) == before },
      "one ⌘Z did not bring both rows back: \(values(first, second)) instead of \(before)")
    app.terminate()
  }

  /// The Analytics window, from its item of the Window menu (see WindowsUITests.openWindow).
  /// Transactions was the window opened here until it became a screen of the main window.
  private func openAnalytics(_ app: XCUIApplication) {
    app.menuBars.menuBarItems["Window"].click()
    let item = app.menuBars.menuItems["Analytics"]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "no Analytics in the Window menu")
    item.click()
    XCTAssertTrue(app.windows["analytics"].waitForExistence(timeout: 20), "no Analytics window")
  }

  private func values(_ first: XCUIElement, _ second: XCUIElement) -> [String?] {
    [first.value as? String, second.value as? String]
  }

  /// The first index whose row and the next one both have a category of their own, one of
  /// them a purchase: the popover then offers the categories of spending. Both inside `band`:
  /// lower down the entry line and the selection bar float over the rows, and a click there
  /// lands on the bar (the first run of `make test-ui`, 19.09). Read from one snapshot of the
  /// window, in the order of the query of the rows: element by element it takes minutes.
  private func firstOrdinaryPair(
    in main: XCUIElement, within band: ClosedRange<CGFloat>
  ) -> Int? {
    guard let window = try? main.snapshot() else { return nil }
    func operations(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
      (node.identifier.hasPrefix("operation.") ? [node] : [])
        + node.children.flatMap(operations)
    }
    let rows = operations(window)
    let system = ["Unknown", "Goals", "Loans", "Surcharges", "Electronics"]
    func fits(_ row: XCUIElementSnapshot) -> Bool {
      guard let value = row.value as? String, !value.isEmpty,
        !system.contains(where: value.contains)
      else { return false }
      return band.contains(row.frame.minY) && band.contains(row.frame.maxY)
    }
    guard rows.count >= 2 else { return nil }
    return (0..<(rows.count - 1)).first {
      fits(rows[$0]) && fits(rows[$0 + 1])
        && (rows[$0].identifier == "operation.expense"
          || rows[$0 + 1].identifier == "operation.expense")
    }
  }

  private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }
}
