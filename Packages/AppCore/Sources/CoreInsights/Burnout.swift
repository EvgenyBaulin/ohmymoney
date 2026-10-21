import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

/// A week of more small purchases one could do without than usual.
public struct BurnoutSignal: Hashable, Sendable {
  public var lastWeekCount: Int
  public var usualCount: Int
  public var from: DateOnly
  public var through: DateOnly

  public init(lastWeekCount: Int, usualCount: Int, from: DateOnly, through: DateOnly) {
    self.lastWeekCount = lastWeekCount
    self.usualCount = usualCount
    self.from = from
    self.through = through
  }
}

/// What the check of burnout says.
public enum BurnoutCheck: Hashable, Sendable {
  case signal(BurnoutSignal)
  case quiet
  /// No category is marked essential: nothing tells a small purchase one could do without.
  case needsEssentials
  case notEnoughHistory
}

/// The hint about burnout: a week of many more small purchases one could do without than
/// usual.
///
/// * A small purchase one could do without is a part of my spending (`LedgerRow.contribution`
///   above zero) in a category not essential (`CategoryTree.isEssential`), neither of the app
///   (goals, loans, …) nor «Сверка», nor a purchase on credit, nor a record the app wrote to keep
///   the books — cheaper than the median of the parts of its category over the 90 days before
///   the week; a category with fewer than 5 parts there takes the median of all such parts.
/// * The week is the last 7 days through today; the usual week is the median count of the 12
///   weeks of 7 days before it that had any operation, and there must be 6 of them.
/// * A signal: the week counts at least 1.5 times the usual and at least 5 more.
/// * Without a single category marked essential nothing tells such a purchase: no hint.
public enum Burnout {
  public static let historyWeeks = 12
  public static let minimumWeeks = 6
  public static let medianDays = 90
  public static let minimumParts = 5
  /// 1.5 times the usual…
  public static let ratioPercent = 150
  /// …and at least this many more.
  public static let minimumMore = 5

  public static func check(ledger: Ledger, tree: CategoryTree, today: DateOnly) -> BurnoutCheck {
    guard ledger.dataset.categories.contains(where: { $0.essential == true }) else {
      return .needsEssentials
    }
    let weekStart = today.adding(days: -6)
    let historyStart = weekStart.adding(days: -7 * historyWeeks)
    let medianStart = weekStart.adding(days: -medianDays)
    let limitless = ledger.dataset.planning.settings.limitlessCategoryIds

    func optional(_ row: LedgerRow) -> Bool {
      guard row.kind == .expense, row.contribution.raw > 0, row.creditDebtId == nil,
        tree.systemRole(of: row.categoryId) == nil, !tree.isEssential(row.categoryId)
      else { return false }
      if let link = row.link, link.isBookkeeping { return false }
      if let category = row.categoryId,
        LimitRules.isLimitless(category, tree: tree, limitless: limitless)
      {
        return false
      }
      return true
    }

    // The medians, of the 90 days before the week.
    var byCategory: [UUID?: [AmountE4]] = [:]
    var all: [AmountE4] = []
    for row in ledger.rows(in: DayRange(medianStart, weekStart.adding(days: -1)))
    where optional(row) {
      byCategory[row.categoryId, default: []].append(row.contribution)
      all.append(row.contribution)
    }
    guard let overall = median(all) else { return .notEnoughHistory }
    func isSmall(_ row: LedgerRow) -> Bool {
      let own = byCategory[row.categoryId] ?? []
      let threshold = own.count >= minimumParts ? (median(own) ?? overall) : overall
      return row.contribution < threshold
    }

    var weekly = Array(repeating: 0, count: historyWeeks)
    var active = Array(repeating: false, count: historyWeeks)
    var lastWeek = 0
    for row in ledger.rows(in: DayRange(historyStart, today)) {
      let index = historyStart.days(to: row.day) / 7
      let small = optional(row) && isSmall(row)
      if index >= historyWeeks {
        if small { lastWeek += 1 }
      } else {
        active[index] = true
        if small { weekly[index] += 1 }
      }
    }
    let counted = zip(weekly, active).filter(\.1).map(\.0).sorted()
    guard counted.count >= minimumWeeks else { return .notEnoughHistory }
    let middle = counted.count / 2
    let usual =
      counted.count % 2 == 1 ? counted[middle] : (counted[middle - 1] + counted[middle] + 1) / 2
    guard lastWeek * 100 >= usual * ratioPercent, lastWeek >= usual + minimumMore else {
      return .quiet
    }
    return .signal(
      BurnoutSignal(lastWeekCount: lastWeek, usualCount: usual, from: weekStart, through: today))
  }

  /// The week of the year a hint was shown in, `YYYY-Www` (weeks from Monday, the first
  /// holding 4 January), as `insights.burnout.lastShown` keeps it.
  public static func weekKey(_ day: DateOnly) -> String {
    let monday = day.weekStart
    let thursday = monday.adding(days: 3)
    let firstThursdayYear = thursday.year
    let january4 = DateOnly(year: firstThursdayYear, month: 1, day: 4)
    let week = january4.weekStart.days(to: monday) / 7 + 1
    return String(format: "%04d-W%02d", firstThursdayYear, week)
  }

  /// Whether the hint may show today: on, and not shown yet this week.
  public static func shows(
    _ check: BurnoutCheck, enabled: Bool, lastShownWeek: String?, today: DateOnly
  ) -> Bool {
    guard enabled, case .signal = check else { return false }
    return lastShownWeek != weekKey(today)
  }

  private static func median(_ values: [AmountE4]) -> AmountE4? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 1 { return sorted[middle] }
    return AmountE4(raw: (sorted[middle - 1].raw + sorted[middle].raw) / 2)
  }
}
