import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A due paid in part is owed in part. A loan of 8 000 on the 5th, taken on 20 August: 3 000 of
/// the due of 5 September were paid on the 6th. Today is the 19th, so the 5 000 that are left
/// are overdue: the grey line of the free sum, the row of the overdue dues, the card of the
/// coming week and the planned month all ask for 5 000, not 8 000 — and October asks for its
/// 8 000 whole.
@Suite("A due paid in part is owed by what is left of it")
struct DebtPartialDueTests {
  typealias Fx = CashFx

  static let loan = Debt(
    id: Fx.id(341), direction: .iOwe, type: .loan, name: "Loan",
    monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)

  func book() -> Fx {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-08-20"), amountE4: Fx.money("80000"),
        kind: .borrowed),
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-09-06"), amountE4: Fx.money("-3000"),
        kind: .payment),
    ]
    return fx
  }

  @Test func theGreyLineTakesWhatIsLeftOfTheDue() {
    let plan = book().plan(until: "2026-10-31")
    #expect(plan.debts == Fx.money("13000"), "5 000 of September and 8 000 of October")
    #expect(plan.overdue == Fx.money("5000"), "only the rest of the due of the 5th is overdue")
    // A due paid in full is owed in full, as before.
    var whole = book()
    whole.debtEntries.append(
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-09-08"), amountE4: Fx.money("-5000"),
        kind: .payment))
    #expect(whole.plan(until: "2026-10-31").debts == Fx.money("8000"))
  }

  @Test func theOverdueRowAsksForTheRestOfTheDue() {
    let overdue = book().snapshot().overdue
    #expect(overdue.map(\.due) == [Fx.day("2026-09-05")])
    #expect(overdue.map(\.amount) == [Fx.money("5000")])
    #expect(overdue.map(\.moreOverdue) == [0])
  }

  /// The rest of the due is never more than the debt itself: 1 500 left on the debt and 3 000 of
  /// the due paid ask for 1 500, as an unpaid due of 8 000 would.
  @Test func theRestIsNeverMoreThanTheBalance() {
    var fx = book()
    fx.debtEntries.append(
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-09-07"), amountE4: Fx.money("-75500"),
        kind: .adjustment))
    #expect(fx.snapshot().overdue.map(\.amount) == [Fx.money("1500")])
  }

  @Test func theCardOfTheComingWeekShowsTheRest() {
    let upcoming = book().snapshot().upcoming.filter { $0.kind == .debt }
    #expect(upcoming.map(\.amount) == [Fx.money("5000")])
    #expect(upcoming.map(\.isOverdue) == [true])
  }

  @Test func thePlannedMonthTakesTheRestAsDueByToday() {
    let fx = book()
    let planned = PlannedMonth.build(
      ledger: fx.ledger, book: fx.book, today: Fx.today, until: Fx.day("2026-10-31"))
    #expect(planned.debtsDueByToday == Fx.money("5000"))
    #expect(planned.items.filter { $0.kind == .debt }.map(\.amount) == [Fx.money("8000")])
  }
}
