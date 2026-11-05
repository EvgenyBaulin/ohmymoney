import CoreAnalytics
import CoreKit
import Foundation

/// Where the «Разобрать» and «Загрузить» items of «Что сделать сейчас» come from. Both are
/// read off the operations already in the book; nothing is guessed.
public enum DoNowSources {
  /// An operation that is a week old or younger and has a part without a category waits for a
  /// decision.
  public static let reviewDays = 7
  /// A bank whose last loaded statement is this many days old or older asks for the next one.
  public static let statementDays = 14

  /// «Разобрать»: one source counting the operations of the last `reviewDays` days (today
  /// included) with a part that has no category. Deleted operations do not count.
  public static func reviews(
    entries: [TransactionEntry], today: DateOnly, calendar: CalendarContext
  ) -> [DoNowSource] {
    let from = today.adding(days: -(reviewDays - 1))
    let waiting = entries.filter { entry in
      guard entry.transaction.deletedAt == nil else { return false }
      let day = calendar.day(of: entry.transaction.occurredAt)
      return day >= from && day <= today && entry.parts.contains { $0.categoryId == nil }
    }
    return waiting.isEmpty ? [] : [DoNowSource(id: "uncategorized", count: waiting.count)]
  }

  /// «Загрузить»: for each account that has had statements loaded, one source when the newest
  /// statement operation is `statementDays` old or older. An account with no statement
  /// operation at all never asks: the owner may not use statements for it.
  public static func statements(
    entries: [TransactionEntry], today: DateOnly, calendar: CalendarContext
  ) -> [DoNowSource] {
    var latest: [UUID: DateOnly] = [:]
    for entry in entries where entry.transaction.deletedAt == nil {
      guard entry.transaction.source == "statement", let account = entry.transaction.paymentMethodId
      else { continue }
      let day = calendar.day(of: entry.transaction.occurredAt)
      if latest[account].map({ day > $0 }) ?? true { latest[account] = day }
    }
    let limit = today.adding(days: -statementDays)
    return latest.compactMap { account, day in
      guard day <= limit else { return nil }
      let ago = day.days(to: today)
      return DoNowSource(id: account.uuidString, count: 1, accountId: account, daysAgo: ago)
    }
  }
}

/// The verdict of the headline of Overview about the free sum. One threshold only: the sum is
/// enough while it is not below zero; a «tight» band is not in the owner's decisions, so none is
/// invented here.
public enum FreeVerdict: String, Hashable, Sendable {
  case enough
  case short

  public init(free main: AmountE4) {
    self = main.isNegative ? .short : .enough
  }
}
