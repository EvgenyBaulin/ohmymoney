import CoreKit
import Foundation
import Testing

@testable import CoreGuide

@Suite("Every scenario of the guide is complete in both languages")
struct GuideCatalogTests {
  private var allCards: [GuideCard] { GuideCatalog.scenarios.flatMap(\.cards) }
  private var allTasks: [GuideTask] { GuideCatalog.scenarios.flatMap(\.tasks) }

  @Test func everyTextHasBothLanguages() {
    for card in allCards {
      #expect(card.title.isComplete && card.body.isComplete, "\(card.id)")
    }
    for task in allTasks {
      #expect(task.title.isComplete, "\(task.id)")
      for hint in task.hints {
        #expect(hint.text.isComplete, "\(task.id)")
        #expect(hint.gesture?.isComplete ?? true, "\(task.id)")
      }
    }
  }

  @Test func everyTaskSaysWhereToPress() {
    for task in allTasks {
      #expect(!task.hints.isEmpty, "\(task.id)")
      #expect(task.hints.allSatisfy { !$0.target.isEmpty }, "\(task.id)")
    }
  }

  @Test func idsAreUnique() {
    let ids = allCards.map(\.id) + allTasks.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(Set(GuideCatalog.scenarios.map(\.id)).count == GuideCatalog.scenarios.count)
  }

  @Test func theFirstLaunchIsFiveToSevenShortCards() {
    let cards = GuideCatalog.firstLaunch.cards
    #expect((5...7).contains(cards.count))
    #expect(cards.allSatisfy { (10...15).contains($0.seconds) && !$0.symbol.isEmpty })
  }

  /// Every version from 1.4 on has at least one card of «Что нового».
  @Test func everyVersionFromOnePointFourHasWhatsNew() {
    let versions = GuideCatalog.whatsNew.compactMap { scenario -> GuideVersion? in
      if case .whatsNew(let version) = scenario.kind { return version }
      return nil
    }
    #expect(versions.contains(GuideVersion(major: 1, minor: 4)))
    #expect(GuideCatalog.whatsNew.allSatisfy { !$0.cards.isEmpty })
  }

