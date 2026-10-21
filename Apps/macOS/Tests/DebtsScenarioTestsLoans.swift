import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A bank loan from the Debts section: interest charged day by day and paid first, a tranche of
/// an education loan, an early repayment and the answer offered for the next one, a planned
/// early repayment and the days its reminder shows, sums typed from the bank's app, the fees and
/// the insurance of a loan, the review of a loan written before this version and the ladder —
/// each write one step of ⌘Z.
@MainActor
final class DebtsScenarioTestsLoans: DebtsScenarioCase {
  private func interestOperations(of id: UUID) throws -> [TransactionEntry] {
    try entries().filter {
      DebtInterestPayment.payment(ofKey: $0.transaction.externalId) != nil
        && $0.transaction.creditDebtId == id
    }
  }

  // MARK: Interest first

  /// 100,000 at 12 % for thirty days of a year of 365: 986.30 accrued.
  func testThirtyDaysOfTwelvePercentArePaidFirstAsAnExpenseInLoans() async throws {
    let loan = try await makeLoan(monthly: nil, daysAgo: 30, expenses: false, accrues: true)
    try await pay(loan, 5_000)
    let interest = try XCTUnwrap(try interestOperations(of: loan.id).first)
    XCTAssertEqual(interest.transaction.amountE4, amount("986.30"))
    XCTAssertEqual(actions.balance(of: try debt(loan.id)), amount("95986.30"))
    XCTAssertEqual(
      try journal(loan.id).filter { $0.kind == .payment }.map(\.amountE4), [money(-5_000)])
  }

  func testWhatIsAccruedShowsOnTheLineBeforeAnyPayment() async throws {
    let loan = try await makeLoan(monthly: nil, daysAgo: 30, expenses: false, accrues: true)
    XCTAssertEqual(try line(loan.id)?.accruedInterestE4, amount("986.30"))
    XCTAssertEqual(actions.payoff(of: loan), amount("100986.30"))
  }

  func testASecondPaymentTheSameDayPaysNoInterestAgain() async throws {
    let loan = try await makeLoan(monthly: nil, daysAgo: 30, expenses: false, accrues: true)
    try await pay(loan, 5_000)
    try await pay(loan, 1_000)
    XCTAssertEqual(try interestOperations(of: loan.id).count, 1)
    XCTAssertEqual(actions.balance(of: try debt(loan.id)), amount("94986.30"))
  }

  func testPayingThePayoffClosesTheLoanAtZero() async throws {
    let loan = try await makeLoan(
      owed: 10_000, monthly: nil, daysAgo: 30, expenses: false, accrues: true)
    let payoff = try XCTUnwrap(actions.payoff(of: loan))
    XCTAssertTrue(
      actions.pay(
        loan, amount: payoff, on: noon(today), paymentMethodId: card.id, closing: true))
    XCTAssertTrue(try debt(loan.id).closed)
    XCTAssertEqual(actions.balance(of: try debt(loan.id)), .zero)
    try await undo()
    XCTAssertFalse(try debt(loan.id).closed)
    XCTAssertEqual(try interestOperations(of: loan.id), [])
  }

  func testALoanThatChargesNoInterestPaysNoneFirst() async throws {
    let loan = try await makeLoan(monthly: nil, daysAgo: 30, expenses: false, accrues: false)
    try await pay(loan, 5_000)
    XCTAssertEqual(try interestOperations(of: loan.id), [])
    XCTAssertEqual(actions.balance(of: try debt(loan.id)), money(95_000))
    XCTAssertEqual(try line(loan.id)?.accruedInterestE4, .zero)
  }

  func testInterestOverAFebruaryOfALeapYearCountsItsTwentyNineDays() async throws {
    try await move(to: DateOnly(year: 2028, month: 3, day: 1))
    let loan = try await makeLoan(
      owed: 366_000, monthly: nil, rate: 10, daysAgo: 29, expenses: false, accrues: true)
    // 366,000 × 10 % / 366 a day, 29 days.
    XCTAssertEqual(try line(loan.id)?.accruedInterestE4, money(2_900))
  }

