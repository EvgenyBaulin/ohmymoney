import SwiftUI
import XCTest

#if os(macOS)
  @testable import OhMyMoney
#else
  @testable import OhMyMoney
#endif

/// Where the phone goes when a shared screen asks for a section, an account or a window of the
/// Mac, and which question of the launch stands first. Plain logic: it runs on the Mac and
/// compiles into the iPhone tests too.
@MainActor
final class PhoneNavigationTests: XCTestCase {
  func testEverySectionOfTheMacSidebarHasAPlaceOnThePhone() {
    for section in MainWindow.Section.allCases {
      let route = PhoneNavigation.route(forSection: section)
      switch section {
      case .overview: XCTAssertEqual(route, PhoneRoute(tab: .overview))
      case .operations: XCTAssertEqual(route, PhoneRoute(tab: .operations))
      case .planning: XCTAssertEqual(route, PhoneRoute(tab: .planning))
      case .debts: XCTAssertEqual(route, PhoneRoute(tab: .more, more: .debts))
      case .calendar: XCTAssertEqual(route, PhoneRoute(tab: .more, more: .calendar))
      case .capital: XCTAssertEqual(route, PhoneRoute(tab: .more, more: .capital))
      case .purchases: XCTAssertEqual(route, PhoneRoute(tab: .more, more: .purchases))
      }
    }
  }

  func testTheNumbersOfTheMacShortcutsMapLikeTheSections() {
    for section in MainWindow.Section.allCases {
      XCTAssertEqual(
        PhoneNavigation.route(forShortcutIndex: section.shortcutIndex),
        PhoneNavigation.route(forSection: section))
    }
    XCTAssertNil(PhoneNavigation.route(forShortcutIndex: 0))
    XCTAssertNil(PhoneNavigation.route(forShortcutIndex: 99))
  }

  func testAnAccountOrAGroupIsShownByTheAccountsTab() {
    let id = UUID()
    XCTAssertEqual(
      PhoneNavigation.route(forItem: .account(id)),
      PhoneRoute(tab: .accounts, account: .account(id)))
    XCTAssertEqual(
      PhoneNavigation.route(forItem: .group(id)),
      PhoneRoute(tab: .accounts, account: .group(id)))
    XCTAssertEqual(
      PhoneNavigation.route(forItem: .allAccounts),
      PhoneRoute(tab: .accounts, account: .allAccounts))
    XCTAssertEqual(
      PhoneNavigation.route(forItem: .section(.debts)), PhoneRoute(tab: .more, more: .debts))
  }

  func testTheRouterFollowsARouteAndForgetsWhatMoreHadPushed() {
    let router = PhoneRouter()
    router.open(section: .capital)
    XCTAssertEqual(router.tab, .more)
    XCTAssertEqual(router.morePath, [.capital])
    router.open(section: .planning)
    XCTAssertEqual(router.tab, .planning)
    // «Ещё» itself, asked for plainly, comes back to its list.
    router.open(PhoneRoute(tab: .more))
    XCTAssertEqual(router.tab, .more)
    XCTAssertEqual(router.morePath, [])
  }

  func testAnAccountRequestLeavesTheSelectionForTheTab() {
    let router = PhoneRouter()
    let id = UUID()
    router.open(item: .account(id))
    XCTAssertEqual(router.tab, .accounts)
    XCTAssertEqual(router.accountsSelection, .account(id))
  }

  func testTheWindowsOfTheMacArePagesOfMoreNotCovers() {
    let router = PhoneRouter()
    router.open(screen: .analytics)
    XCTAssertNil(router.cover, "Analytics is a page of «Ещё», not a window over the tabs")
    XCTAssertEqual(router.tab, .more)
    XCTAssertEqual(router.morePath, [.analytics])
    XCTAssertEqual(router.current, .analytics)
    router.open(screen: .reports)
    XCTAssertEqual(router.morePath.last, .reports)
    router.open(screen: .whatIf)
    XCTAssertEqual(router.morePath.last, .whatIf)
    router.open(screen: .settings)
    XCTAssertNil(router.cover)
    XCTAssertEqual(router.tab, .more)
    XCTAssertEqual(router.morePath.last, .settings)
  }

