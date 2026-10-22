import AppCore
import Foundation

/// The ready-made pairs of one tap, as the chooser lists them, and «свой диапазон».
enum ComparisonPairKind: String, CaseIterable, Identifiable, Hashable, Sendable {
  case monthToPreviousMonth
  case monthToSameMonthLastYear
  case quarterToPreviousQuarter
  case quarterToSameQuarterLastYear
  case eventToUsualMonth
  case custom

  var id: String { rawValue }
}

/// What the owner chose on the comparison card: the kind of pair, the month it hangs on (the
/// month of the toolbar), the event, and the two ranges of a custom pair. A plain value, so
/// every choice is tested without a window and is the key of the calculation.
struct ComparisonSetup: Hashable, Sendable {
  var kind: ComparisonPairKind = .monthToPreviousMonth
  var dimension: ComparisonDimension = .category
  var choice: ComparisonChoice = .automatic
  var eventId: UUID?
  var customCurrent: DayRange
  var customBaseline: DayRange

  /// A fresh setup for `anchor`: the custom ranges start as that month and the one before.
  init(anchor: MonthKey) {
    customCurrent = DayRange(anchor.firstDay, anchor.lastDay)
    customBaseline = DayRange(anchor.previous.firstDay, anchor.previous.lastDay)
  }

  /// The pair to count for `anchor`, or `nil` while the choice is not complete: an event pair
  /// with no event, a custom range that ends before it begins.
  func pair(anchor: MonthKey, events: [Event]) -> ComparisonPair? {
    let quarter = (anchor.month - 1) / 3 + 1
    switch kind {
    case .monthToPreviousMonth:
      return .monthToPreviousMonth(anchor)
    case .monthToSameMonthLastYear:
      return .monthToSameMonthLastYear(anchor)
    case .quarterToPreviousQuarter:
      return .quarterToPreviousQuarter(year: anchor.year, quarter: quarter)
    case .quarterToSameQuarterLastYear:
      return .quarterToSameQuarterLastYear(year: anchor.year, quarter: quarter)
    case .eventToUsualMonth:
      guard let event = events.first(where: { $0.id == eventId && !$0.archived }) else {
        return nil
      }
      return .eventToUsualMonth(event)
    case .custom:
      guard !customCurrent.isEmpty, !customBaseline.isEmpty else { return nil }
      return .custom(current: customCurrent, baseline: customBaseline)
    }
  }

  /// The events a pair can start from: live ones, the latest first.
  static func choosableEvents(_ events: [Event]) -> [Event] {
    events.filter { !$0.archived }.sorted { $0.startDate > $1.startDate }
  }

  /// The event pair starts on the latest event until the owner picks another.
  mutating func chooseDefaultEvent(from events: [Event]) {
    if eventId == nil || !events.contains(where: { $0.id == eventId && !$0.archived }) {
      eventId = Self.choosableEvents(events).first?.id
    }
  }
}
