import CoreKit
import Foundation
import Testing

@testable import CoreModel

/// The model is measured in the order things happened: predict, then learn. Anything else
/// measures a model that had already seen the answer.
@Suite("The model measured in the order things happened")
struct PrequentialEvaluationTests {
  private let groceries = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private let transport = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
  private let coffee = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

  /// A history with a pattern in it: each shop always goes to its own category.
  private func history(days: Int) -> [CategoryExample] {
    let places = [
      ("пятёрочка на углу", groceries), ("метро до работы", transport),
      ("кофейня у дома", coffee),
    ]
    return (0..<days).flatMap { day -> [CategoryExample] in
      places.enumerated().map { index, place in
        CategoryExample(
          query: CategoryQuery(
            day: DateOnly(year: 2026, month: 1 + day / 28, day: 1 + day % 28),
            weekday: 1 + day % 7, kind: .expense, text: place.0,
            amountWhole: Int64(100 + index * 50)),
          partId: UUID(), categoryId: place.1)
      }
    }
  }

  @Test func aPatternIsLearnedAndBeatsBothBaselines() {
    let metrics = PrequentialEvaluation.run(on: history(days: 40))

    #expect(metrics.asked > 0, "the model never got to answer")
    #expect(metrics.top1Bp > 9_000, "a plain pattern should be learned")
    #expect(metrics.top3Bp >= metrics.top1Bp)
    #expect(
      metrics.top1Bp > metrics.baselineMostFrequentBp,
      "the model did no better than always answering the commonest category")
    #expect(metrics.coverageBp > 0, "the model was never sure enough to fill in")
    #expect(metrics.precisionBp > 8_000, "it filled in the wrong thing too often")
  }

  /// Measured against «the last category for the same description». On a history where
  /// the text alone decides, that baseline is very strong — and the model must not be worse.
  @Test func theModelIsNotWorseThanTheLastCategoryForTheSameWords() {
    let metrics = PrequentialEvaluation.run(on: history(days: 40))

    #expect(metrics.top1Bp >= metrics.baselineLastSameTextBp - 200)
  }

  /// Nothing is asked before the model is allowed to speak.
  @Test func nothingIsAskedBelowTheThreshold() {
    let metrics = PrequentialEvaluation.run(on: history(days: 5))

    #expect(metrics.examples == 15)
    #expect(metrics.asked == 0, "the model answered below its own threshold")
  }

  /// Per-class recall and support are what «Качество модели» shows, so they have to add up.
  @Test func everyClassAskedAboutIsCounted() {
    let metrics = PrequentialEvaluation.run(on: history(days: 40))

    #expect(Set(metrics.recallByClass.keys) == Set(metrics.supportByClass.keys))
    #expect(metrics.supportByClass.values.reduce(0, +) == metrics.asked)
    for (_, recall) in metrics.recallByClass { #expect((0...10_000).contains(recall)) }
    #expect((0...10_000).contains(metrics.macroF1Bp))
  }

  /// Two classes taking turns: at every groceries question the two counts are tied, and the
  /// «most frequent» baseline has to break the tie. It breaks it by the smallest id, as the
  /// model does (`CategoryModelScoring`), and not by the order a dictionary happens to walk
  /// in — that order changes from one dictionary to the next, from one launch to the next and
  /// between macOS and Linux, and the number is meant to be pasted into a report. The 50
  /// groceries questions are right, the 50 transport ones wrong (groceries leads by one).
  @Test func aTieOfTheMostFrequentBaselineIsBrokenTheSameWayEveryTime() {
    let turns = (0..<100).map { index in
      let groceriesTurn = index % 2 == 0
      return CategoryExample(
        query: CategoryQuery(
          day: DateOnly(year: 2026, month: 1 + index / 28, day: 1 + index % 28),
          weekday: 1 + index % 7, kind: .expense, text: groceriesTurn ? "пятёрочка" : "метро",
          amountWhole: 200),
        partId: UUID(), categoryId: groceriesTurn ? groceries : transport)
    }

    for _ in 0..<20 {
      let metrics = PrequentialEvaluation.run(on: turns)
      #expect(metrics.asked == 50)
      #expect(metrics.baselineMostFrequentBp == 5_000)
    }
  }

  /// The entry line offers an expense only expense categories and an income only income ones
  /// (`CategoryQuery.kind`), and the evaluation asks the same question. «перевод» is a gift
  /// when it is spent and a transfer from the family when it comes in — four times as often.
  /// Asked about the gift, the model must not answer with the income category it could never
  /// offer there, and «the commonest so far» is the commonest expense category, not the
  /// transfer: of seven questions a day, four income and two groceries are its right ones.
  /// The same holds for the last category used for the same words.
  @Test func anExpenseIsAnsweredOnlyWithCategoriesOfItsKind() {
    let gifts = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let transfers = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    var number = 0
    func example(
      _ day: Int, _ kind: CategoryKind, _ text: String, _ category: UUID
    )
      -> CategoryExample
    {
      number += 1
      return CategoryExample(
        query: CategoryQuery(
          day: DateOnly(year: 2026, month: 1 + day / 28, day: 1 + day % 28),
          weekday: 1 + day % 7, kind: kind, text: text, amountWhole: 500),
        partId: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
        categoryId: category)
    }
    var examples: [CategoryExample] = []
    for day in 0..<40 {
      examples += (0..<4).map { _ in example(day, .income, "перевод", transfers) }
      examples += (0..<2).map { _ in example(day, .expense, "продукты", groceries) }
      examples.append(example(day, .expense, "перевод", gifts))
    }

    let metrics = PrequentialEvaluation.run(on: examples)

    #expect(metrics.asked > 0)
    #expect(metrics.recallByClass[gifts] == 10_000, "a gift was answered with an income")
    #expect(metrics.top1Bp == 10_000)
    #expect(
      metrics.baselineMostFrequentBp > 8_000, "the baseline answered spending with an income")
    // The last category for the same words is the last one of the same kind, as the entry
    // line's history level has it: the gift's last «перевод» spent, not the one that came in.
    #expect(metrics.baselineLastSameTextBp == 10_000)
  }

  /// Macro-F1 adds the classes up in a fixed order: floating-point addition is not
  /// associative, and the dictionary's order would move the last basis point.
  @Test func macroF1AddsTheClassesUpInOneOrder() {
    let ids = (1...12).map {
      UUID(uuidString: String(format: "%08d-0000-0000-0000-000000000000", $0))!
    }
    var hits: [UUID: Int] = [:]
    var support: [UUID: Int] = [:]
    var predicted: [UUID: Int] = [:]
    for (index, id) in ids.enumerated() {
      hits[id] = index + 1
      support[id] = 3 * index + 7
      predicted[id] = 2 * index + 5
    }
    let once = PrequentialEvaluation.macroF1(hits: hits, support: support, predicted: predicted)
    for _ in 0..<20 {
      // The same contents, built in another order: another dictionary, another walk.
      let shuffled = ids.shuffled()
      let again = PrequentialEvaluation.macroF1(
        hits: Dictionary(uniqueKeysWithValues: shuffled.map { ($0, hits[$0]!) }),
        support: Dictionary(uniqueKeysWithValues: shuffled.map { ($0, support[$0]!) }),
        predicted: Dictionary(uniqueKeysWithValues: shuffled.map { ($0, predicted[$0]!) }))
      #expect(again == once)
    }
  }

  /// The same history twice gives the same numbers: a measurement that wanders is not one.
  @Test func theSameHistoryGivesTheSameNumbers() {
    let examples = history(days: 30)
    #expect(
      PrequentialEvaluation.run(on: examples) == PrequentialEvaluation.run(on: examples.reversed()))
  }
}