  func testThePhoneHasTheFiveTabsInOrder() {
    XCTAssertEqual(
      PhoneTab.allCases, [.overview, .operations, .planning, .accounts, .more])
  }

  // MARK: The bar

  func testTheIPadBarGrowsWithTheWindow() {
    let expected: [(Double, Int)] = [
      (744, 4), (834, 5), (1024, 7), (1133, 8), (1194, 8), (1366, 10),
    ]
    for (width, slots) in expected {
      let layout = NavLayout.make(width: width, isPad: true)
      XCTAssertEqual(layout.placement, .top, "\(width)")
      XCTAssertEqual(layout.visible.count, slots, "\(width)")
      XCTAssertEqual(layout.visible + layout.more, NavItem.allCases, "\(width)")
      XCTAssertLessThanOrEqual(
        NavLayout.padBarWidth(slots: layout.visible.count), width * 0.5, "\(width)")
    }
  }

  func testTheIPadSectionsAppearInTheAgreedOrder() {
    XCTAssertEqual(
      NavItem.allCases,
      [
        .overview, .operations, .planning, .accounts, .calendar, .capital, .debts, .analytics,
        .goals, .reports,
      ])
    let layout = NavLayout.make(width: 834, isPad: true)
    XCTAssertEqual(
      layout.visible, [.overview, .operations, .planning, .accounts, .calendar])
    XCTAssertEqual(layout.more.first, .capital)
  }

  func testAnIPadWindowThatShrinksLosesSectionsAndGetsThemBack() {
    var widths = [1366.0, 1024, 834, 744, 1024, 1366]
    var counts: [Int] = []
    while !widths.isEmpty {
      counts.append(NavLayout.make(width: widths.removeFirst(), isPad: true).visible.count)
    }
    XCTAssertEqual(counts, [10, 7, 5, 4, 7, 10])
  }

  func testANarrowIPadWindowWearsThePhoneBar() {
    for width in [320.0, 507, 639, 743] {
      let layout = NavLayout.make(width: width, isPad: true)
      XCTAssertEqual(layout.placement, .bottom, "\(width)")
      XCTAssertEqual(layout.visible, NavItem.defaultPhoneTabs, "\(width)")
    }
  }

  func testThePhoneBarHasTheChosenFourAndTheRestInMore() {
    for width in [320.0, 390, 430, 744] {
      let layout = NavLayout.make(width: width, isPad: false)
      XCTAssertEqual(layout.placement, .bottom)
      XCTAssertEqual(layout.visible, [.overview, .operations, .planning, .accounts])
      XCTAssertEqual(layout.barCount, 5)
      XCTAssertEqual(layout.more.count, 6)
    }
    let chosen: [NavItem] = [.accounts, .debts, .overview, .goals]
    let layout = NavLayout.make(width: 390, isPad: false, phoneTabs: chosen)
    XCTAssertEqual(layout.visible, chosen)
    XCTAssertFalse(layout.more.contains(.debts))
    XCTAssertTrue(layout.more.contains(.operations))
  }

  func testABrokenChoiceOfTabsFallsBackToTheDefault() {
    let layout = NavLayout.make(width: 390, isPad: false, phoneTabs: [.overview, .overview])
    XCTAssertEqual(layout.visible, NavItem.defaultPhoneTabs)
  }

