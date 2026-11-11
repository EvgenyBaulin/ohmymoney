import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

struct ReconciliationSummaryTests {
  @Test func neitherSignChangesWeekMonthOrYearIncome() throws {
    let day = DateOnly(year: 2026, month: 9, day: 15)
    var book = SummaryBook()
    book.add(.init(amount: 1_000, kind: .income), on: day)
    let baseline = book.ledger
    for kind in [TransactionKind.income, .expense] {
      book.add(
        .init(amount: 700, kind: kind, externalId: OperationLink.reconciliation(UUID()).externalId),
        on: day)
      book.add(
        .init(
          amount: 50, kind: kind,
          externalId: OperationLink.reconciledBalance(reconciliation: UUID(), balance: UUID())
            .externalId), on: day)
    }
    let week = WeekKey(containing: day)
    #expect(WeekCards.build(week: week, ledger: book.ledger).total.income == AmountE4(whole: 1_000))
    for id in [SummaryID.month(day.monthKey), .year(2026)] {
      let actual = try #require(SummaryBuilder.summary(id: id, ledger: book.ledger, today: day))
      let expected = try #require(SummaryBuilder.summary(id: id, ledger: baseline, today: day))
      #expect(actual.income == expected.income)
      #expect(actual.expenses == expected.expenses)
    }
  }
}
