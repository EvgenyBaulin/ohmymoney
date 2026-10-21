import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("What the scheduled payments of a kind still ask this month")
struct ScheduledStillDueTests {
  typealias Fx = CashFx

  private func stillDue(_ fx: CashFx, kind: ScheduledKind) -> AmountE4 {
    let ledger = fx.ledger
    let planning = fx.snapshot()
    return CashPlan.scheduledStillDueThisMonth(
      of: kind, ledger: ledger, book: ledger.dataset.planning, accounts: planning.accounts,
      today: Fx.today, rubPerUnit: fx.rubPerUnit, matches: planning.matches)
  }

  /// A weekly bill of 1,000 ₽ unpaid since 14 September asks for the 14th, the 21st and the
  /// 28th — 3,000 ₽, not one week's price; a price raised from the 25th prices the 28th by it.
  @Test func everyUnpaidOccurrenceOfTheMonthCountsAtItsOwnPrice() {
    var fx = Fx()
    fx.scheduled = [
      ScheduledPayment(
        id: Fx.id(1), name: "Cleaning", amountE4: Fx.money("1000"), freq: .weekly,
        nextDate: Fx.day("2026-09-14"))
    ]
    #expect(stillDue(fx, kind: .bill) == Fx.money("3000"))

    fx.prices = [
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-09-25"), amountE4: Fx.money("1500"))
    ]
    #expect(stillDue(fx, kind: .bill) == Fx.money("3500"))
  }

  /// Only the payments of the kind; a payment in dollars at today's rate; overdue dues of an
  /// earlier month still ask; dues of the next month do not; a currency without a rate adds
  /// nothing rather than a guess.
  @Test func theKindTheRatesAndTheMonth() {
    var fx = Fx()
    fx.scheduled = [
      Fx.payment(1, "Rent", "30000", day: 5, next: "2026-08-05"),
      Fx.payment(2, "Hosting", "10", day: 22, next: "2026-09-22", currency: .usd),
      Fx.payment(3, "Gym", "50", day: 25, next: "2026-09-25", currency: .eur),
      ScheduledPayment(
        id: Fx.id(4), name: "Music", kind: .subscription, amountE4: Fx.money("300"), day: 25,
        nextDate: Fx.day("2026-09-25")),
    ]
    // Rent of 5 August and of 5 September, hosting 10 $ at 90 ₽.
    #expect(stillDue(fx, kind: .bill) == Fx.money("60900"))
    #expect(stillDue(fx, kind: .subscription) == Fx.money("300"))
  }

  /// The sum is the one of the free sum's dues through the end of the month, converted.
  @Test func theSumIsTheFreeSumsDues() {
    var fx = Fx()
    fx.scheduled = [
      ScheduledPayment(
        id: Fx.id(1), name: "Cleaning", amountE4: Fx.money("1000"), freq: .weekly,
        nextDate: Fx.day("2026-09-14")),
      Fx.payment(2, "Internet", "1000", day: 25, next: "2026-09-25"),
    ]
    let ledger = fx.ledger
    let planning = fx.snapshot()
    let dues = CashPlan.scheduledDues(
      ledger: ledger, book: ledger.dataset.planning, accounts: planning.accounts,
      today: Fx.today, until: Fx.today.monthKey.lastDay, matches: planning.matches)
    #expect(stillDue(fx, kind: .bill) == AmountE4.sum(dues.map(\.amount)))
  }
}
