import AppCore
import Foundation

extension Notification.Name {
  /// Applies a saved filter to «Операции», or opens a saved report in Reports: the object is the
  /// id of the saved view.
  static let openSavedView = Notification.Name("io.github.EvgenyBaulin.ohmymoney.openSavedView")
  /// Asks for the name under which the filters of «Операции» are to be saved.
  static let saveOperationsFilter = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.saveOperationsFilter")
  /// Opens the list of saved filters and reports.
  static let manageSavedViews = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.manageSavedViews")
}

/// What a saved view says about itself, in words: «Расходы · Кафе · этот месяц».
@MainActor
enum SavedViewsText {
  static func summary(
    of filter: SavedFilter, names: AnalyticsNames, today: DateOnly, _ environment: AppEnvironment
  ) -> String {
    var parts: [String] = []
    if let kind = filter.kind {
      parts.append(environment.language("kind.\(kind.rawValue)"))
    }
    func named(_ id: UUID?) {
      if let id, let name = names[id]?.text { parts.append(name) }
    }
    named(filter.categoryId)
    named(filter.subcategoryId)
    named(filter.placeId)
    named(filter.personId)
    named(filter.eventId)
    named(filter.paymentMethodId)
    named(filter.cardId)
    let text = filter.text.trimmingCharacters(in: .whitespaces)
    if !text.isEmpty { parts.append("«\(text)»") }
    parts.append(period(filter.period, today: today, environment))
    return parts.joined(separator: " · ")
  }

  static func summary(
    of report: SavedReport, today: DateOnly, _ environment: AppEnvironment
  ) -> String {
    [
      ReportsText.title(of: report.kind, environment),
      ReportsText.title(of: report.grouping, environment),
      period(report.period, today: today, environment),
    ].joined(separator: " · ")
  }

  /// «этот месяц» for a period that moves, the days for one that does not, «за всё время»
  /// for none.
  static func period(
    _ period: SavedPeriod?, today: DateOnly, _ environment: AppEnvironment
  ) -> String {
    guard let period else { return QuestionsText.t("questions.saved.allTime", environment) }
    switch period {
    case .floating(let relative):
      return QuestionsText.title(of: relative, today: today, environment)
    case .fixed:
      return QuestionsText.title(of: period.resolved(today: today), environment)
    }
  }

  /// The words of a period kept as it is shown in Reports and Analytics: the current month is
  /// «this month» and moves, September 2025 does not.
  static func relativePeriod(for period: AnalyticsPeriod, today: DateOnly) -> RelativePeriod {
    let month = today.monthKey
    switch period.kind {
    case .month:
      if period.month == month { return .thisMonth }
      if period.month == month.previous { return .lastMonth }
      return .month(period.month)
    case .year:
      if period.month.year == today.year { return .thisYear }
      if period.month.year == today.year - 1 { return .lastYear }
      return .year(period.month.year)
    case .twelveMonths:
      if period.month == month { return .lastMonths(12) }
      let last = period.month
      return .range(last.adding(months: -11).firstDay, last.lastDay)
    }
  }
}
