import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Formulas saved when a lone comma was always decimal are read again on open: the amount is
/// the truth, and a formula that no longer comes to it goes.
@Suite("Formulas kept with operations are read again by today's rule")
struct FormulaRepairTests {
  private func save(
    _ amount: AmountE4, formula: String?, deleted: Bool = false,
    in repository: TransactionRepository
  ) throws -> UUID {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_000_000), currency: .rub,
      amountE4: amount, amountExpr: formula, amountRubE4: amount, note: "taxi",
      createdAt: updatedAt, updatedAt: updatedAt,
      deletedAt: deleted ? Date(timeIntervalSince1970: 1_700_000_100) : nil)
    let part = TransactionPart(
      transactionId: transaction.id, amountE4: amount, amountRubE4: amount)
    try repository.save(TransactionEntry(transaction: transaction, parts: [part]))
    return transaction.id
  }

  @Test func aFormulaThatNoLongerComesToItsAmountIsDropped() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    // «1,500+2,50» was 1.5 + 2.5 = 4 when a lone comma was always decimal; today it is 1 502.50.
    let old = try save(AmountE4(whole: 4), formula: "1,500+2,50", in: repository)
    // Reads the same either way.
    let same = try save(AmountE4(whole: 800), formula: "(1000+600)/2", in: repository)
    let decimal = try save(AmountE4(raw: 35_000), formula: "1,5+2", in: repository)
    let canonical = try save(AmountE4(raw: 15_025_000), formula: "1,500+2.50", in: repository)
    // Not a formula of anything: an archive or an old export may carry such text.
    let garbage = try save(AmountE4(whole: 10), formula: "tax 10", in: repository)
    let deleted = try save(
      AmountE4(raw: 12_500), formula: "1,000+0,250", deleted: true, in: repository)
    let plain = try save(AmountE4(whole: 250), formula: nil, in: repository)

    let check = try repository.dropFormulasThatNoLongerAddUp()

    #expect(check == .init(checked: 6, dropped: 3))
    func formula(_ id: UUID) throws -> String? {
      try repository.entry(id: id)?.transaction.amountExpr
    }
    #expect(try formula(old) == nil)
    #expect(try formula(same) == "(1000+600)/2")
    #expect(try formula(decimal) == "1,5+2")
    #expect(try formula(canonical) == "1,500+2.50")
    #expect(try formula(garbage) == nil)
    #expect(try formula(deleted) == nil)
    #expect(try formula(plain) == nil)
    // Only the formula goes: the amount and the moment of the last edit stay.
    let kept = try #require(try repository.entry(id: old)?.transaction)
    #expect(kept.amountE4 == AmountE4(whole: 4))
    #expect(kept.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))

    // A second pass finds nothing more to do.
    #expect(try repository.dropFormulasThatNoLongerAddUp() == .init(checked: 3, dropped: 0))
  }

  /// In front of `к` a lone comma is decimal now: «1,500к+250» saved as 1 500 250 comes to
  /// 1 750 today, so the formula goes and the amount stays. «2,5к+500» reads the same either way.
  @Test func aFormulaWithACommaBeforeKIsDroppedAndItsAmountKept() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let million = try save(
      AmountE4(whole: 1_500_250), formula: "1,500\u{043A}+250", in: repository)
    let same = try save(AmountE4(whole: 3_000), formula: "2,5\u{043A}+500", in: repository)

    #expect(try repository.dropFormulasThatNoLongerAddUp() == .init(checked: 2, dropped: 1))
    let kept = try #require(try repository.entry(id: million)?.transaction)
    #expect(kept.amountExpr == nil)
    #expect(kept.amountE4 == AmountE4(whole: 1_500_250))
    #expect(try repository.entry(id: same)?.transaction.amountExpr == "2,5\u{043A}+500")
  }
}
