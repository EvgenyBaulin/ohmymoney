import AppCore
import AppDatabase
import CryptoKit
import XCTest

@testable import OhMyMoney

/// The guide on the Mac: the cards of the first launch once, «Пропустить» for good, «Что нового»
/// once after an update, and the tutorial on a set of its own that never touches the owner's
/// database.
@MainActor
final class GuideTests: XCTestCase {
  private let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("ohmymoney-guide-\(UUID().uuidString)", isDirectory: true)
  private var defaults: UserDefaults!
  private let suite = "ohmymoney.tests.guide.\(UUID().uuidString)"

  override func setUp() async throws {
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: scratch)
    UserDefaults().removePersistentDomain(forName: suite)
  }

  private func store() -> GuideStore { GuideStore(defaults: defaults) }

  func testTheFirstLaunchShowsTheCardsOnceOnANewDatabase() {
    let guide = store()
    guide.begin(databaseInUse: false, version: "1.4.0", dataSet: nil, isTestHost: false)
    XCTAssertEqual(guide.cards?.id, "firstLaunch")
    guide.cardsDone(version: "1.4.0", skipped: false)
    XCTAssertNil(guide.cards)

    let next = store()
    next.begin(databaseInUse: true, version: "1.4.0", dataSet: nil, isTestHost: false)
    XCTAssertNil(next.cards, "shown once: not at the next launch, not as «Что нового» either")
  }

  func testSkipCloseTheCardsForGood() {
    let guide = store()
    guide.begin(databaseInUse: false, version: "1.4.0", dataSet: nil, isTestHost: false)
    guide.cardsDone(version: "1.4.0", skipped: true)
    let next = store()
    next.begin(databaseInUse: false, version: "1.4.0", dataSet: nil, isTestHost: false)
    XCTAssertNil(next.cards)
  }

  /// An owner of 1.3 gets «Что нового» of 1.4 after the update, once — not the first launch.
  func testWhatsNewComesOnceAfterAnUpdate() {
    let guide = store()
    guide.begin(databaseInUse: true, version: "1.4.0", dataSet: nil, isTestHost: false)
    XCTAssertEqual(guide.cards?.id, "whatsNew.1.4")
    guide.cardsDone(version: "1.4.0", skipped: false)
    let next = store()
    next.begin(databaseInUse: true, version: "1.4.0", dataSet: nil, isTestHost: false)
    XCTAssertNil(next.cards)
    let patch = store()
    patch.begin(databaseInUse: true, version: "1.4.1", dataSet: nil, isTestHost: false)
    XCTAssertNil(patch.cards, "a fix release has nothing new to show")
  }

  /// An owner of 1.8 gets «Что нового в 1.9» after the update, once, and not at the next launch
  /// or after a fix release.
  func testWhatsNewOfOnePointNineComesOnceToAnOwnerOfOnePointEight() throws {
    let memory = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.8.1")
    defaults.set(try JSONEncoder().encode(memory), forKey: GuideStore.progressKey)
    let guide = store()
    guide.begin(databaseInUse: true, version: "1.9.0", dataSet: nil, isTestHost: false)
    XCTAssertEqual(guide.cards?.id, "whatsNew.1.9")
    XCTAssertEqual(guide.cards?.cards.count, 6)
    guide.cardsDone(version: "1.9.0", skipped: false)
    let next = store()
    next.begin(databaseInUse: true, version: "1.9.0", dataSet: nil, isTestHost: false)
    XCTAssertNil(next.cards)
    let patch = store()
    patch.begin(databaseInUse: true, version: "1.9.1", dataSet: nil, isTestHost: false)
    XCTAssertNil(patch.cards)
  }

  /// A set of synthetic data is nobody's first launch.
  func testNoCardsOnADataSet() {
    let guide = store()
    guide.begin(databaseInUse: false, version: "1.4.0", dataSet: .learn, isTestHost: false)
    XCTAssertNil(guide.cards)
  }

  func testTipsCanBeTurnedOffAndStayOff() {
    let guide = store()
    XCTAssertFalse(guide.tipsOff)
    guide.tipsOff = true
    XCTAssertTrue(store().tipsOff)
  }

  /// The tutorial's set is made in a folder of its own: the owner's database next to it keeps
  /// every byte.
  func testTheTutorialSetLeavesTheOwnersDatabaseAsItWas() throws {
    let owner = scratch.appendingPathComponent("Release", isDirectory: true)
    try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
    let ownerDatabase = AppPaths.databaseURL(in: owner)
    let ownerStack = try DatabaseStack(
      url: ownerDatabase, schema: BundleSchemaSource(bundle: .main))
    try ownerStack.close()
    let before = try Data(contentsOf: ownerDatabase)

    let learn = scratch.appendingPathComponent("Sets/learn", isDirectory: true)
    let stack = try DataSetGeneration.prepare(
      directory: learn, generation: .months(DataSetGeneration.learnMonths),
      today: DateOnly(year: 2026, month: 10, day: 7), calendar: .utc, language: "ru",
      schema: BundleSchemaSource(bundle: .main))
    try stack.close()

    let after = try Data(contentsOf: ownerDatabase)
    XCTAssertEqual(SHA256.hash(data: before), SHA256.hash(data: after))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: AppPaths.databaseURL(in: learn).path),
      "the tutorial has a database of its own")
    XCTAssertNotEqual(AppPaths.databaseURL(in: learn), ownerDatabase)
  }

  /// «Учебный режим» and «Выйти» relaunch the app on the tutorial's set and back.
  func testTheTutorialIsEnteredAndLeftByARelaunch() {
    let asked = AppRestart.askedInTestHost
    AppRestart.relaunch(into: .learn)
    XCTAssertEqual(RelaunchCarry.next, ["--data-set", "learn"])
    AppRestart.relaunch(into: nil)
    XCTAssertEqual(RelaunchCarry.next, [])
    XCTAssertEqual(AppRestart.askedInTestHost, asked + 2)
    RelaunchCarry.next = nil
  }

  func testTheTutorialSetIsReadInRelease() {
    let options = LaunchOptions(arguments: ["OhMyMoney", "--data-set", "learn"], debug: false)
    XCTAssertEqual(options.dataSet, .learn)
    XCTAssertNil(options.generation)
  }

  /// The tasks are found done by what was written after the tutorial began, not before.
  func testTheFactsCountOnlyWhatCameAfterTheStart() throws {
    let set = DataSetGeneration.generate(
      .months(2), today: DateOnly(year: 2026, month: 10, day: 7), calendar: .utc, language: "ru")
    var dataset = Dataset(
      entries: set.entries, categories: set.categories, planning: set.planningBook,
      transfers: set.transfers)
    // The moment the set was made: nothing in it is later (the app makes it lived up to now).
    let start = (dataset.entries.map(\.transaction.createdAt).max() ?? Date()).addingTimeInterval(1)
    let baseline = GuideBaseline(of: dataset, at: start)
    XCTAssertEqual(GuideFactsReader.facts(of: dataset, since: baseline), GuideFacts())

    var coffee = try XCTUnwrap(dataset.entries.first { $0.transaction.kind == .expense })
    coffee.transaction.id = UUID()
    coffee.transaction.note = "кофе"
    coffee.transaction.amountE4 = AmountE4(raw: 3_000_000)
    coffee.transaction.currency = .rub
    coffee.transaction.externalId = nil
    coffee.transaction.deletedAt = nil
    coffee.transaction.createdAt = start.addingTimeInterval(5)
    dataset.entries.append(coffee)
    let facts = GuideFactsReader.facts(of: dataset, since: baseline)
    XCTAssertTrue(
      GuideCatalog.tutorial.tasks.first { $0.id == "task.coffee" }!.done.isMet(by: facts))
  }

  // MARK: The starter set and the tutorial

  /// Every way of living the starter set asks about is one the tutorial knows: a new one must
  /// be added to the guide too, or its tasks would never come.
  func testEveryWayOfLivingOfTheStarterSetIsKnownToTheGuide() {
    for lifestyle in Lifestyle.allCases {
      XCTAssertNotNil(GuideLifestyle(rawValue: lifestyle.rawValue), lifestyle.rawValue)
    }
    XCTAssertEqual(GuideLifestyle.allCases.count, Lifestyle.allCases.count)
  }

  /// The set applied is remembered in the guide's memory on this Mac, survives a new store (a
  /// relaunch into the tutorial) and «Начать заново», and chooses the tasks.
  func testTheStarterSetChoosesTheTasksOfTheTutorial() {
    let guide = GuideStore(defaults: defaults, tutorial: true)
    XCTAssertEqual(guide.tutorial.tasks.count, 10, "without a set: the tasks for everyone")

    guide.remember(
      StarterChoice(lifestyles: [.kids, .working], hasLoans: true, hasSubscriptions: false))
    let ids = guide.tutorial.tasks.map(\.id)
    XCTAssertTrue(ids.contains("task.kids"))
    XCTAssertTrue(ids.contains("task.lunch"))
    XCTAssertTrue(ids.contains("task.loan"))
    XCTAssertFalse(ids.contains("task.subscription"), "the set said: no subscriptions")
    XCTAssertFalse(ids.contains("task.textbook"))

    let relaunched = GuideStore(defaults: defaults, tutorial: true)
    XCTAssertEqual(relaunched.tutorial.tasks.map(\.id), ids)
    relaunched.restartTutorial()
    XCTAssertEqual(relaunched.tutorial.tasks.map(\.id), ids)
  }

  /// A debt, a goal and a cashback rule added after the start are facts; the ones the set had,
  /// and a baseline kept from before they were counted, are not.
  func testTheDebtsGoalsAndCashbackRulesCountFromTheStart() throws {
    var dataset = Dataset()
    let baseline = GuideBaseline(of: dataset, at: Date())
    dataset.debts = [Debt(direction: .iOwe, type: .loan, name: "Car")]
    dataset.goals = [Goal(name: "Cushion", targetE4: AmountE4(whole: 100_000))]
    let facts = GuideFactsReader.facts(of: dataset, since: baseline)
    XCTAssertEqual(facts.debtsAdded, 1)
    XCTAssertEqual(facts.goalsAdded, 1)
    XCTAssertEqual(facts.cashbackRulesAdded, 0)

    var older = baseline
    older.debts = nil
    older.goals = nil
    let fromOlder = GuideFactsReader.facts(of: dataset, since: older)
    XCTAssertEqual(fromOlder.debtsAdded, 0)
    XCTAssertEqual(fromOlder.goalsAdded, 0)
  }
}