  /// «Что нового в 1.6»: the education loan with its grace period and tranches, deposits and
  /// savings accounts with their interest, and the interest in the account forecast — three to
  /// four cards.
  @Test func whatsNewOfOnePointSixTellsOfLoansAndDeposits() throws {
    let scenario = GuideCatalog.whatsNew16
    #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 1, minor: 6)))
    #expect(scenario.id == "whatsNew.1.6")
    #expect((3...4).contains(scenario.cards.count))
    #expect(
      scenario.cards.map(\.id)
        == ["new16.educationLoan", "new16.tranche", "new16.deposits", "new16.forecast"])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.id.hasPrefix("new16.") })
    let progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.5.0")
    #expect(
      progress.whatsNewDue(current: "1.6.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.6"])
  }

  /// «Что нового в 1.7»: the capital on its own screen (⌘6) with the property valued by hand,
  /// the safety cushion in months of living without income, and the cushion goal with the
  /// switch of the free sum — three to four cards.
  @Test func whatsNewOfOnePointSevenTellsOfTheCapitalAndTheCushion() throws {
    let scenario = GuideCatalog.whatsNew17
    #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 1, minor: 7)))
    #expect(scenario.id == "whatsNew.1.7")
    #expect((3...4).contains(scenario.cards.count))
    #expect(
      scenario.cards.map(\.id)
        == ["new17.capital", "new17.assets", "new17.cushion", "new17.cushionGoal"])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.id.hasPrefix("new17.") })
    let capital = try #require(scenario.cards.first)
    #expect(capital.body.russian.contains("⌘6") && capital.body.english.contains("⌘6"))
    let goal = try #require(scenario.cards.last)
    #expect(goal.body.russian.contains("Не считать подушку в свободной сумме"))
    let progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.6.0")
    #expect(
      progress.whatsNewDue(current: "1.7.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.7"])
    let older = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.5.2")
    #expect(
      older.whatsNewDue(current: "1.7.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.6", "whatsNew.1.7"])
  }

  /// «Что нового в 1.8»: Overview in groups with «Почему так», the shorter Planning, the lock
  /// password, and windows without tabs with the lit-up tutorial.
  @Test func whatsNewOfOnePointEightTellsOfTheOverviewThePlanningAndTheLock() throws {
    let scenario = GuideCatalog.whatsNew18
    #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 1, minor: 8)))
    #expect(scenario.id == "whatsNew.1.8")
    #expect(
      scenario.cards.map(\.id)
        == ["new18.overview", "new18.why", "new18.planning", "new18.password", "new18.windows"])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.id.hasPrefix("new18.") })
    let progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.7.0")
    #expect(
      progress.whatsNewDue(current: "1.8.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.8"])
  }

  /// «Что нового в 1.9»: six cards — instalments and the true cost, the credit card as the bank
  /// keeps it, early repayment and the ladder, the allocation of the salary, self-employment,
  /// and what became easier — the latest version.
  @Test func whatsNewOfOnePointNineTellsOfCreditAllocationAndSelfEmployment() throws {
    let scenario = GuideCatalog.whatsNew19
    #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 1, minor: 9)))
    #expect(scenario.id == "whatsNew.1.9")
    #expect(
      scenario.cards.map(\.id)
        == [
          "new19.instalments", "new19.creditCard", "new19.prepay", "new19.allocation",
          "new19.selfEmployed", "new19.easier",
        ])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.id.hasPrefix("new19.") })
    #expect(scenario.cards.allSatisfy { $0.title.isComplete && $0.body.isComplete })
    let easier = try #require(scenario.cards.first { $0.id == "new19.easier" })
    #expect(easier.body.russian.contains("«Операции» вместо «Трат»"))
    #expect(easier.target == GuideTarget.sidebarOperations)
    let card = try #require(scenario.cards.first { $0.id == "new19.creditCard" })
    #expect(card.body.russian.contains("25 дней"))
    #expect(GuideCatalog.whatsNew.contains { $0.id == scenario.id })
  }

  /// «Что нового в 1.10»: the name, the days of «Операции», paying for others and the fixes.
  @Test func whatsNewOfOnePointTenTellsOfTheNameAndTheFixes() throws {
    let scenario = GuideCatalog.whatsNew110
    #expect(scenario.id == "whatsNew.1.10")
    #expect(
      scenario.cards.map(\.id)
        == ["new110.name", "new110.byDay", "new110.forOthers", "new110.fixes"])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.title.isComplete })
    #expect(scenario.cards.allSatisfy { $0.body.isComplete })
    #expect(GuideCatalog.whatsNew.contains { $0.id == scenario.id })
  }

  /// «Что нового в 1.11»: the what-if window, the saved scenarios and the order of the goals.
  @Test func whatsNewOfOnePointElevenTellsOfTheWhatIfWindow() throws {
    let scenario = GuideCatalog.whatsNew111
    #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 1, minor: 11)))
    #expect(scenario.id == "whatsNew.1.11")
    #expect(
      scenario.cards.map(\.id) == ["new111.whatIf", "new111.scenarios", "new111.goalOrder"])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.title.isComplete })
    #expect(scenario.cards.allSatisfy { $0.body.isComplete })
    #expect(GuideCatalog.whatsNew.contains { $0.id == scenario.id })
  }

  /// «Что нового в 1.12»: the names of the copies, the copy of the day with a readable version,
  /// the thinning and the check of the database.
  @Test func whatsNewOfOnePointTwelveTellsOfTheBackups() throws {
    let scenario = GuideCatalog.whatsNew112
    #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 1, minor: 12)))
    #expect(scenario.id == "whatsNew.1.12")
    #expect(
      scenario.cards.map(\.id)
        == ["new112.names", "new112.readable", "new112.thinning", "new112.check"])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.id.hasPrefix("new112.") })
    #expect(scenario.cards.allSatisfy { $0.title.isComplete && $0.body.isComplete })
    let readable = try #require(scenario.cards.first { $0.id == "new112.readable" })
    #expect(
      readable.body.russian.contains("только база")
        && readable.body.english.contains("only the database"))
    #expect(GuideCatalog.whatsNew.contains { $0.id == scenario.id })
  }

  /// «Что нового в 1.13»: the trip strip, the summary of a trip, the cards abroad and the
  /// exchange-rate difference — the latest version.
  @Test func whatsNewOfOnePointThirteenTellsOfTheTrips() throws {
    let scenario = GuideCatalog.whatsNew113
    #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 1, minor: 13)))
    #expect(scenario.id == "whatsNew.1.13")
    #expect(scenario.cards.map(\.id) == ["new113.trip", "new113.summary", "new113.rate"])
    #expect(scenario.cards.allSatisfy { !$0.symbol.isEmpty && $0.title.isComplete })
    #expect(scenario.cards.allSatisfy { $0.body.isComplete })
    let last = try #require(GuideCatalog.whatsNew.last)
    #expect(last.id == scenario.id)
    // 1.12 and 1.13 came out as one build, so a database of 1.11 is told of both.
    var progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.11.0")
    #expect(
      progress.whatsNewDue(current: "1.13.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.12", "whatsNew.1.13"])
    progress.whatsNewSeen = "1.12.0"
    #expect(
      progress.whatsNewDue(current: "1.13.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.13"])
    progress.whatsNewSeen = "1.13.0"
    #expect(progress.whatsNewDue(current: "1.13.0", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  /// A database of 1.11 gets «Что нового в 1.12» once, after the card of 1.11.
  @Test func whatsNewOfOnePointTwelveIsShownOnceToADatabaseOfOnePointEleven() {
    var progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.11.0")
    #expect(
      progress.whatsNewDue(current: "1.12.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.12"])
    progress.whatsNewSeen = "1.12.0"
    #expect(progress.whatsNewDue(current: "1.12.0", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  /// A database of 1.8 gets «Что нового в 1.9» once: due on the first launch of 1.9, and not
  /// again once it was shown; a database already on 1.9 never gets it.
  @Test func whatsNewOfOnePointNineIsShownOnceToADatabaseOfOnePointEight() {
    var progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.8.1")
    #expect(
      progress.whatsNewDue(current: "1.9.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.9"])
    progress.whatsNewSeen = "1.9.0"
    #expect(progress.whatsNewDue(current: "1.9.0", catalog: GuideCatalog.whatsNew).isEmpty)
    #expect(progress.whatsNewDue(current: "1.9.2", catalog: GuideCatalog.whatsNew).isEmpty)
    let older = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.7.0")
    #expect(
      older.whatsNewDue(current: "1.9.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.1.8", "whatsNew.1.9"])
  }

  @Test func theTutorialHasTheTasksOfTheRelease() {
    let ids = Set(GuideCatalog.tutorial.tasks.map(\.id))
    for id in [
      "task.coffee", "task.category", "task.search", "task.subscription", "task.count",
      "task.free", "task.transfer", "task.forSomebody", "task.spending", "task.currencyChart",
    ] {
      #expect(ids.contains(id), "\(id)")
    }
  }

  /// No task is done on empty facts — nothing was done yet.
  @Test func noTaskIsDoneOnNothing() {
    for task in allTasks {
      #expect(!task.done.isMet(by: GuideFacts()), "\(task.id)")
    }
  }

  /// Every task is found done by the facts its own action leaves.
  @Test func everyTaskIsFoundDoneByItsAction() {
    let facts = GuideFacts(
      events: GuideEvent.all,
      operations: [
        GuideOperation(text: "Кофе у дома", amountE4: 3_000_000),
        GuideOperation(text: "ужин", amountE4: 12_000_000, forSomebodyElse: true),
        GuideOperation(text: "учебник", amountE4: 8_000_000),
        GuideOperation(text: "обед", amountE4: 4_500_000),
        GuideOperation(text: "заказчик", amountE4: 200_000_000, kind: .income),
        GuideOperation(text: "помощь маме", amountE4: 30_000_000),
        GuideOperation(text: "свидание", amountE4: 25_000_000),
        GuideOperation(text: "игрушки", amountE4: 15_000_000),
      ],
      scheduledPaymentsAdded: 1, countsMade: 1, transfersAdded: 1, debtsAdded: 1, goalsAdded: 1,
      cashbackRulesAdded: 1)
    for task in allTasks {
      #expect(task.done.isMet(by: facts), "\(task.id)")
    }
  }
}

