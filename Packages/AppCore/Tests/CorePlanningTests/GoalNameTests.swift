import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Two live goals of one name confuse the entry line («цель отпуск 5000» goes to the first), the
/// pickers and the analytics, so a name is taken once among the live goals — when a goal is made,
/// renamed or brought back from the archive.
@Suite("The names of live goals")
struct GoalNameTests: SavingsFixtures {
  private func goal(_ name: String, archived: Bool = false, id: Int) -> Goal {
    Goal(id: uid(id), name: name, targetE4: rub("100000"), archived: archived)
  }

  /// The names are compared as the entry line compares them: case, «ё»/«е», the spaces around.
  @Test func aNameRepeatsALiveGoalOfTheSameName() {
    let goals = [goal("Отпуск", id: 1), goal("Ёлка", id: 2), goal("Машина", id: 3)]
    #expect(GoalRules.liveNamesake(of: "Отпуск", among: goals)?.id == uid(1))
    #expect(GoalRules.liveNamesake(of: "отпуск", among: goals)?.id == uid(1))
    #expect(GoalRules.liveNamesake(of: "  ОТПУСК ", among: goals)?.id == uid(1))
    #expect(GoalRules.liveNamesake(of: "елка", among: goals)?.id == uid(2))
    #expect(GoalRules.liveNamesake(of: "Дача", among: goals) == nil)
  }

  @Test func aNameThatSaysNothingRepeatsNothing() {
    let goals = [goal("Отпуск", id: 1), goal("  ", id: 2)]
    #expect(GoalRules.liveNamesake(of: "", among: goals) == nil)
    #expect(GoalRules.liveNamesake(of: "   ", among: goals) == nil)
  }

  /// Saving a goal again under its own name is an edit of the same goal, not a repeat.
  @Test func aGoalIsNoNamesakeOfItself() {
    let goals = [goal("Отпуск", id: 1), goal("Машина", id: 2)]
    #expect(GoalRules.liveNamesake(of: "Отпуск", excluding: uid(1), among: goals) == nil)
    #expect(GoalRules.liveNamesake(of: "ОТПУСК", excluding: uid(1), among: goals) == nil)
  }

  /// A rename to the name another live goal has is a repeat all the same.
  @Test func aRenameRepeatsAnotherLiveGoal() {
    let goals = [goal("Отпуск", id: 1), goal("Машина", id: 2)]
    #expect(GoalRules.liveNamesake(of: "отпуск", excluding: uid(2), among: goals)?.id == uid(1))
  }

  /// A goal in the archive does not stand in the way: the archive has its own answer —
  /// bring it back or delete it (`archivedNamesake`).
  @Test func anArchivedGoalIsNotALiveNamesake() {
    let goals = [goal("Отпуск", archived: true, id: 1)]
    #expect(GoalRules.liveNamesake(of: "Отпуск", among: goals) == nil)
    #expect(GoalRules.archivedNamesake(of: "Отпуск", among: goals)?.id == uid(1))
  }

  /// Bringing an archived goal back is a live goal appearing: it repeats a live one of its name.
  @Test func aGoalBroughtBackRepeatsALiveOneOfItsName() {
    let old = goal("Отпуск", archived: true, id: 1)
    let goals = [old, goal("Отпуск", id: 2)]
    #expect(GoalRules.liveNamesake(of: old.name, excluding: old.id, among: goals)?.id == uid(2))
  }
}
