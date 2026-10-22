import Foundation

/// A period named the way people say it: «this month», «last year», «September», «the last
/// 30 days». It is kept as the words, not as the days, so a saved report called «last
/// month» means November in December, and a question can be read before any ledger exists.
///
/// `resolved(today:)` turns it into days. Weeks start on Monday, like everywhere else.
public enum RelativePeriod: Hashable, Sendable, Codable {
  case today
  case yesterday
  case thisWeek
  case lastWeek
  case thisMonth
  case lastMonth
  case thisQuarter
  case lastQuarter
  case thisYear
  case lastYear
  /// The given number of days, ending today and including it.
  case lastDays(Int)
  /// The given number of whole months, the last of them the current one.
  case lastMonths(Int)
  /// From here on the period no longer moves with the calendar.
  case month(MonthKey)
  case quarter(year: Int, number: Int)
  case year(Int)
  case range(DateOnly, DateOnly)

  /// Does the period move with `today`? «This month» does, «September 2026» does not.
  public var isFloating: Bool {
    switch self {
    case .month, .quarter, .year, .range: false
    default: true
    }
  }

  /// The first and the last day, both included.
  public func resolved(today: DateOnly) -> (start: DateOnly, end: DateOnly) {
    switch self {
    case .today: return (today, today)
    case .yesterday:
      let day = Self.shift(today, days: -1)
      return (day, day)
    case .thisWeek:
      let start = Self.weekStart(today)
      return (start, Self.shift(start, days: 6))
    case .lastWeek:
      let start = Self.shift(Self.weekStart(today), days: -7)
      return (start, Self.shift(start, days: 6))
    case .thisMonth: return Self.span(of: today.monthKey)
    case .lastMonth: return Self.span(of: today.monthKey.previous)
    case .thisQuarter:
      return Self.span(ofQuarter: (today.month - 1) / 3 + 1, in: today.year)
    case .lastQuarter:
      let number = (today.month - 1) / 3 + 1
      return number == 1
        ? Self.span(ofQuarter: 4, in: today.year - 1)
        : Self.span(ofQuarter: number - 1, in: today.year)
    case .thisYear: return Self.span(ofYear: today.year)
    case .lastYear: return Self.span(ofYear: today.year - 1)
    case .lastDays(let count):
      return (Self.shift(today, days: -(max(count, 1) - 1)), today)
    case .lastMonths(let count):
      let first = Self.months(today.monthKey, adding: -(max(count, 1) - 1))
      return (first.firstDay, Self.span(of: today.monthKey).end)
    case .month(let month): return Self.span(of: month)
    case .quarter(let year, let number): return Self.span(ofQuarter: number, in: year)
    case .year(let year): return Self.span(ofYear: year)
    case .range(let start, let end): return (start, end)
    }
  }

  /// The same words with the days fixed: what «last month» meant on `today`.
  public func fixed(today: DateOnly) -> RelativePeriod {
    guard isFloating else { return self }
    let span = resolved(today: today)
    switch self {
    case .thisMonth, .lastMonth: return .month(span.start.monthKey)
    case .thisYear, .lastYear: return .year(span.start.year)
    case .thisQuarter, .lastQuarter:
      return .quarter(year: span.start.year, number: (span.start.month - 1) / 3 + 1)
    default: return .range(span.start, span.end)
    }
  }

  /// The floating period that is «now» for a kind that has a past form: «last year» is
  /// compared with «this year», «last month» with «this month». `nil` when there is none.
  public var currentCounterpart: RelativePeriod? {
    switch self {
    case .lastWeek: .thisWeek
    case .lastMonth: .thisMonth
    case .lastQuarter: .thisQuarter
    case .lastYear: .thisYear
    case .yesterday: .today
    default: nil
    }
  }

  /// The period right before this one, fixed to its days: the month before a month, the
  /// year before a year, the same number of days before a span of days.
  public func previous(today: DateOnly) -> RelativePeriod {
    let span = resolved(today: today)
    switch self {
    case .thisMonth, .lastMonth, .month:
      return .month(span.start.monthKey.previous)
    case .thisYear, .lastYear, .year:
      return .year(span.start.year - 1)
    case .thisQuarter, .lastQuarter, .quarter:
      let number = (span.start.month - 1) / 3 + 1
      return number == 1
        ? .quarter(year: span.start.year - 1, number: 4)
        : .quarter(year: span.start.year, number: number - 1)
    case .lastMonths(let count):
      let first = Self.months(span.start.monthKey, adding: -max(count, 1))
      return .range(
        first.firstDay, Self.span(of: Self.months(first, adding: max(count, 1) - 1)).end)
    default:
      let length = Self.dayNumber(span.end) - Self.dayNumber(span.start) + 1
      return .range(Self.shift(span.start, days: -length), Self.shift(span.start, days: -1))
    }
  }

  // MARK: - Stable text

