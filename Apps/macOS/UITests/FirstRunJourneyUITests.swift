import XCTest

/// A new person's first minutes, end to end on a set of synthetic data that starts empty
/// (`--generate empty`): the cards of the guide, the starter set, the setup of the accounts,
/// «кофе 250» through the entry line and again through the form at the right, the operation in
/// Operations and on Overview, ⌘Z and ⇧⌘Z, then a quit and a second launch on the same data.
///
/// Run with `make test-ui T=OhMyMoneyUITests/FirstRunJourneyUITests`, never by `make test`.
@MainActor
final class FirstRunJourneyUITests: E2EMacTestCase {
  func testAFirstLaunchAsksTheStarterSetAndTheAccountsThenTakesACoffee() throws {
    self.executionTimeAllowance = 540
    // The style of entry is a habit kept in the Debug defaults, and a launch argument for it is
    // kept too: both launches say which they want, and the last one puts the line back.
    let app = makeApp(generate: "empty", extra: ["-entry.style", "line"])
    app.launch()

    let main = mainWindow(app)
    XCTAssertTrue(main.waitForExistence(timeout: 120), "no main window")
    snapshot("01-first-launch", of: main)
    dump("01-first-launch", of: app)

    // The questions of a first launch, one sheet at a time: the cards, the starter set, the
    // accounts. Whatever comes up is answered until the window is left to itself.
    var seen: [String] = []
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      let sheet = app.sheets.firstMatch
      if sheet.buttons["Skip"].exists {
        seen.append("guide")
        snapshot("02-guide", of: app.windows.firstMatch)
        sheet.buttons["Skip"].click()
      } else if sheet.buttons["Add"].exists, labelled(sheet, "Working").exists {
        if !seen.contains("starter") {
          for label in [
            "Working", "I have loans", "I have subscriptions", "I want a safety cushion",
          ] {
            let toggle = labelled(sheet, label)
            if toggle.waitForExistence(timeout: 3) { toggle.click() }
          }
          snapshot("03-starter-set", of: app.windows.firstMatch)
          dump("03-starter-set", of: app)
        }
        seen.append("starter")
        sheet.buttons["Add"].click()
      } else if sheet.buttons["Done"].exists {
        if !seen.contains("accounts") {
          // «Add at least one account»: the cash quick pick.
          let cash = labelled(sheet, "Cash")
          if cash.waitForExistence(timeout: 5) { cash.click() }
          snapshot("04-accounts", of: app.windows.firstMatch)
          dump("04-accounts", of: app)
        }
        seen.append("accounts")
        if sheet.buttons["Done"].isEnabled { sheet.buttons["Done"].click() }
      } else if seen.contains("accounts"), !app.sheets.firstMatch.exists {
        break
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    snapshot("05-after-questions", of: main)
    dump("05-after-questions", of: app)
    XCTAssertTrue(seen.contains("starter"), "no starter set: \(seen)")
    XCTAssertTrue(seen.contains("accounts"), "no account setup: \(seen)")
    XCTAssertTrue(
      seen.filter { $0 == "starter" }.count <= 2, "the starter set stayed open: \(seen)")

    // «кофе 250» through the entry line.
    let line = main.textFields["entry.line"]
    XCTAssertTrue(line.waitForExistence(timeout: 90), "no entry line after the questions")
    line.click()
    line.typeText("кофе 250")
    snapshot("06-line-typed", of: main)
    line.typeKey(.return, modifierFlags: [])
    // «кофе» is no known word, so the line asks for a category before it writes.
    let category = element(app, "entry.category")
    XCTAssertTrue(category.waitForExistence(timeout: 10), "the line did not open the panel")
    snapshot("06b-asks-a-category", of: main)
    category.click()
    let choices = category.menus.menuItems
    XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5), "no categories to choose from")
    let titles = choices.allElementsBoundByIndex.map(\.title)
    let pick = choices.allElementsBoundByIndex.first {
      !["—", "Unknown", ""].contains($0.title)
    }
    try XCTUnwrap(pick, "no ordinary category among \(titles)").click()
    element(app, "entry.panel.save").click()

    // The operation is in Operations, written once.
    click(app, "sidebar.operations")
    let coffee = coffeeRow(in: main)
    let found = coffee.waitForExistence(timeout: 30)
    snapshot("07-operations", of: main)
    dump("07-operations", of: app)
    XCTAssertTrue(found, "no coffee in Transactions after Save")
    click(app, "sidebar.overview")
    snapshot("08-overview", of: main)

    // ⌘Z and ⇧⌘Z, by the Edit menu items they press (a typed letter depends on the layout).
    click(app, "sidebar.operations")
    editItem(app, startingWith: "Undo")
    let gone = coffee.waitForNonExistence(timeout: 20)
    snapshot("09-after-undo", of: main)
    XCTAssertTrue(gone, "Undo left the coffee in the list")
    editItem(app, startingWith: "Redo")
    XCTAssertTrue(coffee.waitForExistence(timeout: 20), "Redo did not bring the coffee back")
    snapshot("10-after-redo", of: main)