@Suite("Conditions look at what happened, not at a «Done» button")
struct GuideConditionTests {
  @Test func coffeeNeedsTheWordsAndTheAmountInRubles() {
    let coffee = GuideCondition.operation(words: "кофе", amountE4: 3_000_000)
    #expect(coffee.isMet(by: GuideFacts(operations: [.init(text: "КОФЕ", amountE4: 3_000_000)])))
    #expect(!coffee.isMet(by: GuideFacts(operations: [.init(text: "кофе", amountE4: 2_500_000)])))
    #expect(!coffee.isMet(by: GuideFacts(operations: [.init(text: "чай", amountE4: 3_000_000)])))
    #expect(
      !coffee.isMet(
        by: GuideFacts(operations: [.init(text: "кофе", amountE4: 3_000_000, currency: .usd)])))
    #expect(
      !coffee.isMet(
        by: GuideFacts(operations: [.init(text: "кофе", amountE4: 3_000_000, kind: .income)])))
  }

  @Test func yoIsReadAsYe() {
    let condition = GuideCondition.operation(words: "ёлка", amountE4: nil)
    #expect(condition.isMet(by: GuideFacts(operations: [.init(text: "елка", amountE4: 1)])))
  }
}

@Suite("The guide remembers on the device, once per version")
struct GuideProgressTests {
  @Test func theFirstLaunchIsDueOnceOnAnEmptyDatabase() {
    var progress = GuideProgress.starting(onADatabaseInUse: false)
    #expect(progress.firstLaunchDue())
    progress.firstLaunchWasShown(in: "1.4.0")
    #expect(!progress.firstLaunchDue())
    #expect(progress.whatsNewDue(current: "1.4.0", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  @Test func anOwnerOfOnePointThreeGetsWhatsNewOnce() {
    var progress = GuideProgress.starting(onADatabaseInUse: true)
    #expect(!progress.firstLaunchDue())
    let due = progress.whatsNewDue(current: "1.4.0", catalog: GuideCatalog.whatsNew)
    #expect(due.map(\.id) == ["whatsNew.1.4"])
    progress.whatsNewSeen = "1.4.0"
    #expect(progress.whatsNewDue(current: "1.4.0", catalog: GuideCatalog.whatsNew).isEmpty)
    #expect(progress.whatsNewDue(current: "1.4.3", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  @Test func severalVersionsAreShownOldestFirst() {
    let progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.3.2")
    let due = progress.whatsNewDue(current: "1.10.0", catalog: GuideCatalog.whatsNew)
    #expect(
      due.map(\.id)
        == [
          "whatsNew.1.4", "whatsNew.1.5", "whatsNew.1.6", "whatsNew.1.7", "whatsNew.1.8",
          "whatsNew.1.9", "whatsNew.1.10",
        ])
    #expect(
      progress.whatsNewDue(current: "1.4.1", catalog: GuideCatalog.whatsNew).count == 1)
  }

  @Test func tasksStayDoneAndRestartForgetsThem() {
    var progress = GuideProgress()
    let tasks = GuideCatalog.tutorial.tasks
    progress.events.insert(GuideEvent.operationsOpened)
    let fresh = progress.record(
      GuideFacts(operations: [.init(text: "кофе", amountE4: 3_000_000)]), tasks: tasks)
    #expect(Set(fresh) == ["task.coffee", "task.spending"])
    #expect(progress.record(GuideFacts(), tasks: tasks).isEmpty, "done stays done, not twice")
    #expect(progress.progress(of: tasks) == (2, tasks.count))
    progress.restartTutorial()
    #expect(progress.progress(of: tasks).done == 0)
  }

  @Test func versionsAreRead() {
    #expect(GuideVersion("1.4.0") == GuideVersion(major: 1, minor: 4))
    #expect(GuideVersion("v1.10") == GuideVersion(major: 1, minor: 10))
    #expect(GuideVersion("1.10.0")! > GuideVersion("1.9.9")!)
    #expect(GuideVersion("1") == nil)
    #expect(GuideVersion("abc") == nil)
  }

  @Test func progressSurvivesCoding() throws {
    let progress = GuideProgress(
      firstLaunchShown: true, whatsNewSeen: "1.4.0", tasksDone: ["task.coffee"],
      events: [GuideEvent.searched], tipsOff: true)
    let data = try JSONEncoder().encode(progress)
    #expect(try JSONDecoder().decode(GuideProgress.self, from: data) == progress)
  }
}
