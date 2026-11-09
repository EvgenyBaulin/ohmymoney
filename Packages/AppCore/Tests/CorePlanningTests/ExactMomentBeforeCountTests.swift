import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A time the owner typed is kept as it is: an income at 02:51 on a day counted at 04:04 stays
/// at 02:51, before the count, and nothing is asked — the time says it already.
@Suite("Before the count: a typed time is kept")
struct ExactMomentBeforeCountTests {
  typealias Fx = CashFx
  static let mainRub = BalanceKey(accountId: CashFx.main, currency: .rub)

  func balances(counting at: Date, savedAt: Date) -> AccountBalances {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "10000")], at: at)
    return ReconciliationPropertyTests.Scenario.balances(fx, now: savedAt)
  }

  @Test func aTimeBeforeTheCountIsKeptWithoutAQuestion() {
    let count = Fx.at("2026-10-05", 4, 4)
    let typed = Fx.at("2026-10-05", 2, 51)
    let saved = Fx.at("2026-10-05", 9)
    let ask = AccountReconciliation.countToAsk(
      occurredAt: typed, savedAt: saved, keys: [Self.mainRub],
      balances: balances(counting: count, savedAt: saved), calendar: .utc, remembered: [:],
      momentIsExact: true)
    guard case .answered(let stamp) = ask else {
      Issue.record("a typed time needs no question")
      return
    }
    #expect(stamp == typed)
  }

  @Test func aTimeAfterTheCountIsKeptToo() {
    let count = Fx.at("2026-10-05", 4, 4)
    let typed = Fx.at("2026-10-05", 6, 30)
    let saved = Fx.at("2026-10-05", 9)
    let ask = AccountReconciliation.countToAsk(
      occurredAt: typed, savedAt: saved, keys: [Self.mainRub],
      balances: balances(counting: count, savedAt: saved), calendar: .utc, remembered: [:],
      momentIsExact: true)
    guard case .answered(let stamp) = ask else {
      Issue.record("a typed time needs no question")
      return
    }
    #expect(stamp == typed)
  }

  @Test func aMomentThatIsNotTypedStillAsks() {
    let count = Fx.at("2026-10-05", 4, 4)
    let saved = Fx.at("2026-10-05", 9)
    let ask = AccountReconciliation.countToAsk(
      occurredAt: Fx.at("2026-10-05", 2, 51), savedAt: saved, keys: [Self.mainRub],
      balances: balances(counting: count, savedAt: saved), calendar: .utc, remembered: [:])
    guard case .ask = ask else {
      Issue.record("a moment of the clock or of «вчера» is asked about")
      return
    }
  }

  @Test func noCountOnTheDayAsksNothing() {
    let saved = Fx.at("2026-10-05", 9)
    let ask = AccountReconciliation.countToAsk(
      occurredAt: Fx.at("2026-10-04", 2, 51), savedAt: saved, keys: [Self.mainRub],
      balances: balances(counting: Fx.at("2026-10-05", 4, 4), savedAt: saved), calendar: .utc,
      remembered: [:], momentIsExact: true)
    guard case .none = ask else {
      Issue.record("no count that day, no stamp")
      return
    }
  }
}
