import CoreKit
import Foundation

/// A part of the app the mode of a beginner quiets until it has something to say: it stays
/// visible and opens, only dimmed, with «Откроется, когда…» under its name.
public enum BeginnerSection: String, CaseIterable, Hashable, Sendable, Codable {
  /// The window «Аналитика»: its breakdowns say little before a couple of weeks of entries.
  case analytics
  /// The window «Отчёты»: tables of months want a month of entries.
  case reports
  /// «Капитал»: net worth wants counted balances.
  case capital
  /// «Долги»: quiet only for an owner the starter set said has no loans, until the first week of
  /// entries — a loan is never hidden from somebody who has one.
  case debts
}

/// What the mode of a beginner reads from the data: counts only.
public struct BeginnerFacts: Hashable, Sendable {
  /// Days with entry (`HabitEntryDays`).
  public var entryDays: Int
  /// The first day something was typed by hand; `nil` before.
  public var firstEntry: DateOnly?
  /// Counts of the accounts (the starting balances of the setup are not a count).
  public var counts: Int
  /// Debts written down, closed ones included.
  public var debts: Int
  /// The starter set said the owner has loans; `nil` when he chose no set.
  public var hasLoans: Bool?
  public var today: DateOnly

  public init(
    entryDays: Int = 0, firstEntry: DateOnly? = nil, counts: Int = 0, debts: Int = 0,
    hasLoans: Bool? = nil, today: DateOnly
  ) {
    self.entryDays = entryDays
    self.firstEntry = firstEntry
    self.counts = counts
    self.debts = debts
    self.hasLoans = hasLoans
    self.today = today
  }
}

/// When a quiet section opens: what «Откроется, когда…» says.
public enum BeginnerUnlock: Hashable, Sendable {
  /// «Откроется, когда наберётся N дней с записями (сейчас M)».
  case entryDays(needed: Int, have: Int)
  /// «Откроется через N дней — когда наберётся месяц записей».
  case monthOfEntries(daysLeft: Int)
  /// «Откроется после первой сверки».
  case firstCount
}

/// The mode of a beginner: which sections are quiet and until when. Off, nothing is quiet. The
/// switch itself is a habit of this Mac, never in the database or the archive.
public enum BeginnerMode {
  /// Days with entry «Аналитика» opens at.
  public static let analyticsEntryDays = 14
  /// Days since the first entry «Отчёты» opens at.
  public static let reportsDays = 30
  /// Days with entry «Долги» opens at for an owner without loans.
  public static let debtsEntryDays = 7

  /// What a section waits for; `nil` when it is open.
  public static func unlock(_ section: BeginnerSection, facts: BeginnerFacts) -> BeginnerUnlock? {
    switch section {
    case .analytics:
      return facts.entryDays >= analyticsEntryDays
        ? nil : .entryDays(needed: analyticsEntryDays, have: facts.entryDays)
    case .reports:
      guard let first = facts.firstEntry else { return .monthOfEntries(daysLeft: reportsDays) }
      let passed = FirstMonth.dayNumber(facts.today) - FirstMonth.dayNumber(first)
      return passed >= reportsDays ? nil : .monthOfEntries(daysLeft: reportsDays - passed)
    case .capital:
      return facts.counts > 0 ? nil : .firstCount
    case .debts:
      // A loan is never quieted: an owner who has one — or did not say — sees the section open.
      guard facts.hasLoans == false, facts.debts == 0 else { return nil }
      return facts.entryDays >= debtsEntryDays
        ? nil : .entryDays(needed: debtsEntryDays, have: facts.entryDays)
    }
  }

  /// Every quiet section and what it waits for, in the order of the enum; empty when the mode is
  /// off.
  public static func quiet(enabled: Bool, facts: BeginnerFacts) -> [BeginnerSection: BeginnerUnlock]
  {
    guard enabled else { return [:] }
    var quiet: [BeginnerSection: BeginnerUnlock] = [:]
    for section in BeginnerSection.allCases {
      if let unlock = unlock(section, facts: facts) { quiet[section] = unlock }
    }
    return quiet
  }
}