  // MARK: Tranches

  func testATrancheOfALoanOwedToMeOrOfNothingIsRefused() async throws {
    let lent = try await makeOwedToMe()
    XCTAssertFalse(actions.addTranche(lent, amount: money(1_000), on: today, account: card.id))
    let loan = try await makeLoan()
    XCTAssertFalse(actions.addTranche(loan, amount: .zero, on: today, account: card.id))
    XCTAssertEqual(try journal(loan.id).count, 1)
  }

  func testTwoTranchesShareOneEducationCategory() async throws {
    let loan = try await makeLoan(expenses: false)
    XCTAssertTrue(actions.addTranche(loan, amount: money(50_000), on: today, account: card.id))
    try await show()
    XCTAssertTrue(
      actions.addTranche(
        try debt(loan.id), amount: money(60_000), on: today.adding(months: 6), account: card.id))
    let tranches = try entries().filter { $0.transaction.creditDebtId == loan.id }
    XCTAssertEqual(tranches.count, 2)
    XCTAssertEqual(Set(tranches.compactMap { $0.parts.first?.categoryId }).count, 1)
    XCTAssertEqual(try balance(loan.id), money(210_000))
    XCTAssertEqual(try journal(loan.id).filter(\.tranche).count, 2)
  }

  func testATrancheOnAnArchivedAccountIsTakenOnTheMainOne() async throws {
    var old = PaymentMethod(name: "Old", currency: .rub)
    old.archived = true
    try XCTUnwrap(environment.references).save(old)
    let loan = try await makeLoan(expenses: false)
    XCTAssertTrue(actions.addTranche(loan, amount: money(5_000), on: today, account: old.id))
    XCTAssertEqual(
      try entries().first { $0.transaction.creditDebtId == loan.id }?.transaction.paymentMethodId,
      card.id)
  }

  // MARK: Early repayment

