import CoreAnalytics
import CoreKit
import Foundation

/// Which summaries the owner wants to be told about on their own.
public struct SummarySwitches: Hashable, Sendable {
  public var week: Bool
  public var month: Bool
  public var year: Bool

  public init(week: Bool = true, month: Bool = true, year: Bool = true) {
    self.week = week
    self.month = month
    self.year = year
  }

  public func isOn(_ kind: SummaryKind) -> Bool {
    switch kind {
    case .week: week
    case .month: month
    case .year: year
    }
  }
}

/// What the card above the tiles of «Обзор» says today.
public enum SummaryAnnouncement: Hashable, Sendable {
  /// «Итоги сентября готовы».
  case summary(SummaryID)
  /// «Как прошла неделя?» — five faces, one tap.
  case weekQuestion(WeekKey)
}

/// When a summary is ready and when the question of the week is asked.
///
/// A summary comes on its own day — a week on Monday, a month on the 1st, a year on 1
/// January — and stays until it was opened or put away. Only the latest finished one of each
/// kind is offered, never a queue of old ones, and a year only until the end of March: in
/// October nobody wants last year's card.
public enum SummaryScheduler {
  /// The last day of the year a year summary is still offered on its own.
  static let yearOfferedThrough = (month: 3, day: 31)

  /// The summaries ready on `today`, the most important first: a year, then a month, then a
  /// week. A summary of a period before the first operation, or one the owner switched off, or
  /// one already shown, is not among them.
  ///
  /// - Parameters:
  ///   - firstDay: the first day with an operation; `nil` — no operations yet.
  ///   - shown: the summaries opened or put away.
  public static func ready(
    today: DateOnly, firstDay: DateOnly?, switches: SummarySwitches, shown: Set<SummaryID>
  ) -> [SummaryID] {
    guard let firstDay else { return [] }
    var result: [SummaryID] = []
    func offer(_ id: SummaryID) {
      guard switches.isOn(id.kind), !shown.contains(id), let range = id.range,
        range.end >= firstDay
      else { return }
      result.append(id)
    }
    let afterMarch =
      today.month > yearOfferedThrough.month
      || (today.month == yearOfferedThrough.month && today.day > yearOfferedThrough.day)
    if !afterMarch { offer(.year(today.year - 1)) }
    offer(.month(today.monthKey.previous))
    offer(.week(WeekKey(containing: today).previous))
    return result
  }

  /// The week whose question is asked on `today`: the running week on Sunday, the finished
  /// one on Monday if it was left unanswered; `nil` on other days, or when it is answered or
  /// the week had no operations.
  public static func weekToAsk(
    today: DateOnly, firstDay: DateOnly?, answered: Set<WeekKey>, switches: SummarySwitches
  ) -> WeekKey? {
    guard switches.week, let firstDay else { return nil }
    let week: WeekKey
    switch today.weekday {
    case 7: week = WeekKey(containing: today)
    case 1: week = WeekKey(containing: today).previous
    default: return nil
    }
    guard week.end >= firstDay, !answered.contains(week) else { return nil }
    return week
  }

  /// What the card says: a ready summary, else the question of the week.
  public static func announcement(
    today: DateOnly, firstDay: DateOnly?, switches: SummarySwitches, shown: Set<SummaryID>,
    answered: Set<WeekKey>
  ) -> SummaryAnnouncement? {
    if let id = ready(today: today, firstDay: firstDay, switches: switches, shown: shown).first {
      return .summary(id)
    }
    return weekToAsk(today: today, firstDay: firstDay, answered: answered, switches: switches)
      .map(SummaryAnnouncement.weekQuestion)
  }

  /// Every finished period of a kind that has operations, newest first — the list of the
  /// screen «Итоги».
  public static func archive(kind: SummaryKind, today: DateOnly, firstDay: DateOnly?) -> [SummaryID] {
    guard let firstDay else { return [] }
    switch kind {
    case .week:
      var weeks: [SummaryID] = []
      var week = WeekKey(containing: today).previous
      while week.end >= firstDay && weeks.count < 52 {
        weeks.append(.week(week))
        week = week.previous
      }
      return weeks
    case .month:
      let months = MonthKey.range(firstDay.monthKey, through: today.monthKey.previous)
      return months.reversed().map(SummaryID.month)
    case .year:
      guard firstDay.year < today.year else { return [] }
      return (firstDay.year..<today.year).reversed().map(SummaryID.year)
    }
  }
}
