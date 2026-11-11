import XCTest

/// Audits the visible Mac screens on synthetic data. Each screen has its own test so a
/// failure does not prevent the other screens from being checked.
/// Run with `make test-ui T=OhMyMoneyUITests/AccessibilityAuditUITests`.
@MainActor
final class AccessibilityAuditUITests: E2EMacTestCase {
  // XCUIAccessibilityAuditTypes.h exposes these on macOS. Dynamic Type, clipped text and
  // traits are mobile-only audit types; `.all` would obscure that platform distinction.
  private let auditTypes: XCUIAccessibilityAuditType = [
    .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .action, .parentChild,
  ]

  func testOverview() throws {
    try auditMain("overview", ready: "overview.grid")
  }

  func testPlanning() throws {
    try auditMain("planning", ready: "planning.title")
  }

  func testDebts() throws {
    try auditMain("debts", ready: "debts.board")
  }

  func testTransactions() throws {
    try auditMain("operations", ready: "transactions.row.single")
  }

  func testCalendar() throws {
    try auditMain("calendar", ready: "calendar.scope")
  }

  func testCapital() throws {
    try auditMain("capital", ready: "capital.net")
  }

  func testPurchases() throws {
    try auditMain("purchases", ready: "purchases.pages")
  }

  func testAnalytics() throws {
    try auditMain("analytics", ready: "analytics.overview.months")
  }

  func testReports() throws {
    try auditMain("reports", ready: "reports.table")
  }

  func testSettingsGeneral() throws {
    try auditSettings("general", ready: "settings.numbers")
  }

  func testSettingsAppearance() throws {
    try auditSettings("appearance", ready: "settings.appearance.themes")
  }

  func testSettingsAccounts() throws {
    try auditSettings("accounts", ready: "accounts.list")
  }

  func testSettingsCategories() throws {
    try auditSettings("categories", ready: "categories.row.menu")
  }

  func testSettingsEntry() throws {
    try auditSettings("entry", ready: "settings.entry.style")
  }

  func testSettingsPlanning() throws {
    try auditSettings("planning", ready: "settings.planning.freeMoneyHorizon")
  }

  func testSplitPartRemovalHasAnAccessibleDescription() throws {
    let app = launch(section: "overview")
    defer { app.terminate() }
    let main = mainWindow(app)
    let line = main.textFields["entry.line"]
    XCTAssertTrue(line.waitForExistence(timeout: 60), "No entry line")
    line.click()
    line.typeText("coffee 250")
    if !main.buttons["entry.panel.save"].exists {
      let details = main.buttons["entry.details.toggle"]
      XCTAssertTrue(details.waitForExistence(timeout: 20), "No entry details button")
      details.click()
    }
    let split = main.buttons["Split into parts"]
    XCTAssertTrue(split.waitForExistence(timeout: 20), "No Split button in entry details")
    split.click()
    let remove = main.buttons.matching(identifier: "entry.split.removePart")
    XCTAssertTrue(remove.firstMatch.waitForExistence(timeout: 20), "No split removal buttons")
    XCTAssertEqual(remove.count, 2, "Splitting an entry should expose two removable parts")
    for button in remove.allElementsBoundByIndex {
      XCTAssertEqual(button.label, "Remove part", "A minus symbol needs an action description")
    }
    try audit(app, window: main, name: "entry-split")
  }

  private func launch(section: String) -> XCUIApplication {
    // The style otherwise follows the owner's Debug preference. No system accessibility
    // defaults are changed: LaunchOptions has no Increase Contrast override.
    let app = makeApp(
      generate: "2",
      extra: [
        "--section", section, "-entry.style", "line",
        "--analytics-section", "overview", "--analytics-period", "month",
        "-reports.byPeriods.\(Self.dataSet)", "NO",
        "-reports.table.\(Self.dataSet)", "expensesByCategoryAndSubcategory",
      ])
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Debug app is not foreground")
    XCTAssertTrue(mainWindow(app).waitForExistence(timeout: 120), "No main window sidebar")
    return app
  }

  private func auditMain(_ section: String, ready identifier: String) throws {
    let app = launch(section: section)
    defer { app.terminate() }
    let main = mainWindow(app)
    XCTAssertTrue(
      descendant(main, identifier).waitForExistence(timeout: 90),
      "Main / \(section): content did not appear (\(identifier))")
    if section == "analytics" {
      let months = descendant(main, identifier)
      XCTAssertTrue(
        waitUntil(90) { months.progressIndicators.count == 0 },
        "Analytics: the months card is still calculating")
    }
    XCTAssertFalse(main.sheets.firstMatch.exists, "Main / \(section): a sheet covers the screen")
    try audit(app, window: main, name: "main-\(section)")
  }

  private func auditSettings(_ section: String, ready identifier: String) throws {
    let app = launch(section: "overview")
    defer { app.terminate() }
    let open = mainWindow(app).buttons["sidebar.settings"]
    XCTAssertTrue(open.waitForExistence(timeout: 30), "No Settings button in the main sidebar")
    open.click()
    // The search field belongs only to Settings; its title changes with the selected section.
    let settings = app.windows.containing(.textField, identifier: "settings.search").firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 30), "No Settings search field/window")
    let row = settings.buttons["settings.section.\(section)"]
    XCTAssertTrue(row.waitForExistence(timeout: 20), "No Settings / \(section) sidebar row")
    row.click()
    XCTAssertTrue(
      descendant(settings, identifier).waitForExistence(timeout: 60),
      "Settings / \(section): content did not appear (\(identifier))")
    XCTAssertFalse(settings.sheets.firstMatch.exists, "Settings / \(section): a sheet is open")
    try audit(app, window: settings, name: "settings-\(section)")
  }

  private func descendant(_ window: XCUIElement, _ identifier: String) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func audit(_ app: XCUIApplication, window: XCUIElement, name: String) throws {
    try XCTContext.runActivity(named: "Accessibility audit: \(name)") { _ in
      snapshot(name, of: window)
      dump(name, of: app)
      var descriptions: [String] = []
      var completed = false
      // Record every native audit failure, even when several elements fail on one screen.
      // Returning false keeps XCTest's failures and element attachments; nothing is filtered.
      continueAfterFailure = true
      defer {
        continueAfterFailure = false
        let status =
          completed ? "No accessibility issues." : "Audit did not finish; see test failure."
        let report = descriptions.isEmpty ? status : descriptions.joined(separator: "\n\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "accessibility-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      try app.performAccessibilityAudit(for: auditTypes) { issue in
        let element =
          issue.element.map {
            "\($0.elementType), id=\($0.identifier), label=\($0.label), frame=\($0.frame)"
          } ?? "No associated element"
        descriptions.append(
          "[\(name)] \(self.auditName(issue.auditType)): \(issue.compactDescription)\n"
            + "\(issue.detailedDescription)\n\(element)")
        return false
      }
      completed = true
    }
  }

  private func auditName(_ type: XCUIAccessibilityAuditType) -> String {
    switch type {
    case .contrast: "contrast"
    case .elementDetection: "elementDetection"
    case .hitRegion: "hitRegion"
    case .sufficientElementDescription: "sufficientElementDescription"
    case .action: "action"
    case .parentChild: "parentChild"
    default: "audit type \(type.rawValue)"
    }
  }
}
