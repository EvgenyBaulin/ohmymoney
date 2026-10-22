import CoreKit
import Foundation

/// What «Резервные копии», «Проверка базы» and «Курсы ЦБ» say. The app reads the facts — the
/// newest copy, the record of the last check, the newest rate it holds — and this classifies
/// them, so the words of a tile and its «Почему так» come from one rule.
public struct OverviewSystemStatus: Hashable, Sendable {
  /// How a thing that should be renewed regularly stands.
  public enum Freshness: String, Hashable, Sendable {
    /// Nothing was ever made or read.
    case none
    case fresh
    case stale
  }

  /// A copy older than this many days is stale.
  public static let backupStaleDays = 7
  /// A check older than this many days is stale: the schedule is weekly, so two weeks is a miss.
  public static let integrityStaleDays = 14
  /// A rate older than this many days is stale: the bank does not publish on weekends and
  /// holidays, so a few days of age is normal.
  public static let ratesStaleDays = 4

  public var now: Date
  public var today: DateOnly
  public var backupAt: Date?
  public var backupCount: Int
  public var checkedAt: Date?
  /// How many rows the last check found wrong.
  public var problems: Int
  /// The day of the newest rate held.
  public var ratesDay: DateOnly?

  public init(
    now: Date, today: DateOnly, backupAt: Date? = nil, backupCount: Int = 0,
    checkedAt: Date? = nil, problems: Int = 0, ratesDay: DateOnly? = nil
  ) {
    self.now = now
    self.today = today
    self.backupAt = backupAt
    self.backupCount = backupCount
    self.checkedAt = checkedAt
    self.problems = problems
    self.ratesDay = ratesDay
  }

  /// Whole days between `moment` and now, never below zero.
  static func days(from moment: Date, to now: Date) -> Int {
    max(0, Int(now.timeIntervalSince(moment) / 86_400))
  }

  public var backupAgeDays: Int? { backupAt.map { Self.days(from: $0, to: now) } }

  public var backup: Freshness {
    guard let age = backupAgeDays else { return .none }
    return age > Self.backupStaleDays ? .stale : .fresh
  }

  public var checkAgeDays: Int? { checkedAt.map { Self.days(from: $0, to: now) } }

  /// A check that found wrong rows is `stale` however recent: it asks for a look.
  public var integrity: Freshness {
    guard let age = checkAgeDays else { return .none }
    if problems > 0 { return .stale }
    return age > Self.integrityStaleDays ? .stale : .fresh
  }

  public var ratesAgeDays: Int? { ratesDay.map { max(0, $0.days(to: today)) } }

  public var rates: Freshness {
    guard let age = ratesAgeDays else { return .none }
    return age > Self.ratesStaleDays ? .stale : .fresh
  }
}
