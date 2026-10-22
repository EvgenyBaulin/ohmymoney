import CoreAnalytics
import CoreKit
import Foundation

/// What a yearly expense is recognised by: the category it is filed under, or the place it is
/// paid at.
public enum YearlyKey: Hashable, Sendable, Codable {
  case category(UUID)
  case place(UUID)
}

/// One expense of the history, as the finder reads it. The caller makes these from the ledger
/// (the rows that count as my spending, in rubles).
public struct YearlyRecord: Hashable, Sendable {
  public var day: DateOnly
  public var amount: AmountE4
  public var categoryId: UUID?
  public var placeId: UUID?
  /// What the operation is called, for the name of the suggestion.
  public var title: String

  public init(
    day: DateOnly, amount: AmountE4, categoryId: UUID? = nil, placeId: UUID? = nil,
    title: String = ""
  ) {
    self.day = day
    self.amount = amount
    self.categoryId = categoryId
    self.placeId = placeId
    self.title = title
  }
}

/// «Похоже, в марте снова страховка ≈ 12 000 ₽ — завести копилку?»
public struct YearlyExpense: Hashable, Sendable, Identifiable {
  public var key: YearlyKey
  public var title: String
  /// The next time it is expected: the latest occurrence a year on.
  public var expectedDate: DateOnly
  /// The median of the occurrences.
  public var expectedAmount: AmountE4
  /// How many years in a row it came.
  public var years: Int

  public var id: String {
    switch key {
    case .category(let id): return "yearly:category:\(id.uuidString)"
    case .place(let id): return "yearly:place:\(id.uuidString)"
    }
  }
}

/// Finds the expenses that come once a year.
///
/// An occurrence is a cluster of operations of one key within 30 days of its first one; two
/// clusters are consecutive years when their first days are 335…395 days apart. A key is a
/// yearly expense when its latest run of clusters has at least two of them, every gap in the run
/// is a year, the amounts are alike (the smaller at least 60 % of the larger), and nothing else
/// of the key happens in between — which is what keeps groceries, a cafe or a rent out: they
/// are not once a year, they break the run.
public enum YearlyExpenseFinder {
  public static let windowDays = 30
  public static let gapDays = 335...395
  /// The smaller amount of two neighbouring occurrences, in per cent of the larger.
  public static let similarityPercent = 60
  public static let minimumYears = 2
  /// The suggestion is made this many days before the expected date at the earliest.
  public static let leadDays = 62

  /// Every yearly expense in the records, whenever it is expected.
  public static func find(records: [YearlyRecord]) -> [YearlyExpense] {
    var groups: [YearlyKey: [YearlyRecord]] = [:]
    for record in records where record.amount.raw > 0 {
      if let category = record.categoryId {
        groups[.category(category), default: []].append(record)
      }
      if let place = record.placeId { groups[.place(place), default: []].append(record) }
    }
    var result: [YearlyExpense] = []
    for (key, group) in groups {
      guard let expense = expense(key: key, records: group) else { continue }
      result.append(expense)
    }
    return result.sorted { ($0.expectedDate, $0.id) < ($1.expectedDate, $1.id) }
  }

  /// What to suggest on `today`: the yearly expenses expected within `leadDays` and not yet
  /// past, without those the owner already saves for (`covered`) or put off (`dismissed`,
  /// `YearlyExpense.id`). A key that has a place and a category both can be found twice for
  /// the same payment: the one with the place is kept.
  public static func suggestions(
    records: [YearlyRecord], today: DateOnly, covered: Set<YearlyKey> = [],
    dismissed: Set<String> = []
  ) -> [YearlyExpense] {
    let found = find(records: records).filter { expense in
      let ahead = today.days(to: expense.expectedDate)
      return ahead >= 0 && ahead <= leadDays && !covered.contains(expense.key)
        && !dismissed.contains(expense.id)
    }
    var kept: [YearlyExpense] = []
    for expense in found.sorted(by: { rank($0.key) < rank($1.key) }) {
      let twin = kept.contains { other in
        other.expectedDate == expense.expectedDate
          && other.expectedAmount == expense.expectedAmount
      }
      if !twin { kept.append(expense) }
    }
    return kept.sorted { ($0.expectedDate, $0.id) < ($1.expectedDate, $1.id) }
  }

