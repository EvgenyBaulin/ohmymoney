import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A debt whose payment day came before it began owes nothing in its first month, so a payment
/// made in that month has nothing to pay but the first due: a phone bought in parts on
/// 15 September, paid on the 5th, and paid 3 000 on 25 September has paid its 5 October. Every
/// screen that names the next payment says so — the Debts screen, the 7-day card, the
/// reminders, the planned month and the free sum.
@Suite("A payment in the month a debt began pays its first due")
struct DebtStartPrepaymentTests {
  typealias Fx = CashFx

  static let phone = DebtStartTests.phone

  /// A loan of 8 000 a month on the 5th whose payments are expenses.
  static let loan = Debt(
    id: CashFx.id(305), direction: .iOwe, type: .loan, name: "Loan",
    monthlyPaymentE4: CashFx.money("8000"), paymentDay: 5)

  /// The phone bought on `start` for 30 000, and a payment of 3 000 on `paid` — written in the
  /// journal alone, or as an operation on the debt.
  func book(start: String, paid: String?, byOperation: Bool = false) -> CashFx {
    var fx = Fx()
    fx.debts = [Self.phone]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.phone.id, date: Fx.day(start), amountE4: Fx.money("30000"), kind: .borrowed)
    ]
    if let paid {
      if byOperation {
        let id = fx.add(
          .expense, "3000", at: Fx.at(paid, 12), category: Fx.fun, debt: Self.phone.id)
        fx.debtEntries.append(
          DebtEntry(
            debtId: Self.phone.id, date: Fx.day(paid), amountE4: Fx.money("-3000"),
            kind: .payment, transactionId: id))
      } else {
        fx.debtEntries.append(
          DebtEntry(
            debtId: Self.phone.id, date: Fx.day(paid), amountE4: Fx.money("-3000"),
            kind: .payment))
      }
    }
    return fx
  }

  /// Bought on the 15th, paid 3 000 on the 17th, today the 19th: the next payment is
  /// 5 November. Nothing is held back through October; November's is.
  @Test func aPaymentInTheFirstMonthPaysTheFirstDue() {
    for byOperation in [false, true] {
      let fx = book(start: "2026-09-15", paid: "2026-09-17", byOperation: byOperation)
      let snapshot = fx.snapshot()
      #expect(
        snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-11-05"), "\(byOperation)")
      #expect(fx.plan(until: "2026-10-31").debts == .zero, "\(byOperation)")
      #expect(fx.plan(until: "2026-11-30").debts == Fx.money("3000"), "\(byOperation)")
    }
  }

  /// The auditor's case: paid 3 000 on 25 September. On 2 October nothing is reminded and the
  /// 7-day card is empty; on 6 October nothing is overdue — 5 October was paid in September.
  @Test func theFirstDueIsNeitherRemindedNorOverdue() {
    let fx = book(start: "2026-09-15", paid: "2026-09-25")
    for today in ["2026-10-02", "2026-10-06"] {
      let snapshot = fx.snapshot(today: Fx.day(today), now: Fx.at(today, 12))
      #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-11-05"), "\(today)")
      #expect(!snapshot.upcoming.contains { $0.kind == .debt }, "\(today)")
      #expect(!snapshot.reminders.contains { $0.kind == .debtPayment }, "\(today)")
    }
    // Three days before 5 November it is reminded.
    let november = fx.snapshot(today: Fx.day("2026-11-02"), now: Fx.at("2026-11-02", 12))
    #expect(
      november.reminders.filter { $0.kind == .debtPayment }.map(\.due) == [Fx.day("2026-11-05")])
  }

  /// A payment made in October as well closes the next due: each payment closes the earliest
  /// one still unpaid, so the payments of 25 September and 4 October pay 5 October and 5
  /// November, and 5 December is next.
  @Test func aSecondPaymentInTheFirstOwingMonthPaysTheNextDue() {
    var fx = book(start: "2026-09-15", paid: "2026-09-25")
    fx.debtEntries.append(
      DebtEntry(
        debtId: Self.phone.id, date: Fx.day("2026-10-04"), amountE4: Fx.money("-3000"),
        kind: .payment))
    let snapshot = fx.snapshot(today: Fx.day("2026-10-06"), now: Fx.at("2026-10-06", 12))
    #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-12-05"))
    #expect(fx.plan(until: "2026-10-31", today: Fx.day("2026-10-06")).debts == .zero)
    #expect(fx.plan(until: "2026-11-30", today: Fx.day("2026-10-06")).debts == .zero)
    #expect(
      fx.plan(until: "2026-12-31", today: Fx.day("2026-10-06")).debts == Fx.money("3000"))
  }

  /// A debt that began on 3 September, before its day: September owes, so a payment on the
  /// 17th is September's, late — October's is still due.
  @Test func aFirstMonthThatOwesKeepsItsPayment() {
    let fx = book(start: "2026-09-03", paid: "2026-09-17")
    let snapshot = fx.snapshot()
    #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-10-05"))
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("3000"))
    let october = fx.snapshot(today: Fx.day("2026-10-06"), now: Fx.at("2026-10-06", 12))
    #expect(october.upcoming.filter { $0.kind == .debt }.map(\.isOverdue) == [true])
  }

  /// An operation on the debt dated in a month before the one the debt began — typed in the
  /// entry line, with no line of its own in the journal — pays nothing of it: the debt of
  /// 15 October first owes on 5 November.
  @Test func aPaymentBeforeTheFirstMonthPaysNothing() {
    var fx = book(start: "2026-10-15", paid: nil)
    fx.add(.expense, "3000", at: Fx.at("2026-09-17", 12), category: Fx.fun, debt: Self.phone.id)
    let snapshot = fx.snapshot()
    #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-11-05"))
    #expect(fx.plan(until: "2026-11-30").debts == Fx.money("3000"))
  }

  /// A loan whose payments are expenses, taken on the 15th and paid 8 000 on the 17th: the
  /// planned month through October has no payment of it — «can save» and the forecast do not
  /// ask for 5 October again.
  @Test func thePlannedMonthKnowsTheFirstDueIsPaid() {
    var fx = Fx()
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-09-15"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    fx.add(.expense, "8000", at: Fx.at("2026-09-17", 12), category: Fx.fun, debt: Self.loan.id)
    let october = PlannedMonth.build(
      ledger: fx.ledger, book: fx.book, today: Fx.today, until: Fx.day("2026-10-31"),
      rubPerUnit: fx.rubPerUnit)
    #expect(!october.items.contains { $0.kind == .debt })
    let november = PlannedMonth.build(
      ledger: fx.ledger, book: fx.book, today: Fx.today, until: Fx.day("2026-11-30"),
      rubPerUnit: fx.rubPerUnit)
    #expect(november.items.filter { $0.kind == .debt }.map(\.due) == [Fx.day("2026-11-05")])
  }

  /// The date alone decides: `DebtSchedule.nextPaymentDate` given the day the debt began and
  /// whether a payment was made in today's month.
  @Test func theScheduleGivenAPaymentInTheFirstMonth() {
    func next(_ today: String, paid: Bool, start: String?) -> DateOnly? {
      DebtSchedule.nextPaymentDate(
        of: Self.phone, today: Fx.day(today), paidThisMonth: paid, calendar: .utc,
        startsOn: start.map(Fx.day))
    }
    // Paid in the month it began, which owed nothing: the first due is paid.
    #expect(next("2026-09-19", paid: true, start: "2026-09-15") == Fx.day("2026-11-05"))
    // Paid before the month it began: the first due is still owed.
    #expect(next("2026-09-19", paid: true, start: "2026-11-10") == Fx.day("2026-12-05"))
    // The first month owed: paid in it, the next is next month's, as for any debt.
    #expect(next("2026-09-19", paid: true, start: "2026-09-03") == Fx.day("2026-10-05"))
    #expect(next("2026-09-19", paid: true, start: nil) == Fx.day("2026-10-05"))
  }
}
