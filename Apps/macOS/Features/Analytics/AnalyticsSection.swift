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
  case forecast
  case anomalies
  case modelQuality

  var id: String { rawValue }

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
    case .forecast: "chart.line.uptrend.xyaxis"
    case .anomalies: "waveform.path.ecg"
    case .modelQuality: "checkmark.seal"
    }
  }

  /// The release a placeholder section is promised for. Nothing is waiting any more: the
  /// anomalies and «Качество модели» were the last two, and both have arrived.
  var plannedFor: String? { nil }

  /// The forecast is always the current month, whatever period the toolbar shows, and
  /// «Качество модели» measures the whole history: the period elements are inactive on both,
  /// and neither is computed again when the toolbar moves.
  var followsThePeriod: Bool {
    switch self {
    case .forecast, .modelQuality: false
    default: plannedFor == nil
    }
  }
}

/// The period of the toolbar: a month, a year, or twelve months ending with a month, and
/// the month it is anchored on. Stored as text in `UserDefaults` — a preference of the
/// window, never in the database.
struct AnalyticsPeriod: Hashable, Sendable {
  enum Kind: String, CaseIterable, Hashable, Sendable {
    case month
    case year
    case twelveMonths

    var titleKey: String { "analytics.period.\(rawValue)" }
  }

  var kind: Kind
  /// The month itself, a month of the year, or the last of the twelve.
  var month: MonthKey

  init(kind: Kind, month: MonthKey) {
    self.kind = kind
    self.month = month
  }

  /// The month of `today`: what the window opens on the first time and what «Текущий» gives.
  static func current(_ kind: Kind = .month, today: DateOnly) -> AnalyticsPeriod {
    AnalyticsPeriod(kind: kind, month: today.monthKey)
  }

  var period: Period {
    switch kind {
    case .month: .month(month)
    case .year: .year(month.year)
    case .twelveMonths: .twelveMonths(endingWith: month)
    }
  }

  /// One step back or forward: a month, a year; twelve months slide by one month, so the
  /// window of a year can be moved month by month.
  func stepped(by direction: Int) -> AnalyticsPeriod {
    switch kind {
    case .month, .twelveMonths:
      AnalyticsPeriod(kind: kind, month: month.adding(months: direction))
    case .year:
      AnalyticsPeriod(kind: kind, month: month.adding(months: 12 * direction))
    }
  }

  /// The same anchor seen as another kind: September as a month, as 2026, as the twelve
  /// months to September.
  func with(kind: Kind) -> AnalyticsPeriod {
    AnalyticsPeriod(kind: kind, month: month)
  }

  /// A step forward never goes past the period that holds today: there is nothing there.
  /// The anchor decides, not the start of the range — twelve months that end in October
  /// begin long before today and would still be eleven months that have not come.
  func canStepForward(today: DateOnly) -> Bool {
    let next = stepped(by: 1)
    return kind == .year ? next.month.year <= today.year : next.month <= today.monthKey
  }

  /// A year chosen in the popover: anchored on its December, or on the month of today for
  /// the current year, as «Текущий» does. Seen as twelve months, a past year is itself.
  static func year(_ year: Int, today: DateOnly) -> AnalyticsPeriod {
    AnalyticsPeriod(kind: .year, month: MonthKey(year: year, month: 12)).clamped(to: today)
  }

  /// The same period with its anchor no later than the month of today. A year stepped
  /// forward from December, or a text stored before, would otherwise open a month that has
  /// not come once it is seen as a month or as twelve months.
  func clamped(to today: DateOnly) -> AnalyticsPeriod {
    AnalyticsPeriod(kind: kind, month: min(month, today.monthKey))
  }

  /// The period holds today already: «Текущий» has nothing to do.
  func isCurrent(today: DateOnly) -> Bool {
    kind == .year ? month.year == today.year : month == today.monthKey
  }

  /// «month:2026-09», «year:2026-09», «twelveMonths:2026-09».
  var storage: String { "\(kind.rawValue):\(month.iso)" }

  init?(storage: String) {
    let pieces = storage.split(separator: ":", maxSplits: 1).map(String.init)
    guard pieces.count == 2, let kind = Kind(rawValue: pieces[0]),
      let month = MonthKey(iso: pieces[1])
    else { return nil }
    self.init(kind: kind, month: month)
  }
}