  private static func rank(_ key: YearlyKey) -> Int {
    if case .place = key { return 0 }
    return 1
  }

  static func expense(key: YearlyKey, records: [YearlyRecord]) -> YearlyExpense? {
    let sorted = records.sorted { $0.day < $1.day }
    // Clusters: operations within the window of the first one are one occurrence.
    var clusters: [(first: DateOnly, total: AmountE4, title: String, biggest: AmountE4)] = []
    for record in sorted {
      if let last = clusters.last, last.first.days(to: record.day) <= windowDays {
        clusters[clusters.count - 1].total += record.amount
        if record.amount > last.biggest {
          clusters[clusters.count - 1].biggest = record.amount
          clusters[clusters.count - 1].title = record.title
        }
      } else {
        clusters.append((record.day, record.amount, record.title, record.amount))
      }
    }
    // The latest run of clusters a year apart and alike.
    var run = [clusters.count - 1]
    guard let tail = run.first, tail >= 0 else { return nil }
    var index = tail
    while index > 0 {
      let gap = clusters[index - 1].first.days(to: clusters[index].first)
      let (small, large) = (
        min(clusters[index - 1].total, clusters[index].total),
        max(clusters[index - 1].total, clusters[index].total)
      )
      guard gapDays.contains(gap),
        small.decimal * 100 >= large.decimal * Decimal(similarityPercent)
      else { break }
      run.append(index - 1)
      index -= 1
    }
    guard run.count >= minimumYears else { return nil }
    let amounts = run.map { clusters[$0].total }
    guard let median = IncomeEstimate.median(amounts) else { return nil }
    let latest = clusters[tail]
    let expected = Recurrence.clipped(
      day: latest.first.day,
      in: MonthKey(year: latest.first.year + 1, month: latest.first.month))
    return YearlyExpense(
      key: key, title: latest.title, expectedDate: expected, expectedAmount: median,
      years: run.count)
  }
}

/// A saving for a yearly expense is an ordinary goal (answer: «обычная цель с ежемесячным
/// планом и датой»), so the plan of goals, the contributions and «Можно тратить сейчас» all
/// work on it unchanged.
public enum AnnualReserve {
  /// The goal that saves for `expense`: its target and date, and the monthly plan that
  /// reaches the target in the months left — the month of the date is one of them — in whole
  /// rubles, so paying the plan every month reaches the target.
  public static func goal(
    for expense: YearlyExpense, name: String? = nil, today: DateOnly
  )
    -> Goal
  {
    plannedGoal(
      name: name ?? expense.title, target: expense.expectedAmount, date: expense.expectedDate,
      today: today)
  }

  /// «Начать снова к марту 2028»: the goal for the next time, after the money was spent. It is
  /// a new goal — the old one is closed by the caller (the «Потратили деньги цели?» question) —
  /// with the same name and target, a year later than the date of the old one (a year after
  /// `spentOn` when the old one had no date).
  public static func restarted(_ goal: Goal, spentOn: DateOnly, today: DateOnly) -> Goal {
    let base = goal.targetDate ?? spentOn
    let next = Recurrence.clipped(
      day: base.day, in: MonthKey(year: base.year + 1, month: base.month))
    // A date already passed (the old goal was late) moves on until it is ahead.
    var date = next
    while date < today {
      date = Recurrence.clipped(day: date.day, in: MonthKey(year: date.year + 1, month: date.month))
    }
    return plannedGoal(name: goal.name, target: goal.targetE4, date: date, today: today)
  }

  /// The month the restarted goal is for, for the words of the offer.
  public static func restartMonth(_ goal: Goal, spentOn: DateOnly, today: DateOnly) -> MonthKey? {
    restarted(goal, spentOn: spentOn, today: today).targetDate?.monthKey
  }

  private static func plannedGoal(
    name: String, target: AmountE4, date: DateOnly, today: DateOnly
  )
    -> Goal
  {
    let months = max(1, today.monthKey.months(to: date.monthKey) + 1)
    return Goal(
      name: name, targetE4: target, targetDate: date,
      monthlyPlanE4: SavingsMath.ceilingWhole(target, by: months), currency: .rub,
      planStartMonth: today.monthKey)
  }
}
