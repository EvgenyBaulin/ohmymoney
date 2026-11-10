import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The phone-width drawing of the reports table and the words of the new debt wizard.
@MainActor
final class PhoneReportsDebtsStyleTests: XCTestCase {
  private func golden() throws -> Golden {
    let url = try XCTUnwrap(
      Bundle(for: PhoneReportsDebtsStyleTests.self).url(
        forResource: "golden-small", withExtension: "json"),
      "golden-small.json is missing from the test bundle")
    return try Golden.decode(Data(contentsOf: url))
  }

  /// «По категориям» holds every line of the income and of the spending, each part under its
  /// name and over its total, and «Разница» last: the totals' difference, signed.
  func testTheTableByCategoryHoldsEveryLineOfBothTables() throws {
    let golden = try golden()
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let request = ReportsSheetRequest(
      tab: .byCategory, period: AnalyticsPeriod(kind: .year, month: MonthKey(year: 2026, month: 12)),
      today: golden.todayDay)
    let sheet = ReportsSheetBuilder.sheet(request, ledger: golden.ledger())
    XCTAssertEqual(sheet.models.map(\.table.kind), [.incomeByCategory, .expensesByCategoryAndSubcategory])
    let grid = ReportGridBuilder.grid(sheet, .phone, environment)
    let lines = sheet.models.map { model in
      model.lines.filter { !$0.isSummary }.flatMap(\.flattened).count
    }
    XCTAssertEqual(grid.rows.filter { $0.style == .line }.count, lines.reduce(0, +))
    XCTAssertEqual(grid.rows.filter { $0.style == .section }.map { $0.cells[0] }, ["Доходы", "Расходы"])
    XCTAssertEqual(
      grid.rows.filter { $0.style == .total }.map { $0.cells[0] },
      ["Итого доходов", "Итого расходов", "Разница"])
    XCTAssertEqual(grid.columns.map(\.title), ["Категория", "Сумма", "Доля"])
    let income = sheet.models[0].table.total.amount?.wholeRubles ?? 0
    let spending = sheet.models[1].table.total.amount?.wholeRubles ?? 0
    XCTAssertEqual(
      grid.rows.last?.cells[1], ReportsText.signedFigure(income - spending, environment))
    // A subcategory stands a step in under its category.
    XCTAssertTrue(grid.rows.contains { $0.depth == 1 }, "the golden set has subcategories")
    // Shares with two decimals; the totals 100.00 %.
    XCTAssertEqual(
      grid.rows.first { $0.id == "total.1" }?.cells[2], ReportsText.share(10_000, environment))
    XCTAssertTrue(ReportsText.share(10_000, environment).hasPrefix("100.00"))
  }

  /// Every tab of every design draws at its width, in both languages.
  func testEveryTabDrawsAtTheWidthOfItsDesign() throws {
    let golden = try golden()
    let ledger = golden.ledger()
    let environment = AppEnvironment()
    let period = AnalyticsPeriod(kind: .month, month: golden.todayDay.monthKey)
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for (idiom, width) in [(LayoutIdiom.phone, 408.0), (.pad, 900), (.mac, 1_152)] {
        for tab in ReportsTab.tabs(idiom) where !tab.opensSheet {
          let sheet = ReportsSheetBuilder.sheet(
            ReportsSheetRequest(tab: tab, period: period, today: golden.todayDay), ledger: ledger)
          let grid = ReportGridBuilder.grid(sheet, idiom, environment)
          XCTAssertFalse(grid.rows.isEmpty, "\(choice) \(idiom) \(tab)")
          XCTAssertTrue(
            grid.rows.allSatisfy { $0.cells.count == grid.columns.count },
            "every row has a cell per column: \(idiom) \(tab)")
          let host = NSHostingView(
            rootView: ReportGridView(grid: grid, metrics: .of(idiom), idiom: idiom)
              .appDependencies(.forTests(environment))
              .frame(width: width))
          host.layoutSubtreeIfNeeded()
          XCTAssertGreaterThan(host.fittingSize.height, 40, "\(choice) \(idiom) \(tab)")
        }
      }
    }
  }

  /// Every kind of the wizard's first step has its line of explanation in both languages.
  func testEveryWizardKindHasAHint() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for kind in DebtWizardKind.allCases {
        let key = "wizard.kind.\(kind.rawValue).hint"
        XCTAssertNotEqual(environment.language(key, table: "Debts"), key, "\(choice) \(key)")
      }
      for key in ["wizard.how", "wizard.how.undo", "parts.title", "parts.paid", "parts.waits"] {
        XCTAssertNotEqual(environment.language(key, table: "Debts"), key, "\(choice) \(key)")
      }
    }
  }
}
