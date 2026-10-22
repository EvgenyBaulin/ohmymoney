import Foundation

extension NavItem {
  /// Where the phone goes for this section: its own tab, a screen «Ещё» pushes, or (for the two
  /// windows of the Mac) a cover. Goals live in Planning, so they open its tab.
  var route: PhoneRoute? {
    switch self {
    case .overview: PhoneRoute(tab: .overview)
    case .operations: PhoneRoute(tab: .operations)
    case .planning, .goals: PhoneRoute(tab: .planning)
    case .accounts: PhoneRoute(tab: .accounts)
    case .calendar: PhoneRoute(tab: .more, more: .calendar)
    case .capital: PhoneRoute(tab: .more, more: .capital)
    case .debts: PhoneRoute(tab: .more, more: .debts)
    case .analytics: PhoneRoute(tab: .more, more: .analytics)
    case .reports: PhoneRoute(tab: .more, more: .reports)
    }
  }

  /// The page of «Ещё» that shows this section, when it has none of its own tab.
  var moreDestination: MoreDestination? {
    switch self {
    case .calendar: .calendar
    case .capital: .capital
    case .debts: .debts
    case .analytics: .analytics
    case .reports: .reports
    default: nil
    }
  }

  /// The window of the Mac this section is, when it is one.
  var screen: AppScreen? {
    switch self {
    case .analytics: .analytics
    case .reports: .reports
    default: nil
    }
  }
}

extension PhoneRouter {
  /// Goes to a section of the bar or of «Ещё».
  func open(nav item: NavItem) {
    if let route = item.route {
      cover = nil
      open(route)
    } else if let screen = item.screen {
      open(screen: screen)
    }
  }

  /// The section the screen on view stands for, or `nil` when it is «Ещё» itself (or one of its
  /// pages that is no section, such as the settings).
  var current: NavItem? {
    switch tab {
    case .overview: return .overview
    case .operations: return .operations
    case .planning: return .planning
    case .accounts: return .accounts
    case .more:
      switch morePath.last {
      case .debts: return .debts
      case .calendar: return .calendar
      case .capital: return .capital
      case .analytics: return .analytics
      case .reports: return .reports
      case .settings, .whatIf, .conflicts, nil: return nil
      }
    }
  }

  /// Whether the «Ещё» button of a bar showing `visible` is the lit one: the screen on view is
  /// not one of the sections the bar carries.
  func isMoreLit(visible: [NavItem]) -> Bool {
    guard let current else { return true }
    return !visible.contains(current)
  }
}
