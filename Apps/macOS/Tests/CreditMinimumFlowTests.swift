import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

@MainActor
final class CreditMinimumFlowTests: DebtsScenarioCase {
  private let statementDay = DateOnly(year: 2026, month: 10, day: 5)

  func testManualStatementFlowsThroughAccountCalendarAndPlanAndUndo() async throws {
    let account = PaymentMethod(
      name: "Credit", currency: .rub,
      credit: CreditCardTerms(
        limitE4: money(100_000), grace: .statement(day: 5, payDays: 25),
        minPercent: 8, minFloorE4: money(600)))
    try XCTUnwrap(environment.references).save(account)
    try count(account, 0, on: DateOnly(year: 2026, month: 9, day: 1))
    try spend(30_000, on: DateOnly(year: 2026, month: 9, day: 20), account: account)
    try await show()
    let accountActions = AccountActions(environment: environment, store: store)
    let manual = CreditStatementOverride(
      accountId: account.id, closesOn: statementDay, minimumE4: money(3_100),
      due: DateOnly(year: 2026, month: 10, day: 22))
    XCTAssertTrue(
      accountActions.saveCreditMinimum(manual, accountId: account.id, closesOn: statementDay))
    try await show()
    let now = try XCTUnwrap(try snapshot.planning.creditCards[account.id])
    XCTAssertEqual(now.minimumE4, money(3_100))
    XCTAssertEqual(now.payBy, manual.due)
    XCTAssertFalse(now.minimumIsEstimate)
    let plans = CalendarPlans.collect(
      ledger: try snapshot.ledger, book: try snapshot.dataset.planning,
      today: today, through: today.monthKey.lastDay)
    let row = try XCTUnwrap(plans.first { $0.creditAccountId == account.id })
    XCTAssertEqual(row.amount, money(3_100))
    XCTAssertEqual(row.fullAmountE4, money(30_000))
    XCTAssertEqual(row.day, manual.due)
    XCTAssertFalse(row.isEstimate)
    XCTAssertTrue(HiddenPlans(scheduled: [], expected: [], creditAccounts: [account.id]).hides(row))
    XCTAssertFalse(HiddenPlans.none.hides(row))
    let outlook = try XCTUnwrap(CreditCardOutlook.build(of: account.id, snapshot: try snapshot))
    let manualText = CreditCardText.lines(outlook, today: today, environment).toPay
    XCTAssertFalse(manualText?.contains("≈") ?? true)
    let before = try entries().count
    XCTAssertTrue(
      accountActions.saveCreditMinimum(nil, accountId: account.id, closesOn: statementDay))
    try await show()
    XCTAssertTrue(try XCTUnwrap(try snapshot.planning.creditCards[account.id]).minimumIsEstimate)
    XCTAssertEqual(try snapshot.planning.creditCards[account.id]?.minimumE4, money(2_400))
    XCTAssertEqual(try entries().count, before, "statement input moves no money")
    try await undo()
    XCTAssertEqual(try snapshot.planning.creditCards[account.id]?.minimumE4, money(3_100))
    try await undo()
    XCTAssertEqual(try snapshot.planning.creditCards[account.id]?.minimumE4, money(2_400))
  }

  func testStatementTextMarksOnlyEstimatesInBothLanguages() {
    var now = CreditCardNow(
      debtE4: money(10_000), toPayNoInterestE4: money(10_000), minimumE4: money(800),
      payBy: today.adding(days: 7))
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      func text() -> String? {
        CreditCardText.lines(
          CreditCardOutlook(
            accountId: card.id, currency: .rub, terms: CreditCardTerms(limitE4: money(100_000)),
            counted: true, now: now, statements: [], estimates: [], cashLike: []),
          today: today, environment
        ).toPay
      }
      now.minimumIsEstimate = true
      XCTAssertTrue(text()?.contains("≈") == true)
      now.minimumIsEstimate = false
      XCTAssertFalse(text()?.contains("≈") ?? true)
    }
  }
}
