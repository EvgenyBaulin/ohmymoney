import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Переплата за оставшиеся части: отменить / оставить долгом» in the return of a thing bought in
/// instalments: 12,000 in 4 parts with a markup of 600 (150 a part), one part paid, the thing
/// returned. Cancelling takes the markup of the three parts not paid yet (450) off the debt with
/// one `adjustment` line in the same write; the parts keep their amounts; one ⌘Z takes it all back.
@MainActor
final class InstalmentReturnMarkupTests: DebtsScenarioCase {
  /// The plan with one part paid and the whole price returned, ready to write.
  private func scene() async throws -> (
    plan: Debt, refund: TransactionEntry, line: DebtLine, split: InstalmentReturnSplit
  ) {
    let plan = try await makePlan(price: 12_000, parts: 4, markup: money(600))
    // One part: 3,000 of the price and 150 of the markup.
    try await pay(plan, 3_150)
    let bought = try XCTUnwrap(
      try entries().first {
        $0.transaction.creditDebtId == plan.id && $0.transaction.debtId == nil
          && DebtMarkup.payment(ofKey: $0.transaction.externalId) == nil
      })
    var draft = TransactionDraft(
      kind: .refund, occurredAt: noon(today), amount: money(12_000), paymentMethodId: card.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = home.id
    draft.parts[0].refundOfPartId = bought.parts[0].id
    let refund = try draft.materialize()
    let line = try XCTUnwrap(try line(plan.id))
    let paid = InstalmentReturn.paidPrincipal(
      of: plan, journal: try journal(plan.id), balance: line.balance, dues: line.dues)
    let split = RefundRules.instalmentReturn(
      refund: refund.transaction.amountE4, debt: plan, balance: line.balance,
      paidPrincipal: paid, choice: .reducesDebt)
    return (plan, refund, line, split)
  }

  func testTheMarkupOfThePartsNotPaidYetIsWhatCancellingLowersTheDebtBy() async throws {
    let (plan, _, line, _) = try await scene()
    XCTAssertEqual(InstalmentReturn.unpaidMarkup(of: plan, dues: line.dues), money(450))
  }

  func testAPlanWithoutMarkupHasNothingToCancel() async throws {
    let plan = try await makePlan(price: 8_000, parts: 4)
    let line = try XCTUnwrap(try line(plan.id))
    XCTAssertEqual(InstalmentReturn.unpaidMarkup(of: plan, dues: line.dues), .zero)
  }

  func testCancellingTheMarkupLowersTheDebtByIt() async throws {
    let (plan, refund, line, split) = try await scene()
    XCTAssertEqual(line.balance, money(9_450))
    XCTAssertEqual(split.toDebtE4, money(9_000))
    let cancelled = InstalmentReturn.unpaidMarkup(of: plan, dues: line.dues)
    let change = InstalmentReturn.change(
      refund: refund, debt: plan, split: split, day: today, closing: true,
      cancelledMarkup: cancelled, balance: line.balance, markupNote: "Cancelled")
    XCTAssertTrue(PlanningActions(deps).apply(change))
    XCTAssertEqual(try balance(plan.id), .zero)
    XCTAssertTrue(try debt(plan.id).closed)
    let adjustments = try journal(plan.id).filter { $0.kind == .adjustment }
    XCTAssertEqual(adjustments.map(\.amountE4), [-money(450)])
    XCTAssertNil(adjustments.first?.transactionId)
    XCTAssertEqual(adjustments.first?.description, "Cancelled")
  }

  func testLeavingTheMarkupAsDebtWritesTodaysLinesOnly() async throws {
    let (plan, refund, line, split) = try await scene()
    let change = InstalmentReturn.change(
      refund: refund, debt: plan, split: split, day: today, closing: false)
    XCTAssertTrue(PlanningActions(deps).apply(change))
    XCTAssertEqual(try balance(plan.id), money(450))
    XCTAssertEqual(try journal(plan.id).filter { $0.kind == .adjustment }, [])
    XCTAssertEqual(line.balance, money(9_450))
  }

  func testThePartsKeepTheirAmountsAndTheDebtNeverGoesBelowZero() async throws {
    let (plan, refund, line, split) = try await scene()
    let before = try dues(plan.id).instalments
    let change = InstalmentReturn.change(
      refund: refund, debt: plan, split: split, day: today, closing: false,
      cancelledMarkup: money(5_000), balance: line.balance)
    XCTAssertTrue(PlanningActions(deps).apply(change))
    XCTAssertEqual(try balance(plan.id), .zero)
    try await show()
    XCTAssertEqual(try dues(plan.id).instalments, before)
  }

  func testOneUndoBringsBackTheReturnTheLineAndTheDebt() async throws {
    let (plan, refund, line, split) = try await scene()
    let entriesBefore = try journal(plan.id).count
    let change = InstalmentReturn.change(
      refund: refund, debt: plan, split: split, day: today, closing: true,
      cancelledMarkup: InstalmentReturn.unpaidMarkup(of: plan, dues: line.dues),
      balance: line.balance)
    XCTAssertTrue(PlanningActions(deps).apply(change))
    try await undo()
    XCTAssertEqual(try balance(plan.id), money(9_450))
    XCTAssertFalse(try debt(plan.id).closed)
    XCTAssertEqual(try journal(plan.id).count, entriesBefore)
    XCTAssertEqual(try entries().filter { $0.transaction.kind == .refund }, [])
  }

  func testTheQuestionIsWordedOnBothLanguages() throws {
    let keys = [
      "instalmentReturn.markup.question", "instalmentReturn.markup.keep",
      "instalmentReturn.markup.cancel", "instalmentReturn.markup.note",
    ]
    for code in ["ru", "en"] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj"), code)
      let bundle = try XCTUnwrap(Bundle(path: path), code)
      for key in keys {
        let text = bundle.localizedString(forKey: key, value: "∅", table: "Debts")
        XCTAssertNotEqual(text, "∅", "\(key) in \(code)")
      }
    }
  }
}
