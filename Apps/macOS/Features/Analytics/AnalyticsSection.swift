import AppCore
import Foundation

/// The sections of the Analytics window, in the order of its sidebar.
enum AnalyticsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
  case overview
  case quality
  case others
  case forWhom
  case places
  case events
  case paymentMethods
  case incomeSavings
  case forecast
  case anomalies
  case modelQuality
  // The sections of 2.1 («Разбор трат»): counted on demand through `ComputeStore.analysis`.
  case comparison
  case days
  case habits
  case leaks

  var id: String { rawValue }

  /// The sections the window lists. «Качество модели» is not one of them: it lives in
  /// Settings → «Подсказки категорий» on every platform (0577).
  static var listed: [AnalyticsSection] { allCases.filter { $0 != .modelQuality } }

  var titleKey: String { "analytics.section.\(rawValue)" }

  var symbol: String {
    switch self {
    case .overview: "chart.bar.xaxis"
    case .quality: "circle.lefthalf.filled"
    case .others: "person.2"
    case .forWhom: "person.crop.circle"
    case .places: "mappin.and.ellipse"
    case .events: "calendar"
    case .paymentMethods: "creditcard"
    case .incomeSavings: "banknote"
    case .forecast: "chart.line.uptrend.xyaxis"
    case .anomalies: "waveform.path.ecg"
    case .modelQuality: "checkmark.seal"
    case .comparison: "arrow.left.arrow.right"
    case .days: "clock"
    case .habits: "repeat"
    case .leaks: "drop"
    }
  }

  /// The sections of 2.1: they are not built from an `AnalyticsModel` but count what they show
  /// themselves (`SpendingSectionsHost`).
  var isSpending: Bool {
    switch self {
    case .comparison, .days, .habits, .leaks: true
    default: false
    }
  }

  /// The release a placeholder section is promised for. Nothing is waiting any more: the
  /// anomalies and «Качество модели» were the last two, and both have arrived.
  var plannedFor: String? { nil }

  /// The forecast is always the current month, whatever period the toolbar shows, and
  /// «Качество модели» measures the whole history; «Доход и сбережения» looks at the last twelve
  /// months and at the months before today: the period elements are inactive on all three,
  /// and none is computed again when the toolbar moves.
  var followsThePeriod: Bool {
    switch self {
    case .forecast, .modelQuality, .incomeSavings: false
    default: plannedFor == nil
    }
  }
}

/// The period of the header: a week, a month, a quarter, a year, or twelve months ending with a
/// month, and what it is anchored on — the Monday of the week, the month, the first month of the
/// quarter, a month of the year, the last of the twelve. Stored as text in `UserDefaults` — a
/// preference of the window, never in the database.
struct AnalyticsPeriod: Hashable, Sendable {
  enum Kind: String, CaseIterable, Hashable, Sendable {
    case week
    case month
    case quarter
    case year
    case twelveMonths

    var titleKey: String { "analytics.period.\(rawValue)" }
  }

  var kind: Kind
  /// The month itself, the month of the week's Monday, the first month of the quarter, a month
  /// of the year, or the last of the twelve.
  var month: MonthKey
  /// The Monday of a week; `nil` for every other kind.
  var weekStart: DateOnly?

  init(kind: Kind, month: MonthKey) {
    self.kind = kind
    switch kind {
    case .week:
      let monday = month.firstDay.weekStart
      self.month = monday.monthKey
      weekStart = monday
    case .quarter:
      self.month = Self.quarterStart(month)
    case .month, .year, .twelveMonths:
      self.month = month
    }
  }

  /// The week that holds `day`.
  init(week day: DateOnly) {
    kind = .week
    weekStart = day.weekStart
    month = day.weekStart.monthKey
  }

  /// The first month of the quarter that holds `month`.
  static func quarterStart(_ month: MonthKey) -> MonthKey {
    MonthKey(year: month.year, month: (month.month - 1) / 3 * 3 + 1)
  }

  /// The period of `today`: what the window opens on the first time and what «Текущий» gives.
  static func current(_ kind: Kind = .month, today: DateOnly) -> AnalyticsPeriod {
    kind == .week
      ? AnalyticsPeriod(week: today) : AnalyticsPeriod(kind: kind, month: today.monthKey)
  }

