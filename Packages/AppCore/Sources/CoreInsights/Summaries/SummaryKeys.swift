import CoreAnalytics
import CoreKit
import Foundation

/// The three rhythms of «Итоги».
public enum SummaryKind: String, Hashable, Sendable, Codable, CaseIterable {
  case week
  case month
  case year
}

/// A week of the Monday-to-Sunday calendar the whole app uses, numbered the ISO way: the week
/// belongs to the year its Thursday falls in.
public struct WeekKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
  public let year: Int
  public let week: Int

  public init(year: Int, week: Int) {
    self.year = year
    self.week = week
  }

  /// The week a day belongs to.
  public init(containing day: DateOnly) {
    let thursday = day.adding(days: 4 - day.weekday)
    let firstDay = DateOnly(year: thursday.year, month: 1, day: 1)
    self.init(year: thursday.year, week: (thursday.dayNumber - firstDay.dayNumber) / 7 + 1)
  }

  /// `2026-W43`.
  public init?(iso: String) {
    let parts = iso.split(separator: "-")
    guard parts.count == 2, let year = Int(parts[0]), parts[1].hasPrefix("W"),
      let week = Int(parts[1].dropFirst()), (1...53).contains(week)
    else { return nil }
    self.init(year: year, week: week)
  }

  public var iso: String { String(format: "%04d-W%02d", year, week) }
  public var description: String { iso }

  /// The Monday of the week. The 4th of January is always inside the first week.
  public var start: DateOnly {
    let fourth = DateOnly(year: year, month: 1, day: 4)
    return fourth.weekStart.adding(days: 7 * (week - 1))
  }

  public var end: DateOnly { start.adding(days: 6) }
  public var range: DayRange { DayRange(start, end) }
  public var next: WeekKey { WeekKey(containing: start.adding(days: 7)) }
  public var previous: WeekKey { WeekKey(containing: start.adding(days: -7)) }

  public static func < (lhs: WeekKey, rhs: WeekKey) -> Bool {
    (lhs.year, lhs.week) < (rhs.year, rhs.week)
  }
}

/// Which summary: a week, a month or a year, and which one.
public struct SummaryID: Hashable, Sendable, Codable, CustomStringConvertible, Identifiable {
  public let kind: SummaryKind
  /// `2026-W43`, `2026-09` or `2026`.
  public let key: String

  public init(kind: SummaryKind, key: String) {
    self.kind = kind
    self.key = key
  }

  public static func week(_ week: WeekKey) -> SummaryID { SummaryID(kind: .week, key: week.iso) }
  public static func month(_ month: MonthKey) -> SummaryID {
    SummaryID(kind: .month, key: month.iso)
  }
  public static func year(_ year: Int) -> SummaryID { SummaryID(kind: .year, key: String(year)) }

  /// `month:2026-09`, the text kept in the settings.
  public var description: String { "\(kind.rawValue):\(key)" }
  public var id: String { description }

  public init?(raw: String) {
    let parts = raw.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let kind = SummaryKind(rawValue: String(parts[0])) else {
      return nil
    }
    self.init(kind: kind, key: String(parts[1]))
  }

  public var weekKey: WeekKey? { kind == .week ? WeekKey(iso: key) : nil }
  public var monthKey: MonthKey? { kind == .month ? MonthKey(iso: key) : nil }
  public var yearNumber: Int? { kind == .year ? Int(key) : nil }

  /// The days the summary is about.
  public var range: DayRange? {
    switch kind {
    case .week: weekKey?.range
    case .month: monthKey.map { Period.month($0).range }
    case .year: yearNumber.map { Period.year($0).range }
    }
  }
}

/// The answer to «Как прошла неделя?»: one of five faces, 1 the worst, 5 the best.
public struct WeekMood: Hashable, Sendable, Codable {
  public static let range = 1...5

  public var week: WeekKey
  public var mood: Int
  public var answeredAt: Date

  public init(week: WeekKey, mood: Int, answeredAt: Date) {
    self.week = week
    self.mood = min(max(mood, Self.range.lowerBound), Self.range.upperBound)
    self.answeredAt = answeredAt
  }
}

/// Where the answers to the weekly question are kept (the table `week_answers` of the
/// database). The summaries read and write through this seam only, so the core stays free of
/// the database.
public protocol WeekAnswerStore: Sendable {
  func answers() async throws -> [WeekMood]
  /// One answer per week: a new answer for the same week replaces the old one.
  func save(_ answer: WeekMood) async throws
}

/// A value a line of text is made of. The core never writes words: it names the line by a key
/// and hands over these, and the app puts them into the sentence of the language of the moment.
public enum SummaryArg: Hashable, Sendable {
  case money(AmountE4)
  /// Whole per cent.
  case percent(Int)
  case count(Int)
  /// A number with one decimal place, stored times ten: 37 is 3.7.
  case tenths(Int)
  /// 1 = Monday … 7 = Sunday.
  case weekday(Int)
  case month(MonthKey)
  case year(Int)
  case day(DateOnly)
  case category(UUID)
  case place(UUID)
  case timeOfDay(TimeBucket)
  /// A name the owner typed himself (a debt, a note).
  case name(String)

  public var isMoney: Bool {
    if case .money = self { return true }
    return false
  }
}

/// A part of the day the habits are counted by.
public enum TimeBucket: String, Hashable, Sendable, CaseIterable {
  case morning  // 05:00–10:59
  case day  // 11:00–16:59
  case evening  // 17:00–22:59
  case night  // 23:00–04:59

  public init(hour: Int) {
    switch hour {
    case 5..<11: self = .morning
    case 11..<17: self = .day
    case 17..<23: self = .evening
    default: self = .night
    }
  }
}

/// One line of a card: a catalog key and what goes into it.
public struct SummaryLine: Hashable, Sendable {
  public var key: String
  public var args: [SummaryArg]

  public init(_ key: String, _ args: [SummaryArg] = []) {
    self.key = key
    self.args = args
  }

  /// Does the line say an amount of money? With «Скрыть суммы» on, no line may.
  public var showsMoney: Bool { args.contains(where: \.isMoney) }
}

/// A card of a summary: a title and the lines under it.
public struct SummaryCard: Hashable, Sendable, Identifiable {
  public var id: String
  public var title: SummaryLine
  public var lines: [SummaryLine]

  public init(id: String, title: SummaryLine, lines: [SummaryLine]) {
    self.id = id
    self.title = title
    self.lines = lines
  }

  public var showsMoney: Bool { title.showsMoney || lines.contains(where: \.showsMoney) }
}
