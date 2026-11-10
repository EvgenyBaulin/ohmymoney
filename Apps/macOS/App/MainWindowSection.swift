import Foundation

extension MainWindow {
  enum Section: String, CaseIterable, Identifiable {
    // The order of the sidebar, and of ⌘1 … ⌘9 with it.
    case overview, operations, planning, calendar, capital, debts, purchases, analytics, reports

    var id: String { rawValue }

    /// Decision 0583 limits the floating line; the form at the right stays on every section.
    var showsEntryLine: Bool {
      switch self {
      case .planning, .reports: false
      case .overview, .operations, .calendar, .capital, .debts, .purchases, .analytics: true
      }
    }

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

    /// The icons of the sidebar of the design, in their SF Symbols.
    var symbol: String {
      switch self {
      case .overview: "house"
      case .operations: "list.bullet"
      case .planning: "chart.line.uptrend.xyaxis"
      case .debts: "banknote"
      case .calendar: "calendar"
      case .capital: "chart.bar"
      case .purchases: "bag"
      case .analytics: "chart.pie"
      case .reports: "doc.text"
      }
    }

    /// ⌘1 … ⌘9: the place in the sidebar, counted from 1. The order and the shortcuts are one
    /// thing, so they cannot drift apart.
    var shortcutIndex: Int {
      (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
  }
}
