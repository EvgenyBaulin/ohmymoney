import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The income a month is expected to bring, on random books with no expectation for it: what
/// came this month by today, or the median of the last complete months — at most three, none
/// before the book's first whole month — when that is more; months without income next to one that
/// had some are real zeros; with no income in any of them, only what came, marked «мало
/// данных».
@Suite("The income of the month by the median of the months before")
struct IncomeEstimatePropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...50)

  /// Random incomes from a random first day of the book — some written for the next month —
  /// against the rule: received is this month's by today; the median is of the months from the
  /// book's first whole month — its first month when it began on the 1st, else the next —
  /// through the last complete one, three at most, the midpoint of the two middle ones rounded
  /// half up; the estimate is the larger of the two, or what came.
  @Test(arguments: seeds)
  func withoutAnExpectationTheMedianOfUpToThreeMonths(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &* 73 &+ 1)
    var fx = Fx()
    let start = Fx.day("2026-04-01").adding(days: random.int(in: 0...170))
    // Something on the first day, so the book starts there.
    fx.add(.expense, "100", at: Fx.at(start.iso, 9))
    var byMonth: [MonthKey: AmountE4] = [:]
    var received = AmountE4.zero
    let span = max(0, start.days(to: Fx.day("2026-09-30")))
    for _ in 0..<random.int(in: 0...10) {
      let day = start.adding(days: random.int(in: 0...span))
      let amount = AmountE4(whole: Int64(random.int(in: 1...150) * 1_000))
      let id = fx.add(
        .income, amount.decimal.description, at: Fx.at(day.iso, 10), category: Fx.salary)
      var month = day.monthKey
      if random.chance(1, outOf: 5), let index = fx.entries.firstIndex(where: { $0.id == id }) {
        // Written for the next month, as an advance.
        month = month.next
        fx.entries[index].transaction.periodMonth = month
      }
      byMonth[month, default: .zero] += amount
      if month == Fx.today.monthKey, day <= Fx.today { received += amount }
    }
    let estimate = IncomeEstimate.month(ledger: fx.ledger, statuses: [], today: Fx.today)

    var history: [MonthKey] = []
    var month = Fx.today.monthKey.previous
    let firstWhole = start.day == 1 ? start.monthKey : start.monthKey.next
    while history.count < 3, month >= firstWhole {
      history.insert(month, at: 0)
      month = month.previous
    }
    let incomes = history.map { byMonth[$0] ?? .zero }.sorted()
    var median: AmountE4?
    if incomes.contains(where: { $0.raw > 0 }) {
      let middle = incomes.count / 2
      median =
        incomes.count % 2 == 1
        ? incomes[middle]
        : AmountE4(raw: (incomes[middle - 1].raw + incomes[middle].raw + 1) / 2)
    }
    #expect(estimate.received == received, "seed \(seed)")
    #expect(estimate.median3 == median, "seed \(seed): \(history)")
    #expect(estimate.monthsInMedian == (median == nil ? 0 : history.count), "seed \(seed)")
    if let median {
      #expect(estimate.value == max(received, median), "seed \(seed)")
      #expect(estimate.source == .median)
    } else {
      #expect(estimate.value == (received.raw > 0 ? received : nil), "seed \(seed)")
      #expect(estimate.source == .receivedOnly)
      #expect(estimate.lowData)
    }
  }

  /// A book begun on 25 July, after July's salary: July is only part of a month and no history
  /// of income, so the median is August's 100 000 alone — not the 50 000 a zero July would
  /// make of it.
  @Test func aBookBegunMidMonthLeavesItsFirstMonthOut() {
    var fx = Fx()
    fx.add(.expense, "500", at: Fx.at("2026-07-25", 12))
    fx.add(.income, "100000", at: Fx.at("2026-08-05", 10), category: Fx.salary)
    let estimate = IncomeEstimate.month(ledger: fx.ledger, statuses: [], today: Fx.today)
    #expect(estimate.monthsInMedian == 1)
    #expect(estimate.median3 == Fx.money("100000"))
    #expect(estimate.value == Fx.money("100000"))
  }
}
