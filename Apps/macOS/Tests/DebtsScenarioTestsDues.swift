import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The dues of a debt on the calendar and how money closes them: the 31st in February of a leap
/// year and of another, a loan that crosses the new year, a loan taken on its own payment day,
/// payments in halves, in two dues at once, short by the bank's cent and short by more, «больше
/// платежей не будет», a due that passed unpaid, the last due capped by what is left, and the
/// dues of a plan every few days across January.
@MainActor
final class DebtsScenarioTestsDues: DebtsScenarioCase {
  // MARK: The calendar

  func testThe31stIsTheLastDayOfFebruaryInALeapYear() async throws {
    try await move(to: DateOnly(year: 2028, month: 1, day: 31))
    let loan = try await makeLoan(paymentDay: 31, daysAgo: 0)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.due(0), DateOnly(year: 2028, month: 1, day: 31))
    XCTAssertEqual(dues.due(1), DateOnly(year: 2028, month: 2, day: 29))
    XCTAssertEqual(dues.due(2), DateOnly(year: 2028, month: 3, day: 31))
    XCTAssertEqual(dues.due(3), DateOnly(year: 2028, month: 4, day: 30))
  }

  func testThe31stIsThe28thOfFebruaryInAnOrdinaryYear() async throws {
    try await move(to: DateOnly(year: 2027, month: 1, day: 31))
    let loan = try await makeLoan(paymentDay: 31, daysAgo: 0)
    XCTAssertEqual(try dues(loan.id).due(1), DateOnly(year: 2027, month: 2, day: 28))
  }

  func testThe29thOfFebruaryOfALeapYearIsAPaymentDayOfItsOwn() async throws {
    try await move(to: DateOnly(year: 2028, month: 2, day: 29))
    let loan = try await makeLoan(paymentDay: 29, daysAgo: 0)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.firstDue, DateOnly(year: 2028, month: 2, day: 29))
    XCTAssertEqual(dues.due(12), DateOnly(year: 2029, month: 2, day: 28))
    XCTAssertEqual(dues.due(48), DateOnly(year: 2032, month: 2, day: 29))
  }

  func testALoanTakenInDecemberAfterItsDayFirstOwesInJanuary() async throws {
    try await move(to: DateOnly(year: 2026, month: 12, day: 15))
    let loan = try await makeLoan(paymentDay: 5, daysAgo: 0)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.firstDue, DateOnly(year: 2027, month: 1, day: 5))
    XCTAssertEqual(try line(loan.id)?.nextPayment, DateOnly(year: 2027, month: 1, day: 5))
  }

  func testALoanTakenOnItsPaymentDayOwesThatDayAndIsNotOverdue() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.firstDue, today)
    XCTAssertEqual(dues.overdue(today: today), [])
    XCTAssertEqual(try line(loan.id)?.nextPayment, today)
  }

  func testAPurchaseOnCreditBoughtOnItsPaymentDayFirstOwesAMonthLater() async throws {
    XCTAssertTrue(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "Sofa", price: money(30_000), currency: .rub, day: today, categoryId: home.id,
          account: card.id, parts: nil, everyDays: nil, paymentDay: today.day, markup: nil,
          monthly: money(5_000))))
    try await show()
    let sofa = try XCTUnwrap(try debts().first { $0.name == "Sofa" })
    XCTAssertEqual(try dues(sofa.id).firstDue, today.adding(months: 1))
  }

  func testAPlanEveryTwoWeeksCrossesTheNewYearByDays() async throws {
    try await move(to: DateOnly(year: 2026, month: 12, day: 25))
    let plan = try await makePlan()
    let dues = try dues(plan.id)
    XCTAssertEqual(
      (0..<4).map(dues.due),
      [
        DateOnly(year: 2026, month: 12, day: 25), DateOnly(year: 2027, month: 1, day: 8),
        DateOnly(year: 2027, month: 1, day: 22), DateOnly(year: 2027, month: 2, day: 5),
      ])
  }

  // MARK: Money closes the dues

  func testOneMonthlyPaymentClosesTheDueAndTheNextOneIsAMonthOn() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 10_000)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.paidCount, 1)
    XCTAssertEqual(dues.firstUnpaid, today.adding(months: 1))
    XCTAssertEqual(try line(loan.id)?.paidThisMonth, true)
  }

  func testTwoHalvesCloseOneDue() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 5_000)
    XCTAssertEqual(try dues(loan.id).paidCount, 0)
    XCTAssertEqual(try dues(loan.id).partialE4, money(5_000))
    XCTAssertEqual(try dues(loan.id).owed(today), money(5_000))
    try await pay(loan, 5_000)
    XCTAssertEqual(try dues(loan.id).paidCount, 1)
    XCTAssertEqual(try dues(loan.id).partialE4, .zero)
  }

  func testOnePaymentOfTwoDuesClosesBoth() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 20_000)
    XCTAssertEqual(try dues(loan.id).paidCount, 2)
    XCTAssertEqual(try dues(loan.id).firstUnpaid, today.adding(months: 2))
  }

  func testAPaymentShortByTheBanksCentStillClosesTheDue() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 9_950)
    XCTAssertEqual(try dues(loan.id).paidCount, 1, "within 1 % of the monthly payment")
  }

  func testAPaymentShortByMoreLeavesTheRestOwed() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 9_000)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.paidCount, 0)
    XCTAssertEqual(dues.owed(today), money(1_000))
  }

  func testNoMorePaymentsThisMonthClosesAShortDueAndUndoOpensIt() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 3_000, closesTerm: true)
    XCTAssertTrue(try journal(loan.id).last?.closesTerm ?? false)
    XCTAssertEqual(try dues(loan.id).paidCount, 1)
    try await undo()
    XCTAssertEqual(try dues(loan.id).paidCount, 0)
  }

  func testTheWordOnAFullPaymentChangesNothing() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 10_000, closesTerm: true)
    XCTAssertEqual(try dues(loan.id).paidCount, 1, "the money closed it anyway")
    XCTAssertEqual(try dues(loan.id).partialE4, .zero)
  }

  func testThePaymentsAddUpWhateverTheirOrderWithinTheDay() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 2_500)
    try await pay(loan, 2_500)
    try await pay(loan, 2_500)
    try await pay(loan, 2_500)
    try await pay(loan, 2_500)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.paidCount, 1)
    XCTAssertEqual(dues.partialE4, money(2_500))
  }

  // MARK: Time passes

  func testADueThatPassedUnpaidIsOverdueTheNextDay() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await move(to: today.adding(days: 1))
    XCTAssertEqual(try dues(loan.id).overdue(today: today), [today.adding(days: -1)])
    let overdue = try snapshot.planning.overdue.filter { $0.subject == .debt(loan.id) }
    XCTAssertEqual(overdue.map(\.due), [today.adding(days: -1)])
    XCTAssertEqual(overdue.first?.amount, money(10_000))
  }

  func testTwoMonthsUnpaidAreTwoOverdueDuesAndOnePaymentClosesTheEarliest() async throws {
    let start = today
    let loan = try await makeLoan(daysAgo: 0)
    try await move(to: start.adding(months: 1).adding(days: 3))
    XCTAssertEqual(
      try dues(loan.id).overdue(today: today), [start, start.adding(months: 1)])
    try await pay(loan, 10_000)
    XCTAssertEqual(try dues(loan.id).overdue(today: today), [start.adding(months: 1)])
  }

  func testAPaidDueNeverBecomesOverdue() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 10_000)
    try await move(to: today.adding(days: 10))
    XCTAssertEqual(try dues(loan.id).overdue(today: today), [])
    XCTAssertFalse(try snapshot.planning.overdue.contains { $0.subject == .debt(loan.id) })
  }

  func testAClosedDebtHasNoOverdueDues() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(actions.close(loan, balance: money(100_000), writeOff: true, on: today))
    try await move(to: today.adding(months: 2))
    XCTAssertFalse(try snapshot.planning.overdue.contains { $0.subject == .debt(loan.id) })
  }

  func testADeletedDebtHasNoOverdueDues() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(actions.delete(loan, at: noon(today)))
    try await move(to: today.adding(months: 2))
    XCTAssertFalse(try snapshot.planning.overdue.contains { $0.subject == .debt(loan.id) })
  }

  // MARK: Taken before a count

  func testADueTakenBeforeACountIsALineWithoutMoneyAndUndoGivesItBack() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await move(to: today.adding(days: 2))
    let due = today.adding(days: -2)
    XCTAssertTrue(actions.settle(debt: try debt(loan.id), due: due))
    let settled = try XCTUnwrap(try journal(loan.id).last)
    XCTAssertEqual(settled.kind, .payment)
    XCTAssertNil(settled.transactionId)
    XCTAssertNil(settled.paymentMethodId)
    XCTAssertEqual(settled.date, due)
    XCTAssertEqual(settled.amountE4, money(-10_000))
    XCTAssertEqual(try payments(of: loan.id), [], "no money moved")
    try await show()
    XCTAssertEqual(try dues(loan.id).paidCount, 1)
    try await undo()
    XCTAssertEqual(try dues(loan.id).paidCount, 0)
  }

  func testADueHalfPaidIsTakenForWhatIsLeftOfIt() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    try await pay(loan, 4_000)
    XCTAssertTrue(
      actions.settle(debt: try debt(loan.id), due: today, owed: try dues(loan.id).owed(today)))
    XCTAssertEqual(try journal(loan.id).last?.amountE4, money(-6_000))
    try await show()
    XCTAssertEqual(try dues(loan.id).paidCount, 1)
  }

  func testAClosedDebtTakesNoDueBeforeACount() async throws {
    let loan = try await makeLoan(daysAgo: 0)
    XCTAssertTrue(actions.close(loan, balance: money(100_000), writeOff: true, on: today))
    XCTAssertFalse(actions.settle(debt: try debt(loan.id), due: today))
  }

  func testADueTakenBeforeACountNeverTakesMoreThanIsLeft() async throws {
    let loan = try await makeLoan(owed: 3_000, daysAgo: 0)
    XCTAssertTrue(actions.settle(debt: try debt(loan.id), due: today))
    XCTAssertEqual(try journal(loan.id).last?.amountE4, money(-3_000))
    XCTAssertEqual(try balance(loan.id), .zero)
  }

  // MARK: What is left caps the dues

  func testTheLastDueAsksOnlyWhatIsLeft() async throws {
    let loan = try await makeLoan(owed: 15_000, daysAgo: 0)
    let dues = try dues(loan.id)
    XCTAssertEqual(dues.owed(today), money(10_000))
    XCTAssertEqual(dues.owed(today.adding(months: 1)), money(5_000))
    XCTAssertEqual(dues.owed(today.adding(months: 2)), .zero)
    XCTAssertEqual(dues.unpaid(through: today.adding(months: 6)).count, 2)
  }

  func testAPaidOffDebtOwesNoDueAnyMore() async throws {
    let loan = try await makeLoan(owed: 10_000, daysAgo: 0)
    try await pay(loan, 10_000)
    let dues = try dues(loan.id)
    XCTAssertFalse(dues.owes)
    XCTAssertNil(dues.firstUnpaid)
    XCTAssertNil(try line(loan.id)?.nextPayment)
  }

  // MARK: Debts without dues

  func testADebtWithoutAPaymentDayHasNoDues() async throws {
    let lent = try await makeOwedToMe()
    XCTAssertFalse(lent.hasDues)
    XCTAssertNil(try line(lent.id)?.nextPayment)
    XCTAssertNil(try dues(lent.id).firstUnpaid)
  }

  func testADayWithoutAMonthlySumIsNoDue() async throws {
    let loan = try await makeLoan(monthly: nil, rate: nil, daysAgo: 0)
    XCTAssertFalse(loan.hasDues)
    try await move(to: today.adding(months: 3))
    XCTAssertFalse(try snapshot.planning.overdue.contains { $0.subject == .debt(loan.id) })
  }

  func testTheMonthlyPaymentsOfTheSectionLeaveClosedDebtsOut() async throws {
    let first = try await makeLoan(name: "First", monthly: 3_000, daysAgo: 0)
    try await makeLoan(name: "Second", monthly: 2_000, daysAgo: 0)
    XCTAssertEqual(try snapshot.planning.debts.monthlyPaymentsRub, money(5_000))
    XCTAssertTrue(actions.close(first, balance: money(100_000), writeOff: true, on: today))
    try await show()
    XCTAssertEqual(try snapshot.planning.debts.monthlyPaymentsRub, money(2_000))
  }
}