  func testTheChoiceOfTabsIsKeptAsFourDifferentSections() {
    let defaults = UserDefaults(suiteName: "tests.phone.tabs.\(UUID().uuidString)")!
    XCTAssertEqual(PhoneTabsPreference.load(defaults), NavItem.defaultPhoneTabs)
    let chosen: [NavItem] = [.capital, .overview, .reports, .debts]
    XCTAssertTrue(PhoneTabsPreference.save(chosen, to: defaults))
    XCTAssertEqual(PhoneTabsPreference.load(defaults), chosen)
    XCTAssertEqual(defaults.string(forKey: "phone.tabs"), "capital,overview,reports,debts")
    XCTAssertFalse(PhoneTabsPreference.save([.overview], to: defaults))
    XCTAssertFalse(PhoneTabsPreference.save([.overview, .overview, .debts, .goals], to: defaults))
    XCTAssertEqual(PhoneTabsPreference.load(defaults), chosen, "a refused save changes nothing")
    for damaged in ["", "overview", "overview,nonsense,debts,goals", "a,b,c,d"] {
      XCTAssertEqual(PhoneTabsPreference.decode(damaged), NavItem.defaultPhoneTabs, damaged)
    }
  }

  func testEverySectionOfTheBarHasASymbolAndATitle() {
    for item in NavItem.allCases {
      XCTAssertFalse(item.symbol.isEmpty)
      XCTAssertFalse(item.titleKey.isEmpty)
    }
    XCTAssertEqual(
      Array(NavItem.allCases.prefix(4)).map(\.symbol),
      ["house", "list.bullet", "calendar", "wallet.bifold"])
  }

  func testTheBarOpensEverySectionWhereItBelongs() {
    let router = PhoneRouter()
    router.open(nav: .debts)
    XCTAssertEqual(router.tab, .more)
    XCTAssertEqual(router.morePath, [.debts])
    XCTAssertEqual(router.current, .debts)
    router.open(nav: .accounts)
    XCTAssertEqual(router.current, .accounts)
    router.open(nav: .goals)
    XCTAssertEqual(router.tab, .planning)
    router.open(nav: .analytics)
    XCTAssertNil(router.cover)
    XCTAssertEqual(router.tab, .more)
    XCTAssertEqual(router.current, .analytics)
    router.open(nav: .overview)
    XCTAssertNil(router.cover)
    XCTAssertEqual(router.current, .overview)
  }

  func testMoreIsLitWhenTheScreenIsNotOnTheBar() {
    let router = PhoneRouter()
    let bar = NavItem.defaultPhoneTabs
    XCTAssertFalse(router.isMoreLit(visible: bar))
    router.open(nav: .capital)
    XCTAssertTrue(router.isMoreLit(visible: bar))
    // The same page, once it has a place on the bar of an iPad, lights its own button.
    XCTAssertFalse(router.isMoreLit(visible: bar + [.capital]))
    router.open(PhoneRoute(tab: .more))
    XCTAssertNil(router.current)
    XCTAssertTrue(router.isMoreLit(visible: bar))
    router.open(screen: .settings)
    XCTAssertTrue(router.isMoreLit(visible: bar))
  }

  func testMoreListsWhatTheBarDoesNotCarry() {
    let menu = MoreMenu.make(more: NavLayout.make(width: 390, isPad: false).more, tripIsOn: false)
    XCTAssertEqual(
      menu.sections.prefix(6),
      [
        .section(.calendar), .section(.capital), .section(.debts), .section(.analytics),
        .section(.goals), .section(.reports),
      ])
    XCTAssertTrue(menu.sections.contains(.whatIf))
    XCTAssertTrue(menu.sections.contains(.purchases), "«Покупки» has a row in «Ещё»")
    XCTAssertFalse(menu.sections.contains(.trip), "no trip, no row")
    XCTAssertEqual(menu.app, [.settings, .tour, .whatsNew, .problemReport])
    let travelling = MoreMenu.make(more: [], tripIsOn: true)
    XCTAssertTrue(travelling.sections.contains(.trip))
    XCTAssertFalse(travelling.sections.contains(.section(.calendar)))
  }

