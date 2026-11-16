import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("Period board: money audit regressions")
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
    #expect(AmountE4.sum(board.slices.map(\.amount)) == board.spent)
    #expect(board.slices.map(\.shareBP).reduce(0, +) == Shares.whole)
    #expect(board.slices.count == 1)
    let slice = try #require(board.slices.first)
    #expect(slice.isUncategorized)
    #expect(slice.id == "uncategorized")
    let filter = try #require(slice.operationsFilter(in: board.range))
    #expect(filter.uncategorizedOnly)
    #expect(filter.apply(to: ledger) == [id])
  }

  @Test func uncategorizedAndOtherRemainSeparateWhenThereAreMoreThanFourCategories() throws {
    let day = DateOnly(year: 2026, month: 11, day: 1)
    let categories = (1...5).map { CoreKit.Category(kind: .expense, name: "Synthetic \($0)") }
    let entries = (0..<6).map { index in
      let id = UUID()
      let amount = AmountE4(whole: 100)
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense, occurredAt: CalendarContext.utc.noon(of: day), amountE4: amount),
        parts: [
          TransactionPart(
            transactionId: id, categoryId: index < 5 ? categories[index].id : nil, amountE4: amount)
        ])
    }
    let ledger = Ledger(dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
    let board = try #require(PeriodBoard.build(.month(day.monthKey), ledger: ledger, today: day))
    #expect(board.slices.count == 6)
    #expect(Set(board.slices.map(\.id)).count == 6)
    #expect(board.slices.filter(\.isUncategorized).count == 1)
    #expect(board.slices.first { $0.id == "rest" }?.amount == AmountE4(whole: 100))
    #expect(AmountE4.sum(board.slices.map(\.amount)) == board.spent)
    #expect(board.slices.map(\.shareBP).reduce(0, +) == Shares.whole)
  }

  @Test func savedUncategorizedFiltersRoundTripAndOlderFiltersStillRead() throws {
    let day = DateOnly(year: 2026, month: 11, day: 1)
    let saved = SavedFilter(
      name: "Synthetic", filter: EntryFilter(uncategorizedOnly: true), period: nil)
    let data = try JSONEncoder().encode(saved)
    let decoded = try JSONDecoder().decode(SavedFilter.self, from: data)
    #expect(decoded.entryFilter(today: day).uncategorizedOnly)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "uncategorizedOnly")
    let old = try JSONSerialization.data(withJSONObject: object)
    #expect(
      try !JSONDecoder().decode(SavedFilter.self, from: old).entryFilter(today: day)
        .uncategorizedOnly)
  }
}
