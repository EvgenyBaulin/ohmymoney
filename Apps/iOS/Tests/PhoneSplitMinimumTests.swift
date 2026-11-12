import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class PhoneSplitMinimumTests: XCTestCase {
  func testSharedWizardKeepsEveryEditedPayment() throws {
    let today = DateOnly(year: 2026, month: 11, day: 11)
    var model = DebtWizardModel(today: today, currency: .rub)
    model.kind = .split
    model.name = "Split"
    model.amount = AmountE4(whole: 10_000)
    model.monthly = AmountE4(whole: 2_650)
    model.categoryId = UUID()
    var rows = model.splitRows
    rows[1].day = today.adding(days: 16)
    rows[2].amountE4 = AmountE4(whole: 2_700)
    model.splitRows = rows
    XCTAssertTrue(model.canLeave(.payments))
    XCTAssertEqual(model.purchase.splitPayments, rows)
    XCTAssertEqual(model.preview(calendar: .utc).rows.map(\.due), rows.map(\.day))
    XCTAssertEqual(model.preview(calendar: .utc).interest, AmountE4(whole: 650))
    let environment = AppEnvironment()
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      XCTAssertNotEqual(
        environment.language("wizard.kind.split", table: "Debts"), "wizard.kind.split")
      XCTAssertNotEqual(
        environment.language("account.credit.minimum.due", table: "Accounts"),
        "account.credit.minimum.due")
    }
  }
}