  func testTheSearchOfMoreIgnoresCaseAndYo() {
    let menu = MoreMenu.make(more: NavItem.allCases, tripIsOn: false)
    let titles: [MoreRow: String] = [
      .section(.reports): "Отчёты", .section(.debts): "Долги", .settings: "Настройки",
    ]
    func title(_ row: MoreRow) -> String { titles[row] ?? "—" }
    XCTAssertEqual(menu.filtered(by: "отчеты", title: title).sections, [.section(.reports)])
    XCTAssertEqual(menu.filtered(by: "ДОЛ", title: title).sections, [.section(.debts)])
    XCTAssertEqual(menu.filtered(by: "наст", title: title).app, [.settings])
    XCTAssertEqual(menu.filtered(by: "  ", title: title), menu)
    XCTAssertTrue(menu.filtered(by: "zzz", title: title).sections.isEmpty)
  }

  // MARK: Order of the questions

  func testNothingIsAskedWhileTheAppIsCovered() {
    var gate = LaunchGate()
    gate.covered = true
    gate.asksSetup = true
    XCTAssertNil(gate.current)
    XCTAssertFalse(gate.allowsReminders)
    XCTAssertFalse(gate.allowsProblemReport)
  }

  func testTheQuestionsComeInTheOrderOfTheMacWindow() {
    var gate = LaunchGate()
    gate.asksSetup = true
    gate.offersProblemReport = true
    gate.currenciesMissing = true
    gate.remindersCalculating = true
    XCTAssertEqual(gate.current, .accountSetup)
    gate.asksSetup = false
    XCTAssertEqual(gate.current, .problemReport)
    gate.offersProblemReport = false
    XCTAssertEqual(gate.current, .currencies)
    gate.currenciesMissing = false
    XCTAssertEqual(gate.current, .reminders)
    gate.remindersCalculating = false
    XCTAssertEqual(gate.current, .questions)
  }

  func testTheRemindersWaitForEverythingBeforeThem() {
    var gate = LaunchGate()
    XCTAssertTrue(gate.allowsReminders)
    gate.asksSetup = true
    XCTAssertFalse(gate.allowsReminders)
    gate = LaunchGate(offersProblemReport: true)
    XCTAssertFalse(gate.allowsReminders)
    gate = LaunchGate(currenciesMissing: true)
    XCTAssertFalse(gate.allowsReminders)
    gate = LaunchGate(remindersShown: true)
    XCTAssertFalse(gate.allowsReminders, "one sheet at a time")
  }

  func testTheLaterQuestionsWaitForTheReminders() {
    XCTAssertFalse(LaunchGate().questionsWait)
    XCTAssertTrue(LaunchGate(remindersShown: true).questionsWait)
    XCTAssertTrue(LaunchGate(remindersCalculating: true).questionsWait)
    XCTAssertTrue(LaunchGate(asksSetup: true).questionsWait)
    XCTAssertTrue(LaunchGate(offersProblemReport: true).questionsWait)
    XCTAssertTrue(LaunchGate(currenciesMissing: true).questionsWait)
  }

  func testTheReportOfferWaitsOnlyForTheSetup() {
    XCTAssertTrue(LaunchGate().allowsProblemReport)
    XCTAssertFalse(LaunchGate(asksSetup: true).allowsProblemReport)
    XCTAssertTrue(LaunchGate(currenciesMissing: true).allowsProblemReport)
  }

  func testTheHostCoverHoldsBackTheQuestionsThePrivacyLockHolds() {
    let lock = PrivacyLock(applies: false, defaults: nil)
    var asked = true
    XCTAssertTrue(lock.lets(asked))
    lock.hostCovers = true
    XCTAssertTrue(lock.isCovered)
    XCTAssertFalse(lock.lets(asked))
    let binding = lock.presenting(Binding(get: { asked }, set: { asked = $0 }))
    XCTAssertFalse(binding.wrappedValue)
    binding.wrappedValue = false
    XCTAssertTrue(asked, "what is written back while covered is dropped")
    lock.hostCovers = false
    XCTAssertTrue(lock.lets(asked))
  }
}
