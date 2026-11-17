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
      let day = calendar.day(of: entry.transaction)
      if day > today { continue }
      if day >= from { recent += 1 } else { older += 1 }
    }
    var sources: [DoNowSource] = []
    if recent > 0 { sources.append(DoNowSource(id: recentReviewId, count: recent)) }
    if older > 0 { sources.append(DoNowSource(id: olderReviewId, count: older)) }
    return sources
  }

  /// «Загрузить»: ask for each open account whose latest statement import was
  /// `statementDays` ago or earlier. Import dates include batches that added no operations;
  /// accounts without an import record fall back to their statement operations. Archived
  /// accounts and accounts skipped fewer than `statementDays` days ago are left out.
  public static func statements(
    entries: [TransactionEntry], today: DateOnly, calendar: CalendarContext,
    statementImportMoments: [UUID: Date] = [:],
    archivedAccounts: Set<UUID> = [], skips: StatementSkips = StatementSkips()
  ) -> [DoNowSource] {
    var latest: [UUID: DateOnly] = [:]
    for (account, moment) in statementImportMoments
    where !archivedAccounts.contains(account) {
      latest[account] = calendar.day(of: moment)
    }
    for entry in entries where entry.transaction.deletedAt == nil {
      guard entry.transaction.source == "statement",
        let account = entry.transaction.paymentMethodId,
        !archivedAccounts.contains(account),
        statementImportMoments[account] == nil
      else { continue }
      let day = calendar.day(of: entry.transaction.createdAt)
      if latest[account].map({ day > $0 }) ?? true { latest[account] = day }
    }
    let limit = today.adding(days: -statementDays)
    return latest.compactMap { account, day in
      guard day <= limit, !skips.isQuiet(account, today: today) else { return nil }
      let ago = day.days(to: today)
      return DoNowSource(id: account.uuidString, count: 1, accountId: account, daysAgo: ago)
    }
  }
}

/// The free sum is tight when its daily guide is below half the usual daily spending.
/// Without a month of history only an actual shortage changes the verdict.
public enum FreeVerdict: String, Hashable, Sendable {
  case enough
  case tight
  case short

  public init(free main: AmountE4, days: Int = 1, usualDaily: AmountE4? = nil) {
    if main.isNegative {
      self = .short
    } else if let usualDaily, usualDaily.raw > 0,
      main.decimal * 2 < usualDaily.decimal * Decimal(max(1, days))
    {
      self = .tight
    } else {
      self = .enough
    }
  }
}
