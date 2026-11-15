import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Amounts far beyond what anyone types — an archive, a CSV or a row of an older build may hold
/// any `Int64` — must not turn the SQL sums of the repositories into errors.
@Suite("Large amounts in the database")
struct LargeAmountsStorageTests {
  let moment = Date(timeIntervalSince1970: 1_789_000_000)

  /// An operation of `amount` whose parts are `parts`, written as it is: the parts add up to
  /// the amount only as `AmountE4` adds them up, clamped at the edge of `Int64`.
  private func hugeEntry(amount: Int64, parts: [Int64]) -> TransactionEntry {
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: moment, currency: .rub, amountE4: AmountE4(raw: amount),
      amountRubE4: AmountE4(raw: amount))
    let id = transaction.id
    return TransactionEntry(
      transaction: transaction,
      parts: parts.map {
        TransactionPart(
          transactionId: id, amountE4: AmountE4(raw: $0), amountRubE4: AmountE4(raw: $0))
      })
  }

  @Test func theCheckOfTheDatabaseSurvivesPartsThatAddUpBeyondInt64() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(hugeEntry(amount: Int64.max, parts: [Int64.max, Int64.max]))
    let report = try DatabaseCheck.run(stack.writer)
    #expect(report.operations == 1)
    // Two parts of the largest amount are not that amount: the check says so, it does not fail.
    #expect(report.findings.contains { $0.rule == .partsSum })
  }

  @Test func aBalancedBookOfHugeAmountsIsHealthy() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(hugeEntry(amount: Int64.max, parts: [Int64.max - 1, 1]))
    let report = try DatabaseCheck.run(stack.writer)
    #expect(!report.findings.contains { $0.rule == .partsSum })
  }

  /// A refund of `amount` taken back from `part` of `purchase`.
  private func refund(of part: TransactionPart, amount: Int64) -> TransactionEntry {
    let transaction = CoreKit.Transaction(
      kind: .refund, occurredAt: moment.addingTimeInterval(86_400), currency: .rub,
      amountE4: AmountE4(raw: amount), amountRubE4: AmountE4(raw: amount))
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, amountE4: AmountE4(raw: amount),
          amountRubE4: AmountE4(raw: amount), refundOfPartId: part.id)
      ])
  }

  @Test func refundsBeyondAPartOfTheLargestAmountAreRefusedNotFailedByTheSum() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let purchase = hugeEntry(amount: Int64.max, parts: [Int64.max])
    try repository.save(purchase)
    try repository.save(refund(of: purchase.parts[0], amount: Int64.max))
    // The part is taken back whole: one more unit is more than it holds, however large it is.
    for amount: Int64 in [1, Int64.max] {
      #expect(throws: RefundError.exceedsRemaining) {
        try repository.save(refund(of: purchase.parts[0], amount: amount))
      }
    }
  }
}
