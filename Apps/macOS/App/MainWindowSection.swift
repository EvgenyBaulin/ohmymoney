import Foundation

extension MainWindow {
  enum Section: String, CaseIterable, Identifiable {
    case overview, operations, planning, debts, calendar, capital

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
      }
    }

    /// ⌘1 / ⌘2 / ⌘3, the first three sections; «Операции», added
    /// after them, is ⌘4, «Календарь» ⌘5 and «Капитал» ⌘6.
    var shortcutIndex: Int {
      switch self {
      case .overview: 1
      case .planning: 2
      case .debts: 3
      case .operations: 4
      case .calendar: 5
      case .capital: 6
      }
    }
  }
}
