import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The monthly spending «Хватит ли?» waits with: the median of my expenses over the last three
/// full months.
@Suite("Spending behind «подождать до …»")
struct AffordSpendingTests {
  typealias Fx = CapitalFx

  let today = Fx.day("2026-10-11")
  let food = Fx.id(10)
  let goals = Fx.id(11)

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: food, kind: .expense, name: "Food"),
      CoreKit.Category(id: goals, kind: .expense, name: "Goals", systemRole: .goals),
    ]
  }

  func spending(_ entries: [TransactionEntry]) -> AffordSpending {
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
    return AffordSpending.build(ledger: ledger, today: today)
  }

  @Test func theMedianOfTheLastThreeFullMonths() {
    let result = spending([
      Fx.operation(1, "2026-06-10", "90000", category: food),  // older than three months
      Fx.operation(2, "2026-07-10", "30000", category: food),
      Fx.operation(3, "2026-08-10", "50000", category: food),
      Fx.operation(4, "2026-09-10", "40000", category: food),
      Fx.operation(5, "2026-10-02", "99000", category: food),  // the current month
    ])
    #expect(result.fullMonths == 3)
    #expect(result.medianRub == Fx.rub("40000"))
  }

  @Test func fewerThanThreeFullMonthsGiveNoMedian() {
    let result = spending([
      Fx.operation(1, "2026-08-10", "50000", category: food),
      Fx.operation(2, "2026-09-10", "40000", category: food),
    ])
    #expect(result.fullMonths == 2)
    #expect(result.medianRub == nil)
    #expect(spending([]).medianRub == nil)
  }

  @Test func refundsReduceAndCountsAndGoalsStayOut() {
    let purchase = Fx.operation(2, "2026-08-10", "50000", category: food)
    var refund = Fx.operation(3, "2026-08-20", "10000", kind: .refund, category: food)
    refund.parts[0].refundOfPartId = purchase.parts[0].id
    var contribution = Fx.operation(5, "2026-09-12", "7000", category: goals)
    contribution.parts[0].goalId = Fx.id(40)
    let result = spending([
      Fx.operation(1, "2026-07-10", "40000", category: food),
      purchase, refund,
      Fx.operation(4, "2026-09-10", "40000", category: food),
      contribution,
      // The difference of a count is no spending, and a part for somebody else is not mine.
      Fx.operation(6, "2026-09-15", "9999", category: food, link: .reconciliation(Fx.id(70))),
      Fx.operation(7, "2026-07-15", "8888", category: food, reimbursable: true),
    ])
    // July 40,000, August 50,000 − 10,000, September 40,000.
    #expect(result.medianRub == Fx.rub("40000"))
  }
}
