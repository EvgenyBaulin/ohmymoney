import CoreKit
import Foundation
import Testing

@testable import CoreModel

@Suite("Monthly accuracy measured before learning")
struct MonthlyModelQualityTests {
  private let category = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  private func example(_ month: Int, _ index: Int) -> CategoryExample {
    CategoryExample(
      query: CategoryQuery(
        day: DateOnly(year: 2026, month: month, day: index + 1), weekday: 1,
        kind: .expense, text: "groceries", amountWhole: 100),
      partId: UUID(), categoryId: category)
  }

  @Test func coldMonthsAreAbsentAndHistoryCarriesAcrossMonths() {
    let examples =
      (0..<5).map { example(1, $0) }
      + (0..<2).map { example(3, $0) } + [example(4, 0)]
    let options = CategoryModelOptions(minimumExamples: 5, minimumPerClass: 5)
    let report = PrequentialEvaluation.report(on: Array(examples.reversed()), options: options)
    #expect(
      report.months.map(\.month) == [
        MonthKey(year: 2026, month: 3), MonthKey(year: 2026, month: 4),
      ])
    #expect(report.months.map(\.asked) == [2, 1])
    #expect(report.months.allSatisfy { $0.accuracyBp == 10_000 && $0.historyBp == 10_000 })
    #expect(report.months.map(\.asked).reduce(0, +) == report.metrics.asked)
    #expect(report.metrics == PrequentialEvaluation.run(on: examples, options: options))
  }

  @Test func theFirstAnswerCannotLearnItsOwnLabel() {
    let options = CategoryModelOptions(minimumExamples: 1, minimumPerClass: 1)
    let report = PrequentialEvaluation.report(on: [example(1, 0)], options: options)
    #expect(report.months.isEmpty)
    #expect(report.metrics.asked == 0)
    #expect(PrequentialEvaluation.report(on: []).months.isEmpty)
  }

  @Test func anUnseenCategoryIsWrongInItsOwnMonthRatherThanLearnedInAdvance() {
    var changed = example(2, 0)
    changed.categoryId = UUID()
    let options = CategoryModelOptions(minimumExamples: 1, minimumPerClass: 1)
    let report = PrequentialEvaluation.report(
      on: [example(1, 0), example(1, 1), changed], options: options)
    #expect(report.months.map(\.accuracyBp) == [10_000, 0])
    #expect(report.months.map(\.historyBp) == [10_000, 0])
    #expect(report.metrics.top1Bp == 5_000)
  }
}
