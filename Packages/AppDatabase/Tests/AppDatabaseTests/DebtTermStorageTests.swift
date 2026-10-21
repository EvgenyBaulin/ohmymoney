import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// «В этом месяце больше платежей не будет»: the line of a payment says that the due it was made
/// for is closed, and the database keeps it — off for every line a database of an older build
/// already holds, and only ever 0 or 1.
@Suite("The term a payment closes, in the database")
struct DebtTermStorageTests {
  @Test func theFlagOfALineIsKept() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Car", monthlyPaymentE4: AmountE4(whole: 8_000))
    try references.save(debt)
    let plain = DebtRules.makeEntry(
      debtId: debt.id, kind: .payment, amountE4: AmountE4(whole: 8_000),
      date: DateOnly(year: 2026, month: 9, day: 5))
    let closing = DebtRules.makeEntry(
      debtId: debt.id, kind: .payment, amountE4: AmountE4(whole: 4_000),
      date: DateOnly(year: 2026, month: 10, day: 5), closesTerm: true)
    try references.save(plain)
    try references.save(closing)
    let read = try references.debtEntries(debtId: debt.id)
    #expect(read.map(\.closesTerm) == [false, true])
    #expect(read == [plain, closing])
  }

  /// A line written without the column — by SQL, as a database of the older build holds it —
  /// reads as one that closes nothing; the column takes nothing but 0 and 1.
  @Test func theColumnIsOffByDefaultAndOnlyEverZeroOrOne() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let debt = Debt(direction: .iOwe, type: .loan, name: "Car")
    try references.save(debt)
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO debt_entries (id, debt_id, amount_e4, kind)
          VALUES ('A0000000-0000-0000-0000-000000000001', ?, -80000000, 'payment')
          """, arguments: [debt.id.uuidString])
    }
    #expect(try references.debtEntries(debtId: debt.id).map(\.closesTerm) == [false])
    #expect(throws: GRDB.DatabaseError.self) {
      try stack.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO debt_entries (id, debt_id, amount_e4, kind, closes_term)
            VALUES ('A0000000-0000-0000-0000-000000000002', ?, -80000000, 'payment', 2)
            """, arguments: [debt.id.uuidString])
      }
    }
  }
}
