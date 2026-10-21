import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Последняя запись» on Overview: the moment the owner last wrote an operation or a transfer.
/// It is the moment of writing, not the day the money moved, and it is the owner's writing:
/// lines the app keeps the books with, and deleted operations, do not count.
@Suite("The moment of the last record")
struct LastRecordTests {
  /// A moment of 27.09.2026 in UTC, the calendar of these ledgers.
  static func at(_ hour: Int, _ minute: Int = 0, day: Int = 27) -> Date {
    CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: day))
      .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
  }

  static func operation(
    happened: Date, written: Date, updated: Date? = nil, deleted: Date? = nil,
    link: OperationLink? = nil, kind: TransactionKind = .expense
  ) -> TransactionEntry {
    let id = UUID()
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: happened, amountE4: AmountE4(whole: 250),
        externalId: link?.externalId, createdAt: written, updatedAt: updated ?? written,
        deletedAt: deleted),
      parts: [TransactionPart(transactionId: id, amountE4: AmountE4(whole: 250))])
  }

  static func transfer(written: Date) -> Transfer {
    Transfer(
      occurredAt: written, fromAccountId: UUID(), fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_000), toAccountId: UUID(), toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1_000), createdAt: written, updatedAt: written)
  }

  static func lastRecord(
    _ entries: [TransactionEntry], transfers: [Transfer] = []
  ) -> Date? {
    OverviewSummary.lastRecordedAt(Dataset(entries: entries, transfers: transfers))
  }

  @Test func theLatestWriteOfAnOperationOrATransferIsTheLastRecord() {
    let coffee = Self.operation(happened: Self.at(14, 30), written: Self.at(14, 32))
    #expect(Self.lastRecord([coffee]) == Self.at(14, 32))
    let moved = Self.transfer(written: Self.at(14, 50))
    #expect(Self.lastRecord([coffee], transfers: [moved]) == Self.at(14, 50))
    // A transfer written before the operation leaves the operation the last.
    let earlier = Self.transfer(written: Self.at(9))
    #expect(Self.lastRecord([coffee], transfers: [earlier]) == Self.at(14, 32))
  }

  @Test func anOperationOfAnEarlierDayWrittenNowIsWrittenNow() {
    // A purchase of 12.09 typed at 14:35 of 27.09 — the owner wrote it now.
    let coffee = Self.operation(happened: Self.at(14, 30), written: Self.at(14, 32))
    let backdated = Self.operation(happened: Self.at(12, day: 12), written: Self.at(14, 35))
    #expect(Self.lastRecord([coffee, backdated]) == Self.at(14, 35))
  }

  @Test func anEditDoesNotMoveTheLastRecord() {
    // Corrected at 18:00: the moment it was first written stays.
    let edited = Self.operation(
      happened: Self.at(9), written: Self.at(9, 5), updated: Self.at(18))
    #expect(Self.lastRecord([edited]) == Self.at(9, 5))
  }

  @Test func aDeletedOperationDoesNotCount() {
    let coffee = Self.operation(happened: Self.at(9), written: Self.at(9, 5))
    let deleted = Self.operation(
      happened: Self.at(15), written: Self.at(15, 1), deleted: Self.at(15, 2))
    #expect(Self.lastRecord([coffee, deleted]) == Self.at(9, 5))
  }

  @Test func aLineTheAppKeepsTheBooksWithDoesNotCount() {
    let coffee = Self.operation(happened: Self.at(14, 30), written: Self.at(14, 35))
    // A reconciliation at 14:40 writes its difference; money back at 15:00 writes a surplus.
    let difference = Self.operation(
      happened: Self.at(14, 40), written: Self.at(14, 40),
      link: .reconciledBalance(reconciliation: UUID(), balance: UUID()), kind: .income)
    let surplus = Self.operation(
      happened: Self.at(15), written: Self.at(15),
      link: .surplus(reimbursement: UUID().uuidString.lowercased()), kind: .income)
    #expect(Self.lastRecord([coffee, difference, surplus]) == Self.at(14, 35))
    // A fee the bank took on a transfer is a real operation, written by the owner's transfer.
    let fee = Self.operation(
      happened: Self.at(16), written: Self.at(16), link: .transferFee(UUID()))
    #expect(Self.lastRecord([coffee, difference, fee]) == Self.at(16))
  }

  @Test func anEmptyBookHasNoLastRecord() {
    #expect(Self.lastRecord([]) == nil)
    // Nothing but lines of the books is nothing the owner wrote.
    let difference = Self.operation(
      happened: Self.at(14, 40), written: Self.at(14, 40),
      link: .reconciliation(UUID()), kind: .income)
    #expect(Self.lastRecord([difference]) == nil)
  }
}
