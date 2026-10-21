import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreInsights
@testable import CoreModel

/// The ledger turned into what the model learns from — on the synthetic history the whole
/// project is tested against, so the numbers below are the ones `make sample` produces.
@Suite("The ledger turned into what the model learns from")
struct LedgerTrainingTests {
  private static let endingOn = DateOnly(year: 2026, month: 9, day: 18)

  private func dataset(months: Int = 6) -> Dataset {
    let set = SampleDataGenerator(seed: 20_260_920).generate(
      months: months, endingOn: Self.endingOn, calendar: .moscow, language: "en")
    return Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))
  }

  @Test func theSyntheticHistoryGivesTheModelSomethingToLearnFrom() {
    let examples = LedgerTraining.examples(of: dataset(), calendar: .moscow)

    // Six months of the sample teach the model several hundred operations — comfortably
    // past the fifty needed before it may say anything.
    #expect(
      examples.count > CategoryModelOptions.standard.minimumExamples,
      "the sample does not teach the model enough to turn it on")
    #expect(examples.count == Set(examples.map(\.partId)).count, "a part was counted twice")
  }

  /// Every rule of `CategoryTraining` holds on real rows, not only on hand-made ones.
  @Test func nothingSystemOrWrittenByTheApplicationIsLearnedFrom() {
    let dataset = dataset()
    let rows = LedgerTraining.rows(of: dataset, calendar: .moscow)
    let learned = Set(CategoryTraining.examples(from: rows).map(\.partId))

    for row in rows where learned.contains(row.partId) {
      #expect(row.systemRole == nil, "a system category was learned from")
      #expect(row.externalId == nil, "an operation the app wrote was learned from")
      #expect(row.categorySource != .model)
      #expect(!row.isDeleted)
    }
  }

  /// The question the entry line asks about a draft (`query(draft:calendar:)`, which
  /// `EntryDraftModel` asks the model) is the question the model is taught with once that
  /// operation is saved (`rows(of:calendar:)`) — if the two ever differ, the model answers
  /// something it was never taught. The draft is the one the ↓ panel reopens the operation as,
  /// and both sides read the day in the same calendar.
  @Test func theQuestionIsTheSameWhenLearningAndWhenAsking() throws {
    let dataset = dataset()
    let rows = LedgerTraining.rows(of: dataset, calendar: .moscow)
    // A purchase in rubles and one in dollars from the sample, found by what they are.
    let ruble = try #require(
      dataset.entries.first { $0.parts.count == 1 && $0.transaction.currency == .rub })
    let foreign = try #require(
      dataset.entries.first { $0.parts.count == 1 && $0.transaction.currency != .rub })

    for entry in [ruble, foreign] + Self.handMade() {
      let taught = LedgerTraining.rows(
        of: Dataset(entries: [entry], categories: dataset.categories), calendar: .moscow)
      let row = try #require(
        (rows + taught).first { $0.partId == entry.parts[0].id }, "\(entry.transaction.note ?? "")")
      let asked = LedgerTraining.query(draft: TransactionDraft(entry: entry), calendar: .moscow)
      #expect(asked == row.query, "\(entry.transaction.note ?? "")")
    }
  }

  /// Operations the sample does not pin down: one stamped late in the evening UTC, which is
  /// already the next day in Moscow, in dollars at 90; and a split whose first part has a
  /// description of its own.
  private static func handMade() -> [TransactionEntry] {
    let late = Date(timeIntervalSince1970: 1_789_770_600)  // 2026-09-18 22:30 UTC
    let dollars = UUID()
    let lateEntry = TransactionEntry(
      transaction: Transaction(
        id: dollars, kind: .expense, occurredAt: late, currency: .usd,
        amountE4: AmountE4(whole: 50), rate: 90, rateSource: .cbr,
        amountRubE4: AmountE4(whole: 4_500), note: "late dollars", createdAt: late,
        updatedAt: late),
      parts: [
        TransactionPart(
          transactionId: dollars, amountE4: AmountE4(whole: 50),
          amountRubE4: AmountE4(whole: 4_500))
      ])
    let split = UUID()
    let splitEntry = TransactionEntry(
      transaction: Transaction(
        id: split, kind: .expense, occurredAt: late, currency: .rub,
        amountE4: AmountE4(whole: 1_000), amountRubE4: AmountE4(whole: 1_000),
        note: "market", createdAt: late, updatedAt: late),
      parts: [
        TransactionPart(
          transactionId: split, amountE4: AmountE4(whole: 600), amountRubE4: AmountE4(whole: 600),
          note: "cheese"),
        TransactionPart(
          transactionId: split, amountE4: AmountE4(whole: 400), amountRubE4: AmountE4(whole: 400)),
      ])
    return [lateEntry, splitEntry]
  }
}
