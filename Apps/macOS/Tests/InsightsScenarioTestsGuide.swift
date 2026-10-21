import AppCore
import XCTest

@testable import OhMyMoney

/// The guide and «Что нового» as data: versions read from any tag, what is new shown once and
/// in order after any jump of versions, tasks ticked once and forgotten on «Начать заново»,
/// conditions that fold case and «ё», the tutorial following the starter set, walks of steps,
/// and a catalog whose every word is there in Russian and in English.
final class InsightsScenarioGuideTests: XCTestCase {
  private func version(_ text: String) -> GuideVersion? { GuideVersion(text) }

  // MARK: - Versions

  /// A tag, a release, a version of two numbers; anything else is no version.
  func testVersionsAreReadFromTagsAndReleases() {
    XCTAssertEqual(version("1.4.0"), GuideVersion(major: 1, minor: 4))
    XCTAssertEqual(version("v1.10"), GuideVersion(major: 1, minor: 10))
    XCTAssertEqual(version("2.0.3"), GuideVersion(major: 2, minor: 0))
    for text in ["1", "1.2.3.4", "1.x", "", "v", "1..2", "1.4.", ".1.4", "a.b"] {
      XCTAssertNil(version(text), text)
    }
    XCTAssertEqual(version("1.9.1")?.description, "1.9")
  }

  /// 1.10 comes after 1.9, and 2.0 after both.
  func testVersionsCompareAsNumbers() throws {
    let nine = try XCTUnwrap(version("1.9"))
    let ten = try XCTUnwrap(version("1.10"))
    XCTAssertLessThan(nine, ten)
    XCTAssertLessThan(ten, try XCTUnwrap(version("2.0")))
  }

  // MARK: - What is new

  private var shownOnce: GuideProgress {
    var progress = GuideProgress()
    progress.firstLaunchWasShown(in: "1.6")
    return progress
  }

  /// From 1.6 to 1.9.2: what is new in 1.7, 1.8 and 1.9, oldest first; nothing of 1.6 or before.
  func testWhatIsNewAfterAJumpOfVersionsComesInOrder() {
    let due = shownOnce.whatsNewDue(current: "1.9.2", catalog: GuideCatalog.whatsNew)
    XCTAssertEqual(due.map(\.id), ["whatsNew.1.7", "whatsNew.1.8", "whatsNew.1.9"])
  }

