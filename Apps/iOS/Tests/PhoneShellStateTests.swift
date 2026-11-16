import AppCore
import XCTest

@testable import OhMyMoney

/// The states and transitions of the shell of the phone, without a window: where a request
/// lands and what stays behind, when the round «+» and its line are up, which four sections the
/// owner can keep on the bar, and how a damaged setting reads. Corners the shared navigation
/// tests leave.
@MainActor
final class PhoneShellStateTests: XCTestCase {
  // MARK: Router

  func testAShortcutNumberThePhoneDoesNotKnowLeavesTheRouterWhereItWas() {
    let router = PhoneRouter()
    router.open(PhoneRoute(tab: .more, more: .debts))
    router.cover = .reports
    for index in [0, -1, 10, 99, Int.max, Int.min] {
      router.open(shortcutIndex: index)
      XCTAssertEqual(router.tab, .more, "\(index)")
      XCTAssertEqual(router.morePath, [.debts], "\(index)")
      XCTAssertEqual(router.cover, .reports, "\(index)")
    }
  }

  func testAMoreRouteWithoutAPageEmptiesThePathAndOneWithAPageReplacesIt() {
    let router = PhoneRouter()
    router.open(PhoneRoute(tab: .more, more: .capital))
    router.open(PhoneRoute(tab: .more, more: .settings))
    XCTAssertEqual(router.morePath, [.settings], "one page at a time, never a stack of requests")
    router.open(PhoneRoute(tab: .more))
    XCTAssertEqual(router.morePath, [])
    XCTAssertEqual(router.tab, .more)
  }

  func testAskingForTheSamePlaceTwiceIsTheSameAsOnce() {
    let router = PhoneRouter()
    router.open(PhoneRoute(tab: .more, more: .calendar))
    router.open(PhoneRoute(tab: .more, more: .calendar))
    XCTAssertEqual(router.morePath, [.calendar])
    router.open(section: .planning)
    router.open(section: .planning)
    XCTAssertEqual(router.tab, .planning)
  }

  func testEverySectionOfTheBarOrMoreIsLitWhereItsRequestLands() {
    for item in NavItem.allCases {
      let router = PhoneRouter()
      router.open(nav: item)
      // Goals live in Planning, which is the section they light.
      let expected: NavItem = item == .goals ? .planning : item
      XCTAssertEqual(router.current, expected, "\(item)")
      XCTAssertNil(router.cover, "\(item)")
    }
  }

  func testMoreIsLitExactlyWhenTheScreenIsNotOnTheChosenBar() {
    let router = PhoneRouter()
    let custom: [NavItem] = [.overview, .debts, .capital, .accounts]
    router.open(nav: .debts)
    XCTAssertFalse(router.isMoreLit(visible: custom), "debts are on this bar")
    XCTAssertTrue(router.isMoreLit(visible: NavItem.defaultPhoneTabs), "and not on the default")
    router.open(PhoneRoute(tab: .more, more: .settings))
    XCTAssertTrue(router.isMoreLit(visible: custom), "the settings are no section of any bar")
    router.open(PhoneRoute(tab: .more))
    XCTAssertTrue(router.isMoreLit(visible: custom))
    XCTAssertNil(router.current)
  }

  func testWindowsOfTheMacClearTheCoverBeforeGoingToTheirPage() {
    for screen in [AppScreen.settings, .whatIf, .analytics, .reports] {
      let router = PhoneRouter()
      router.cover = .reports
      router.open(screen: screen)
      XCTAssertNil(router.cover, "\(screen)")
      XCTAssertEqual(router.tab, .more, "\(screen)")
      XCTAssertEqual(router.morePath.count, 1, "\(screen)")
    }
  }

  func testSummariesOpenTheirOwnPageOnAPhoneAndReportsOnATablet() {
    let phone = PhoneRouter()
    phone.cover = .analytics
    phone.openSummaries(isPad: false)
    XCTAssertEqual(phone.morePath, [.summaries])
    XCTAssertNil(phone.cover)
    let pad = PhoneRouter()
    pad.openSummaries(isPad: true)
    XCTAssertEqual(pad.morePath, [.reports])
  }

