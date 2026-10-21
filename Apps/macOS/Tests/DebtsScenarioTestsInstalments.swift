import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Рассрочка» and a purchase on credit from the Debts section: the parts to the kopeck with the
/// rest in the last, the markup spent part by part, a plan paid to the end and closed, parts paid
/// two at once, a plan in dollars, a plan on a day of the month at the end of February, the
/// summary «В рассрочках», a purchase on credit made a plan later, a thing returned to the card —
/// and every write taken back by one ⌘Z.
@MainActor
final class DebtsScenarioTestsInstalments: DebtsScenarioCase {
  private func markups(of id: UUID) throws -> [TransactionEntry] {
    try entries().filter {
      DebtMarkup.payment(ofKey: $0.transaction.externalId) != nil
        && $0.transaction.creditDebtId == id
    }
  }

  private func purchase(of id: UUID) throws -> TransactionEntry {
    try XCTUnwrap(
      try entries().first {
        $0.transaction.creditDebtId == id && $0.transaction.debtId == nil
          && DebtMarkup.payment(ofKey: $0.transaction.externalId) == nil
      })
  }

  // MARK: Made

  func testAThousandInThreePartsIsTwoEvenAndALastWithTheKopeck() async throws {
    let plan = try await makePlan(price: 1_000, parts: 3)
    let dues = try dues(plan.id)
    XCTAssertEqual(
      (0..<3).map { dues.amount(ofDue: $0) },
      [amount("333.33"), amount("333.33"), amount("333.34")])
    XCTAssertEqual(dues.amount(ofDue: 3), .zero, "no due after the last part")
  }

  func testTheMarkupIsSharedByThePartsToTheKopeck() async throws {
    let plan = try await makePlan(price: 9_000, parts: 3, markup: money(1_000))
    let dues = try dues(plan.id)
    XCTAssertEqual(dues.amount(ofDue: 0), amount("3333.33"))
    XCTAssertEqual(dues.amount(ofDue: 2), amount("3333.34"))
    XCTAssertEqual(try balance(plan.id), money(10_000))
  }

  func testThePurchaseIsSpentOnceAtItsPriceAndTheDebtHoldsTheMarkupToo() async throws {
    let plan = try await makePlan(markup: money(600))
    let bought = try purchase(of: plan.id)
    XCTAssertEqual(bought.transaction.amountE4, money(10_000))
    XCTAssertEqual(bought.parts.first?.categoryId, home.id)
    XCTAssertEqual(bought.transaction.paymentMethodId, card.id)
    let line = try XCTUnwrap(try journal(plan.id).first)
    XCTAssertEqual(line.kind, .borrowed)
    XCTAssertEqual(line.amountE4, money(10_600))
    XCTAssertEqual(line.transactionId, bought.id)
    XCTAssertEqual(plan.markupE4, money(600))
    XCTAssertFalse(plan.paymentsAreExpenses)
  }

  func testThePartsAreKeptBetweenTwoAndAHundredAndTwenty() async throws {
    let few = try await makePlan(name: "Few", parts: 1)
    XCTAssertEqual(few.parts, 2)
    let many = try await makePlan(name: "Many", price: 100_000, parts: 500)
    XCTAssertEqual(many.parts, 120)
  }

