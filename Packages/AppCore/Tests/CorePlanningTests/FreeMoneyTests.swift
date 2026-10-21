import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The free sum: the money now, the grey line and the daily guide")
struct FreeMoneyTests {
  typealias Fx = CashFx

  /// Right after a count the money now is the count at today's rates: 100 000 ₽ and 500 $ at
  /// 90 on the card. What moved after it moves the figure; what is out of the summary does not.
  @Test func rightAfterACountTheMoneyIsTheCount() {
    var fx = Fx()
    fx.count(
      [(Fx.main, .rub, "100000"), (Fx.card, .usd, "500"), (Fx.freedom, Fx.tenge, "1000000")],
      at: Fx.at("2026-09-19", 14))
    let counted = fx.snapshot().freeMoney
    #expect(counted.state == .ready)
    #expect(counted.main == Fx.money("145000"))
    // The card's rubles were never counted: listed, not guessed.
    #expect(counted.unanchored == [BalanceKey(accountId: Fx.card, currency: .rub)])
    // Kazakhstan is apart, with its own total.
    #expect(counted.excluded.map(\.group.id) == [Fx.kazakhstan])
    #expect(counted.excluded.first?.totalRub == Fx.money("200000"))

    fx.add(.expense, "2500", at: Fx.at("2026-09-19", 14, 30))
    fx.add(
      .expense, "50000", at: Fx.at("2026-09-19", 14, 40), currency: Fx.tenge, account: Fx.freedom)
    #expect(fx.snapshot().freeMoney.main == Fx.money("142500"))
  }

  /// Nothing counted: no figure at all, «сделайте первую сверку».
  @Test func withoutACountThereIsNoFreeSum() {
    var fx = Fx()
    fx.add(.income, "90000", at: Fx.at("2026-09-05", 12), category: Fx.salary)
    let free = fx.snapshot().freeMoney
    #expect(free.state == .noReconciliation)
    #expect(free.main == nil)
    #expect(free.grey == nil)
    #expect(free.dailyGuide == .zero)
  }

  /// grey = main − every line; the guide spreads it over the days of [today, D], today
  /// included — 12 days through 30 September. An overspent grey line guides nothing.
  @Test func theGreyLineAndTheDailyGuide() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "50000")], at: Fx.at("2026-09-18", 20))
    fx.scheduled = [Fx.payment(1, "Internet", "2000", day: 25, next: "2026-09-25")]
    let free = fx.snapshot().freeMoney
    #expect(
      free.lines.map(\.key) == [
        FreeMoney.Key.scheduled, FreeMoney.Key.debts, FreeMoney.Key.goalPlans,
        FreeMoney.Key.events,
      ])
    #expect(free.lines.allSatisfy { $0.sign == .minus })
    #expect(free.grey == Fx.money("48000"))
    #expect(free.main.map { $0 + AmountE4.sum(free.lines.map(\.signedAmount)) } == free.grey)
    #expect(free.days == 12)
    #expect(free.until == Fx.day("2026-09-30"))
    #expect(free.dailyGuide == Fx.money("4000"))

    fx.scheduled[0].amountE4 = Fx.money("60000")
    let over = fx.snapshot().freeMoney
    #expect(over.grey == Fx.money("-10000"))
    #expect(over.dailyGuide == .zero)
  }

  /// D is never before today and never more than twelve months ahead; without one it is the
  /// end of this month.
  @Test func theWindowReachesAYearAhead() {
    let today = Fx.today
    #expect(FreeMoney.window(today: today, until: nil).end == Fx.day("2026-09-30"))
    #expect(FreeMoney.window(today: today, until: Fx.day("2026-09-01")).end == today)
    #expect(FreeMoney.window(today: today, until: Fx.day("2027-03-01")).end == Fx.day("2027-03-01"))
    #expect(FreeMoney.window(today: today, until: Fx.day("2028-01-01")).end == Fx.day("2027-09-19"))
  }

  /// Income still expected is a line of its own, never added: the salary of 5 September is
  /// late and still waited for, and through November so are October's and November's.
  @Test func incomeStillExpectedIsShownNotAdded() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "20000")], at: Fx.at("2026-09-18", 20))
    fx.expected = [
      ExpectedIncome(
        id: Fx.id(601), name: "Salary", categoryId: Fx.salary, kind: .recurring,
        totalE4: Fx.money("100000"), dueDate: Fx.day("2026-01-05"), freq: .monthly, day: 5)
    ]
    let snapshot = fx.snapshot()
    let month = snapshot.freeMoney
    #expect(
      month.info == [
        FreeToSpendLine(key: FreeMoney.Key.stillExpected, sign: .plus, amount: Fx.money("100000"))
      ])
    #expect(month.grey == Fx.money("20000"))
    let later = snapshot.freeMoney(until: Fx.day("2026-11-30"), ledger: fx.ledger)
    #expect(later.info.first?.amount == Fx.money("300000"))
    #expect(later.grey == Fx.money("20000"))
  }

  /// A day before the end of the month does not take again the rent an ordinary operation
  /// paid either.
  @Test func aMatchedPaymentIsTakenOnceForAnyDay() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-09-15")]
    fx.settings.reserveGoalPlan = false
    fx.add(.expense, "30000", at: Fx.at("2026-09-14", 10), category: Fx.rent)
    let ledger = fx.ledger
    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: Fx.day("2026-09-16"), now: Fx.at("2026-09-16", 12),
      rubPerUnit: fx.rubPerUnit)
    for until in ["2026-09-20", "2026-09-30"] {
      let free = snapshot.freeMoney(until: Fx.day(until), ledger: ledger)
      #expect(
        free.lines.first { $0.key == FreeMoney.Key.scheduled }?.amount == .zero, "\(until)")
    }
  }
}