  func testAnAccountRequestKeepsTheLastChoiceWhenTheNextOneNamesNone() {
    let router = PhoneRouter()
    router.open(item: .allAccounts)
    XCTAssertEqual(router.accountsSelection, .allAccounts)
    router.open(PhoneRoute(tab: .accounts))
    XCTAssertEqual(router.accountsSelection, .allAccounts)
    router.open(section: .overview)
    XCTAssertEqual(router.tab, .overview)
    XCTAssertEqual(router.accountsSelection, .allAccounts, "leaving the tab forgets nothing")
  }

  func testTheEntryHostIsChosenForEveryPlaceThePhoneCanBe() {
    let router = PhoneRouter()
    for tab in [PhoneTab.overview, .operations, .accounts] {
      router.open(PhoneRoute(tab: tab))
      XCTAssertEqual(router.phoneEntryHost, tab)
    }
    router.open(PhoneRoute(tab: .planning))
    XCTAssertEqual(router.phoneEntryHost, .more, "planning keeps its own tools, no line")
    for page in MoreDestination.allCases {
      router.open(PhoneRoute(tab: .more, more: page))
      let host = router.phoneEntryHost
      switch page {
      case .calendar, .capital, .debts, .purchases, .analytics:
        XCTAssertEqual(host, .overview, "\(page)")
      case .reports, .summaries, .settings, .whatIf, .conflicts:
        XCTAssertEqual(host, .more, "\(page)")
      }
    }
    router.open(PhoneRoute(tab: .more))
    XCTAssertEqual(router.phoneEntryHost, .more)
  }

  // MARK: The round «+» and its line

  func testNoEventAsksForTheKeyboardExceptThoseTheOwnerMakesOnTheLine() {
    for tab in PhoneTab.allCases {
      for event in [
        PhoneEntryEvent.saved, .escaped, .tappedOutside, .tabChanged(tab),
      ] {
        var state = PhoneEntryState(tab: tab)
        XCTAssertFalse(state.apply(event), "\(event) on \(tab)")
        XCTAssertFalse(state.isShown, "\(event) on \(tab)")
        XCTAssertFalse(PhoneEntryState.focusesLine(event))
      }
    }
    XCTAssertTrue(PhoneEntryState.focusesLine(.plusTapped))
    XCTAssertTrue(PhoneEntryState.focusesLine(.newEntryRequested))
  }

  func testMoreHasNeitherThePlusNorALineWhateverIsAskedOfIt() {
    var state = PhoneEntryState(tab: .more)
    XCTAssertFalse(state.showsPlus)
    XCTAssertFalse(state.apply(.plusTapped))
    XCTAssertFalse(state.apply(.newEntryRequested))
    XCTAssertFalse(state.isShown)
    XCTAssertFalse(state.shows(lineOf: .more))
  }

  func testOneLineAtATimeAndItStaysWithItsSection() {
    var state = PhoneEntryState(tab: .operations)
    XCTAssertTrue(state.showsPlus)
    XCTAssertTrue(state.apply(.plusTapped))
    XCTAssertTrue(state.shows(lineOf: .operations))
    XCTAssertFalse(state.shows(lineOf: .overview))
    XCTAssertFalse(state.showsPlus)
    XCTAssertTrue(state.apply(.plusTapped), "a second tap asks for the keyboard again")
    XCTAssertTrue(state.shows(lineOf: .operations))

    state.apply(.tabChanged(.accounts))
    XCTAssertFalse(state.isShown, "a section change drops the line")
    XCTAssertTrue(state.showsPlus)
    XCTAssertTrue(state.apply(.newEntryRequested))
    XCTAssertTrue(state.shows(lineOf: .accounts))
    XCTAssertFalse(state.shows(lineOf: .operations))
  }

  func testSavingTwiceOrEscapingAHiddenLineIsHarmless() {
    var state = PhoneEntryState()
    state.apply(.plusTapped)
    state.apply(.saved)
    state.apply(.saved)
    state.apply(.escaped)
    state.apply(.tappedOutside)
    XCTAssertFalse(state.isShown)
    XCTAssertTrue(state.showsPlus)
  }

  func testComingBackToMoreFromALineHidesItAtOnce() {
    var state = PhoneEntryState()
    state.apply(.plusTapped)
    state.apply(.tabChanged(.more))
    XCTAssertFalse(state.isShown)
    XCTAssertFalse(state.showsPlus)
    state.apply(.tabChanged(.overview))
    XCTAssertTrue(state.showsPlus)
  }

