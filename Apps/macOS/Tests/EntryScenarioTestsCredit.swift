import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «В кредит» and «Рассрочка частями» from the ↓ panel, followed to the database: only a
/// purchase is bought on credit, the count of payments and the instalment move together and stay
/// within their range, an instalment plan is four parts by default with its markup in every
/// part, the purchase, the debt and its first line are one write — and one ⌘Z takes all three.
@MainActor
final class EntryScenarioCreditTests: EntryScenarioCase {
  private func purchase(_ line: String = "ноутбук 12000") throws -> EntryDraftModel {
    let model = book.model()
    try book.enter(line, into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    return model
  }

  private func debts() throws -> [Debt] {
    try book.references.debts(includeClosed: true, includeDeleted: false)
  }

  func testTheBoxStartsWithTwelveEqualPayments() throws {
    let model = try purchase()
    XCTAssertTrue(model.offersCredit)
    model.startCreditPlan()
    let plan = try XCTUnwrap(model.creditPlan)
    XCTAssertEqual(plan.payments, 12)
    XCTAssertEqual(plan.monthlyAmount, AmountE4(whole: 1_000))
    XCTAssertFalse(plan.instalments)
    XCTAssertTrue(model.isOnCredit)
  }

  func testAPurchaseOnCreditIsOneWriteOfPurchaseDebtAndLine() throws {
    let model = try purchase()
    model.startCreditPlan()
    let entry = try book.save(model)
    let debt = try XCTUnwrap(try debts().first)
    XCTAssertEqual(entry.transaction.creditDebtId, debt.id)
    XCTAssertEqual(debt.direction, .iOwe)
    XCTAssertEqual(debt.origin, .purchase)
    XCTAssertFalse(debt.paymentsAreExpenses, "the expense is the purchase itself")
    XCTAssertEqual(debt.monthlyPaymentE4, AmountE4(whole: 1_000))
    XCTAssertEqual(debt.name, "ноутбук")
    let lines = try book.references.debtEntries(debtId: debt.id)
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(lines.first?.transactionId, entry.id)
  }

  func testOneUndoTakesThePurchaseTheDebtAndItsLine() throws {
    let model = try purchase()
    model.startCreditPlan()
    let entry = try book.save(model)
    let debt = try XCTUnwrap(try debts().first)
    book.store.undo()
    XCTAssertNil(try book.stored(entry.id).flatMap { $0.transaction.isDeleted ? nil : $0 })
    XCTAssertTrue(try debts().filter { $0.id == debt.id }.isEmpty)
    XCTAssertTrue(try book.references.debtEntries(debtId: debt.id).isEmpty)
  }

  func testTheExpenseIsCountedOnceAsMySpending() throws {
    let model = try purchase()
    model.startCreditPlan()
    try book.save(model)
    XCTAssertEqual(RowTotals(entries: try book.entries()).myExpenses, AmountE4(whole: 12_000))
  }

  func testAnIncomeIsNeverBoughtOnCredit() throws {
    let model = book.model()
    try book.enter("+5000 абв", into: model)
    XCTAssertFalse(model.offersCredit)
    model.startCreditPlan()
    XCTAssertNil(model.creditPlan)
  }

  func testAPlanIsDroppedWhenTheLineTurnsIntoIncome() throws {
    let model = try purchase()
    model.startCreditPlan()
    try book.enter("+12000 ноутбук", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertNil(model.creditPlan)
    XCTAssertFalse(model.isOnCredit)
  }

  func testTheCountStaysWithinOneAndAHundredAndTwenty() throws {
    let model = try purchase()
    model.startCreditPlan()
    model.setCreditPayments(0)
    XCTAssertEqual(model.creditPlan?.payments, 1)
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 12_000))
    model.setCreditPayments(500)
    XCTAssertEqual(model.creditPlan?.payments, 120)
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 100))
  }

  func testAnInstalmentTypedGivesTheCountWithASmallerLastOne() throws {
    let model = try purchase()
    model.startCreditPlan()
    model.setCreditMonthly(AmountE4(whole: 5_000))
    XCTAssertEqual(model.creditPlan?.payments, 3, "5000 + 5000 + 2000")
  }

  func testANewAmountKeepsTheCountAndMovesTheInstalment() throws {
    let model = try purchase()
    model.startCreditPlan()
    model.setCreditPayments(6)
    model.setTotal(AmountE4(whole: 24_000))
    XCTAssertEqual(model.creditPlan?.payments, 6)
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 4_000))
  }

  func testInstalmentsAreFourPartsEveryTwoWeeks() throws {
    let model = try purchase()
    model.startCreditPlan()
    model.setInstalments(true)
    let plan = try XCTUnwrap(model.creditPlan)
    XCTAssertTrue(plan.instalments)
    XCTAssertEqual(plan.payments, InstalmentPlan.defaultCount)
    XCTAssertEqual(plan.everyDays, InstalmentPlan.defaultEveryDays)
    XCTAssertEqual(plan.monthlyAmount, AmountE4(whole: 12_000 / Int64(plan.payments)))
  }

  func testTheMarkupGoesIntoEveryPart() throws {
    let model = try purchase()
    model.startCreditPlan()
    model.setInstalments(true)
    model.setInstalmentMarkup(AmountE4(whole: 400))
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 3_100))
    model.setInstalmentMarkup(AmountE4(whole: -50))
    XCTAssertEqual(model.creditPlan?.markup, .zero, "a markup below zero is none")
  }

  func testThreePartsOfAThousandAddUpToTheKopeck() throws {
    let model = try purchase("наушники 1000")
    model.startCreditPlan()
    model.setInstalments(true)
    model.setCreditPayments(3)
    let parts = InstalmentPlan.parts(total: model.draft.amount, count: 3)
    XCTAssertEqual(parts.reduce(.zero, +), AmountE4(whole: 1_000))
    XCTAssertEqual(model.creditPlan?.monthlyAmount, parts.first)
  }

  func testInstalmentsAreAtLeastTwoParts() throws {
    let model = try purchase()
    model.startCreditPlan()
    model.setInstalments(true)
    model.setCreditPayments(1)
    XCTAssertEqual(model.creditPlan?.payments, 2)
  }

  func testAnInstalmentPlanIsWrittenWithItsPartsAndMarkup() throws {
    let model = try purchase("пылесос 12000")
    model.startCreditPlan()
    model.setInstalments(true)
    model.setInstalmentMarkup(AmountE4(whole: 400))
    let entry = try book.save(model)
    let debt = try XCTUnwrap(try debts().first)
    XCTAssertEqual(entry.transaction.creditDebtId, debt.id)
    XCTAssertEqual(debt.parts, 4)
    XCTAssertEqual(debt.markupE4, AmountE4(whole: 400))
    XCTAssertEqual(debt.name, "пылесос")
    XCTAssertTrue(debt.termsReviewed)
    let line = try XCTUnwrap(try book.references.debtEntries(debtId: debt.id).first)
    XCTAssertEqual(line.amountE4.raw.magnitude, AmountE4(whole: 12_400).raw.magnitude)
    book.store.undo()
    XCTAssertTrue(try debts().isEmpty)
  }

  func testOffTheBoxThePurchaseIsAPlainExpense() throws {
    let model = try purchase()
    model.startCreditPlan()
    model.stopCreditPlan()
    XCTAssertFalse(model.isOnCredit)
    let entry = try book.save(model)
    XCTAssertNil(entry.transaction.creditDebtId)
    XCTAssertTrue(try debts().isEmpty)
  }

  func testAPurchaseOnCreditDatedAheadIsNoPlan() throws {
    let ahead = EntryScenarioQuestionTests.dotted(book.today.adding(days: 3))
    let model = try purchase("ноутбук 12000 \(ahead)")
    model.startCreditPlan()
    XCTAssertNil(model.planAhead(today: book.today))
  }

  func testAPurchaseInDollarsOpensADebtInDollars() throws {
    let model = try purchase("ноутбук 1000 usd")
    model.setManualRate("90")
    model.startCreditPlan()
    try book.save(model)
    XCTAssertEqual(try debts().first?.currency, .usd)
  }

  func testJoiningAnOpenDebtAddsALineAndNoSecondDebt() throws {
    let first = try purchase("телефон 30000")
    first.startCreditPlan()
    try book.save(first)
    let debt = try XCTUnwrap(try debts().first)

    let second = try purchase("чехол 2000")
    second.startCreditPlan()
    var plan = try XCTUnwrap(second.creditPlan)
    plan.debtId = debt.id
    second.creditPlan = plan
    second.reload()
    let entry = try book.save(second)
    XCTAssertEqual(entry.transaction.creditDebtId, debt.id)
    XCTAssertEqual(try debts().count, 1)
    XCTAssertEqual(try book.references.debtEntries(debtId: debt.id).count, 2)
  }

  func testNoCashbackIsExpectedFromAPurchaseOnCredit() throws {
    let model = try purchase()
    model.startCreditPlan()
    let entry = try book.save(model)
    XCTAssertNil(entry.transaction.cashback)
  }
}
