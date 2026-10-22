import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

/// «Подписки» tile: its breakdown lists what the running subscriptions cost a month and the
/// total is the figure the screen shows. Synthetic subscriptions only.
@Suite("Subscriptions tile breakdown")
struct SubscriptionsTileTests {
  let today = DateOnly(year: 2026, month: 10, day: 14)

  func subscription(
    _ name: String, _ amount: Int64, freq: Frequency = .monthly, currency: CurrencyCode = .rub
  ) -> ScheduledPayment {
    ScheduledPayment(
      name: name, kind: .subscription, amountE4: AmountE4(whole: amount), currency: currency,
      freq: freq, day: 20, month: freq == .yearly ? 12 : nil,
      nextDate: DateOnly(year: 2026, month: freq == .yearly ? 12 : 10, day: 20))
  }

  @Test func theRowsAddUpToTheTotalOfTheScreen() {
    let payments = [
      subscription("Music", 300), subscription("Cloud", 2_400, freq: .yearly),
      subscription("Service", 10, currency: .usd),
    ]
    let explanation = TileExplanations.subscriptions(
      book: PlanningBook(scheduled: payments), subscriptions: .empty, today: today,
      rubPerUnit: [.usd: 100])
    #expect(explanation.tile == .subscriptions)
    let section = explanation.sections.first
    #expect(section?.rows.count == 3)
    let lines = SubscriptionCosts.lines(
      book: PlanningBook(scheduled: payments), subscriptions: .empty, today: today,
      rubPerUnit: [.usd: 100])
    let total = SubscriptionCosts.totals(of: lines).monthlyRub
    #expect(total == AmountE4(whole: 1_500))
    #expect(section?.total?.value == TileExplanations.money(total))
    // The priciest first.
    #expect(
      section?.rows.first?.label.arguments == [.text("Service")])
  }

  @Test func aCurrencyWithoutARateIsNamedNotGuessed() {
    let explanation = TileExplanations.subscriptions(
      book: PlanningBook(scheduled: [subscription("Service", 10, currency: .usd)]),
      subscriptions: .empty, today: today, rubPerUnit: [:])
    #expect(explanation.sections.first?.rows.isEmpty == true)
    #expect(explanation.notes.count == 1)
  }

  @Test func noSubscriptionsIsAnEmptyStateWithWords() {
    let explanation = TileExplanations.subscriptions(
      book: PlanningBook(), subscriptions: .empty, today: today, rubPerUnit: [:])
    guard case .empty(let phrase) = explanation.state else {
      Issue.record("expected an empty state")
      return
    }
    #expect(phrase.key == "why.subs.none")
    #expect(phrase.table == "Subscriptions")
  }
}
