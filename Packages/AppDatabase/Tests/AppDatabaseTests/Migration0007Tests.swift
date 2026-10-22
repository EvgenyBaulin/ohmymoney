import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to the loans with a grace period and the accounts that earn interest
/// (`0007_debts_and_deposits`) only adds: a database of 1.5 keeps every value, every debt and
/// account reads as it did — no interest, no grace, no tranche —, and each new check refuses
/// exactly what it promises to.
@Suite("The terms of loans and deposits come in without touching a value")
struct Migration0007Tests {
  // MARK: Helpers

  private enum Verdict: Equatable {
    case taken
    case refused
  }

  /// What SQLite says of the statement; nothing of it stays either way.
  private func verdict(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments = []
  ) throws -> Verdict {
    var result = Verdict.taken
    try stack.writer.writeWithoutTransaction { db in
      try db.inSavepoint {
        do {
          try db.execute(sql: sql, arguments: arguments)
        } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          result = .refused
        }
        return .rollback
      }
    }
    return result
  }

  private func takes(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments = []
  ) throws -> Bool {
    try verdict(stack, sql, arguments) == .taken
  }

  private static let debtColumns =
    "id, direction, type, name, interest_rate, payment_day, accrues_interest, main_from, grace_kind, grace_payment_e4, repay_months"

  /// An insert of a debt with the new terms, for `takes`.
  private func debt(
    direction: String = "i_owe", rate: String? = "3", day: Int? = 5, accrues: Int = 0,
    mainFrom: String? = nil, kind: String? = nil, payment: Int64? = nil, months: Int? = nil
  ) -> (String, StatementArguments) {
    (
      "INSERT INTO debts (\(Self.debtColumns)) VALUES (?, ?, 'loan', 'Loan', ?, ?, ?, ?, ?, ?, ?)",
      [UUID().uuidString, direction, rate, day, accrues, mainFrom, kind, payment, months]
    )
  }

  /// An insert of an account with the new interest columns, for `takes`.
  private func account(
    id: String = UUID().uuidString, rate: String? = "16", period: String? = "monthly",
    day: Int? = nil, payout: String? = nil, opened: String? = nil, ends: String? = nil
  ) -> (String, StatementArguments) {
    (
      """
      INSERT INTO payment_methods (id, name, interest_rate, interest_period, interest_day,
        interest_account_id, deposit_opened_on, deposit_ends_on)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [id, "Deposit \(id.prefix(4))", rate, period, day, payout, opened, ends]
    )
  }

  // MARK: 1. A new database

  @Test func aNewDatabaseHasTheColumnsWithTheirDefaults() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0012_sync")
    #expect(try stack.appliedMigrations().count == 12)
    let debtId = UUID().uuidString
    let accountId = UUID().uuidString
    let entryId = UUID().uuidString
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO debts (id, direction, type, name) VALUES (?, 'i_owe', 'loan', 'Loan');
          INSERT INTO debt_entries (id, debt_id, amount_e4, kind) VALUES (?, ?, 10000, 'borrowed');
          INSERT INTO payment_methods (id, name) VALUES (?, 'Card');
          """, arguments: [debtId, entryId, debtId, accountId])
    }
    try stack.writer.read { (db: Database) throws in
      let debt = try #require(
        try Row.fetchOne(
          db,
          sql: """
            SELECT accrues_interest, main_from, grace_kind, grace_payment_e4, repay_months
            FROM debts WHERE id = ?
            """, arguments: [debtId]))
      #expect(debt["accrues_interest"] as Int64? == 0)
      for column in ["main_from", "grace_kind", "grace_payment_e4", "repay_months"] {
        #expect((debt[column] as DatabaseValue).isNull, "\(column)")
      }
      #expect(
        try Int64.fetchOne(
          db, sql: "SELECT tranche FROM debt_entries WHERE id = ?", arguments: [entryId]) == 0)
      let account = try #require(
        try Row.fetchOne(
          db,
          sql: """
            SELECT interest_rate, interest_period, interest_day, interest_account_id,
              deposit_opened_on, deposit_ends_on
            FROM payment_methods WHERE id = ?
            """, arguments: [accountId]))
      for column in account.columnNames {
        #expect((account[column] as DatabaseValue).isNull, "\(column)")
      }
      // The records read them as no terms at all.
      let read = try #require(try Debt.fetchOne(db, key: debtId))
      #expect(!read.accruesInterest && read.grace == nil && read.repayMonths == nil)
      #expect(try DebtEntry.fetchOne(db, key: entryId)?.tranche == false)
      #expect(try PaymentMethod.fetchOne(db, key: accountId)?.interest == nil)
    }
  }

  // MARK: 2. From 1.5

  /// A database of 1.5 (`0006_banks`) is updated and keeps every value it had, byte for byte;
  /// the new columns start empty or false.
  @Test func aDatabaseOfTheVersionBeforeKeepsEveryValue() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0007-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    let older = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0006_banks"))
    let card = PaymentMethod(name: "Card", kind: .card, currency: .rub)
    let loan = Debt(
      direction: .iOwe, type: .loan, name: "Bank", interestRate: 12,
      monthlyPaymentE4: AmountE4(whole: 8_000), paymentDay: 5)
    try older.writer.write { db in
      try LegacyWriter.insert(card, db: db)
      try LegacyWriter.insert(loan, db: db)
      try LegacyWriter.insert(
        DebtEntry(
          debtId: loan.id, date: DateOnly(year: 2026, month: 8, day: 1),
          amountE4: AmountE4(whole: 100_000), kind: .borrowed, paymentMethodId: card.id), db: db)
      try LegacyWriter.insert(
        DebtEntry(
          debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 5),
          amountE4: AmountE4(whole: -8_000), kind: .payment, closesTerm: true), db: db)
      try LegacyWriter.insert(
        PaymentMethod(
          name: "Savings", kind: .account, currency: .rub, cashbackPointsAccountId: card.id),
        db: db)
    }
    let before = try older.writer.read { db in try TestSupport.contents(db) }
    try older.close()

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().last == "0012_sync")
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table) changed")
      }
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debts WHERE accrues_interest <> 0") == 0)
      #expect(
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM debts
            WHERE main_from IS NOT NULL OR grace_kind IS NOT NULL OR grace_payment_e4 IS NOT NULL
              OR repay_months IS NOT NULL
            """) == 0)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debt_entries WHERE tranche <> 0") == 0)
      #expect(
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM payment_methods
            WHERE interest_rate IS NOT NULL OR interest_period IS NOT NULL
              OR interest_day IS NOT NULL OR interest_account_id IS NOT NULL
              OR deposit_opened_on IS NOT NULL OR deposit_ends_on IS NOT NULL
            """) == 0)
      // Every debt, line and account reads as it did.
      #expect(try Debt.fetchAll(db).allSatisfy { !$0.accruesInterest && $0.grace == nil })
      #expect(try DebtEntry.fetchAll(db).allSatisfy { !$0.tranche })
      #expect(try PaymentMethod.fetchAll(db).allSatisfy { $0.interest == nil })
      _ = try DatasetRepository.dataset(db, version: 0)
    }
    #expect(try DatabaseStack.check(fileAt: url, schema: TestSupport.schemaSource) == .sound)
  }

  // MARK: 3. The checks of a loan

  @Test func theInterestOfALoanNeedsARate() throws {
    let stack = try TestSupport.makeStack()
    let (sql, _) = debt()
    #expect(try takes(stack, sql, debt(accrues: 1).1))
    #expect(try !takes(stack, sql, debt(rate: nil, accrues: 1).1))
    #expect(try !takes(stack, sql, debt(accrues: 2).1))
    #expect(try takes(stack, sql, debt(rate: nil, accrues: 0).1))
  }

  @Test func aGracePeriodIsADayAKindAndForAFixedOneASum() throws {
    let stack = try TestSupport.makeStack()
    let (sql, _) = debt()
    // Interest, the programme and a fixed sum.
    #expect(try takes(stack, sql, debt(mainFrom: "2029-03-01", kind: "interest").1))
    #expect(try takes(stack, sql, debt(mainFrom: "2029-03-01", kind: "programme").1))
    #expect(try takes(stack, sql, debt(mainFrom: "2029-03-01", kind: "fixed", payment: 10_000).1))
    // A day without a kind, a kind without a day, a word that is no kind.
    #expect(try !takes(stack, sql, debt(mainFrom: "2029-03-01").1))
    #expect(try !takes(stack, sql, debt(kind: "interest").1))
    #expect(try !takes(stack, sql, debt(mainFrom: "2029-03-01", kind: "holiday").1))
    // Interest and the programme need a rate; a fixed sum does not.
    #expect(try !takes(stack, sql, debt(rate: nil, mainFrom: "2029-03-01", kind: "interest").1))
    #expect(try !takes(stack, sql, debt(rate: nil, mainFrom: "2029-03-01", kind: "programme").1))
    #expect(
      try takes(stack, sql, debt(rate: nil, mainFrom: "2029-03-01", kind: "fixed", payment: 1).1))
    // The sum goes with a fixed payment and nothing else, and is above zero.
    #expect(try !takes(stack, sql, debt(mainFrom: "2029-03-01", kind: "fixed").1))
    #expect(try !takes(stack, sql, debt(mainFrom: "2029-03-01", kind: "fixed", payment: 0).1))
    #expect(try !takes(stack, sql, debt(mainFrom: "2029-03-01", kind: "interest", payment: 5).1))
    #expect(try !takes(stack, sql, debt(payment: 5).1))
    // Only a debt I owe, paid on a day of the month, has a grace period.
    #expect(
      try !takes(
        stack, sql, debt(direction: "owed_to_me", mainFrom: "2029-03-01", kind: "interest").1))
    #expect(try !takes(stack, sql, debt(day: nil, mainFrom: "2029-03-01", kind: "interest").1))
  }

  @Test func theMonthsOfTheMainScheduleNeedARate() throws {
    let stack = try TestSupport.makeStack()
    let (sql, _) = debt()
    #expect(try takes(stack, sql, debt(months: 1).1))
    #expect(try takes(stack, sql, debt(months: 600).1))
    #expect(try !takes(stack, sql, debt(months: 0).1))
    #expect(try !takes(stack, sql, debt(months: 601).1))
    #expect(try !takes(stack, sql, debt(rate: nil, months: 60).1))
  }

  @Test func aTrancheIsMoneyThatGrowsTheDebt() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let sql =
      "INSERT INTO debt_entries (id, debt_id, amount_e4, kind, tranche) VALUES (?, ?, ?, ?, ?)"
    func line(_ amount: Int64, _ kind: String, _ tranche: Int) -> StatementArguments {
      [UUID().uuidString, references.debt.id.uuidString, amount, kind, tranche]
    }
    #expect(try takes(stack, sql, line(10_000, "borrowed", 1)))
    #expect(try takes(stack, sql, line(10_000, "adjustment", 1)))
    #expect(try !takes(stack, sql, line(-10_000, "adjustment", 1)))
    #expect(try !takes(stack, sql, line(-10_000, "payment", 1)))
    #expect(try !takes(stack, sql, line(10_000, "transfer_in", 1)))
    #expect(try !takes(stack, sql, line(10_000, "borrowed", 2)))
    #expect(try takes(stack, sql, line(-10_000, "payment", 0)))
  }

  // MARK: 4. The checks of an account

  @Test func theInterestOfAnAccountIsARateAndAPeriodTogether() throws {
    let stack = try TestSupport.makeStack()
    let (sql, _) = account()
    #expect(try takes(stack, sql, account().1))
    #expect(try takes(stack, sql, account(period: "quarterly").1))
    #expect(try takes(stack, sql, account(rate: nil, period: nil).1))
    #expect(try !takes(stack, sql, account(period: nil).1))
    #expect(try !takes(stack, sql, account(rate: nil).1))
    #expect(try !takes(stack, sql, account(period: "weekly").1))
    #expect(try !takes(stack, sql, account(rate: "  ").1))
  }

  @Test func theDayIsOneToThirtyOneOfAMonthlyOrQuarterlyPayout() throws {
    let stack = try TestSupport.makeStack()
    let (sql, _) = account()
    #expect(try takes(stack, sql, account(day: 1).1))
    #expect(try takes(stack, sql, account(period: "quarterly", day: 31).1))
    #expect(try !takes(stack, sql, account(day: 0).1))
    #expect(try !takes(stack, sql, account(day: 32).1))
    #expect(try !takes(stack, sql, account(period: "end", day: 5, ends: "2027-01-01").1))
    #expect(try !takes(stack, sql, account(rate: nil, period: nil, day: 5).1))
  }

  @Test func aTermEndsAfterItOpensAndAPayoutAtTheEndNeedsAnEnd() throws {
    let stack = try TestSupport.makeStack()
    let (sql, _) = account()
    #expect(try takes(stack, sql, account(period: "end", ends: "2027-04-01").1))
    #expect(try !takes(stack, sql, account(period: "end").1))
    #expect(
      try takes(stack, sql, account(opened: "2026-10-01", ends: "2027-04-01").1))
    #expect(try !takes(stack, sql, account(opened: "2026-10-01", ends: "2026-10-01").1))
    #expect(try !takes(stack, sql, account(opened: "2026-10-01", ends: "2026-09-01").1))
    #expect(try !takes(stack, sql, account(rate: nil, period: nil, opened: "2026-10-01").1))
    #expect(try !takes(stack, sql, account(rate: nil, period: nil, ends: "2027-04-01").1))
  }

  @Test func theInterestGoesToAnotherAccountThatStays() throws {
    let stack = try TestSupport.makeStack()
    let card = UUID().uuidString
    try stack.writer.write { db in
      try db.execute(
        sql: "INSERT INTO payment_methods (id, name) VALUES (?, 'Card')", arguments: [card])
    }
    let (sql, _) = account()
    #expect(try takes(stack, sql, account(payout: card).1))
    #expect(try !takes(stack, sql, account(rate: nil, period: nil, payout: card).1))
    let itself = UUID().uuidString
    #expect(try !takes(stack, sql, account(id: itself, payout: itself).1))
    #expect(try !takes(stack, sql, account(payout: UUID().uuidString).1), "an account that is not")
    // RESTRICT: the account another one pays its interest to is not deleted.
    let deposit = account(payout: card)
    try stack.writer.write { db in try db.execute(sql: deposit.0, arguments: deposit.1) }
    #expect(try !takes(stack, "DELETE FROM payment_methods WHERE id = ?", [card]))
  }

  // MARK: 5. The records

  @Test func theRecordsRoundTripEveryNewColumn() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let loans = [
      Debt(
        direction: .iOwe, type: .loan, name: "Education", interestRate: 3,
        monthlyPaymentE4: AmountE4(whole: 12_000), paymentDay: 5, accruesInterest: true,
        grace: DebtGrace(mainFrom: DateOnly(year: 2029, month: 3, day: 1), payment: .programme),
        repayMonths: 120),
      Debt(
        direction: .iOwe, type: .loan, name: "Fixed", interestRate: Decimal(string: "9.5"),
        paymentDay: 31,
        grace: DebtGrace(
          mainFrom: DateOnly(year: 2028, month: 9, day: 30),
          payment: .fixed(AmountE4(raw: 12_345_678)))),
      Debt(
        direction: .iOwe, type: .loan, name: "Interest", interestRate: 3, paymentDay: 1,
        grace: DebtGrace(mainFrom: DateOnly(year: 2030, month: 1, day: 1), payment: .interest)),
    ]
    let tranche = DebtEntry(
      debtId: references.debt.id, date: DateOnly(year: 2027, month: 2, day: 1),
      amountE4: AmountE4(whole: 150_000), kind: .adjustment, tranche: true)
    let payout = PaymentMethod(name: "Card", kind: .card, currency: .rub)
    let deposit = PaymentMethod(
      name: "Deposit", kind: .account, currency: .rub,
      interest: DepositTerms(
        rate: Decimal(string: "16.25")!, period: .quarterly, day: 31, payoutAccountId: payout.id,
        openedOn: DateOnly(year: 2026, month: 10, day: 1),
        endsOn: DateOnly(year: 2027, month: 10, day: 1)))
    let atEnd = PaymentMethod(
      name: "At the end", kind: .account,
      interest: DepositTerms(
        rate: 18, period: .atEnd, endsOn: DateOnly(year: 2027, month: 4, day: 1)))
    try stack.writer.write { db in
      for loan in loans { try loan.insert(db) }
      try tranche.insert(db)
      try payout.insert(db)
      try deposit.insert(db)
      try atEnd.insert(db)
    }
    try stack.writer.read { (db: Database) throws in
      for loan in loans { #expect(try Debt.fetchOne(db, key: loan.id.uuidString) == loan) }
      #expect(try DebtEntry.fetchOne(db, key: tranche.id.uuidString) == tranche)
      #expect(try PaymentMethod.fetchOne(db, key: deposit.id.uuidString) == deposit)
      #expect(try PaymentMethod.fetchOne(db, key: atEnd.id.uuidString) == atEnd)
      #expect(
        try String.fetchOne(
          db,
          sql: "SELECT interest_rate || ' ' || interest_period FROM payment_methods WHERE id = ?",
          arguments: [deposit.id.uuidString]) == "16.25 quarterly")
      #expect(
        try String.fetchOne(
          db, sql: "SELECT interest_period FROM payment_methods WHERE id = ?",
          arguments: [atEnd.id.uuidString]) == "end")
    }
  }

  /// A value only a hand edit leaves reads as nothing, and never stops the read.
  @Test func aValueOnlyAHandEditLeavesReadsAsNothing() throws {
    let stack = try TestSupport.makeStack()
    let debtId = UUID().uuidString
    let accountId = UUID().uuidString
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql: """
          INSERT INTO debts (id, direction, type, name, main_from, grace_kind, repay_months)
            VALUES (?, 'i_owe', 'loan', 'Loan', 'soon', 'holiday', 'many');
          INSERT INTO payment_methods (id, name, interest_rate, interest_period, interest_day,
            deposit_opened_on) VALUES (?, 'Odd', 'lots', 'weekly', 99, 'yesterday');
          """, arguments: [debtId, accountId])
      try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
    }
    try stack.writer.read { (db: Database) throws in
      let debt = try #require(try Debt.fetchOne(db, key: debtId))
      #expect(debt.grace == nil)
      #expect(debt.repayMonths == nil)
      #expect(try PaymentMethod.fetchOne(db, key: accountId)?.interest == nil)
    }
  }
}
