import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

@MainActor
final class SplitPaymentFlowTests: DebtsScenarioCase {
  func testEditedSchedulePersistsAndPurchaseIsSpentOnlyOnce() async throws {
    var model = DebtWizardModel(today: today, currency: .rub)
    model.kind = .split
    model.name = "Service purchase"
    model.amount = money(10_000)
    model.monthly = money(2_650)
    model.categoryId = home.id
    model.account = card.id
    model.splitFirstDue = today.adding(days: 2)
    var rows = model.splitRows
    rows[1].day = today.adding(days: 19)
    rows[2].amountE4 = money(2_600)
    rows[3].amountE4 = money(2_700)
    model.splitRows = rows
    XCTAssertTrue(model.canLeave(.payments))
    XCTAssertTrue(actions.createPurchase(model.purchase))
    try await show()
    let plan = try XCTUnwrap(try debts().first { $0.name == model.name })
    XCTAssertFalse(plan.paymentsAreExpenses)
    XCTAssertEqual(plan.origin, .purchase)
    XCTAssertEqual(plan.markupE4, money(600))
    let state = try dues(plan.id)
    XCTAssertEqual((0..<4).map { state.due($0) }, rows.map(\.day))
    XCTAssertEqual((0..<4).map { state.amount(ofDue: $0) }, rows.map(\.amountE4))
    XCTAssertEqual(try snapshot.planning.spentWithoutGoals, money(10_000))
    let calendarPlans = CalendarPlans.collect(
      ledger: try snapshot.ledger, book: try snapshot.dataset.planning, today: today,
      through: rows[3].day)
    XCTAssertEqual(calendarPlans.filter { $0.sourceId == plan.id }.map(\.day), rows.map(\.day))
    XCTAssertEqual(
      try snapshot.planning.freeMoney.plan.debts,
      AmountE4.sum(rows.filter { $0.day <= today.monthKey.lastDay }.map(\.amountE4)))
    try await pay(plan, 2_650)
    XCTAssertEqual(try balance(plan.id), money(7_950))
    XCTAssertEqual(try snapshot.planning.spentWithoutGoals, money(10_150))
    let markup = try XCTUnwrap(
      try entries().first {
        DebtMarkup.payment(ofKey: $0.transaction.externalId) != nil
      })
    XCTAssertEqual(markup.parts.first?.quality, .bad)
    let feeId = try XCTUnwrap(environment.settings).string(AccountSettings.transferFeeCategoryKey)
    XCTAssertEqual(markup.parts.first?.categoryId?.uuidString, feeId)
    XCTAssertEqual(
      try categories().first { $0.id == markup.parts.first?.categoryId }?.name,
      environment.language("category.fees", table: "Accounts"))
    try await undo()
    XCTAssertEqual(try balance(plan.id), money(10_600))
    XCTAssertEqual(try snapshot.planning.spentWithoutGoals, money(10_000))
    try await undo()
    XCTAssertTrue(try debts().isEmpty)
    XCTAssertTrue(try snapshot.dataset.debtSettings.splitDates.isEmpty)
  }

  func testShortOrUnorderedSplitIsRefusedWithoutWritingAnything() {
    var model = DebtWizardModel(today: today, currency: .rub)
    model.kind = .split
    model.name = "Invalid"
    model.amount = money(12_000)
    model.monthly = money(2_000)
    model.categoryId = home.id
    XCTAssertFalse(model.canLeave(.payments))
    XCTAssertFalse(actions.createPurchase(model.purchase))
    model.amount = money(7_000)
    var rows = model.splitRows
    rows[1].day = rows[0].day
    model.splitRows = rows
    XCTAssertFalse(model.canLeave(.payments))
    XCTAssertFalse(actions.createPurchase(model.purchase))
  }
}
