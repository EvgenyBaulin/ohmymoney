import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A value of the wrong type where an amount, a flag or a count belongs — a text in `amount_e4`,
/// a word in `archived`, written by a hand edit or another program with the checks of the schema
/// off — stops the read with `UnreadableValue` naming its column, never the program: GRDB's own
/// subscript stops the program on such a value, and the whole history is read at every start,
/// so the app would stop at every start. The value itself is never in the error.
@Suite("A value of the wrong type stops the read, not the program")
struct UnreadableValueTests {
  /// A stack with one of everything, then `sql` run with the checks of the schema off, the way
  /// another program can write a row.
  private func stack(after sql: String) throws -> DatabaseStack {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    try TransactionRepository(writer: stack.writer).save(
      TestSupport.makeEntry().assigning(account: references.paymentMethod.id))
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(sql: sql)
      try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
    }
    return stack
  }

  private func load(_ stack: DatabaseStack) throws -> Dataset {
    try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
  }

  /// An amount that is a word, of an operation, a part, a link, a limit, a debt, a goal: the
  /// load stops and names the column.
  @Test(arguments: [
    ("UPDATE transactions SET amount_e4 = 'abc'", "amount_e4"),
    ("UPDATE transactions SET amount_rub_e4 = x'00ff'", "amount_rub_e4"),
    ("UPDATE transaction_parts SET amount_rub_e4 = 'twelve'", "amount_rub_e4"),
    ("UPDATE goals SET target_e4 = 'a lot'", "target_e4"),
    ("UPDATE debts SET monthly_payment_e4 = 'some'", "monthly_payment_e4"),
    ("UPDATE events SET budget_e4 = '1 000'", "budget_e4"),
    ("UPDATE transactions SET amount_e4 = 1e30", "amount_e4"),
  ])
  func anAmountOfTheWrongTypeStopsTheLoad(sql: String, column: String) throws {
    let stack = try stack(after: sql)
    #expect(throws: UnreadableValue(column: column)) { try load(stack) }
  }

  /// A flag that is a word stops the load; one that is a number reads as SQLite reads it in a
  /// condition — zero is false, anything else true — as it always has.
  @Test(arguments: [
    ("UPDATE people SET archived = 'x'", "archived"),
    ("UPDATE categories SET archived = 'no'", "archived"),
    ("UPDATE payment_methods SET is_default = 'yes'", "is_default"),
    ("UPDATE transactions SET rate_provisional = 'maybe'", "rate_provisional"),
    ("UPDATE transaction_parts SET reimbursable = 'no'", "reimbursable"),
    ("UPDATE debts SET closed = 'closed'", "closed"),
    ("UPDATE events SET recurring_yearly = 'yearly'", "recurring_yearly"),
  ])
  func aFlagThatIsAWordStopsTheLoad(sql: String, column: String) throws {
    let stack = try stack(after: sql)
    #expect(throws: UnreadableValue(column: column)) { try load(stack) }
  }

  /// A count or a day of the month that is a word stops the read of its row.
  @Test(arguments: [
    ("UPDATE categories SET sort = 'first'", "sort"),
    ("UPDATE payment_methods SET sort = 'top'", "sort"),
    ("UPDATE debts SET payment_day = 'fifth'", "payment_day"),
  ])
  func aCountThatIsAWordStopsTheLoad(sql: String, column: String) throws {
    let stack = try stack(after: sql)
    #expect(throws: UnreadableValue(column: column)) { try load(stack) }
  }

  /// The planning and the templates are read on their own too: a word in their amounts, flags
  /// and counts stops that read the same way.
  @Test func thePlanningAndTheTemplatesStopTheirReadToo() throws {
    let base = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(base)
    let payment = ScheduledPayment(
      name: "Rent", kind: .bill, amountE4: AmountE4(whole: 100), categoryId: references.category.id)
    _ = try PlanningRepository(writer: base.writer).apply(
      PlanningChange(upsert: PlanningRows(scheduled: [payment])))
    try base.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO templates (id, text, amount_e4, pinned, use_count)
          VALUES (?, 'coffee', 2500000, 0, 3)
          """, arguments: [UUID().uuidString])
    }
    let cases: [(String, String, (Database) throws -> Void)] = [
      (
        "UPDATE scheduled_payments SET amount_e4 = 'rent'", "amount_e4",
        { db in _ = try ScheduledPayment.fetchAll(db) }
      ),
      (
        "UPDATE scheduled_payments SET interval = 'often'", "interval",
        { db in _ = try ScheduledPayment.fetchAll(db) }
      ),
      (
        "UPDATE scheduled_payments SET active = 'on'", "active",
        { db in _ = try ScheduledPayment.fetchAll(db) }
      ),
      (
        "UPDATE templates SET use_count = 'many'", "use_count",
        { db in _ = try Template.fetchAll(db) }
      ),
      ("UPDATE templates SET pinned = 'pin'", "pinned", { db in _ = try Template.fetchAll(db) }),
    ]
    for (sql, column, read) in cases {
      let snapshot = try DatabaseQueue()
      try base.writer.backup(to: snapshot)
      try snapshot.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
        try db.execute(sql: sql)
      }
      #expect(throws: UnreadableValue(column: column), "\(sql)") {
        try snapshot.read { db in try read(db) }
      }
    }
  }

  /// The check of the formulas, run at every start, reads the amount of every operation that
  /// keeps one: an amount that is a word beside a formula neither stops it nor is written over —
  /// the row is left as it is, for the load to report — and the other formulas are still checked.
  @Test func theCheckOfTheFormulasPassesOverAnUnreadableAmount() throws {
    let stack = try stack(
      after: """
        UPDATE transactions SET amount_e4 = 'abc', amount_expr = '(100+50)/2';
        """)
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_expr,
            amount_rub_e4, created_at, updated_at)
          VALUES (?, 'expense', '2026-09-01 10:00:00.000', 'RUB', 40000, '1,500+2,50', 40000,
            '2026-09-01 10:00:00.000', '2026-09-01 10:00:00.000')
          """, arguments: [UUID().uuidString])
    }
    let before = try stack.writer.read { db in
      try Row.fetchAll(
        db, sql: "SELECT quote(amount_e4), amount_expr FROM transactions ORDER BY rowid")
    }
    let check = try TransactionRepository(writer: stack.writer).dropFormulasThatNoLongerAddUp()
    #expect(check == .init(checked: 2, dropped: 1))
    let after = try stack.writer.read { db in
      try Row.fetchAll(
        db, sql: "SELECT quote(amount_e4), amount_expr FROM transactions ORDER BY rowid")
    }
    #expect(after.first == before.first, "the row with the unreadable amount changed")
    #expect(after.last?["amount_expr"] as String? == nil)
  }

  /// The values the schema lets in all still read: an amount stored as a whole real number
  /// reads as that integer, NULL in an optional amount as none, a flag of 0 or 1 as itself.
  @Test func theValuesTheSchemaLetsInStillRead() throws {
    let stack = try stack(
      after: """
        UPDATE transactions SET amount_e4 = 2500000.0, amount_rub_e4 = CAST(2500000 AS REAL);
        UPDATE debts SET monthly_payment_e4 = NULL, payment_day = 31;
        UPDATE people SET archived = 1;
        """)
    let dataset = try load(stack)
    let entry = try #require(dataset.entries.first)
    #expect(entry.transaction.amountE4 == AmountE4(raw: 2_500_000))
    #expect(entry.transaction.amountRubE4 == AmountE4(raw: 2_500_000))
    #expect(dataset.debts.allSatisfy { $0.monthlyPaymentE4 == nil && $0.paymentDay == 31 })
    #expect(dataset.people.allSatisfy { $0.archived })
  }
}

extension TransactionEntry {
  /// The entry with its operation on `account`.
  fileprivate func assigning(account: UUID) -> TransactionEntry {
    var entry = self
    entry.transaction.paymentMethodId = account
    return entry
  }
}
