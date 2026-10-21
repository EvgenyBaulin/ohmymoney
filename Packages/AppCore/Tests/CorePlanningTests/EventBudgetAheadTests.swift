import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The free sum is the money on the accounts now, less what has to leave them by D. An
/// operation written for a later day has not left yet: the money now still holds it, and it
/// pays no due of a payment or a debt before its day. So it does not eat into the budget of its
/// event either — otherwise its money would be neither taken off the money now nor held back,
/// and the free sum would hand it out once more.
@Suite("An event purchase written ahead is still to be paid")
struct EventBudgetAheadTests {
  typealias Fx = CashFx

  /// The trip of 25–30 September has a budget of 30 000. On the 19th the hotel of the 26th is
  /// written ahead, 20 000: the account still holds 100 000 now, and by the end of the trip
  /// 30 000 leave it — the hotel and 10 000 more. The plan holds back 30 000, not 10 000.
  @Test func aPurchaseWrittenAheadDoesNotShrinkTheBudgetHeldBack() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-25"),
        endDate: Fx.day("2026-09-30"), budgetE4: Fx.money("30000"))
    ]
    fx.add(.expense, "20000", at: Fx.at("2026-09-26", 12), category: Fx.fun)
    fx.entries[fx.entries.count - 1].parts[0].eventId = Fx.id(501)

    let plan = fx.plan(until: "2026-09-30")
    #expect(plan.events == Fx.money("30000"))
    let free = try #require(
      fx.snapshot().freeMoney(until: Fx.day("2026-09-30"), ledger: fx.ledger).grey)
    #expect(free == Fx.money("70000"), "100 000 now, the hotel and 10 000 more to come")

    // On its day the hotel is paid: the money now is 80 000, and 10 000 are held back.
    let onTheDay = fx.plan(until: "2026-09-30", today: Fx.day("2026-09-26"))
    #expect(onTheDay.events == Fx.money("10000"))
  }
}
