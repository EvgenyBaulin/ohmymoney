import CoreKit
import Foundation

/// Where the cashback of one month stands against the day its bank pays it.
public enum CashbackPayoutStatus: Hashable, Sendable {
  /// The account has not said when its bank pays: nothing is told.
  case unknown
  /// The bank pays with the purchase.
  case immediately
  /// The bank pays by this day, which has not passed (or the cashback of the month is nothing).
  case due(DateOnly)
  /// The day has passed and nothing came for the month: what was expected, in rubles.
  case late(since: DateOnly, expectedRub: AmountE4)
  /// The day has passed and the cashback came.
  case paid(DateOnly)
}

/// The payout day of an account's cashback set against what was expected and what came.
public enum CashbackSchedule {
  /// The status of the cashback for the purchases of `month` on a day `today`.
  ///
  /// Late means that nothing at all was received for the month once the day is over: the amount
  /// the bank pays is an estimate here, and a few rubles of difference is not a delay.
  public static func status(
    of month: MonthKey, payout: CashbackPayout?, today: DateOnly, expectedRub: AmountE4,
    receivedRub: AmountE4, calendar: CalendarContext
  ) -> CashbackPayoutStatus {
    guard let payout else { return .unknown }
    guard let due = payout.dueDate(forPurchasesOf: month, calendar: calendar) else {
      return .immediately
    }
    guard today > due else { return .due(due) }
    if receivedRub.isZero && expectedRub > .zero {
      return .late(since: due, expectedRub: expectedRub)
    }
    return receivedRub.isZero ? .due(due) : .paid(due)
  }
}
