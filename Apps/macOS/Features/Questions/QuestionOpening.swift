import AppCore
import Foundation

extension Notification.Name {
  /// Opens the command palette over the window that has the keyboard (⌘K, the button of the
  /// phone).
  static let showCommandPalette = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.showCommandPalette")
  /// Opens the sheet of one question, for the owner who has no question line to hand.
  static let showQuestionSheet = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.showQuestionSheet")
  /// «Операции» with a filter set from outside: the object is an `OperationsFilterRequest`.
  /// The window that owns the screen's state receives it, so a request made while the screen
  /// is not on show is not lost.
  static let applyOperationsFilter = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.applyOperationsFilter")
  /// A palette command run from a menu item: the object is the id of the palette entry.
  static let runPaletteCommand = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.runPaletteCommand")
}

/// What «Операции» is asked to show: the filter of the core, and the columns of a saved filter
/// when it has its own.
struct OperationsFilterRequest: Sendable {
  var filter: EntryFilter
  /// The text of `operations.columns` to set, or `nil` to leave the columns as they are.
  var columns: String?
}

extension TransactionFilters {
  /// The filters of the screen that show what `filter` finds. A whole current month, last
  /// month or this year is the period's own choice; any other span is the custom range.
  init(_ filter: EntryFilter, today: DateOnly, tree: [CoreKit.Category] = []) {
    self.init(today: today)
    setKind(filter.kind, tree: tree)
    setCategory(filter.categoryId)
    subcategoryId = filter.subcategoryId
    quality = filter.quality
    forWhom = filter.forWhom
    personId = filter.personId
    placeId = filter.placeId
    eventId = filter.eventId
    paymentMethodId = filter.paymentMethodId
    cardId = filter.cardId
    status = filter.reimbursementStatus
    search = filter.text
    if let span = filter.period {
      if span == Period.month(today.monthKey) {
        period = .thisMonth
      } else if span == Period.month(today.monthKey.previous) {
        period = .lastMonth
      } else if span == Period.year(today.year) {
        period = .thisYear
      } else {
        customStart = span.range.start
        customEnd = span.range.end
        period = .custom
      }
    }
  }

  /// The screen's filters as a saved filter: the period kept as words when it is one of the
  /// three the screen names and the owner did not ask for the days (`floating`), as days
  /// otherwise; no period at all for «Всё время».
  func saved(
    named name: String, floating: Bool = true, today: DateOnly, columns: [String]? = nil
  ) -> SavedFilter {
    let savedPeriod: SavedPeriod?
    switch period {
    case .allTime: savedPeriod = nil
    case .thisMonth: savedPeriod = SavedPeriod.saving(.thisMonth, floating: floating, today: today)
    case .lastMonth: savedPeriod = SavedPeriod.saving(.lastMonth, floating: floating, today: today)
    case .thisYear: savedPeriod = SavedPeriod.saving(.thisYear, floating: floating, today: today)
    case .custom:
      savedPeriod = .fixed(start: min(customStart, customEnd), end: max(customStart, customEnd))
    }
    return SavedFilter(
      name: name, filter: entryFilter(today: today), period: savedPeriod, columns: columns)
  }

  /// Whether the period of the screen is one that can float: then the owner is asked which
  /// of the two he wants.
  var periodCanFloat: Bool {
    switch period {
    case .thisMonth, .lastMonth, .thisYear: true
    case .allTime, .custom: false
    }
  }
}

/// How an answer or a saved view reaches the other screens of the app.
@MainActor
enum QuestionOpening {
  /// The Analytics period an answer's period is shown as. Analytics knows months, years and
  /// twelve months; any other span is shown as the month it ends in, and the exact days are the
  /// operations list's to show.
  static func analyticsPeriod(for period: Period, today: DateOnly) -> AnalyticsPeriod {
    let target: AnalyticsPeriod
    switch period.kind {
    case .month(let month): target = AnalyticsPeriod(kind: .month, month: month)
    case .year(let year): target = AnalyticsPeriod.year(year, today: today)
    case .twelveMonths(let last): target = AnalyticsPeriod(kind: .twelveMonths, month: last)
    case .days: target = AnalyticsPeriod(kind: .month, month: period.range.end.monthKey)
    }
    return target.clamped(to: today)
  }

  /// Sets the Analytics window to the period and the section of the answer, so opening it shows
  /// the same figure. The window reads these preferences when it opens and while it is open.
  static func prepareAnalytics(
    period: Period, today: DateOnly, defaults: UserDefaults = .standard
  ) {
    defaults.set(
      analyticsPeriod(for: period, today: today).storage, forKey: AnalyticsWindow.periodKey)
    defaults.set(AnalyticsSection.overview.rawValue, forKey: AnalyticsWindow.sectionKey)
  }

  /// Sets the Reports window to a saved report: the table, the grouping and the period as of
  /// today.
  static func prepareReports(
    _ report: SavedReport, today: DateOnly, defaults: UserDefaults = .standard
  ) {
    let target = analyticsPeriod(for: report.period.resolved(today: today), today: today)
    defaults.set(report.kind.rawValue, forKey: ReportsSelection.tableKey)
    defaults.set(report.grouping.rawValue, forKey: ReportsSelection.groupingKey)
    defaults.set(target.storage, forKey: ReportsSelection.periodKey)
  }

  /// Asks the window that owns «Операции» to show `request`, and to come to that screen.
  static func showOperations(_ request: OperationsFilterRequest) {
    NotificationCenter.default.post(name: .applyOperationsFilter, object: request)
  }
}
