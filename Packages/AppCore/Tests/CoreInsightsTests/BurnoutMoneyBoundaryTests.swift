import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("Burnout: large stored amounts")
struct BurnoutMoneyBoundaryTests {
  @Test func anEvenSampleDoesNotOverflowWhileFindingItsMedian() {
    let today = DateOnly(year: 2026, month: 11, day: 15)
    let first = today.adding(days: -6)
    let essential = CoreKit.Category(kind: .expense, name: "Synthetic essential", essential: true)
    let optional = CoreKit.Category(kind: .expense, name: "Synthetic optional")
    let amount = AmountE4(raw: Int64.max / 2 + 1)
    let entries = (1...6).flatMap { week in
      (0..<2).map { offset in
        let id = UUID()
        return TransactionEntry(
          transaction: Transaction(
            id: id, kind: .expense,
            occurredAt: CalendarContext.utc.noon(of: first.adding(days: -7 * week + offset)),
            amountE4: amount),
          parts: [TransactionPart(transactionId: id, categoryId: optional.id, amountE4: amount)])
      }
    }
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: [essential, optional]), calendar: .utc)
    #expect(Burnout.check(ledger: ledger, tree: ledger.tree, today: today) == .quiet)
  }
}
