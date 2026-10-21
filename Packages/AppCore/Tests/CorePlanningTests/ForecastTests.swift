import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The forecast counts a scheduled payment paid by an ordinary operation once")
struct ForecastTests {
  typealias Fx = CashFx

  /// Groceries every day for forty days, and the rent of 15 September typed as an ordinary
  /// expense on the 14th. The rent is a planned payment: in the daily average as well it would
  /// be counted twice. Left out by its match, the remainder is the one of the history without
  /// it.
  @Test func aMatchedOperationLeavesTheAverage() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-09-15")]
    var day = Fx.day("2026-08-10")
    while day < Fx.today {
      fx.add(.expense, "1000", at: CalendarContext.utc.startOfDay(day).addingTimeInterval(43_200))
      day = day.adding(days: 1)
    }
    let without = fx.ledger
    let rent = fx.add(.expense, "30000", at: Fx.at("2026-09-14", 10), category: Fx.rent)
    let ledger = fx.ledger
    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: Fx.today, now: Fx.now, rubPerUnit: fx.rubPerUnit)
    #expect(snapshot.matches.operationIds == [rent])

    let matched = MonthForecast.remainder(
      ledger: ledger, today: Fx.today, scheduledOperations: snapshot.matches.operationIds)
    let plain = MonthForecast.remainder(ledger: without, today: Fx.today)
    let twice = MonthForecast.remainder(ledger: ledger, today: Fx.today)
    #expect(matched == plain)
    #expect(twice.middle > plain.middle)
    // The planned payments of the month no longer hold the rent either.
    #expect(snapshot.planned.scheduled == .zero)
  }

  /// The rent typed by hand in July and August, then «Провести» in September: the payment's
  /// `next_date` is October now. The operations of the summer paid due dates before it; they
  /// are still planned payments, not daily spending, and stay out of the average — the
  /// remainder is the one of the history without them. They pay nothing any more.
  @Test func pastMatchesStayOutOfTheAverageAfterTheDueMovesOn() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-10-15")]
    var day = Fx.day("2026-06-01")
    while day < Fx.today {
      fx.add(.expense, "1000", at: CalendarContext.utc.startOfDay(day).addingTimeInterval(43_200))
      day = day.adding(days: 1)
    }
    let without = fx.ledger
    var summer: Set<UUID> = []
    for month in ["2026-07-15", "2026-08-15"] {
      summer.insert(fx.add(.expense, "30000", at: Fx.at(month, 10), category: Fx.rent))
    }
    fx.add(
      .expense, "30000", at: Fx.at("2026-09-15", 10), category: Fx.rent,
      link: .scheduled(paymentId: Fx.id(1), due: Fx.day("2026-09-15")))
    let ledger = fx.ledger
    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: Fx.today, now: Fx.now, rubPerUnit: fx.rubPerUnit)
    #expect(snapshot.matches.operationIds == summer)
    #expect(snapshot.matches.matchedDues(of: Fx.id(1)).isEmpty)
    #expect(!snapshot.matches.isPaid(Fx.id(1), Fx.day("2026-08-15")))

    let matched = MonthForecast.remainder(
      ledger: ledger, today: Fx.today, scheduledOperations: snapshot.matches.operationIds)
    let plain = MonthForecast.remainder(ledger: without, today: Fx.today)
    #expect(matched == plain)
  }
}
