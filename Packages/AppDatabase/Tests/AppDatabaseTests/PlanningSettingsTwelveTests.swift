import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The planning settings as the repository reads them from the settings table: the valuation of
/// goal money, the counts whose difference is real, the answers about a count, and the two
/// categories of the reconciliation, which the planning only reads.
@Suite("The planning reads its new settings from the database")
struct PlanningSettingsTwelveTests {
  /// Written through a change of the planning — one step of ⌘Z — and read back by the book;
  /// ⌘Z takes them away again.
  @Test func theThreeKeysRoundTripThroughTheBook() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let kept: Set<UUID> = [UUID(), UUID()]
    let answers = [UUID(): true, UUID(): false]
    let written = PlanningSettings(
      goalSavingsValuation: .deposits, firstCountKept: kept, beforeCountAnswers: answers)
    var settings: [String: String?] = [:]
    for key in [
      PlanningSettings.goalSavingsValuationKey, PlanningSettings.firstCountKeptKey,
      PlanningSettings.beforeCountAnswersKey,
    ] {
      settings.updateValue(written.storedValues[key] ?? nil, forKey: key)
    }
    let undo = try repository.apply(PlanningChange(settings: settings))
    let read = try repository.book().settings
    #expect(read.goalSavingsValuation == .deposits)
    #expect(read.firstCountKept == kept)
    #expect(read.beforeCountAnswers == answers)

    try repository.revert(undo)
    let back = try repository.book().settings
    #expect(back.goalSavingsValuation == .today)
    #expect(back.firstCountKept.isEmpty)
    #expect(back.beforeCountAnswers.isEmpty)
  }

  /// The categories the reconciliation remembers are in what the planning reads — so no limit
  /// is offered on them — though the planning never writes them.
  @Test func theReconcileCategoriesAreReadByTheRepository() async throws {
    let stack = try TestSupport.makeStack()
    let expense = UUID()
    let income = UUID()
    let settings = SettingsRepository(writer: stack.writer)
    try settings.set(PlanningSettings.reconcileExpenseCategoryKey, to: expense.uuidString)
    try settings.set(PlanningSettings.reconcileIncomeCategoryKey, to: income.uuidString)
    try settings.set(PlanningSettings.goalSavingsValuationKey, to: "gibberish")

    let read = try PlanningRepository(writer: stack.writer).book().settings
    #expect(read.reconcileExpenseCategoryId == expense)
    #expect(read.reconcileIncomeCategoryId == income)
    #expect(read.limitlessCategoryIds == [expense, income])
    #expect(read.goalSavingsValuation == .today)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    #expect(dataset.planning.settings.limitlessCategoryIds == [expense, income])
  }
}
