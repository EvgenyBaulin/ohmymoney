import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One charge of a subscription on a day of the calendar: paid already, or still to come.
public struct SubscriptionCalendarItem: Hashable, Sendable, Identifiable {
  public var paymentId: UUID
  public var name: String
  public var day: DateOnly
  /// In the payment's currency for a coming charge; in rubles for a paid one — what the
  /// operation took.
  public var amount: AmountE4
  public var currency: CurrencyCode
  public var paid: Bool
  public var id: String { "\(paymentId.uuidString.lowercased()):\(day.iso):\(paid)" }
}

/// The «только подписки» filter of the spending calendar: the days of a month on which
/// subscriptions are charged. The calendar of 1.5 is the screen; this is its filter.
public enum SubscriptionCalendar {

  /// Charges of the running subscriptions in `month`: paid ones (operations «Отметить
  /// оплаченным» wrote, before today) and coming ones (`CalendarPlans`, today on). Sorted by
  /// day, then name.
  public static func items(
    in month: MonthKey, ledger: Ledger, book: PlanningBook, today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal] = [:], matches: ScheduledMatches = .empty
  ) -> [SubscriptionCalendarItem] {
    let subscriptions = Dictionary(
      book.scheduled.filter { $0.kind == .subscription && !$0.isOneOff }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    var items: [SubscriptionCalendarItem] = []

    let first = month.firstDay
    let last = month.lastDay
    if first < today {
      let range = DayRange(first, min(last, today.adding(days: -1)))
      var seen = Set<UUID>()
      for row in ledger.rows(in: range) where row.isFirstPart {
        guard case .scheduled(let id, _)? = row.link, let payment = subscriptions[id],
          seen.insert(row.transactionId).inserted,
          let entry = ledger.entry(row.transactionId)
        else { continue }
        items.append(
          SubscriptionCalendarItem(
            paymentId: id, name: payment.name, day: row.day,
            amount: entry.transaction.amountE4, currency: entry.transaction.currency, paid: true))
      }
    }
    if last >= today {
      let plans = CalendarPlans.collect(
        ledger: ledger, book: book, today: today, through: last, rubPerUnit: rubPerUnit,
        matches: matches)
      for plan in plans where plan.kind == .payment && plan.day >= first {
        guard let payment = subscriptions[plan.sourceId] else { continue }
        items.append(
          SubscriptionCalendarItem(
            paymentId: payment.id, name: payment.name, day: plan.day, amount: plan.amount,
            currency: plan.currency, paid: false))
      }
    }
    return items.sorted { ($0.day, $0.name, $0.id) < ($1.day, $1.name, $1.id) }
  }

  /// The charges of the month grouped by day.
  public static func byDay(
    _ items: [SubscriptionCalendarItem]
  ) -> [DateOnly: [SubscriptionCalendarItem]] {
    Dictionary(grouping: items, by: \.day)
  }
}

/// The «APPLE.COM/BILL» problem: one line of the statement stands for several subscriptions
/// bought through the App Store, which cannot be told apart. The app says so and leaves it to
/// the owner to lay them out by hand.
public enum AppStoreBilling {
  static let markers = [
    "apple.com/bill", "itunes.com/bill", "apple com bill", "app store", "appstore",
  ]

  /// Whether a statement description is the Apple billing line.
  public static func isAppleBilling(_ text: String?) -> Bool {
    guard let text else { return false }
    let folded = text.lowercased()
    return markers.contains { folded.contains($0) }
  }

  /// Whether a candidate found by `SubscriptionCandidates` is such a line (its key is the
  /// normalized description, or `place:<id>`).
  public static func isAppleBilling(_ candidate: SubscriptionCandidate) -> Bool {
    isAppleBilling(candidate.key)
  }
}
