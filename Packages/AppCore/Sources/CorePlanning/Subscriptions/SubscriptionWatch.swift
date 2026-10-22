import CoreAnalytics
import CoreKit
import Foundation

/// What a subscription watch tells: a line of «Стоит посмотреть» today, and from 2.13 a
/// notification on `notifyOn`.
public struct SubscriptionNotice: Identifiable, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    /// «Завтра Кинопоиск спишет 399 ₽ — пробный период кончается».
    case trialEnding
    /// «Через 14 дней — годовая оплата Яндекс 360».
    case yearlyCharge
    /// «Коммуналка 5 900 ₽ вместо обычных 3 800–4 400».
    case floatingOutside

    public var key: String { "subscriptions.notice." + rawValue }
  }

  public var id: String
  public var kind: Kind
  public var paymentId: UUID
  /// The day it is about: the end of the trial, the yearly charge, the day of the charge.
  public var day: DateOnly
  /// The amount of the charge in the payment's currency.
  public var amount: AmountE4
  public var currency: CurrencyCode
  /// The day a notification of 2.13 goes out.
  public var notifyOn: DateOnly
  /// For `floatingOutside`: the band the charge missed.
  public var band: FloatingBand?
}

public enum SubscriptionWatch {
  /// «За день»: a trial is announced from the day before its end.
  public static let trialDaysAhead = 1
  /// A yearly subscription is announced two weeks ahead.
  public static let yearlyDaysAhead = 14

  /// Trial endings and yearly charges to show on `today`, soonest first; ids are
  /// `subtrial:<payment>:<date>` and `subyear:<payment>:<due>` (lowercased UUIDs) so a put-off
  /// notice stays away until the occasion changes, like every reminder.
  ///
  /// * Trial: a running subscription whose `trialEnd` is today or tomorrow. The first charge is
  ///   then the next date — or the end of the trial when that is later.
  /// * Yearly: a running subscription paid every year (interval 1 or more), not switched off
  ///   in its terms, whose next unpaid due date is 0…14 days ahead. A trial in progress
  ///   announces itself instead.
  public static func notices(
    book: PlanningBook, subscriptions: SubscriptionBook, today: DateOnly,
    matches: ScheduledMatches = .empty
  ) -> [SubscriptionNotice] {
    var result: [SubscriptionNotice] = []
    for payment in book.scheduled where SubscriptionCosts.isRunning(payment, on: today) {
      let paymentId = payment.id.uuidString.lowercased()
      let price = SubscriptionMath.price(of: payment, on: today, prices: book.prices)

      if let end = payment.trialEnd, end >= today, end <= today.adding(days: trialDaysAhead) {
        result.append(
          SubscriptionNotice(
            id: "subtrial:\(paymentId):\(end.iso)", kind: .trialEnding, paymentId: payment.id,
            day: end, amount: price, currency: payment.currency,
            notifyOn: end.adding(days: -trialDaysAhead), band: nil))
        continue
      }

      guard payment.freq == .yearly, subscriptions.terms(of: payment.id)?.yearlyReminderOff != true,
        let next = payment.nextDate
      else { continue }
      let horizon = today.adding(days: yearlyDaysAhead)
      let due = Recurrence.occurrences(
        from: next, through: horizon, rule: RecurrenceRule(payment: payment),
        end: payment.endDate, limit: 8
      ).first { $0 >= today && !matches.isPaid(payment.id, $0) }
      guard let due else { continue }
      result.append(
        SubscriptionNotice(
          id: "subyear:\(paymentId):\(due.iso)", kind: .yearlyCharge, paymentId: payment.id,
          day: due, amount: SubscriptionMath.price(of: payment, on: due, prices: book.prices),
          currency: payment.currency, notifyOn: due.adding(days: -yearlyDaysAhead), band: nil))
    }
    return result.sorted { ($0.day, $0.id) < ($1.day, $1.id) }
  }
}
