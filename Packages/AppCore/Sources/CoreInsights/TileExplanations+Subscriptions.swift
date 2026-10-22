import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

extension TileExplanations {
  /// The table of the phrases of the subscriptions (their own String Catalog).
  static let subscriptionsTable = "Subscriptions"

  /// «Подписки»: what the running subscriptions cost a month, each at the rate of the day, the
  /// priciest first, and the ones left out for want of a rate. The total is the figure of the
  /// tile (`SubscriptionCosts.totals`).
  public static func subscriptions(
    book: PlanningBook, subscriptions: SubscriptionBook, today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> TileExplanation {
    let lines = SubscriptionCosts.lines(
      book: book, subscriptions: subscriptions, today: today, rubPerUnit: rubPerUnit)
    guard !lines.isEmpty else {
      return TileExplanation(
        tile: .subscriptions,
        state: .empty(TilePhrase("why.subs.none", table: subscriptionsTable)))
    }
    let totals = SubscriptionCosts.totals(of: lines)
    let rows = lines.compactMap { line -> TileRow? in
      guard let monthly = line.monthlyRub else { return nil }
      return TileRow(
        TilePhrase("why.name", .text(line.payment.name)), money(monthly), role: .plus,
        share: Shares.ratio(monthly, of: totals.monthlyRub))
    }
    let missing = lines.filter { $0.monthlyRub == nil }.map(\.payment.currency.code)
    return TileExplanation(
      tile: .subscriptions,
      sections: [
        TileSection(
          rows: rows,
          total: TileRow(
            TilePhrase("why.subs.total", table: subscriptionsTable), money(totals.monthlyRub)))
      ],
      notes: missing.isEmpty
        ? []
        : [
          TilePhrase(
            "why.subs.withoutRate", table: subscriptionsTable,
            .text(Array(Set(missing)).sorted().joined(separator: ", ")))
        ])
  }
}