  var period: Period {
    switch kind {
    case .week:
      let monday = weekStart ?? month.firstDay.weekStart
      return .days(DayRange(monday, monday.adding(days: 6)))
    case .month: return .month(month)
    case .quarter: return .days(DayRange(month.firstDay, month.adding(months: 2).lastDay))
    case .year: return .year(month.year)
    case .twelveMonths: return .twelveMonths(endingWith: month)
    }
  }

  /// One step back or forward: a week, a month, a quarter, a year; twelve months slide by one
  /// month, so the window of a year can be moved month by month.
  func stepped(by direction: Int) -> AnalyticsPeriod {
    switch kind {
    case .week:
      AnalyticsPeriod(week: (weekStart ?? month.firstDay.weekStart).adding(days: 7 * direction))
    case .month, .twelveMonths:
      AnalyticsPeriod(kind: kind, month: month.adding(months: direction))
    case .quarter:
      AnalyticsPeriod(kind: kind, month: month.adding(months: 3 * direction))
    case .year:
      AnalyticsPeriod(kind: kind, month: month.adding(months: 12 * direction))
    }
  }

  /// The same anchor seen as another kind: September as a month, as 2026, as the twelve
  /// months to September, as its third quarter, as the week of its first day.
  func with(kind: Kind) -> AnalyticsPeriod {
    AnalyticsPeriod(kind: kind, month: month)
  }

  /// The same anchor seen as another kind, the week being that of today when the anchor is the
  /// month of today, so «Неделя» opens this week rather than the first of the month.
  func with(kind: Kind, today: DateOnly) -> AnalyticsPeriod {
    guard kind == .week else { return with(kind: kind) }
    let day = month == today.monthKey ? today : month.firstDay
    return AnalyticsPeriod(week: day).clamped(to: today)
  }

  /// A step forward never goes past the period that holds today: there is nothing there.
  /// The anchor decides, not the start of the range — twelve months that end in October
  /// begin long before today and would still be eleven months that have not come.
  func canStepForward(today: DateOnly) -> Bool {
    let next = stepped(by: 1)
    switch kind {
    case .year: return next.month.year <= today.year
    case .week: return (next.weekStart ?? next.month.firstDay) <= today.weekStart
    case .quarter: return next.month <= Self.quarterStart(today.monthKey)
    case .month, .twelveMonths: return next.month <= today.monthKey
    }
  }

  /// A year chosen in the popover: anchored on its December, or on the month of today for
  /// the current year, as «Текущий» does. Seen as twelve months, a past year is itself.
  static func year(_ year: Int, today: DateOnly) -> AnalyticsPeriod {
    AnalyticsPeriod(kind: .year, month: MonthKey(year: year, month: 12)).clamped(to: today)
  }

  /// The same period with its anchor no later than the period of today. A year stepped
  /// forward from December, or a text stored before, would otherwise open a month that has
  /// not come once it is seen as a month or as twelve months.
  func clamped(to today: DateOnly) -> AnalyticsPeriod {
    switch kind {
    case .week:
      let monday = weekStart ?? month.firstDay.weekStart
      return monday > today.weekStart ? AnalyticsPeriod(week: today) : self
    case .quarter:
      return AnalyticsPeriod(kind: .quarter, month: min(month, Self.quarterStart(today.monthKey)))
    case .month, .year, .twelveMonths:
      return AnalyticsPeriod(kind: kind, month: min(month, today.monthKey))
    }
  }

  /// The period holds today already: «Текущий» has nothing to do.
  func isCurrent(today: DateOnly) -> Bool {
    switch kind {
    case .week: weekStart == today.weekStart
    case .quarter: month == Self.quarterStart(today.monthKey)
    case .year: month.year == today.year
    case .month, .twelveMonths: month == today.monthKey
    }
  }

  /// «month:2026-09», «year:2026-09», «twelveMonths:2026-09», «quarter:2026-07»,
  /// «week:2026-11-09».
  var storage: String {
    if kind == .week, let weekStart { return "\(kind.rawValue):\(weekStart.iso)" }
    return "\(kind.rawValue):\(month.iso)"
  }

  init?(storage: String) {
    let pieces = storage.split(separator: ":", maxSplits: 1).map(String.init)
    guard pieces.count == 2, let kind = Kind(rawValue: pieces[0]) else { return nil }
    if kind == .week {
      guard let day = DateOnly(iso: pieces[1]) else { return nil }
      self.init(week: day)
    } else {
      guard let month = MonthKey(iso: pieces[1]) else { return nil }
      self.init(kind: kind, month: month)
    }
  }
}
