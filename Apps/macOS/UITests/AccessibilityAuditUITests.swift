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
    // The hero combines its children, so `capital.net` is not a separate AX element.
    try auditMain("capital", ready: "capital.assets.header")
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
    // Exercise the section command as well as the launch option, after the sidebar exists.
    click(app, "sidebar.\(section)")
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
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App is not foreground")
    app.typeKey(",", modifierFlags: .command)
    // The search can be exposed as a search field or a text field by AppKit. This sidebar
    // button belongs only to Settings and does not depend on the window's changing title.
    let settings = app.windows.containing(.button, identifier: "settings.section.general")
      .firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 30), "No Settings sidebar/window after Cmd-,")
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
      var systemDescriptions: [String] = []
      var completed = false
      // Record every finding ourselves so its first log line identifies the element. Returning
      // true only avoids XCTest's duplicate, context-free failure after our own XCTFail.
      continueAfterFailure = true
      defer {
        continueAfterFailure = false
        let status =
          completed ? "No accessibility issues." : "Audit did not finish; see test failure."
        var report = descriptions.isEmpty ? status : descriptions.joined(separator: "\n\n")
        if !systemDescriptions.isEmpty {
          report +=
            "\n\nSystem chart role exceptions:\n" + systemDescriptions.joined(separator: "\n\n")
        }
        let attachment = XCTAttachment(string: report)
        attachment.name = "accessibility-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      try app.performAccessibilityAudit(for: auditTypes) { issue in
        var element = "identifier=<none> label=<none> elementType=<none> frame=<none>"
        var snapshotError = ""
        var systemChartRole = false
        do {
          if let target = issue.element {
            // Resolve once: repeated queries can see different layouts or lose a stale node.
            let node = try target.snapshot()
            element =
              "identifier=\(String(reflecting: node.identifier))"
              + " label=\(String(reflecting: node.label)) elementType=\(node.elementType)"
              + " frame=\(node.frame)"
            // Swift Charts exports these mark nodes as AXUnknown. ChartContent allows labels,
            // values and identifiers, but has no role/trait setter. Exempt only that role
            // finding on our explicitly identified native marks; labels, actions, contrast,
            // parent/child issues and unmarked framework containers must still fail.
            let nativeMark =
              node.identifier == "chart.native.average"
              || ["chart.native.column.", "chart.native.pair.", "chart.native.share."].contains {
                node.identifier.hasPrefix($0)
              }
            systemChartRole =
              issue.auditType == .elementDetection
              && issue.compactDescription == "Unknown role" && node.elementType == .other
              && nativeMark
          }
        } catch {
          snapshotError = "\nCould not snapshot audit element: \(error)"
        }
        let headline =
          "[\(name)] type=\(self.auditName(issue.auditType)) \(element)"
          + " issue=\(String(reflecting: issue.compactDescription))"
        let report = headline + "\n" + issue.detailedDescription + snapshotError
        if systemChartRole {
          systemDescriptions.append(report)
          return true
        }
        descriptions.append(report)
        XCTFail(report)
        return true
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