  // MARK: Tabs of the bar

  func testAStoredChoiceThatIsDamagedReadsAsTheDefault() {
    let defaults = NavItem.defaultPhoneTabs
    for text in [
      "", " ", ",", ",,,,", "nonsense", "overview", "overview,overview,planning,accounts",
      "overview,operations,planning,accounts,calendar", "overview, operations, planning, accounts",
      "OVERVIEW,OPERATIONS,PLANNING,ACCOUNTS", "overview;operations;planning;accounts",
    ] {
      XCTAssertEqual(PhoneTabsPreference.decode(text), defaults, "«\(text)»")
    }
    XCTAssertEqual(PhoneTabsPreference.decode(nil), defaults)
  }

  func testAnUnknownNameInsideAGoodListIsDroppedAndTheRestStands() {
    XCTAssertEqual(
      PhoneTabsPreference.decode("overview,future,debts,capital,accounts"),
      [.overview, .debts, .capital, .accounts])
  }

  func testEveryFourDifferentSectionsInAnyOrderSurviveTheRoundTrip() {
    let all = NavItem.allCases
    var checked = 0
    for a in all {
      for b in all where b != a {
        for c in all where c != a && c != b {
          for d in all where d != a && d != b && d != c {
            let items = [a, b, c, d]
            XCTAssertEqual(PhoneTabsPreference.decode(PhoneTabsPreference.encode(items)), items)
            XCTAssertNotNil(PhoneTabsPreference.validated(items))
            checked += 1
          }
        }
      }
    }
    XCTAssertEqual(checked, 10 * 9 * 8 * 7)
  }

  func testARefusedChoiceKeepsWhatWasStored() throws {
    let suite = "tabs-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(PhoneTabsPreference.load(defaults), NavItem.defaultPhoneTabs)
    XCTAssertTrue(PhoneTabsPreference.save([.debts, .capital, .goals, .reports], to: defaults))
    for bad in [
      [NavItem](), [.overview], [.overview, .overview, .planning, .accounts],
      [.overview, .operations, .planning, .accounts, .debts],
    ] {
      XCTAssertFalse(PhoneTabsPreference.save(bad, to: defaults), "\(bad)")
    }
    XCTAssertEqual(PhoneTabsPreference.load(defaults), [.debts, .capital, .goals, .reports])
  }

  func testTheBarKeepsFourSlotsAndMoreHoldsTheRestAtAnyWidth() {
    let chosen: [NavItem] = [.reports, .goals, .debts, .overview]
    for width in [-10.0, 0, 1, 320, 375, 440, 1_024, 100_000] {
      let phone = NavLayout.make(width: width, isPad: false, phoneTabs: chosen)
      XCTAssertEqual(phone.visible, chosen, "\(width)")
      XCTAssertEqual(Set(phone.visible + phone.more), Set(NavItem.allCases))
      XCTAssertEqual(phone.visible.count + phone.more.count, NavItem.allCases.count)
      XCTAssertEqual(phone.placement, .bottom)
      XCTAssertEqual(phone.barCount, 5)
      let pad = NavLayout.make(width: width, isPad: true, phoneTabs: chosen)
      XCTAssertEqual(pad.placement, .sidebar)
      XCTAssertEqual(pad.visible, NavItem.allCases)
      XCTAssertTrue(pad.more.isEmpty)
    }
  }

  func testABrokenChoiceHandedToTheLayoutFallsBackToTheDefault() {
    let layout = NavLayout.make(width: 390, isPad: false, phoneTabs: [.debts])
    XCTAssertEqual(layout.visible, NavItem.defaultPhoneTabs)
    XCTAssertEqual(Set(layout.more), Set(NavItem.allCases).subtracting(NavItem.defaultPhoneTabs))
  }

