import Foundation

extension MainWindow {
  enum Section: String, CaseIterable, Identifiable {
    // The order of the sidebar, and of ⌘1 … ⌘9 with it.
    case overview, operations, planning, calendar, capital, debts, purchases, analytics, reports

    var id: String { rawValue }

    /// `--section` names a section by its raw value; «spending», the name of «Операции» when it
    /// was «Траты», still finds it.
    static func named(_ name: String) -> Section? {
      name == "spending" ? .operations : Section(rawValue: name)
    }

    var titleKey: String {
      switch self {
      case .overview: "section.overview"
      case .operations: "section.operations"
      case .planning: "section.planning"
      case .debts: "section.debts"
      case .calendar: "section.calendar"
      case .capital: "section.capital"
      case .purchases: "section.purchases"
      case .analytics: "window.analytics"
      case .reports: "window.reports"
      }
    }

    var symbol: String {
      switch self {
      case .overview: "house"
      case .operations: "list.bullet"
      case .planning: "calendar.badge.clock"
      case .debts: "creditcard"
      case .calendar: "calendar"
      case .capital: "chart.bar"
      case .purchases: "bag"
      case .analytics: "chart.xyaxis.line"
      case .reports: "tablecells"
      }
    }

    /// ⌘1 … ⌘9: the place in the sidebar, counted from 1. The order and the shortcuts are one
    /// thing, so they cannot drift apart.
    var shortcutIndex: Int {
      (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
  }
}
