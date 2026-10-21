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

  func testTheWindowsOfTheMacAreCoversAndTheSettingsAreAList() {
    let router = PhoneRouter()
    router.open(screen: .analytics)
    XCTAssertEqual(router.cover, .analytics)
    router.open(screen: .reports)
    XCTAssertEqual(router.cover, .reports)
    router.open(screen: .whatIf)
    XCTAssertEqual(router.cover, .whatIf)
    router.closeCover()
    XCTAssertNil(router.cover)
    router.open(screen: .analytics)
    router.open(screen: .settings)
    XCTAssertNil(router.cover, "the settings are not a cover: they take it down")
    XCTAssertEqual(router.tab, .more)
    XCTAssertEqual(router.morePath, [.settings])
  }

  func testThePhoneHasTheFiveTabsInOrder() {
    XCTAssertEqual(
      PhoneTab.allCases, [.overview, .operations, .planning, .accounts, .more])
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
