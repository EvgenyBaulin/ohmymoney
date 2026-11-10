import XCTest

/// The rest of the journey on a generated history (`--generate 2`): a bank statement imported
/// from a synthetic file, and the reconciliation sheet. Each test starts the set anew, so none
/// depends on another.
///
/// The files the app would ask a panel for come from its test folder (`--test-io`, with the
/// files in the launch arguments). Run with `make test-ui T=OhMyMoneyUITests/DataJourneyUITests`.
@MainActor
final class DataJourneyUITests: E2EMacTestCase {
  private func launch(files: [String: String] = [:]) throws -> (XCUIApplication, XCUIElement) {
    self.executionTimeAllowance = 540
    let app = makeApp(generate: "2", files: files)
    app.launch()
    let main = mainWindow(app)
    XCTAssertTrue(main.waitForExistence(timeout: 120), "no main window")
    snapshot("00-state", of: main)
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    snapshot("00-launched", of: main)
    // The history is in once Transactions lists a row.
    click(app, "sidebar.operations")
    let listed = element(app, "transactions.row.single").waitForExistence(timeout: 60)
    if !listed {
      snapshot("01-no-rows", of: main)
      snapshotScreen("01-no-rows-screen")
      dump("01-no-rows", of: app)
    }
    XCTAssertTrue(listed, "Transactions listed no operations")
    click(app, "sidebar.overview")
    return (app, main)
  }

  /// A statement of the format the bank's own export has: three card payments of the last days,
  /// invented shops and sums.
  static func statement(now: Date = Date()) -> String {
    let header =
      #"Дата операции;Выполнено банком;Номер документа;Сумма в валюте операции (поступления);Сумма в валюте операции (расходы);Валюта операции;Сумма в валюте счета (поступления);Сумма в валюте счета (расходы);Валюта счета;Детали операции (назначение платежа);Номер карты"#
    let day = DateFormatter()
    day.dateFormat = "dd.MM.yyyy"
    day.locale = Locale(identifier: "en_US_POSIX")
    func line(_ offset: Int, _ doc: String, _ expense: String, _ details: String) -> String {
      let date = day.string(from: now.addingTimeInterval(TimeInterval(-offset * 86_400)))
      let fields = [
        "\(date) 10:15", date, doc, "", expense, "RUB", "", expense, "RUB", details, "*1111",
      ]
      return fields.map { "\"\($0)\"" }.joined(separator: ";")
    }
    // A byte-order mark and Windows line ends, as the bank writes the file.
    return "\u{FEFF}"
      + [
        header,
        line(2, "E2E0001", "310,00", " SAMPLE BAKERY"),
        line(3, "E2E0002", "1 480,50", " SAMPLE MARKET"),
        line(4, "E2E0003", "95,00", " SAMPLE KIOSK"),
      ].joined(separator: "\r\n") + "\r\n"
  }

  func testAStatementIsImportedFromAFileAndItsRowsLand() throws {
    let (app, main) = try launch(files: ["statement.csv": Self.statement()])
    snapshot("20-before-import", of: main)

    choose("File", "Import Statement…", in: app)
    let flow = element(app, "import.flow")
    XCTAssertTrue(flow.waitForExistence(timeout: 20), "the import window did not open")
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    snapshot("21-import-files", of: app.windows.firstMatch)

    // The account the statement belongs to, then «Write».
    let account = element(app, "import.account")
    XCTAssertTrue(account.waitForExistence(timeout: 10), "no account choice for the file")
    account.click()
    let accounts = account.descendants(matching: .menuItem)
    XCTAssertTrue(accounts.firstMatch.waitForExistence(timeout: 5), "no accounts to choose from")
    let titles = accounts.allElementsBoundByIndex.map(\.title)
    let index =
      titles.firstIndex { $0.hasPrefix("Every") }
      ?? titles.firstIndex {
        !$0.isEmpty && !$0.hasPrefix("Choose")
      }
    accounts.element(boundBy: try XCTUnwrap(index, "no account among \(titles)")).click()
    let write = app.sheets.buttons["Write"]
    XCTAssertTrue(waitUntil(20) { write.isEnabled }, "Write stayed off after the account")
    snapshot("22-import-ready", of: app.windows.firstMatch)
    write.click()
    let close = app.sheets.buttons["Close"]
    XCTAssertTrue(close.waitForExistence(timeout: 30), "the import did not finish")
    snapshot("23-import-done", of: app.windows.firstMatch)
    // The outcome says what was written: a new operation, and the one left for sorting.
    XCTAssertTrue(
      app.sheets.staticTexts["1 new operation"].exists, "the outcome does not count the new row")
    close.click()
    XCTAssertTrue(close.waitForNonExistence(timeout: 10))

    // The newest imported row is the last entry of Overview.
    let market = main.descendants(matching: .staticText).matching(
      NSPredicate(format: "value CONTAINS[c] 'SAMPLE MARKET'")
    ).firstMatch
    let landed = market.waitForExistence(timeout: 30)
    snapshot("24-after-import", of: main)
    XCTAssertTrue(landed, "the imported row is not on Overview")
  }

  func testTheReconciliationSheetOpensFromTheCardOfOverview() throws {
    let (app, main) = try launch()
    let open = main.buttons["Reconcile…"].firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 20), "no «Reconcile…» on Overview")
    snapshot("30-before-reconcile", of: main)
    open.click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 20), "the reconciliation sheet did not open")
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    snapshot("31-reconcile-sheet", of: app.windows.firstMatch)
    dump("31-reconcile", of: app)
  }
}
