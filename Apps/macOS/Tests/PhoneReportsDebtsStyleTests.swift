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

  /// A folded parent hides its children and nothing else; the average and the total stay.
  func testCardTableFoldsOnlyTheFoldedParent() throws {
    let golden = try golden()
    let request = ReportsRequest(
      kind: .expensesByCategoryAndSubcategory, period: .year(2026), grouping: .category,
      today: golden.todayDay)
    let model = ReportsBuilder.model(request, ledger: golden.ledger())
    let open = ReportCardTable.visibleRows(model.lines, collapsed: [])
    XCTAssertEqual(open.count, model.lines.flatMap(\.flattened).count)
    guard let parent = model.lines.first(where: { !$0.children.isEmpty }) else {
      return XCTFail("the golden set has a category with subcategories")
    }
    let folded = ReportCardTable.visibleRows(model.lines, collapsed: [parent.id])
    XCTAssertEqual(open.count - folded.count, parent.flattened.count - 1)
    XCTAssertEqual(folded.last?.line.type, .total)
    XCTAssertTrue(open.filter { $0.depth == 0 }.allSatisfy { $0.line.id.contains("/") == false })
  }

  /// Every table draws at the width of a phone, in both languages.
  func testCardTableDrawsAtPhoneWidth() throws {
    let golden = try golden()
    let ledger = golden.ledger()
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for kind in ReportTable.Kind.allCases {
        let request = ReportsRequest(
          kind: kind, period: .year(2026), grouping: .category, today: golden.todayDay)
        let model = ReportsBuilder.model(request, ledger: ledger)
        let host = NSHostingView(
          rootView: ReportCardTable(model: model, collapsed: .constant([]))
            .appDependencies(.forTests(environment))
            .frame(width: 360))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 40, "\(choice) \(kind)")
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
