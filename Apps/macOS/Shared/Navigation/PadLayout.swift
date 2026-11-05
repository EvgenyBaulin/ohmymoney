import Foundation

/// How the sidebar of an iPad stands at a window width. The sizes come from the iPad frames of
/// the design: wider than 1100 pt the panel is always there (a button hides it), from 600 to
/// 1100 pt it lies over the content when asked for, and narrower than 600 pt it is the first
/// screen — a list of the sections — and a section opens with a way back.
enum PadSidebarMode: Equatable, Sendable {
  case permanent
  case overlay
  case firstScreen
}

enum PadLayout {
  /// The width of the sidebar of the sections and of the one of the settings.
  static let sidebarWidth: Double = 250
  static let settingsSidebarWidth: Double = 300
  /// A window wider than this keeps the panel on screen.
  static let permanentAbove: Double = 1100
  /// A window narrower than this turns the panel into the first screen.
  static let overlayFrom: Double = 600
  /// The inspector stands to the right of the content from this width.
  static let inspectorFrom: Double = 1194
  /// The narrowest tile of Overview.
  static let minimumTileWidth: Double = 300

  static func mode(forWidth width: Double) -> PadSidebarMode {
    if width > permanentAbove { return .permanent }
    return width >= overlayFrom ? .overlay : .firstScreen
  }

  static func showsInspector(forWidth width: Double) -> Bool { width >= inspectorFrom }

  /// What is left of the window for the content: the permanent panel takes its width, an
  /// overlay one and the first screen take none.
  static func contentWidth(forWidth width: Double) -> Double {
    mode(forWidth: width) == .permanent ? width - sidebarWidth : width
  }

  /// Tiles of Overview in a row: 3 at 1366, 1194 and 1024, 2 at 1133, 834 and 744, one in a
  /// window of the first screen's narrowness. A tile is never narrower than 300 pt.
  static func overviewColumns(forWidth width: Double) -> Int {
    switch mode(forWidth: width) {
    case .firstScreen: return 1
    case .overlay: return width >= 1000 ? 3 : 2
    case .permanent: return width >= inspectorFrom ? 3 : 2
    }
  }

  /// The rows of the tools sheet: what the phone keeps in «Ещё» besides the sections and the
  /// settings, which the sidebar carries itself.
  static func tools(tripIsOn: Bool, hasConflicts: Bool) -> [MoreRow] {
    let menu = MoreMenu.make(more: [], tripIsOn: tripIsOn, hasConflicts: hasConflicts)
    return (menu.sections + menu.app).filter { row in
      switch row {
      case .section, .purchases, .settings: false
      default: true
      }
    }
  }
}

/// The sections of the iPad sidebar, in the order of the design (and of the Mac sidebar).
enum PadSection: String, CaseIterable, Identifiable, Sendable {
  case overview, operations, planning, calendar, capital, debts, purchases, analytics, reports

  var id: String { rawValue }

  var titleKey: String {
    switch self {
    case .overview: "section.overview"
    case .operations: "section.operations"
    case .planning: "section.planning"
    case .calendar: "section.calendar"
    case .capital: "section.capital"
    case .debts: "section.debts"
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
    case .calendar: "calendar"
    case .capital: "chart.bar"
    case .debts: "creditcard"
    case .purchases: "bag"
    case .analytics: "chart.xyaxis.line"
    case .reports: "tablecells"
    }
  }

  /// Where the router goes for this section.
  var route: PhoneRoute {
    switch self {
    case .overview: PhoneRoute(tab: .overview)
    case .operations: PhoneRoute(tab: .operations)
    case .planning: PhoneRoute(tab: .planning)
    case .calendar: PhoneRoute(tab: .more, more: .calendar)
    case .capital: PhoneRoute(tab: .more, more: .capital)
    case .debts: PhoneRoute(tab: .more, more: .debts)
    case .purchases: PhoneRoute(tab: .more, more: .purchases)
    case .analytics: PhoneRoute(tab: .more, more: .analytics)
    case .reports: PhoneRoute(tab: .more, more: .reports)
    }
  }
}

extension PhoneRouter {
  /// The section of the sidebar the screen on view is, if it is one (accounts, the settings and
  /// «Что если…» are none).
  var padSection: PadSection? {
    switch tab {
    case .overview: return .overview
    case .operations: return .operations
    case .planning: return .planning
    case .accounts: return nil
    case .more:
      switch morePath.last {
      case .calendar: return .calendar
      case .capital: return .capital
      case .debts: return .debts
      case .purchases: return .purchases
      case .analytics: return .analytics
      case .reports: return .reports
      case .settings, .whatIf, .conflicts, nil: return nil
      }
    }
  }

  /// The settings are a screen of their own on an iPad, with a sidebar of their own.
  var showsSettingsScreen: Bool { tab == .more && morePath.last == .settings }

  func open(pad section: PadSection) { open(section.route) }

  /// The tab whose entry line the screen on view hosts. An iPad has no tab for Calendar,
  /// Capital, Debts, Purchases, Analytics and Reports, but they carry the line like the
  /// others; the settings, «Что если…» and the conflicts carry none (`.more`).
  var padEntryHost: PhoneTab {
    guard tab == .more else { return tab }
    return padSection == nil ? .more : .overview
  }
}