  /// The form kept in a saved report and handed to a language model: `this_month`,
  /// `month:2026-09`, `quarter:2026-Q3`, `year:2025`, `last_days:30`,
  /// `range:2026-09-01..2026-09-30`.
  public var token: String {
    switch self {
    case .today: "today"
    case .yesterday: "yesterday"
    case .thisWeek: "this_week"
    case .lastWeek: "last_week"
    case .thisMonth: "this_month"
    case .lastMonth: "last_month"
    case .thisQuarter: "this_quarter"
    case .lastQuarter: "last_quarter"
    case .thisYear: "this_year"
    case .lastYear: "last_year"
    case .lastDays(let count): "last_days:\(count)"
    case .lastMonths(let count): "last_months:\(count)"
    case .month(let month): "month:\(month.iso)"
    case .quarter(let year, let number): "quarter:\(year)-Q\(number)"
    case .year(let year): "year:\(year)"
    case .range(let start, let end): "range:\(start.iso)..\(end.iso)"
    }
  }

  public init?(token: String) {
    let text = token.trimmingCharacters(in: .whitespaces).lowercased()
    switch text {
    case "today": self = .today
    case "yesterday": self = .yesterday
    case "this_week": self = .thisWeek
    case "last_week": self = .lastWeek
    case "this_month": self = .thisMonth
    case "last_month": self = .lastMonth
    case "this_quarter": self = .thisQuarter
    case "last_quarter": self = .lastQuarter
    case "this_year": self = .thisYear
    case "last_year": self = .lastYear
    default:
      let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { return nil }
      let value = parts[1]
      switch parts[0] {
      case "last_days":
        guard let count = Int(value), (1...3_660).contains(count) else { return nil }
        self = .lastDays(count)
      case "last_months":
        guard let count = Int(value), (1...120).contains(count) else { return nil }
        self = .lastMonths(count)
      case "month":
        guard let month = MonthKey(iso: value), value.count == 7 else { return nil }
        self = .month(month)
      case "quarter":
        let pieces = value.split(separator: "-").map(String.init)
        guard pieces.count == 2, let year = Int(pieces[0]), pieces[1].hasPrefix("q"),
          let number = Int(pieces[1].dropFirst()), (1...4).contains(number)
        else { return nil }
        self = .quarter(year: year, number: number)
      case "year":
        guard let year = Int(value), (1900...2200).contains(year) else { return nil }
        self = .year(year)
      case "range":
        let pieces = value.components(separatedBy: "..")
        guard pieces.count == 2, let start = DateOnly(iso: pieces[0]),
          let end = DateOnly(iso: pieces[1]), start <= end
        else { return nil }
        self = .range(start, end)
      default: return nil
      }
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let value = RelativePeriod(token: try container.decode(String.self)) else {
      throw CoreError.invalidDate
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(token)
  }

  // MARK: - Calendar arithmetic
  //
  // `CoreKit` has no day arithmetic of its own (it lives in the analytics target), and this
  // type must stay below it, so the few steps it needs are written out here.

  static func dayNumber(_ date: DateOnly) -> Int {
    let shiftedYear = date.month <= 2 ? date.year - 1 : date.year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let shiftedMonth = date.month > 2 ? date.month - 3 : date.month + 9
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + date.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func date(dayNumber: Int) -> DateOnly {
    let shifted = dayNumber + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return DateOnly(year: year, month: month, day: day)
  }

  static func shift(_ date: DateOnly, days: Int) -> DateOnly {
    Self.date(dayNumber: dayNumber(date) + days)
  }

  static func weekStart(_ date: DateOnly) -> DateOnly {
    // 1970-01-01 was a Thursday: day 0 has Monday-based index 3.
    let index = ((dayNumber(date) + 3) % 7 + 7) % 7
    return shift(date, days: -index)
  }

  static func months(_ month: MonthKey, adding count: Int) -> MonthKey {
    let index = month.year * 12 + (month.month - 1) + count
    let year = index >= 0 ? index / 12 : (index - 11) / 12
    return MonthKey(year: year, month: index - year * 12 + 1)
  }

  public static func lastDay(of month: MonthKey) -> DateOnly {
    let leap = (month.year % 4 == 0 && month.year % 100 != 0) || month.year % 400 == 0
    let count: Int
    switch month.month {
    case 2: count = leap ? 29 : 28
    case 4, 6, 9, 11: count = 30
    default: count = 31
    }
    return DateOnly(year: month.year, month: month.month, day: count)
  }

  private static func span(of month: MonthKey) -> (start: DateOnly, end: DateOnly) {
    (month.firstDay, lastDay(of: month))
  }

  private static func span(ofQuarter number: Int, in year: Int) -> (start: DateOnly, end: DateOnly)
  {
    let first = MonthKey(year: year, month: (min(max(number, 1), 4) - 1) * 3 + 1)
    return (first.firstDay, lastDay(of: months(first, adding: 2)))
  }

  private static func span(ofYear year: Int) -> (start: DateOnly, end: DateOnly) {
    (DateOnly(year: year, month: 1, day: 1), DateOnly(year: year, month: 12, day: 31))
  }
}
