import CoreAnalytics
import CoreKit
import Foundation

/// Which badges the history earns, and which of them are not written yet. A badge is about the
/// owner's own habit — a streak of days of entry, a month with a count of the accounts, months of
/// counts in a row — and never about anybody else. The rule only finds them; once written, a badge
/// stays whatever the history says later (`HabitRepository.award`).
public enum HabitBadges {
  /// The months with a count of the accounts: a reconciliation of the accounts or of one total,
  /// by the month of its day. An opening — the balances given at the setup, with a new account or
  /// a merge — is not a count. With the first day of a count in each month.
  public static func countMonths(_ reconciliations: [Reconciliation]) -> [MonthKey: DateOnly] {
    var months: [MonthKey: DateOnly] = [:]
    for reconciliation in reconciliations where reconciliation.kind != .opening {
      let month = reconciliation.date.monthKey
      months[month] = min(months[month] ?? reconciliation.date, reconciliation.date)
    }
    return months
  }

  /// Every badge the history earns as of `today`, in the order they were earned (then by key).
  /// `earnedAt` is the instant given: the moment they are found.
  public static func earned(
    entryDays: Set<DateOnly>, reconciliations: [Reconciliation], today: DateOnly, at instant: Date
  ) -> [HabitBadge] {
    var badges: [HabitBadge] = []
    for streak in EntryStreaks.runs(days: entryDays, today: today) {
      for kind in HabitBadgeKind.streaks {
        guard let days = kind.streakDays, let day = streak.reached(days) else { continue }
        badges.append(
          HabitBadge(kind: kind, period: streak.start.iso, earnedOn: day, earnedAt: instant))
      }
    }
    let months = countMonths(reconciliations).filter { $0.value <= today }
    for (month, first) in months {
      badges.append(
        HabitBadge(kind: .countMonth, period: month.iso, earnedOn: first, earnedAt: instant))
    }
    for series in monthSeries(Set(months.keys)) {
      for kind in [HabitBadgeKind.count3, .count12] {
        guard let length = kind.countMonths, series.count >= length else { continue }
        let reachedMonth = series[length - 1]
        badges.append(
          HabitBadge(
            kind: kind, period: series[0].iso, earnedOn: months[reachedMonth] ?? today,
            earnedAt: instant))
      }
    }
    return badges.sorted { ($0.earnedOn, $0.key) < ($1.earnedOn, $1.key) }
  }

  /// The badges of `earned` not among `stored`, by key.
  public static func new(_ earned: [HabitBadge], stored: [HabitBadge]) -> [HabitBadge] {
    let known = Set(stored.map(\.key))
    return earned.filter { !known.contains($0.key) }
  }

  /// The badges earned within the days of a period, the earliest first: what «Итоги» of that
  /// week, month or year show.
  public static func earned(in range: DayRange, of badges: [HabitBadge]) -> [HabitBadge] {
    badges.filter { range.contains($0.earnedOn) }
      .sorted { ($0.earnedOn, $0.key) < ($1.earnedOn, $1.key) }
  }

  /// Runs of months in a row, oldest first, each oldest month first.
  static func monthSeries(_ months: Set<MonthKey>) -> [[MonthKey]] {
    var series: [[MonthKey]] = []
    for month in months.sorted() {
      if let last = series.last?.last, last.next == month {
        series[series.count - 1].append(month)
      } else {
        series.append([month])
      }
    }
    return series
  }
}
