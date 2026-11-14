import CoreAnalytics
import CoreKit
import Foundation

/// Where the «Разобрать» and «Загрузить» items of «Что сделать сейчас» come from. Both are
/// read off the operations already in the book; nothing is guessed.
public enum DoNowSources {
  /// An operation that is a week old or younger and has a part without a category is the recent
  /// «Разобрать» source.
  public static let reviewDays = 7
  /// A bank whose last loaded statement is this many days old or older asks for the next one.
  public static let statementDays = 14

  /// Ids of the two «Разобрать» sources. The older one sorts after the recent one, which is the
  /// order the list shows them in.
  public static let recentReviewId = "uncategorized"
  public static let olderReviewId = "uncategorized-older"

  /// «Разобрать»: operations with a part that has no category, deleted ones not counted. The
  /// last `reviewDays` days (today included) are one source; what is older does not vanish but
  /// is a second source below it.
  public static func reviews(
    entries: [TransactionEntry], today: DateOnly, calendar: CalendarContext
  ) -> [DoNowSource] {
    let from = today.adding(days: -(reviewDays - 1))
    var recent = 0
    var older = 0
    for entry in entries where entry.transaction.deletedAt == nil {
      guard entry.parts.contains(where: { $0.categoryId == nil }) else { continue }
      let day = calendar.day(of: entry.transaction.occurredAt)
      if day > today { continue }
      if day >= from { recent += 1 } else { older += 1 }
    }
    var sources: [DoNowSource] = []
    if recent > 0 { sources.append(DoNowSource(id: recentReviewId, count: recent)) }
    if older > 0 { sources.append(DoNowSource(id: olderReviewId, count: older)) }
    return sources
  }

  /// «Загрузить»: for each open account that has had statements loaded, one source when the
  /// newest statement was loaded `statementDays` ago or earlier. The day of loading is when the
  /// operations were created, not the day of the newest operation in the file: a quiet card
  /// whose last operation is old is not asked. An account with no statement operation at all
  /// never asks (the owner may not use statements for it), nor does an archived one.
  public static func statements(
    entries: [TransactionEntry], today: DateOnly, calendar: CalendarContext,
    archivedAccounts: Set<UUID> = []
  ) -> [DoNowSource] {
    var latest: [UUID: DateOnly] = [:]
    for entry in entries where entry.transaction.deletedAt == nil {
      guard entry.transaction.source == "statement", let account = entry.transaction.paymentMethodId,
        !archivedAccounts.contains(account)
      else { continue }
      let day = calendar.day(of: entry.transaction.createdAt)
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