  func testEverySectionIsNamedForTheBarInEveryLanguageAndNeverByItsKey() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for language in AppLanguage.Choice.allCases where language != .system {
      environment.language.choice = language
      for item in NavItem.allCases {
        let name = environment.language(item.phoneBarKey.key, table: item.phoneBarKey.table)
        XCTAssertFalse(name.isEmpty, "\(item) in \(language.rawValue)")
        XCTAssertNotEqual(
          name, item.phoneBarKey.key, "\(item) is a bare key in \(language.rawValue)")
      }
      let more = environment.language("phone.tab.more", table: "Phone")
      XCTAssertNotEqual(more, "phone.tab.more", "\(language.rawValue)")
    }
  }

  // MARK: The data set

  func testAStoredSetThatIsNoSetOpensTheDemo() throws {
    let suite = "profile-garbage-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for text in ["", "Real", "REAL", "banana", " real"] {
      defaults.set(text, forKey: ProfileStore.key)
      XCTAssertEqual(ProfileStore(defaults: defaults).current, .demo, "«\(text)»")
    }
    defaults.set(7, forKey: ProfileStore.key)
    XCTAssertEqual(ProfileStore(defaults: defaults).current, .demo)
    defaults.set("real", forKey: ProfileStore.key)
    XCTAssertEqual(ProfileStore(defaults: defaults).current, .real)
  }

  func testTheFoldersOfTheSetsHoldUnderAnyRootAndNeverNestInEachOther() {
    for path in ["/tmp/a", "/tmp/with space/ö ü/папка", "/", "/tmp/a/../b"] {
      let root = URL(fileURLWithPath: path, isDirectory: true)
      let demo = DataProfile.demo.directory(in: root)
      let real = DataProfile.real.directory(in: root)
      XCTAssertNotEqual(demo, real, path)
      XCTAssertFalse(demo.path.hasPrefix(real.path + "/"), path)
      XCTAssertFalse(real.path.hasPrefix(demo.path + "/"), path)
      XCTAssertEqual(DataProfile.demo.placement(in: root).directory, demo)
      XCTAssertEqual(DataProfile.real.placement(in: root).directory, real)
    }
    XCTAssertEqual(DataProfile.defaultRoot.lastPathComponent, "OhMyMoney")
    XCTAssertEqual(DataProfile.allCases, [.demo, .real])
  }

  func testSwitchingToTheSetAlreadyOpenDoesNothing() async throws {
    let suite = "session-same-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ios-session-\(UUID().uuidString)", isDirectory: true)
    defer {
      AppPaths.placement = nil
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let session = AppSession(
      profiles: ProfileStore(defaults: defaults), root: root, launches: false)
    let environment = session.deps.environment
    await session.switchProfile(to: .demo)
    XCTAssertEqual(session.generation, 0)
    XCTAssertTrue(session.deps.environment === environment, "the open set is not rebuilt")
    XCTAssertFalse(session.isSwitching)
  }

  func testEverySwitchBuildsNewObjectsAndTheChoiceOutlivesTheSession() async throws {
    let suite = "session-chain-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ios-session-\(UUID().uuidString)", isDirectory: true)
    defer {
      AppPaths.placement = nil
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let session = AppSession(
      profiles: ProfileStore(defaults: defaults), root: root, launches: false)
    var seen: [AppEnvironment] = [session.deps.environment]
    for (index, next) in [DataProfile.real, .demo, .real].enumerated() {
      await session.switchProfile(to: next)
      XCTAssertEqual(session.generation, index + 1)
      XCTAssertEqual(session.profile, next)
      XCTAssertFalse(session.isSwitching)
      seen.append(session.deps.environment)
    }
    for (index, environment) in seen.enumerated() {
      for other in seen[(index + 1)...] {
        XCTAssertFalse(environment === other, "no environment is used for two sets")
      }
    }

    AppPaths.placement = nil
    let relaunched = AppSession(
      profiles: ProfileStore(defaults: defaults), root: root, launches: false)
    XCTAssertEqual(relaunched.profile, .real, "the next launch opens where the owner was")
    XCTAssertEqual(AppPaths.dataDirectory, DataProfile.real.directory(in: root))
    XCTAssertNil(AppPaths.dataSet)
  }

  // MARK: The text of a bank

  func testWhateverTheTextAndWhetherOrNotTheActionIsOnItNeverWritesWithoutTheBooks() {
    let hugeLine = String(repeating: "Покупка 450 ₽ ", count: 20_000)
    for text in ["", " ", "\n\n", "💸", "450", hugeLine, "\u{0}\u{0}", "٤٥٠ ₽", "1e999 ₽"] {
      for enabled in [false, true] {
        let outcome = PhoneAutoEntry.receive(text, dependencies: nil, enabled: enabled)
        guard case .refused(let said) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(said.isEmpty)
        XCTAssertFalse(said.contains("450"), "the refusal never repeats the text")
      }
    }
  }
}
