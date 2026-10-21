import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A scheduled payment paid by an ordinary operation is the same money as one paid with
/// «Провести»: a limit must neither count it as still due nor spread it over the days as if it
/// were spent a little every day.
@Suite("Limits and scheduled payments paid by ordinary operations")
struct LimitPaceScheduledTests {
  typealias Fx = CashFx

  static let housingLimit = Budget(
    id: CashFx.id(701), scope: .category, categoryId: CashFx.housing,
    amountE4: CashFx.money("40000"))

  /// The rent of 30 000 on the 15th of June, July, August and September.
  static let rentDays = ["2026-06-15", "2026-07-15", "2026-08-15", "2026-09-15"]

  func snapshot(_ fx: CashFx, budgets: [Budget]) -> PlanningSnapshot {
    var book = fx.book
    book.budgets = budgets
    let base = fx.ledger.dataset
    let ledger = Ledger(
      dataset: Dataset(
        entries: base.entries, categories: base.categories, events: base.events,
        paymentMethods: base.paymentMethods, debts: base.debts, goals: base.goals,
        planning: book, transfers: base.transfers, accountGroups: base.accountGroups),
      calendar: .utc)
    return PlanningSnapshot.build(
      ledger: ledger, today: Fx.today, now: Fx.now, rubPerUnit: fx.rubPerUnit)
  }

  /// A limit of 40 000 on Housing and the rent of 30 000 paid on the 15th of every month. Paid
  /// with «Провести» (a `sched:` key), the rent is no daily spending: 30 000 spent, nothing
  /// more expected by the end of September, the limit is within. Typed in the entry line as
  /// ordinary operations that match the payment, it is the same money and the same limit:
  /// the rent must not come back as 1 000 a day over the 11 days left, which would push the
  /// forecast to 41 000 and the limit on the edge.
  @Test func aMatchedRentIsNoDailySpendingOfTheLimit() {
    var linked = Fx()
    linked.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-10-15")]
    for day in Self.rentDays {
      linked.add(
        .expense, "30000", at: Fx.at(day, 10), category: Fx.rent,
        link: .scheduled(paymentId: Fx.id(1), due: Fx.day(day)))
    }
    let byKey = snapshot(linked, budgets: [Self.housingLimit]).limits
    #expect(byKey.map(\.status) == [.ok])
    #expect(byKey.first?.forecast == Fx.money("30000"))

    var typed = Fx()
    typed.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-06-15")]
    for day in Self.rentDays {
      typed.add(.expense, "30000", at: Fx.at(day, 10), category: Fx.rent)
    }
    let planning = snapshot(typed, budgets: [Self.housingLimit])
    // The four operations are the rent: every due of it is paid by one of them.
    #expect(planning.matches.operationIds.count == 4)
    let byMatch = planning.limits
    #expect(byMatch.first?.spent == Fx.money("30000"))
    #expect(byMatch.first?.planned == .zero)
    #expect(byMatch.first?.forecast == Fx.money("30000"))
    #expect(byMatch.map(\.status) == [.ok])
  }

  /// The operations that matched due dates before `next_date` — the rent typed in July and
  /// August while «Провести» moved the payment on in September — are planned money too.
  @Test func earlierMatchedRentStaysOutOfTheLimitsPace() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-10-15")]
    for day in Self.rentDays.dropLast() {
      fx.add(.expense, "30000", at: Fx.at(day, 10), category: Fx.rent)
    }
    fx.add(
      .expense, "30000", at: Fx.at("2026-09-15", 10), category: Fx.rent,
      link: .scheduled(paymentId: Fx.id(1), due: Fx.day("2026-09-15")))
    let planning = snapshot(fx, budgets: [Self.housingLimit])
    #expect(planning.limits.first?.forecast == Fx.money("30000"))
    #expect(planning.limits.map(\.status) == [.ok])
  }

  /// Other housing spending under the same limit is daily spending all the same: only the rent
  /// leaves the rate. 9 000 of it over the 90 days of the window is 100 a day, 1 100 over the
  /// 11 days left.
  @Test func otherSpendingUnderTheLimitKeepsItsPace() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-06-15")]
    for day in Self.rentDays {
      fx.add(.expense, "30000", at: Fx.at(day, 10), category: Fx.rent)
    }
    for day in ["2026-06-25", "2026-07-25", "2026-08-25"] {
      fx.add(.expense, "3000", at: Fx.at(day, 10), category: Fx.housing)
    }
    let line = snapshot(fx, budgets: [Self.housingLimit]).limits.first
    #expect(line?.spent == Fx.money("30000"))
    #expect(line?.forecast == Fx.money("31100"))
  }
}
