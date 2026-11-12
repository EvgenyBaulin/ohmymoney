import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// A rate the bank has announced for a savings account or a deposit: from which day, and from
/// what to what.
public struct RateChangeNotice: Hashable, Sendable {
  public enum Direction: Hashable, Sendable {
    case up
    case down
    case same
  }

  public var accountId: UUID
  public var currentRate: Decimal
  public var nextRate: Decimal
  public var on: DateOnly
  public var daysLeft: Int
  public var direction: Direction
}

/// The announced rates of savings accounts, and the reminder to look at the account before the
/// new rate starts.
public enum RateChanges {
  /// Days ahead a change is reminded of.
  public static let leadDays = 7

  /// Every announced change not yet in force, the nearest first: live accounts with interest and
  /// an announced rate from `today` on. A change that already started is the rate itself, and an
  /// announcement without a day or a rate above zero is none (`DepositTerms.nextRate`).
  public static func announced(accounts: [PaymentMethod], today: DateOnly) -> [RateChangeNotice] {
    var notices: [RateChangeNotice] = []
    for account in accounts where !account.archived {
      guard let terms = account.interest, let next = terms.nextRate, next > 0,
        let on = terms.nextRateOn, on >= today
      else { continue }
      notices.append(
        RateChangeNotice(
          accountId: account.id, currentRate: terms.rate, nextRate: next, on: on,
          daysLeft: today.days(to: on),
          direction: next > terms.rate ? .up : (next < terms.rate ? .down : .same)))
    }
    return notices.sorted { ($0.on, $0.accountId.uuidString) < ($1.on, $1.accountId.uuidString) }
  }

  /// The ones to remind of today: starting within `leadDays`, the day itself included.
  public static func reminding(accounts: [PaymentMethod], today: DateOnly) -> [RateChangeNotice] {
    announced(accounts: accounts, today: today).filter { $0.daysLeft <= leadDays }
  }

  /// The reminders of the announced rates, one per account and day (`rate:<account>:<day>`).
  static func reminders(accounts: [PaymentMethod], today: DateOnly) -> [Reminder] {
    reminding(accounts: accounts, today: today).map { notice in
      Reminder(
        id: "rate:\(notice.accountId.uuidString.lowercased()):\(notice.on.iso)",
        kind: .rateChange, due: notice.on, subjectId: notice.accountId,
        urgency: ReminderUrgency(due: notice.on, today: today))
    }
  }
}
