import CoreKit
import Foundation
import Testing

@testable import CoreGuide

/// The tutorial follows the starter set: tasks for everyone, the ones of the owner's ways of
/// living and answers, none about a life the set says is not his.
@Suite("The tasks of the tutorial follow the starter set")
struct GuideProfileTests {
  private func ids(_ profile: GuideProfile?) -> [String] {
    GuideCatalog.tutorialTasks(for: profile).map(\.id)
  }

  private static let general = [
    "task.coffee", "task.category", "task.search", "task.subscription", "task.count",
    "task.free", "task.transfer", "task.forSomebody", "task.spending", "task.currencyChart",
  ]

  /// Without a set the tutorial is the one everybody had: ten tasks, none of a set.
  @Test func withoutASetTheTutorialIsTheGeneralOne() {
    #expect(ids(nil) == Self.general)
  }

  /// A set that says nothing — no way of living, no answers — drops only the subscription.
  @Test func aSetWithoutSubscriptionsDoesNotAskForOne() {
    #expect(ids(GuideProfile()) == Self.general.filter { $0 != "task.subscription" })
    #expect(ids(GuideProfile(hasSubscriptions: true)) == Self.general)
  }

  @Test(arguments: [
    (GuideLifestyle.student, "task.textbook"), (.working, "task.lunch"),
    (.freelance, "task.client"), (.family, "task.familyHelp"), (.partner, "task.date"),
    (.kids, "task.kids"),
  ])
  func aWayOfLivingBringsItsOwnTask(_ lifestyle: GuideLifestyle, _ task: String) {
    #expect(ids(GuideProfile(lifestyles: [lifestyle])).contains(task))
    let others = Set(GuideLifestyle.allCases).subtracting([lifestyle])
    #expect(!ids(GuideProfile(lifestyles: others)).contains(task), "only its own way of living")
    #expect(!ids(nil).contains(task), "not without a set")
  }

  @Test func livingAloneAddsNothing() {
    #expect(ids(GuideProfile(lifestyles: [.alone])) == ids(GuideProfile()))
  }

  @Test func theAnswersBringTheirTasks() {
    #expect(ids(GuideProfile(hasLoans: true)).contains("task.loan"))
    #expect(ids(GuideProfile(tracksCashback: true)).contains("task.cashback"))
    #expect(ids(GuideProfile(wantsACushion: true)).contains("task.cushion"))
    let none = ids(GuideProfile())
    for task in ["task.loan", "task.cashback", "task.cushion"] {
      #expect(!none.contains(task))
      #expect(!ids(nil).contains(task))
    }
  }

