import Foundation
import Observation

/// The tabs of the phone, in the order they stand: the three main sections of the Mac sidebar
/// that carry a day-to-day use (Overview, Operations, Planning), the accounts, and «Ещё» with
/// everything else. On an iPad the same tabs get more room and nothing else.
enum PhoneTab: String, Hashable, CaseIterable, Sendable {
  case overview, operations, planning, accounts, more
}

/// What «Ещё» pushes: the sections that did not fit into a tab, and the list of the settings.
enum MoreDestination: Hashable, Sendable {
  case debts, calendar, capital, settings, conflicts
}

/// Where a request to show something lands on the phone.
struct PhoneRoute: Equatable, Sendable {
  var tab: PhoneTab
  /// The screen «Ещё» pushes, when the route goes there.
  var more: MoreDestination?
  /// The account or group «Счета» shows, when the route goes there.
  var account: SidebarItem?

  init(tab: PhoneTab, more: MoreDestination? = nil, account: SidebarItem? = nil) {
    self.tab = tab
    self.more = more
    self.account = account
  }
}

/// How the sidebar of the Mac maps onto the tabs of the phone. The shared screens ask for a
/// section by its shortcut number or for a sidebar item, exactly as they do on the Mac
/// (`.selectSection`, `.openSidebarItem`); the phone root listens and goes where this says.
enum PhoneNavigation {
  static func route(forSection section: MainWindow.Section) -> PhoneRoute {
    switch section {
    case .overview: PhoneRoute(tab: .overview)
    case .operations: PhoneRoute(tab: .operations)
    case .planning: PhoneRoute(tab: .planning)
    case .debts: PhoneRoute(tab: .more, more: .debts)
    case .calendar: PhoneRoute(tab: .more, more: .calendar)
    case .capital: PhoneRoute(tab: .more, more: .capital)
    }
  }

  /// ⌘1 … ⌘6 of the Mac: the number `.selectSection` carries.
  static func route(forShortcutIndex index: Int) -> PhoneRoute? {
    MainWindow.Section.allCases.first { $0.shortcutIndex == index }.map(route(forSection:))
  }

  static func route(forItem item: SidebarItem) -> PhoneRoute {
    switch item {
    case .section(let section): route(forSection: section)
    case .account, .group, .allAccounts: PhoneRoute(tab: .accounts, account: item)
    }
  }
}

/// Where the phone is: the tab, what «Ещё» has pushed, what «Счета» shows, and the screen that
/// covers everything (Analytics, Reports, «Что если…»). One instance per root; the screens ask
/// it by notification, and a test drives it without a view.
@MainActor
@Observable
final class PhoneRouter {
  var tab: PhoneTab = .overview
  var morePath: [MoreDestination] = []
  var accountsSelection: SidebarItem?
  /// The cover over the tabs, if any.
  var cover: AppScreen?

  init() {}

  func open(_ route: PhoneRoute) {
    tab = route.tab
    if let more = route.more {
      morePath = [more]
    } else if route.tab == .more {
      morePath = []
    }
    if let account = route.account { accountsSelection = account }
  }

  func open(section: MainWindow.Section) { open(PhoneNavigation.route(forSection: section)) }

  func open(item: SidebarItem) { open(PhoneNavigation.route(forItem: item)) }

  /// `.selectSection`: the number of a section; one the phone does not know is ignored.
  func open(shortcutIndex: Int) {
    if let route = PhoneNavigation.route(forShortcutIndex: shortcutIndex) { open(route) }
  }

  /// A window of the Mac: a cover here, except the settings, which are a list in «Ещё».
  func open(screen: AppScreen) {
    switch screen {
    case .settings:
      cover = nil
      open(PhoneRoute(tab: .more, more: .settings))
    case .whatIf:
      // «Что если…» belongs to Planning; it covers whichever tab asked.
      cover = screen
    case .analytics, .reports:
      cover = screen
    }
  }

  func closeCover() { cover = nil }
}
