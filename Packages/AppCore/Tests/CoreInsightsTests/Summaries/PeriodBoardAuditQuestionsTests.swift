import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("Period board: unresolved money audit questions")
struct PeriodBoardAuditQuestionsTests {
  @Test func uncategorizedSpendingDoesNotDisappearFromTheRing() throws {
    let day = DateOnly(year: 2026, month: 11, day: 1)
    let id = UUID()
    let amount = AmountE4(whole: 500)
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: CalendarContext.utc.noon(of: day), amountE4: amount),
      parts: [TransactionPart(transactionId: id, amountE4: amount)])
    let ledger = Ledger(dataset: Dataset(entries: [entry]), calendar: .utc)
    let board = try #require(PeriodBoard.build(.month(day.monthKey), ledger: ledger, today: day))
    #expect(board.spent == amount)
    withKnownIssue("Choose a separate uncategorized slice or include it in Other") {
      #expect(AmountE4.sum(board.slices.map(\.amount)) == board.spent)
    }
  }
}