    // Quit the way the owner does, and a second launch on the same data.
    quit(app)
    let again = makeApp(generate: nil, extra: ["-entry.style", "form"])
    again.launch()
    let second = mainWindow(again)
    XCTAssertTrue(second.waitForExistence(timeout: 60), "no main window on the second launch")
    // A clean quit leaves no «the last session did not end» question behind.
    XCTAssertFalse(
      again.staticTexts["The last session did not end"].waitForExistence(timeout: 3),
      "the quit was not clean")
    click(again, "sidebar.operations")
    let kept = coffeeRow(in: second)
    let stayed = kept.waitForExistence(timeout: 30)
    snapshot("11-second-launch", of: second)
    dump("11-second-launch", of: again)
    XCTAssertTrue(stayed, "the coffee was gone after the second launch")

    // The form at the right: the kind first, then its fields.
    click(again, "sidebar.overview")
    let expense = element(again, "entry.kind.expense")
    XCTAssertTrue(expense.waitForExistence(timeout: 10), "no form at the right")
    snapshot("12-form", of: second)
    expense.click()
    snapshot("13-form-expense", of: second)

    // «кофе 250» again, field by field: amount, category, note.
    let amount = second.textFields.matching(NSPredicate(format: "placeholderValue == '0'"))
      .firstMatch
    XCTAssertTrue(amount.waitForExistence(timeout: 10), "no amount field in the form")
    amount.click()
    amount.typeText("250")
    let formCategory = element(again, "entry.category")
    formCategory.click()
    let options = formCategory.menus.menuItems
    XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 5), "no categories in the form")
    let ordinary = options.allElementsBoundByIndex.first {
      !["—", "Unknown", ""].contains($0.title)
    }
    try XCTUnwrap(ordinary, "no ordinary category in the form").click()
    let note = second.textFields.matching(NSPredicate(format: "placeholderValue == 'Note'"))
      .firstMatch
    note.click()
    note.typeText("кофе")
    snapshot("14-form-filled", of: second)
    element(again, "entry.form.save").click()
    // The same operation a moment ago: the app asks, and this one is meant.
    let duplicate = again.sheets.buttons["Add"]
    XCTAssertTrue(duplicate.waitForExistence(timeout: 10), "no question about the repeated entry")
    snapshot("14b-same-operation", of: second)
    duplicate.click()

    click(again, "sidebar.operations")
    let coffees = second.descendants(matching: .staticText).matching(
      NSPredicate(format: "identifier == 'transactions.row.single' AND value CONTAINS[c] 'кофе'"))
    let two = waitUntil(30) { coffees.count == 2 }
    snapshot("15-two-coffees", of: second)
    dump("15-two-coffees", of: again)
    XCTAssertTrue(two, "two coffees expected, found \(coffees.count)")
    click(again, "sidebar.overview")
    snapshot("16-overview-two-coffees", of: second)
    quit(again)

    let restored = makeApp(generate: nil, extra: ["-entry.style", "line"])
    restored.launch()
    XCTAssertTrue(
      mainWindow(restored).waitForExistence(timeout: 90), "no main window to put the line back")
    quit(restored)
    app.terminate()
  }

  private func labelled(_ parent: XCUIElement, _ label: String) -> XCUIElement {
    parent.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
      .firstMatch
  }

  private func editItem(_ app: XCUIApplication, startingWith prefix: String) {
    app.menuBars.menuBarItems["Edit"].click()
    let item = app.menuBars.menuItems.matching(
      NSPredicate(format: "title BEGINSWITH %@", prefix)
    ).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(prefix) in the Edit menu")
    item.click()
  }

  /// The row of the table of Transactions that holds the coffee — not the chip of the template
  /// under the line, which stays when the operation is taken back.
  private func coffeeRow(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .staticText).matching(
      NSPredicate(format: "identifier == 'transactions.row.single' AND value CONTAINS[c] 'кофе'")
    ).firstMatch
  }

  private func quit(_ app: XCUIApplication) {
    let item = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Quit'"))
      .firstMatch
    app.menuBars.menuBarItems.element(boundBy: 1).click()
    XCTAssertTrue(item.waitForExistence(timeout: 5), "no Quit item in the app menu")
    item.click()
    if !app.wait(for: .notRunning, timeout: 30) {
      dump("quit-stuck", of: app)
      if let window = app.windows.allElementsBoundByIndex.first {
        snapshot("quit-stuck", of: window)
      }
    }
    XCTAssertEqual(app.state, .notRunning, "the app did not quit")
  }
}