  /// The tasks of a set come right after the first «кофе 300», in the order of the catalog.
  @Test func theTasksOfASetKeepTheOrderOfTheCatalog() {
    let everything = GuideProfile(
      lifestyles: Set(GuideLifestyle.allCases), hasLoans: true, hasSubscriptions: true,
      tracksCashback: true, wantsACushion: true)
    #expect(ids(everything) == GuideCatalog.tutorial.tasks.map(\.id))
    #expect(
      Array(ids(GuideProfile(lifestyles: [.kids, .student])).prefix(3))
        == ["task.coffee", "task.textbook", "task.kids"])
  }

  /// Each task of a set is done by the line its hint suggests, in either language, and not by
  /// the line of another set.
  @Test func theLineOfTheHintDoesTheTask() throws {
    let lines: [(String, String, String, TransactionKind)] = [
      ("task.textbook", "учебник 800", "textbook 800", .expense),
      ("task.lunch", "обед 450", "lunch 450", .expense),
      ("task.client", "заказчик", "client", .income),
      ("task.familyHelp", "помощь маме", "help mum", .expense),
      ("task.date", "свидание", "date", .expense),
      ("task.kids", "игрушки", "toys", .expense),
    ]
    let tasks = GuideCatalog.tutorial.tasks
    for (id, russian, english, kind) in lines {
      let task = try #require(tasks.first { $0.id == id })
      for text in [russian, english] {
        let facts = GuideFacts(operations: [GuideOperation(text: text, amountE4: 1, kind: kind)])
        #expect(task.done.isMet(by: facts), "\(id): «\(text)»")
      }
      let coffee = GuideFacts(operations: [GuideOperation(text: "кофе", amountE4: 1, kind: kind)])
      #expect(!task.done.isMet(by: coffee), "\(id)")
    }
    let client = try #require(tasks.first { $0.id == "task.client" })
    #expect(
      !client.done.isMet(by: GuideFacts(operations: [.init(text: "заказчик", amountE4: 1)])),
      "a payment from a client is income, not an expense")
  }

  @Test func theAnswersAreDoneByWhatTheyAdd() throws {
    let tasks = GuideCatalog.tutorial.tasks
    let loan = try #require(tasks.first { $0.id == "task.loan" })
    let cushion = try #require(tasks.first { $0.id == "task.cushion" })
    let cashback = try #require(tasks.first { $0.id == "task.cashback" })
    #expect(loan.done.isMet(by: GuideFacts(debtsAdded: 1)))
    #expect(!loan.done.isMet(by: GuideFacts(goalsAdded: 1)))
    #expect(cushion.done.isMet(by: GuideFacts(goalsAdded: 1)))
    #expect(cashback.done.isMet(by: GuideFacts(cashbackRulesAdded: 1)))
  }

  @Test func theNamesOfTheStarterSetAreRead() {
    let profile = GuideProfile(
      lifestyleNames: ["kids", "student", "pirate"], hasLoans: true, hasSubscriptions: false,
      tracksCashback: false, wantsACushion: true)
    #expect(profile.lifestyles == [.kids, .student])
    #expect(profile.has(.loans) && profile.has(.cushion) && !profile.has(.cashback))
  }

  @Test func theAudienceOfATask() {
    let kids = GuideProfile(lifestyles: [.kids])
    #expect(GuideAudience.everyone.includes(nil))
    #expect(GuideAudience.everyone.includes(kids))
    #expect(GuideAudience.only(.lifestyle(.kids)).includes(kids))
    #expect(!GuideAudience.only(.lifestyle(.kids)).includes(nil))
    #expect(GuideAudience.unlessNot(.subscriptions).includes(nil))
    #expect(!GuideAudience.unlessNot(.subscriptions).includes(kids))
  }

  /// The set is remembered with the rest of the memory and survives «Начать заново»; a memory
  /// written before the set was remembered still reads, without one.
  @Test func theMemoryKeepsTheSet() throws {
    var progress = GuideProgress(
      tasksDone: ["task.coffee"], profile: GuideProfile(lifestyles: [.working], hasLoans: true))
    let data = try JSONEncoder().encode(progress)
    #expect(try JSONDecoder().decode(GuideProgress.self, from: data) == progress)
    progress.restartTutorial()
    #expect(progress.profile == GuideProfile(lifestyles: [.working], hasLoans: true))
    #expect(progress.tutorialTasks.map(\.id).contains("task.lunch"))

    let older = Data(
      #"{"firstLaunchShown":true,"whatsNewSeen":"1.4","tasksDone":[],"events":[],"tipsOff":false}"#
        .utf8)
    let read = try JSONDecoder().decode(GuideProgress.self, from: older)
    #expect(read.profile == nil)
    #expect(read.tutorialTasks.map(\.id) == Self.general)
  }

  /// A done task of another set does not count towards this one's «N из M».
  @Test func theProgressCountsTheTasksOfTheSet() {
    var progress = GuideProgress(profile: GuideProfile(lifestyles: [.student]))
    progress.record(
      GuideFacts(operations: [
        .init(text: "учебник", amountE4: 1), .init(text: "обед", amountE4: 1),
      ]),
      tasks: progress.tutorialTasks)
    #expect(progress.tasksDone == ["task.textbook"])
    #expect(progress.progress(of: progress.tutorialTasks) == (1, progress.tutorialTasks.count))
  }
}