  /// A fix release brings nothing new; nor does going back to an older version.
  func testAFixReleaseOrAnOlderVersionBringsNothing() {
    var progress = shownOnce
    progress.whatsNewSeen = "1.9"
    XCTAssertTrue(progress.whatsNewDue(current: "1.9.1", catalog: GuideCatalog.whatsNew).isEmpty)
    XCTAssertTrue(progress.whatsNewDue(current: "1.5.0", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  /// Before the first launch, or with a version that does not read, nothing is due.
  func testNothingIsDueBeforeTheFirstLaunchOrForAnUnreadableVersion() {
    XCTAssertTrue(
      GuideProgress().whatsNewDue(current: "1.9", catalog: GuideCatalog.whatsNew)
        .isEmpty)
    XCTAssertTrue(shownOnce.whatsNewDue(current: "dev", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  /// A memory that does not read counts as having seen nothing: every «Что нового» up to now.
  func testAnUnreadableMemoryShowsEverythingUpToNow() {
    var progress = shownOnce
    progress.whatsNewSeen = "garbage"
    let due = progress.whatsNewDue(current: "1.5", catalog: GuideCatalog.whatsNew)
    XCTAssertEqual(due.map(\.id), ["whatsNew.1.4", "whatsNew.1.5"])
  }

  /// A database in use before the guide existed starts as seen through 1.3: no first launch,
  /// «Что нового» from 1.4.
  func testADatabaseInUseStartsAfterOnePointThree() {
    let progress = GuideProgress.starting(onADatabaseInUse: true)
    XCTAssertFalse(progress.firstLaunchDue())
    let due = progress.whatsNewDue(current: "1.4.0", catalog: GuideCatalog.whatsNew)
    XCTAssertEqual(due.map(\.id), ["whatsNew.1.4"])
    XCTAssertTrue(GuideProgress.starting(onADatabaseInUse: false).firstLaunchDue())
  }

  // MARK: - Tasks

  private func task(_ id: String, _ done: GuideCondition) -> GuideTask {
    GuideTask(id: id, title: GuideText("Задача", "Task"), hints: [], done: done)
  }

  private func facts(
    events: Set<String> = [], operations: [GuideOperation] = []
  ) -> GuideFacts {
    GuideFacts(events: events, operations: operations)
  }

  /// A task is ticked once: a second report of the same facts brings nothing fresh.
  func testATaskIsTickedOnce() {
    var progress = GuideProgress(events: [GuideEvent.searched])
    let tasks = [
      task("search", .event(GuideEvent.searched)),
      task("chart", .event(GuideEvent.currencyChartSeen)),
    ]
    XCTAssertEqual(progress.record(facts(), tasks: tasks), ["search"])
    XCTAssertTrue(progress.record(facts(), tasks: tasks).isEmpty)
    XCTAssertEqual(progress.progress(of: tasks).done, 1)
    XCTAssertEqual(
      progress.record(facts(events: [GuideEvent.currencyChartSeen]), tasks: tasks), ["chart"])
    XCTAssertTrue(progress.progress(of: tasks) == (2, 2))
  }

  /// «Начать заново» forgets the tasks and the events, not the starter set or the tips.
  func testStartingOverKeepsTheProfileAndTheTips() {
    let profile = GuideProfile(lifestyles: [.student], hasLoans: true)
    var progress = GuideProgress(
      tasksDone: ["a"], events: [GuideEvent.searched], tipsOff: true, profile: profile)
    progress.restartTutorial()
    XCTAssertTrue(progress.tasksDone.isEmpty)
    XCTAssertTrue(progress.events.isEmpty)
    XCTAssertTrue(progress.tipsOff)
    XCTAssertEqual(progress.profile, profile)
  }

  /// «Кофе 250»: the words fold case and «ё», the amount is rubles only, income is its own.
  func testConditionsFoldCaseAndYo() {
    let coffee = GuideCondition.operation(words: "ёлка", amountE4: 2_500_000)
    XCTAssertTrue(
      coffee.isMet(
        by: facts(operations: [
          GuideOperation(text: "Купил ЕЛКА", amountE4: 2_500_000, currency: .rub, kind: .expense)
        ])))
    XCTAssertFalse(
      coffee.isMet(
        by: facts(operations: [
          GuideOperation(text: "елка", amountE4: 2_500_000, currency: .usd, kind: .expense)
        ])))
    XCTAssertFalse(
      coffee.isMet(
        by: facts(operations: [
          GuideOperation(text: "елка", amountE4: 2_500_000, currency: .rub, kind: .income)
        ])))
    let salary = GuideCondition.income(words: "зарплата")
    XCTAssertTrue(
      salary.isMet(
        by: facts(operations: [
          GuideOperation(text: "Зарплата за май", amountE4: 1, currency: .eur, kind: .income)
        ])))
    let either = GuideCondition.any([.countMade, .event(GuideEvent.searched)])
    XCTAssertTrue(either.isMet(by: facts(events: [GuideEvent.searched])))
    XCTAssertFalse(GuideCondition.any([]).isMet(by: facts()))
  }

  // MARK: - The starter set

  /// Without a starter set every task but the ones for a particular life is there; «only»
  /// tasks wait for their trait, «unless not» ones go only when the set says no.
  func testAudiencesFollowTheStarterSet() {
    XCTAssertTrue(GuideAudience.everyone.includes(nil))
    XCTAssertFalse(GuideAudience.only(.loans).includes(nil))
    XCTAssertTrue(GuideAudience.unlessNot(.cashback).includes(nil))
    let profile = GuideProfile(lifestyles: [.family], tracksCashback: false)
    XCTAssertFalse(GuideAudience.unlessNot(.cashback).includes(profile))
    XCTAssertTrue(GuideAudience.only(.lifestyle(.family)).includes(profile))
    XCTAssertFalse(GuideAudience.only(.lifestyle(.student)).includes(profile))
  }

  /// Ways of living by name: the unknown ones are passed over.
  func testAProfileReadsItsWaysOfLivingByName() {
    let profile = GuideProfile(
      lifestyleNames: ["student", "astronaut", "kids"], hasLoans: false, hasSubscriptions: true,
      tracksCashback: false, wantsACushion: true)
    XCTAssertEqual(profile.lifestyles, [.student, .kids])
    XCTAssertTrue(profile.has(.subscriptions))
    XCTAssertTrue(profile.has(.cushion))
    XCTAssertFalse(profile.has(.loans))
  }

  /// A profile with every trait has at least the tasks of no profile beyond the «only» ones.
  func testTheTutorialGrowsWithTheProfile() {
    let none = Set(GuideCatalog.tutorialTasks(for: nil).map(\.id))
    let everything = GuideProfile(
      lifestyles: Set(GuideLifestyle.allCases), hasLoans: true, hasSubscriptions: true,
      tracksCashback: true, wantsACushion: true)
    let all = Set(GuideCatalog.tutorialTasks(for: everything).map(\.id))
    XCTAssertTrue(none.isSubset(of: all))
    XCTAssertEqual(all, Set(GuideCatalog.tutorial.tasks.map(\.id)))
  }

  // MARK: - Walks

  private func hint(_ target: String, click: Bool = true) -> GuideHint {
    GuideHint(target: target, text: GuideText("Шаг", "Step"), advancesOnClick: click)
  }

  /// A walk: a click elsewhere or on a typed step does nothing; the last step finishes.
  func testAWalkMovesOnlyOnItsOwnPlace() throws {
    var walk = try XCTUnwrap(
      GuideWalkthrough(.whereToClick, steps: [hint("a"), hint("b", click: false), hint("c")]))
    XCTAssertEqual(walk.clicked("z"), .ignored)
    XCTAssertEqual(walk.clicked("a"), .moved)
    XCTAssertEqual(walk.clicked("b"), .ignored)
    XCTAssertEqual(walk.next(), .moved)
    XCTAssertTrue(walk.isLast)
    XCTAssertTrue(walk.position == (3, 3))
    XCTAssertEqual(walk.clicked("c"), .finished)
    XCTAssertEqual(walk.next(), .finished)
  }

  /// No steps, no walk; a card that points at nothing has no «Показать, где».
  func testNothingToPointAtIsNoWalk() {
    XCTAssertNil(GuideWalkthrough(.whereToClick, steps: []))
    let card = GuideCard(
      id: "x", title: GuideText("Т", "T"), body: GuideText("Б", "B"), symbol: "star", seconds: 5)
    XCTAssertNil(GuideWalkthrough(card: card))
    XCTAssertNotNil(GuideWalkthrough.whereToClick())
  }

  // MARK: - The catalog

  /// Every word of the catalog is there in both languages; ids are unique; «Что нового» goes up
  /// version by version, never past the app's own.
  func testTheCatalogIsWholeInBothLanguages() throws {
    var cardIds: Set<String> = []
    for scenario in GuideCatalog.scenarios {
      for card in scenario.cards {
        XCTAssertTrue(card.title.isComplete && card.body.isComplete, card.id)
        XCTAssertTrue(cardIds.insert("\(scenario.id)/\(card.id)").inserted, card.id)
      }
      for task in scenario.tasks {
        XCTAssertTrue(task.title.isComplete, task.id)
        XCTAssertTrue(task.hints.allSatisfy { $0.text.isComplete }, task.id)
      }
    }
    let taskIds = GuideCatalog.tutorial.tasks.map(\.id)
    XCTAssertEqual(Set(taskIds).count, taskIds.count)
    let versions = GuideCatalog.whatsNew.compactMap { scenario -> GuideVersion? in
      if case .whatsNew(let version) = scenario.kind { return version }
      return nil
    }
    XCTAssertEqual(versions.count, GuideCatalog.whatsNew.count)
    XCTAssertEqual(versions, versions.sorted())
    XCTAssertEqual(Set(versions).count, versions.count)
    let app = try XCTUnwrap(GuideVersion(AppEnvironment.appVersion))
    XCTAssertLessThanOrEqual(try XCTUnwrap(versions.last), app)
    XCTAssertTrue(GuideCatalog.whereToClick.allSatisfy { $0.text.isComplete })
  }

  /// The memory of the guide survives being written down.
  func testTheMemorySurvivesBeingWrittenDown() throws {
    let progress = GuideProgress(
      firstLaunchShown: true, whatsNewSeen: "1.9", tasksDone: ["coffee"],
      events: [GuideEvent.searched], tipsOff: true,
      profile: GuideProfile(lifestyles: [.alone], tracksCashback: true))
    let data = try JSONEncoder().encode(progress)
    XCTAssertEqual(try JSONDecoder().decode(GuideProgress.self, from: data), progress)
  }
}
