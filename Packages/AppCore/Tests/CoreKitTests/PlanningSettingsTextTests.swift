import Foundation
import Testing

@testable import CoreKit

/// The answers «Это было до сверки?» remembered per reconciliation are one text in the
/// `settings` table: «<uuid> before» or «<uuid> after», one per line, sorted by id.
@Suite("The remembered answers about a count read and write as one text")
struct PlanningSettingsTextTests {
  private let first = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let second = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  @Test func countAnswersRoundTrip() throws {
    let answers = [second: false, first: true]
    let text = try #require(PlanningSettings.countAnswersText(answers))
    #expect(
      text
        == "11111111-2222-3333-4444-555555555555 before\n"
        + "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE after")
    #expect(PlanningSettings.countAnswers(from: text) == answers)
  }

  @Test func unreadableLinesAreSkipped() {
    let text = """
      not-a-uuid before
      11111111-2222-3333-4444-555555555555 maybe
      \(second.uuidString) after

        \(first.uuidString.lowercased())   before  \r
      \(first.uuidString)
      """
    #expect(PlanningSettings.countAnswers(from: text) == [first: true, second: false])
  }

  @Test func noAnswerIsNoText() {
    #expect(PlanningSettings.countAnswersText([:]) == nil)
    #expect(PlanningSettings.countAnswers(from: nil) == [:])
    #expect(PlanningSettings.countAnswers(from: "") == [:])
  }

  @Test func theSameAnswersAreAlwaysTheSameText() {
    var many: [UUID: Bool] = [:]
    for index in 0..<40 { many[UUID()] = index % 3 == 0 }
    let text = PlanningSettings.countAnswersText(many)
    #expect(
      PlanningSettings.countAnswersText(Dictionary(uniqueKeysWithValues: many.shuffled())) == text)
    #expect(PlanningSettings.countAnswers(from: text) == many)
  }

  /// «Сверка» and its income twin are the categories no limit may be set on.
  @Test func theLimitlessCategoriesAreTheTwoOfTheReconciliation() {
    #expect(PlanningSettings().limitlessCategoryIds.isEmpty)
    let expense = UUID()
    let income = UUID()
    let settings = PlanningSettings(
      reconcileExpenseCategoryId: expense, reconcileIncomeCategoryId: income)
    #expect(settings.limitlessCategoryIds == [expense, income])
    #expect(
      PlanningSettings(reconcileExpenseCategoryId: expense).limitlessCategoryIds == [expense])
  }

  @Test func theNewSettingsHaveTheirDefaults() {
    let settings = PlanningSettings()
    #expect(settings.goalSavingsValuation == .today)
    #expect(settings.firstCountKept.isEmpty)
    #expect(settings.beforeCountAnswers.isEmpty)
    #expect(settings.reconcileExpenseCategoryId == nil)
    #expect(settings.reconcileIncomeCategoryId == nil)
    #expect(PlanningSettings.goalSavingsValuationKey == "planning.goalSavingsValuation")
    #expect(PlanningSettings.firstCountKeptKey == "reconcile.firstCountKept")
    #expect(PlanningSettings.beforeCountAnswersKey == "reconcile.beforeCountAnswers")
    #expect(GoalSavingsValuation(rawValue: "deposits") == .deposits)
    #expect(ReconciliationOrigin.allCases.map(\.rawValue) == ["setup", "account", "merge"])
  }
}
