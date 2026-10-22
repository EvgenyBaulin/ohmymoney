import CoreAnalytics
import CoreKit
import CoreParse
import CoreSample
import Foundation
import Testing

@testable import CoreInsights

/// Answering on the large synthetic set — about 20 000 operations over two years. Only
/// `make bench` runs the stopwatch (release, `OHMYMONEY_BENCH=1`). The questions run on
/// Enter, not on every keystroke, but the answer has to come before the owner looks away.
@Suite("Time budgets of the answers", .serialized, .enabled(if: InsightsBench.isOn))
struct QuestionAnswerPerformanceTests {
  static let calendar = CalendarContext.moscow
  static let set = SampleDataGenerator(seed: 20_260_918).generate(
    months: SampleDataGenerator.largeSetMonths,
    endingOn: DateOnly(year: 2026, month: 9, day: 18), calendar: calendar, language: "en",
    density: SampleDataGenerator.largeSetDensity)
  static let dataset = Dataset(
    entries: set.entries, links: set.links, categories: set.categories, people: set.people,
    places: set.places, events: set.events, paymentMethods: set.paymentMethods,
    debts: set.debts, goals: set.goals, planning: set.planningBook,
    settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))
  static let ledger = Ledger(dataset: dataset, calendar: calendar)
  static let today = DateOnly(year: 2026, month: 9, day: 18)

  private func category() -> String {
    Self.dataset.categories.first { $0.kind == .expense && $0.parentId == nil }?.name ?? "x"
  }

  @Test func buildingTheDesk() {
    let times = InsightsBench.measure("question desk, \(Self.ledger.rows.count) rows") {
      _ = QuestionDesk(ledger: Self.ledger, today: Self.today)
    }
    #expect(times.median < .milliseconds(20))
  }

  @Test func howMuchOnACategory() {
    let desk = QuestionDesk(ledger: Self.ledger, today: Self.today)
    let name = category()
    let times = InsightsBench.measure("how much on a category, a month", runs: 9) {
      _ = desk.ask("how much on \(name) in august")
    }
    #expect(times.median < .milliseconds(40))
  }

  @Test func howMuchOnAWordInTheNotes() {
    let desk = QuestionDesk(ledger: Self.ledger, today: Self.today)
    let times = InsightsBench.measure("how much on a word, two years", runs: 5) {
      _ = desk.ask("how much on zzzword in the last 24 months")
    }
    #expect(times.median < .milliseconds(80))
  }

  @Test func comparingAYear() {
    let desk = QuestionDesk(ledger: Self.ledger, today: Self.today)
    let name = category()
    let times = InsightsBench.measure("compare a year with the last", runs: 5) {
      _ = desk.ask("compare \(name) with last year")
    }
    #expect(times.median < .milliseconds(80))
  }

  @Test func whatGrewAndTheLargest() {
    let desk = QuestionDesk(ledger: Self.ledger, today: Self.today)
    let grew = InsightsBench.measure("what grew beyond the usual", runs: 5) {
      _ = desk.ask("what grew this month")
    }
    #expect(grew.median < .milliseconds(150))
    let biggest = InsightsBench.measure("the largest categories", runs: 5) {
      _ = desk.ask("what did I spend the most on last year")
    }
    #expect(biggest.median < .milliseconds(80))
  }
}
