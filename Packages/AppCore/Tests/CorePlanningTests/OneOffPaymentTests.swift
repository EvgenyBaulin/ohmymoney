import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A planned expense of one date — «Разово», saved as every month ending on its own next date —
/// is one charge, not a rhythm: it has no figure per month or per year, and it adds nothing to
/// what the subscriptions cost a month or a year.
@Suite("A one-off payment is one charge")
struct OneOffPaymentTests {
  typealias Fx = CashFx

  static func sofa(kind: ScheduledKind = .bill) -> ScheduledPayment {
    var sofa = Fx.payment(1, "Sofa", "25000", day: 25, next: "2026-09-25", end: "2026-09-25")
    sofa.kind = kind
    return sofa
  }

  /// A sofa of 25 000 planned for the 25th: its line says nothing per month or per year — not
  /// «25 000 a month, 300 000 a year».
  @Test func aOneOffBillHasNoFigurePerMonthOrYear() {
    var fx = Fx()
    fx.scheduled = [Self.sofa()]
    let status = fx.snapshot().scheduled.first
    #expect(status?.amountNext == Fx.money("25000"))
    #expect(status?.monthly == .zero)
    #expect(status?.yearly == .zero)
  }

  /// A licence of 12 000 bought once, filed as a subscription, next to a music subscription
  /// of 300 a month: the subscriptions cost 300 a month and 3 600 a year.
  @Test func aOneOffSubscriptionAddsNothingToTheTotals() {
    var fx = Fx()
    var music = Fx.payment(2, "Music", "300", day: 10, next: "2026-10-10")
    music.kind = .subscription
    fx.scheduled = [Self.sofa(kind: .subscription), music]
    let snapshot = fx.snapshot()
    #expect(snapshot.subscriptionsMonthly == Fx.money("300"))
    #expect(snapshot.subscriptionsYearly == Fx.money("3600"))
  }

  /// The one-off stays a payment in every other way: it is listed, reminded (a week ahead,
  /// its own lead), on the 7-day card and held back by the free sum, in full, once.
  @Test func aOneOffIsStillPlannedOnce() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    var sofa = Self.sofa()
    sofa.remindDaysBefore = 7
    fx.scheduled = [sofa]
    let snapshot = fx.snapshot()
    #expect(snapshot.scheduled.map(\.nextUnpaid) == [Fx.day("2026-09-25")])
    #expect(snapshot.upcoming.map(\.due) == [Fx.day("2026-09-25")])
    #expect(snapshot.reminders.filter { $0.kind == .payment }.map(\.due) == [Fx.day("2026-09-25")])
    let year = snapshot.freeMoney(until: Fx.day("2027-09-19"), ledger: fx.ledger)
    #expect(year.plan.scheduled == Fx.money("25000"))
  }

  /// A monthly subscription and a yearly one keep their figures: 500 a month is 6 000 a year,
  /// 12 000 a year is 1 000 a month.
  @Test func aRhythmKeepsItsFigures() {
    var fx = Fx()
    var music = Fx.payment(2, "Music", "500", day: 10, next: "2026-10-10")
    music.kind = .subscription
    var domain = Fx.payment(3, "Domain", "12000", day: 1, next: "2027-03-01")
    domain.kind = .subscription
    domain.freq = .yearly
    domain.month = 3
    fx.scheduled = [music, domain]
    let snapshot = fx.snapshot()
    let figures = Dictionary(
      uniqueKeysWithValues: snapshot.scheduled.map { ($0.payment.name, [$0.monthly, $0.yearly]) })
    #expect(figures["Music"] == [Fx.money("500"), Fx.money("6000")])
    #expect(figures["Domain"] == [Fx.money("1000"), Fx.money("12000")])
    #expect(snapshot.subscriptionsMonthly == Fx.money("1500"))
    #expect(snapshot.subscriptionsYearly == Fx.money("18000"))
  }

  /// The advice about subscriptions counts the running ones: a one-off licence is not one of
  /// them, and alone it gives no advice at all.
  @Test func theAdviceCountsNoOneOff() {
    var fx = Fx()
    fx.scheduled = [Self.sofa(kind: .subscription)]
    let alone = fx.snapshot()
    #expect(
      AdviceRules.subscriptions(
        scheduled: alone.scheduled, monthly: alone.subscriptionsMonthly,
        yearly: alone.subscriptionsYearly
      ).isEmpty)

    var music = Fx.payment(2, "Music", "300", day: 10, next: "2026-10-10")
    music.kind = .subscription
    fx.scheduled.append(music)
    let both = fx.snapshot()
    let advice = AdviceRules.subscriptions(
      scheduled: both.scheduled, monthly: both.subscriptionsMonthly,
      yearly: both.subscriptionsYearly)
    #expect(advice.first?.terms.first?.value == .count(1))
    #expect(advice.first?.result?.value == .money(Fx.money("300")))
  }
}
