import Foundation
import Testing

@testable import CoreGuide

@Suite("The guide points at one place at a time")
struct GuideWalkthroughTests {
  private func hint(_ target: String, click: Bool = true) -> GuideHint {
    GuideHint(target: target, text: GuideText("т", "t"), advancesOnClick: click)
  }

  @Test func theStepsGoInOrderAndEndAfterTheLast() throws {
    var walk = try #require(
      GuideWalkthrough(.whereToClick, steps: [hint("a"), hint("b"), hint("c")]))
    #expect(walk.current.target == "a")
    #expect(walk.position == (1, 3))
    #expect(walk.next() == .moved)
    #expect(walk.current.target == "b")
    #expect(walk.next() == .moved)
    #expect(walk.isLast)
    #expect(walk.position == (3, 3))
    #expect(walk.next() == .finished)
    #expect(walk.current.target == "c", "the last step stays where it was")
  }

  @Test func aClickOnThePlaceMovesOnAndAClickElsewhereDoesNot() throws {
    var walk = try #require(GuideWalkthrough(.whereToClick, steps: [hint("a"), hint("b")]))
    #expect(walk.clicked("b") == .ignored)
    #expect(walk.index == 0)
    #expect(walk.clicked("a") == .moved)
    #expect(walk.clicked("b") == .finished)
  }

  @Test func aTypedStepDoesNotMoveOnByAClick() throws {
    var walk = try #require(
      GuideWalkthrough(.whereToClick, steps: [hint("line", click: false), hint("b")]))
    #expect(walk.clicked("line") == .ignored)
    #expect(walk.next() == .moved, "«Далее» still moves on")
  }

  @Test func noStepsNoWalk() {
    #expect(GuideWalkthrough(.whereToClick, steps: []) == nil)
  }

  /// Every task of the tutorial, whoever's it is, becomes a walk of its own steps; each step has
  /// a place, words in both languages and a why.
  @Test func everyTaskOfTheTutorialIsAWalk() throws {
    for task in GuideCatalog.tutorial.tasks {
      let walk = try #require(GuideWalkthrough(task: task), "\(task.id)")
      #expect(walk.source == .task(task.id))
      #expect(walk.steps == task.hints)
      for step in walk.steps {
        #expect(!step.target.isEmpty, "\(task.id)")
        #expect(step.text.isComplete, "\(task.id)")
        #expect(step.why?.isComplete == true, "\(task.id) has no why")
      }
    }
  }

  /// A task typed into the line ends on the line, and its last step waits for the typing: a
  /// click into the line does not close the words before the owner has read them.
  @Test func theTasksTypedIntoTheLineWaitForTheTyping() {
    for task in GuideCatalog.tutorial.tasks
    where task.hints.last?.target == GuideTarget.entryLine {
      #expect(task.hints.last?.advancesOnClick == false, "\(task.id)")
    }
  }

  /// A walk that opens a section first: the sidebar item moves on by a click, as the owner
  /// opens it.
  @Test func openingASectionMovesOnByTheClick() {
    for task in GuideCatalog.tutorial.tasks where task.hints.count > 1 {
      let first = task.hints[0]
      if first.target.hasPrefix("sidebar.") {
        #expect(first.advancesOnClick, "\(task.id)")
      }
    }
  }

  /// «Показать, куда нажимать»: the line, its fields, every section of the sidebar and the
  /// three buttons of the toolbar, each with keys where it has them.
  @Test func whereToClickNamesEveryPlace() throws {
    let walk = try #require(GuideWalkthrough.whereToClick())
    #expect(
      walk.steps.map(\.target) == [
        GuideTarget.entryLine, GuideTarget.entryDetails, GuideTarget.sidebarOverview,
        GuideTarget.sidebarPlanning, GuideTarget.sidebarDebts, GuideTarget.sidebarOperations,
        GuideTarget.sidebarCalendar, GuideTarget.sidebarCapital, GuideTarget.toolbarTransactions,
        GuideTarget.toolbarReconcile, GuideTarget.toolbarSettings,
      ])
    #expect(
      walk.steps.map(\.keys) == ["⌘N", "Tab", "⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘⇧T", nil, "⌘,"])
    for step in walk.steps {
      #expect(step.text.isComplete && step.why?.isComplete == true, "\(step.target)")
    }
    #expect(walk.steps.first?.text.russian == "Запись операции")
  }

  /// A card that speaks of a place shows it: one step, the card's own words.
  @Test func aCardWithAPlaceIsAWalkOfOneStep() throws {
    let cards = GuideCatalog.scenarios.flatMap(\.cards)
    let pointing = cards.filter { $0.target != nil }
    #expect(pointing.map(\.id).contains("first.line"))
    for card in cards {
      let walk = GuideWalkthrough(card: card)
      if let target = card.target {
        let walk = try #require(walk)
        #expect(walk.steps.count == 1)
        #expect(walk.current.target == target)
        #expect(walk.current.text == card.title)
        #expect(walk.current.why == card.body)
        #expect(walk.source == .card(card.id))
      } else {
        #expect(walk == nil)
      }
    }
  }

  /// The places the steps name are the ones the app marks; the ones outside the content are
  /// named as such.
  @Test func everyStepNamesAKnownPlace() {
    let known = Set([
      GuideTarget.entryLine, GuideTarget.entryDetails, GuideTarget.entryForWhom,
      GuideTarget.entryQuick, GuideTarget.sidebarOverview, GuideTarget.sidebarPlanning,
      GuideTarget.sidebarDebts, GuideTarget.sidebarOperations, GuideTarget.sidebarCalendar,
      GuideTarget.sidebarCapital, GuideTarget.operationsSearch, GuideTarget.operationsList,
      GuideTarget.planningAddPayment, GuideTarget.planningAddGoal,
      GuideTarget.planningFreeToSpend, GuideTarget.debtsAdd,
    ]).union(GuideTarget.outsideTheContent)
    let steps =
      GuideCatalog.tutorial.tasks.flatMap(\.hints) + GuideCatalog.whereToClick
      + GuideCatalog.scenarios.flatMap(\.cards).compactMap { card in
        card.target.map { GuideHint(target: $0, text: card.title) }
      }
    for step in steps {
      #expect(known.contains(step.target), "\(step.target)")
    }
  }
}
