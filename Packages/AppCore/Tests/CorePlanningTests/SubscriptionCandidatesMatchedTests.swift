import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Похоже на подписку» never offers what already is a payment: operations that pay a
/// scheduled payment by matching it are its charges — as those «Провести» wrote are — even when
/// the payment is in dollars and they were typed in rubles, so neither category nor currency
/// nor name gives them away.
@Suite("Subscription candidates leave out the charges of existing payments")
struct SubscriptionCandidatesMatchedTests {
  typealias Fx = CashFx

  /// A cloud of 5 $ a month on the 10th, typed every month as «облако 450» in rubles — 5 $ at
  /// 90. The four operations pay its due dates; nothing is offered as a new subscription.
  @Test func aDollarPaymentTypedInRublesIsNoCandidate() {
    var fx = Fx()
    var cloud = Fx.payment(
      1, "Cloud", "5", day: 10, next: "2026-06-10", currency: .usd, category: Fx.fun)
    cloud.kind = .subscription
    fx.scheduled = [cloud]
    for day in ["2026-06-10", "2026-07-10", "2026-08-10", "2026-09-10"] {
      fx.add(.expense, "450", at: Fx.at(day, 9), category: Fx.fun, note: "облако")
    }
    let snapshot = fx.snapshot()
    #expect(snapshot.matches.operationIds.count == 4)
    #expect(snapshot.candidates.isEmpty)
  }

  /// Without the payment the same operations are a subscription to offer: monthly, 450 ₽.
  @Test func theSameOperationsWithoutAPaymentAreACandidate() {
    var fx = Fx()
    for day in ["2026-06-10", "2026-07-10", "2026-08-10", "2026-09-10"] {
      fx.add(.expense, "450", at: Fx.at(day, 9), category: Fx.fun, note: "облако")
    }
    let candidates = fx.snapshot().candidates
    #expect(candidates.map(\.key) == ["облако"])
    #expect(candidates.first?.freq == .monthly)
    #expect(candidates.first?.typicalAmount == Fx.money("450"))
    #expect(candidates.first?.occurrences == 4)
  }
}