  func testAPlanWithoutANameOrAPriceIsRefused() {
    XCTAssertFalse(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "   ", price: money(1_000), currency: .rub, day: today, categoryId: home.id,
          account: card.id, parts: 4, everyDays: 14, paymentDay: nil, markup: nil, monthly: nil)))
    XCTAssertFalse(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "Free", price: .zero, currency: .rub, day: today, categoryId: home.id,
          account: card.id, parts: 4, everyDays: 14, paymentDay: nil, markup: nil, monthly: nil)))
    XCTAssertTrue(try debts().isEmpty)
    XCTAssertTrue(try entries().isEmpty)
  }

  func testOneUndoTakesThePurchaseAndThePlanAway() async throws {
    let plan = try await makePlan(markup: money(600))
    try await undo()
    XCTAssertNil(try debts().first { $0.id == plan.id })
    XCTAssertEqual(try entries(), [])
  }

  func testAPlanOnTheLastDayOfTheMonthPaysOnTheLastDayOfFebruary() async throws {
    try await move(to: DateOnly(year: 2027, month: 1, day: 15))
    let plan = try await makePlan(everyDays: nil, paymentDay: 31)
    let dues = try dues(plan.id)
    XCTAssertNil(plan.steps)
    XCTAssertEqual(plan.paymentDay, 31)
    XCTAssertEqual(dues.due(0), DateOnly(year: 2027, month: 1, day: 31))
    XCTAssertEqual(dues.due(1), DateOnly(year: 2027, month: 2, day: 28))
    XCTAssertEqual(plan.monthlyPaymentE4, money(2_500))
  }

  func testAPlanPaidOnADayAlreadyGoneStartsNextMonth() async throws {
    try await move(to: DateOnly(year: 2026, month: 12, day: 20))
    let plan = try await makePlan(everyDays: nil, paymentDay: 10)
    XCTAssertEqual(try dues(plan.id).firstDue, DateOnly(year: 2027, month: 1, day: 10))
  }

  func testAPlanInDollarsIsInDollarsAndCountsInRublesInTheSummary() async throws {
    let plan = try await makePlan(price: 400, currency: .usd, account: wallet.id)
    XCTAssertEqual(plan.currency, .usd)
    XCTAssertEqual(try purchase(of: plan.id).transaction.currency, .usd)
    let summary = try snapshot.planning.instalments
    XCTAssertEqual(summary.totalRub, money(36_000))
    XCTAssertEqual(summary.next.first?.currency, .usd)
    XCTAssertEqual(summary.next.first?.amountE4, money(100))
  }

  /// A purchase in euros on a ruble card with no rate of the euro known: its rubles cannot be
  /// told, so nothing is written — neither the purchase nor the plan.
  func testAPlanInACurrencyWithoutARateIsRefusedWhole() async throws {
    XCTAssertFalse(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "Euro", price: money(400), currency: .eur, day: today, categoryId: home.id,
          account: card.id, parts: 4, everyDays: 14, paymentDay: nil, markup: nil,
          monthly: nil)))
    XCTAssertTrue(try debts().isEmpty)
    XCTAssertEqual(try entries(), [])
  }

  // MARK: Paid

  func testEachPartSpendsItsShareOfTheMarkupAndTheLastClosesThePlan() async throws {
    let plan = try await makePlan(markup: money(600))
    for index in 0..<4 {
      let done = try await pay(
        plan, 2_650, on: today, closing: index == 3)
      XCTAssertTrue(done)
    }
    XCTAssertEqual(
      try markups(of: plan.id).map(\.transaction.amountE4),
      Array(repeating: money(150), count: 4))
    XCTAssertEqual(try balance(plan.id), .zero)
    XCTAssertTrue(try debt(plan.id).closed)
    let tree = CategoryTree(try categories())
    XCTAssertTrue(
      try markups(of: plan.id).allSatisfy { !AccountBalances.movesMoney($0, tree: tree) })
  }

  func testTwoPartsPaidAtOnceSpendTwoSharesOfTheMarkup() async throws {
    let plan = try await makePlan(markup: money(600))
    try await pay(plan, 5_300)
    XCTAssertEqual(try markups(of: plan.id).map(\.transaction.amountE4), [money(300)])
    XCTAssertEqual(try dues(plan.id).paidCount, 2)
  }

  func testAPartPaidInHalvesSpendsTheMarkupWhenTheDueCloses() async throws {
    let plan = try await makePlan(markup: money(600))
    try await pay(plan, 1_325)
    XCTAssertEqual(try markups(of: plan.id), [], "the due is not closed yet")
    try await pay(plan, 1_325)
    XCTAssertEqual(try markups(of: plan.id).map(\.transaction.amountE4), [money(150)])
  }

  func testAPlanWithoutMarkupSpendsNothingButThePurchase() async throws {
    let plan = try await makePlan()
    try await pay(plan, 2_500)
    XCTAssertEqual(try markups(of: plan.id), [])
    XCTAssertEqual(try entries().count, 2, "the purchase and the payment")
  }

  func testAPaymentOfAPlanIsNotMySpendingAgain() async throws {
    let plan = try await makePlan()
    try await pay(plan, 2_500)
    XCTAssertFalse(DebtRules.paymentIsExpense(on: try debt(plan.id)))
    XCTAssertTrue(DebtRules.purchaseIsExpense(on: try debt(plan.id)))
  }

  func testUndoOfAPaymentTakesItsMarkupBack() async throws {
    let plan = try await makePlan(markup: money(600))
    try await pay(plan, 2_650)
    try await undo()
    XCTAssertEqual(try markups(of: plan.id), [])
    XCTAssertEqual(try balance(plan.id), money(10_600))
    XCTAssertEqual(try dues(plan.id).paidCount, 0)
  }

  // MARK: The summary

  func testTheSummaryCountsWhatIsLeftAndTheSoonestParts() async throws {
    let first = try await makePlan(name: "First", price: 4_000, parts: 4)
    let second = try await makePlan(
      name: "Second", price: 6_000, parts: 2, day: today.adding(days: 3))
    let summary = try snapshot.planning.instalments
    XCTAssertEqual(summary.count, 2)
    XCTAssertEqual(summary.totalRub, money(10_000))
    XCTAssertEqual(summary.next.count, 5)
    XCTAssertEqual(summary.next.first?.debtId, first.id)
    XCTAssertEqual(summary.next.first?.due, today)
    XCTAssertEqual(summary.next[1].debtId, second.id)
    XCTAssertEqual(summary.next[1].amountE4, money(3_000))
    XCTAssertEqual(summary.next.map(\.due), summary.next.map(\.due).sorted())
  }

  func testAPlanPaidToTheEndLeavesTheSummary() async throws {
    let plan = try await makePlan(price: 2_000, parts: 2)
    try await pay(plan, 2_000)
    let summary = try snapshot.planning.instalments
    XCTAssertEqual(summary.count, 0)
    XCTAssertEqual(summary.next, [])
  }

  func testALoanIsNoPlanOfTheSummary() async throws {
    try await makeLoan()
    XCTAssertEqual(try snapshot.planning.instalments, .empty)
  }

  func testAPurchaseOnCreditCountsInTheSummaryToo() async throws {
    XCTAssertTrue(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "Sofa", price: money(30_000), currency: .rub, day: today, categoryId: home.id,
          account: card.id, parts: nil, everyDays: nil, paymentDay: 5, markup: nil,
          monthly: money(5_000))))
    try await show()
    let sofa = try XCTUnwrap(try debts().first { $0.name == "Sofa" })
    XCTAssertFalse(sofa.isInstalmentPlan)
    XCTAssertEqual(sofa.origin, .purchase)
    let summary = try snapshot.planning.instalments
    XCTAssertEqual(summary.count, 1)
    XCTAssertEqual(summary.totalRub, money(30_000))
    XCTAssertEqual(summary.next.first?.amountE4, money(5_000))
  }

  // MARK: A purchase on credit made a plan later

  private func sofa() async throws -> Debt {
    XCTAssertTrue(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "Sofa", price: money(30_000), currency: .rub, day: today, categoryId: home.id,
          account: card.id, parts: nil, everyDays: nil, paymentDay: nil, markup: nil,
          monthly: nil)))
    try await show()
    return try XCTUnwrap(try debts().first { $0.name == "Sofa" })
  }

  func testAPurchaseOnCreditWithoutAMonthlySumHasNoDues() async throws {
    let sofa = try await sofa()
    XCTAssertNil(sofa.paymentDay)
    XCTAssertFalse(sofa.hasDues)
  }

  func testAPurchaseOnCreditBecomesAPlanWithItsMarkupInOneStep() async throws {
    let sofa = try await sofa()
    XCTAssertTrue(
      actions.makeInstalmentPlan(
        sofa, parts: 6, everyDays: 30, firstDue: today.adding(days: 30), markup: money(1_200)))
    try await show()
    let plan = try debt(sofa.id)
    XCTAssertTrue(plan.isInstalmentPlan)
    XCTAssertEqual(plan.parts, 6)
    XCTAssertEqual(plan.steps, DebtSteps(everyDays: 30, firstDue: today.adding(days: 30)))
    XCTAssertEqual(try balance(sofa.id), money(31_200))
    XCTAssertEqual(try dues(sofa.id).amount(ofDue: 0), money(5_200))
    try await undo()
    XCTAssertNil(try debt(sofa.id).parts)
    XCTAssertEqual(try balance(sofa.id), money(30_000))
  }

  func testMadeAPlanTheCountOfPartsIsKeptInItsBounds() async throws {
    let sofa = try await sofa()
    XCTAssertTrue(
      actions.makeInstalmentPlan(sofa, parts: 1, everyDays: 0, firstDue: today, markup: nil))
    let plan = try debt(sofa.id)
    XCTAssertEqual(plan.parts, 2)
    XCTAssertEqual(plan.steps?.everyDays, 1)
    XCTAssertNil(plan.markupE4)
    XCTAssertEqual(try journal(sofa.id).count, 1, "no markup, no line")
  }

  // MARK: A thing returned

  private func refund(
    of plan: Debt, _ whole: Int64
  ) throws -> (TransactionEntry, DebtLine) {
    let bought = try purchase(of: plan.id)
    var draft = TransactionDraft(
      kind: .refund, occurredAt: noon(today), amount: money(whole), paymentMethodId: card.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = home.id
    draft.parts[0].refundOfPartId = bought.parts[0].id
    return (try draft.materialize(), try XCTUnwrap(try line(plan.id)))
  }

  func testAThingReturnedToTheCardLeavesTheDebtAlone() async throws {
    let plan = try await makePlan(price: 8_000, parts: 4)
    try await pay(plan, 2_000)
    let (refund, line) = try refund(of: plan, 8_000)
    XCTAssertEqual(InstalmentReturn.plan(of: refund, dataset: try snapshot.dataset)?.id, plan.id)
    let split = RefundRules.instalmentReturn(
      refund: money(8_000), debt: plan, balance: line.balance, paidPrincipal: money(2_000),
      choice: .toCard)
    XCTAssertEqual(split.toDebtE4, .zero)
    XCTAssertEqual(split.toAccountE4, money(8_000))
    let change = InstalmentReturn.change(
      refund: refund, debt: plan, split: split, day: today, closing: false)
    XCTAssertTrue(PlanningActions(deps).apply(change))
    XCTAssertEqual(try balance(plan.id), money(6_000))
    XCTAssertEqual(try entries().filter { $0.transaction.kind == .refund }.count, 1)
    try await undo()
    XCTAssertEqual(try entries().filter { $0.transaction.kind == .refund }, [])
  }

  func testAThingReturnedBeforeAnyPartIsPaidClosesTheDebtWhole() async throws {
    let plan = try await makePlan(price: 8_000, parts: 4)
    let (refund, line) = try refund(of: plan, 8_000)
    let paid = InstalmentReturn.paidPrincipal(
      of: plan, journal: try journal(plan.id), balance: line.balance, dues: line.dues)
    XCTAssertEqual(paid, .zero)
    let split = RefundRules.instalmentReturn(
      refund: money(8_000), debt: plan, balance: line.balance, paidPrincipal: paid,
      choice: .reducesDebt)
    XCTAssertEqual(split.toDebtE4, money(8_000))
    XCTAssertEqual(split.toAccountE4, .zero)
    XCTAssertTrue(
      PlanningActions(deps).apply(
        InstalmentReturn.change(
          refund: refund, debt: plan, split: split, day: today, closing: true)))
    XCTAssertEqual(try balance(plan.id), .zero)
    XCTAssertTrue(try debt(plan.id).closed)
    let refunds = try entries().filter { $0.transaction.kind == .refund }
    XCTAssertEqual(refunds.count, 1)
    XCTAssertNotNil(RefundRules.instalmentReturnKey(ofKey: refunds.first?.transaction.externalId))
  }

  func testHalfAThingReturnedLowersTheDebtByHalf() async throws {
    let plan = try await makePlan(price: 8_000, parts: 4)
    let (refund, line) = try refund(of: plan, 4_000)
    let split = RefundRules.instalmentReturn(
      refund: money(4_000), debt: plan, balance: line.balance, paidPrincipal: .zero,
      choice: .reducesDebt)
    XCTAssertTrue(
      PlanningActions(deps).apply(
        InstalmentReturn.change(
          refund: refund, debt: plan, split: split, day: today, closing: false)))
    XCTAssertEqual(try balance(plan.id), money(4_000))
    XCTAssertFalse(try debt(plan.id).closed)
  }

  func testWhatWasPaidOffThePriceLeavesTheMarkupOut() async throws {
    let plan = try await makePlan(markup: money(600))
    try await pay(plan, 2_650)
    try await show()
    let line = try XCTUnwrap(try line(plan.id))
    XCTAssertEqual(
      InstalmentReturn.paidPrincipal(
        of: plan, journal: try journal(plan.id), balance: line.balance, dues: line.dues),
      money(2_500))
  }

  func testARefundOfAnOrdinaryPurchaseIsNoReturnOfAPlan() async throws {
    let plain = try spend(1_000, on: today, account: card)
    try await show()
    var draft = TransactionDraft(
      kind: .refund, occurredAt: noon(today), amount: money(1_000), paymentMethodId: card.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = home.id
    draft.parts[0].refundOfPartId = plain.parts[0].id
    XCTAssertNil(InstalmentReturn.plan(of: try draft.materialize(), dataset: try snapshot.dataset))
  }
}