  func testNoQuestionWhileThePaymentIsTheDue() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertNil(
      DebtPrepayment.question(
        debt: loan, amount: money(10_000), day: today, dues: try dues(loan.id),
        journal: try journal(loan.id)))
  }

  func testTheMoneyAboveTheDueIsWhatIsAskedAbout() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    let question = try XCTUnwrap(
      DebtPrepayment.question(
        debt: loan, amount: money(40_000), day: today, dues: try dues(loan.id),
        journal: try journal(loan.id)))
    XCTAssertEqual(question.excess, money(29_900), "above the due and its cent")
    XCTAssertEqual(question.choice, .term)
  }

  func testAnInstalmentPlanIsNeverAskedAboutAnEarlyRepayment() async throws {
    let plan = try await makePlan()
    XCTAssertNil(
      DebtPrepayment.question(
        debt: plan, amount: money(10_000), day: today, dues: try dues(plan.id),
        journal: try journal(plan.id)))
  }

  func testTheAnswerOfTheLatestEarlyRepaymentIsOfferedFirst() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 30_000, prepay: .term)
    try await pay(loan, 20_000, prepay: .payment)
    XCTAssertEqual(
      DebtPrepay.defaultChoice(debtId: loan.id, journal: try journal(loan.id)), .payment,
      "the answer given last, though both were given the same day")
  }

  func testAShorterTermKeepsThePaymentAndEndsSooner() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    let before = try dues(loan.id).unpaid(through: today.adding(months: 24)).count
    try await pay(loan, 40_000, prepay: .term)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.paidCount, 1, "the money above the due pays no next one")
    XCTAssertEqual(dues.owed(today.adding(months: 1)), money(10_000))
    XCTAssertLessThan(dues.unpaid(through: today.adding(months: 24)).count, before - 1)
  }

  func testASmallerPaymentKeepsTheTermAndLowersTheNextDue() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 40_000, prepay: .payment)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.paidCount, 1)
    XCTAssertLessThan(dues.amount(ofDue: 1), money(10_000))
  }

  func testUndoOfAnEarlyRepaymentGivesThePlanBack() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(
      actions.planPrepay(
        loan, PlannedPrepay(day: today, amountE4: money(30_000)), noticeDays: nil))
    try await show()
    try await pay(loan, 40_000, prepay: .term)
    XCTAssertNil(try debt(loan.id).plannedPrepay)
    try await undo()
    XCTAssertEqual(try debt(loan.id).plannedPrepay?.amountE4, money(30_000))
  }

  // MARK: A planned early repayment

  private func reminded(_ id: UUID) throws -> Bool {
    try snapshot.planning.debtReminders.contains {
      if case .prepayNotice(let debtId, _, _, _) = $0 { debtId == id } else { false }
    }
  }

  func testTheReminderShowsFromTheDayToFileItToTheDayOfThePayment() async throws {
    let start = today
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(
      actions.planPrepay(
        loan, PlannedPrepay(day: start.adding(days: 10), amountE4: money(30_000)),
        noticeDays: 3))
    try await show()
    XCTAssertFalse(try reminded(loan.id))
    try await move(to: start.adding(days: 6))
    XCTAssertFalse(try reminded(loan.id), "the day before the day to file")
    try await move(to: start.adding(days: 7))
    XCTAssertTrue(try reminded(loan.id))
    try await move(to: start.adding(days: 10))
    XCTAssertTrue(try reminded(loan.id))
    try await move(to: start.adding(days: 11))
    XCTAssertFalse(try reminded(loan.id))
  }

  func testWithoutNoticeDaysTheReminderComesADayBefore() async throws {
    let start = today
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(
      actions.planPrepay(
        loan, PlannedPrepay(day: start.adding(days: 5), amountE4: money(30_000)),
        noticeDays: nil))
    try await move(to: start.adding(days: 3))
    XCTAssertFalse(try reminded(loan.id))
    try await move(to: start.adding(days: 4))
    XCTAssertTrue(try reminded(loan.id))
  }

  func testTheNoticeDaysAreKeptBetweenNoneAndNinety() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(actions.planPrepay(loan, nil, noticeDays: 200))
    XCTAssertEqual(try debt(loan.id).prepayNoticeDays, 90)
    XCTAssertTrue(actions.planPrepay(try debt(loan.id), nil, noticeDays: -5))
    XCTAssertEqual(try debt(loan.id).prepayNoticeDays, 0)
  }

  func testAPlanTakenAwayIsOneStepAndUndoBringsItBack() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(
      actions.planPrepay(
        loan, PlannedPrepay(day: today, amountE4: money(30_000)), noticeDays: 2))
    XCTAssertTrue(actions.planPrepay(try debt(loan.id), nil, noticeDays: 2))
    XCTAssertNil(try debt(loan.id).plannedPrepay)
    try await undo()
    XCTAssertEqual(try debt(loan.id).plannedPrepay?.day, today)
  }

  func testAClosedLoanIsRemindedOfNoPlan() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(
      actions.planPrepay(
        loan, PlannedPrepay(day: today, amountE4: money(30_000)), noticeDays: 2))
    XCTAssertTrue(actions.close(try debt(loan.id), balance: .zero, writeOff: true, on: today))
    try await show()
    XCTAssertFalse(try reminded(loan.id))
  }

  // MARK: Sums from the bank's app

  func testASumTypedTwiceForOneDueKeepsTheLatest() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(actions.typeInstalment(loan, fromIndex: 2, amount: money(9_000)))
    try await show()
    XCTAssertTrue(actions.typeInstalment(loan, fromIndex: 2, amount: money(8_000)))
    try await show()
    XCTAssertEqual(try snapshot.dataset.debtInstalments.filter { $0.debtId == loan.id }.count, 1)
    let typed = try dues(loan.id)
    XCTAssertEqual(typed.amount(ofDue: 1), money(10_000))
    XCTAssertEqual(typed.amount(ofDue: 2), money(8_000))
    XCTAssertEqual(typed.amount(ofDue: 3), money(8_000), "the sum holds for the dues after it")
    try await undo()
    XCTAssertEqual(try dues(loan.id).amount(ofDue: 2), money(9_000))
  }

  func testTakingAwayASumNeverTypedWritesNothing() async throws {
    let loan = try await makeLoan()
    XCTAssertFalse(actions.typeInstalment(loan, fromIndex: 1, amount: nil))
  }

  func testASumTypedBelowTheFirstDueIsKeptAtTheFirst() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(actions.typeInstalment(loan, fromIndex: -3, amount: money(7_000)))
    try await show()
    XCTAssertEqual(try dues(loan.id).amount(ofDue: 0), money(7_000))
  }

  // MARK: Fees and insurance

  private func insuredLoan(
    costs: [DebtCost]
  ) async throws -> Debt {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Car loan", interestRate: 15,
      monthlyPaymentE4: money(10_000), paymentDay: today.day)
    XCTAssertTrue(
      actions.create(debt, balance: money(200_000), on: today, moneyMovedNow: false, costs: costs))
    try await show()
    return try self.debt(debt.id)
  }

  private func cooling(_ id: UUID) throws -> Bool {
    try snapshot.planning.debtReminders.contains {
      if case .insuranceCooling(_, let debtId, _) = $0 { debtId == id } else { false }
    }
  }

  func testInsuranceCanBeGivenBackForThirtyDaysAndNotOneMore() async throws {
    let start = today
    let loan = try await insuredLoan(
      costs: [DebtCost(debtId: UUID(), kind: .insurance, amountE4: money(20_000), day: start)])
    XCTAssertTrue(try cooling(loan.id))
    try await move(to: start.adding(days: 30))
    XCTAssertTrue(try cooling(loan.id))
    try await move(to: start.adding(days: 31))
    XCTAssertFalse(try cooling(loan.id))
  }

  func testAMonthlyCostIsNotSpentAhead() async throws {
    let loan = try await insuredLoan(
      costs: [
        DebtCost(debtId: UUID(), kind: .fee, amountE4: money(500), every: .monthly, day: today)
      ])
    XCTAssertEqual(try entries(), [])
    XCTAssertEqual(try snapshot.dataset.debtCosts.filter { $0.debtId == loan.id }.count, 1)
    XCTAssertFalse(try cooling(loan.id))
  }

  func testAFeePaidApartIsAnExpenseInTheLoansSubcategory() async throws {
    let loan = try await insuredLoan(
      costs: [DebtCost(debtId: UUID(), kind: .fee, amountE4: money(3_000), day: today)])
    let fee = try XCTUnwrap(try entries().first)
    XCTAssertEqual(fee.transaction.amountE4, money(3_000))
    XCTAssertEqual(fee.parts.first?.categoryId, loan.loansSubcategoryId)
    XCTAssertEqual(try balance(loan.id), money(200_000), "paid apart, the debt is the same")
  }

  func testInsuranceGoesToAnInsuranceCategoryThereAlreadyIs() async throws {
    let insurance = CoreKit.Category(kind: .expense, name: "Insurance", quality: .neutral)
    try XCTUnwrap(environment.references).save(insurance)
    try await show()
    _ = try await insuredLoan(
      costs: [DebtCost(debtId: UUID(), kind: .insurance, amountE4: money(1_000), day: today)])
    XCTAssertEqual(try entries().first?.parts.first?.categoryId, insurance.id)
    XCTAssertEqual(
      try categories().filter {
        $0.parentId == nil && ["Insurance", "Страховка"].contains($0.name)
      }.count, 1, "no second one at the top")
  }

  func testCostsAddedLaterGrowTheLoanWhenHeldBackAndUndoTakesThem() async throws {
    let loan = try await insuredLoan(costs: [])
    XCTAssertTrue(
      actions.addCosts(
        loan,
        costs: [
          DebtCost(debtId: loan.id, kind: .fee, amountE4: money(2_000), day: today, inLoan: true),
          DebtCost(debtId: loan.id, kind: .insurance, amountE4: money(5_000), day: today),
        ]))
    XCTAssertEqual(try balance(loan.id), money(202_000))
    XCTAssertEqual(try entries().map(\.transaction.amountE4), [money(5_000)])
    try await undo()
    XCTAssertEqual(try balance(loan.id), money(200_000))
    XCTAssertEqual(try entries(), [])
  }

  func testNoCostsAndNoDebtToSaveIsNothingToWrite() async throws {
    let loan = try await insuredLoan(costs: [])
    XCTAssertFalse(actions.addCosts(loan, costs: []))
  }

  func testACostTakenAwayTakesItsExpenseAndUndoGivesBoth() async throws {
    _ = try await insuredLoan(
      costs: [DebtCost(debtId: UUID(), kind: .insurance, amountE4: money(20_000), day: today)])
    let cost = try XCTUnwrap(try snapshot.dataset.debtCosts.first)
    XCTAssertTrue(actions.removeCost(cost))
    try await show()
    XCTAssertEqual(try entries(), [])
    XCTAssertEqual(try snapshot.dataset.debtCosts, [])
    try await undo()
    XCTAssertEqual(try entries().count, 1)
    XCTAssertEqual(try snapshot.dataset.debtCosts.count, 1)
  }

  // MARK: Loans of an earlier version

  private func oldLoan(
    direction: DebtDirection = .iOwe, closed: Bool = false
  ) async throws
    -> Debt
  {
    let old = Debt(
      direction: direction, type: .loan, name: "Old", interestRate: 15,
      monthlyPaymentE4: money(5_000), paymentDay: 5, closed: closed, termsReviewed: false)
    var rows = PlanningRows.empty
    rows.debts = [old]
    XCTAssertTrue(PlanningActions(deps).apply(PlanningChange(upsert: rows)))
    try await show()
    return old
  }

  func testAClosedOldLoanIsNotAskedAbout() async throws {
    _ = try await oldLoan(closed: true)
    XCTAssertEqual(try snapshot.planning.debtReview, [])
  }

  func testAnOldDebtOwedToMeIsNotAskedAbout() async throws {
    _ = try await oldLoan(direction: .owedToMe)
    XCTAssertEqual(try snapshot.planning.debtReview, [])
  }

  func testAReviewWithInsuranceWritesTheInsurance() async throws {
    let old = try await oldLoan()
    XCTAssertTrue(
      actions.review(
        old,
        costs: [DebtCost(debtId: old.id, kind: .insurance, amountE4: money(4_000), day: today)]))
    try await show()
    XCTAssertTrue(try debt(old.id).termsReviewed)
    XCTAssertEqual(try entries().map(\.transaction.amountE4), [money(4_000)])
    XCTAssertEqual(try snapshot.planning.debtReview, [])
  }

  // MARK: The ladder

  func testTheLadderLeavesOutDebtsOwedToMeClosedAndLeftOnes() async throws {
    let kept = try await makeLoan(name: "Kept")
    let left = try await makeLoan(name: "Left")
    let paid = try await makeLoan(name: "Paid", owed: 10_000)
    try await makeOwedToMe()
    XCTAssertTrue(actions.setInLadder(left, false))
    try await pay(paid, 10_000, closing: true)
    XCTAssertEqual(LadderSection.candidates(try snapshot).map(\.id), [kept.id])
    XCTAssertTrue(actions.setInLadder(try debt(left.id), true))
    try await show()
    XCTAssertNil(try debt(left.id).inLadder, "back to the standard rule")
    XCTAssertEqual(Set(LadderSection.candidates(try snapshot).map(\.id)), [kept.id, left.id])
  }
}
