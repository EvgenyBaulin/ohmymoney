import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

/// «Качество модели» reads what the owner chose against the model (`category_feedback`):
/// how many choices were made, how many went elsewhere than the model offered
/// first, and how sure the model was when it was overruled.
@Suite("The owner's choices against the model in «Качество модели»")
struct ModelQualityChoicesTests {
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func entry(deleted: Bool = false) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    var entry = try draft.materialize()
    if deleted { entry.transaction.deletedAt = Date() }
    return entry
  }

  private func choice(
    of entry: TransactionEntry, predicted: UUID, chosen: UUID, confidence: Int
  ) -> CategoryFeedback {
    CategoryFeedback(
      text: "coffee", predictedCategoryId: predicted, chosenCategoryId: chosen,
      partId: entry.parts[0].id, confidenceBp: confidence, at: Date())
  }

  @Test func theChoicesAreCountedAndTheConfidenceWhenOverruledIsTheMedian() throws {
    let coffee = UUID()
    let taxi = UUID()
    let entries = try (0..<5).map { _ in try entry() }
    let gone = try entry(deleted: true)
    let dataset = Dataset(
      entries: entries + [gone],
      feedback: [
        choice(of: entries[0], predicted: coffee, chosen: coffee, confidence: 9_000),
        choice(of: entries[1], predicted: coffee, chosen: taxi, confidence: 7_000),
        choice(of: entries[2], predicted: coffee, chosen: taxi, confidence: 8_000),
        choice(of: entries[3], predicted: coffee, chosen: taxi, confidence: 6_000),
        // An operation deleted since is no longer the book the model is measured on.
        choice(of: gone, predicted: coffee, chosen: taxi, confidence: 100),
      ])

    let choices = ModelQuality.build(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today
    ).categories.choices

    #expect(choices.made == 4)
    #expect(choices.overruled == 3)
    #expect(choices.confidenceWhenOverruledBp == 7_000)
  }

  @Test func noChoiceNoFigure() {
    let choices = ModelQuality.build(
      ledger: Ledger(dataset: .empty, calendar: .utc), today: today
    ).categories.choices

    #expect(choices == ModelQuality.Choices())
    #expect(choices.confidenceWhenOverruledBp == nil)
  }
}
