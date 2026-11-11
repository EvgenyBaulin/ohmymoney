import CoreAccounting
import CoreKit
import CoreModel
import Foundation
import Testing

@testable import CoreInsights

@Suite("Model quality carries monthly replay to settings")
struct ModelQualityMonthsTests {
  @Test func theSummaryAndMonthsComeFromTheSameTrainingParts() throws {
    let category = CoreKit.Category(kind: .expense, name: "Synthetic groceries")
    let entries = try (0..<4).map { index in
      let day = DateOnly(year: 2026, month: index < 2 ? 1 : 2, day: index + 1)
      let moment = CalendarContext.utc.startOfDay(day)
      var draft = TransactionDraft(
        occurredAt: moment, amount: AmountE4(whole: 100), note: "groceries")
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = category.id
      draft.parts[0].categorySource = .manual
      return try draft.materialize(now: moment, timeZone: TimeZone(secondsFromGMT: 0)!)
    }
    let ledger = Ledger(dataset: Dataset(entries: entries, categories: [category]), calendar: .utc)
    let options = CategoryModelOptions(minimumExamples: 1, minimumPerClass: 1)
    let expected = PrequentialEvaluation.report(
      on: LedgerTraining.examples(of: ledger.dataset, calendar: .utc), options: options)
    let categories = ModelQuality.build(
      ledger: ledger, today: DateOnly(year: 2026, month: 2, day: 20), options: options
    ).categories
    #expect(categories.examples == 4)
    #expect(categories.metrics == expected.metrics)
    #expect(categories.months == expected.months)
    #expect(categories.months.map(\.asked) == [1, 2])
  }

  @Test func anEmptyBookHasNoMadeUpPoints() {
    let categories = ModelQuality.build(
      ledger: Ledger(dataset: .empty, calendar: .utc),
      today: DateOnly(year: 2026, month: 2, day: 20)
    ).categories
    #expect(categories.examples == 0)
    #expect(categories.metrics == nil)
    #expect(categories.months.isEmpty)
  }
}
