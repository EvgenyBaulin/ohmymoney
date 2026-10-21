import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// An account is deleted only while nothing points at it — found here from the schema itself:
/// every column of every table that points at the accounts, the bin included, but the balances
/// counted on it, its cards and the cashback rules on it, which are its own and go with it, and
/// an income expected on it, which lets go of it. The deletion takes along exactly those
/// balances, cards and rules and a reconciliation of accounts it leaves with no balance at all;
/// a total of the time before accounts stays whatever it counted. The main account is never deleted while no
/// other live account is main. A refused deletion writes nothing. Checked on every account of a
/// history with accounts, in a drawn order, with unused accounts made on purpose among them.
@Suite("An account is deleted only when nothing points at it")
struct AccountDeletionPropertyTests {
  /// The tables whose rows go with the account or let go of it, and never keep it.
  private static let ownRows: Set = [
    "reconciliation_balances", "cards", "cashback_rules", "expected_income",
  ]

  /// Whether a column of the schema, the account's own rows aside, points at the account.
  private static func isPointedAt(_ id: UUID, db: Database) throws -> Bool {
    let tables = try String.fetchAll(
      db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    for child in tables where !ownRows.contains(child) {
      for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(child))")
      where (key["table"] as String) == "payment_methods" {
        let column: String = key["from"]
        if try Bool.fetchOne(
          db, sql: "SELECT EXISTS (SELECT 1 FROM \(child) WHERE \(column) = ?)",
          arguments: [id.uuidString]) == true
        {
          return true
        }
      }
    }
    return false
  }

  /// A history with accounts and, among its accounts, unused ones counted in every way: alone in
  /// a reconciliation of accounts, beside a used account in one, in an opening count, in a total
  /// of the older time; one used only by an operation in the bin, one only by a payment. The
  /// lonely one has a card with its rules and a rule of its own, the opened one an income
  /// expected on it.
  private static func stack() throws -> DatabaseStack {
    let stack = try PlanningUndoPropertyTests.stack()
    let at = Date(timeIntervalSince1970: 1_789_000_000)
    let day = DateOnly(year: 2026, month: 9, day: 10)
    try stack.writer.write { db in
      let used = try #require(
        try PaymentMethod.filter(sql: "archived = 0 AND is_default = 0").fetchOne(db))
      let lonely = PaymentMethod(name: "Lonely", kind: .card, currency: .rub)
      let shared = PaymentMethod(name: "Shared", kind: .card, currency: .usd)
      let opened = PaymentMethod(name: "Opened", kind: .cash, currency: .rub)
      let older = PaymentMethod(name: "Older", kind: .account, currency: .rub)
      let binned = PaymentMethod(name: "Binned", kind: .card, currency: .rub)
      let planned = PaymentMethod(name: "Planned", kind: .card, currency: .rub)
      let plain = PaymentMethod(name: "Plain", kind: .other, currency: .rub, archived: true)
      for account in [lonely, shared, opened, older, binned, planned, plain] {
        try account.insert(db)
      }
      let card = PaymentCard(accountId: lonely.id, name: "Lonely card")
      try card.insert(db)
      try CashbackRule(
        accountId: lonely.id, cardId: card.id, percent: CashbackPercent(e4: 15_000) ?? .zero
      ).insert(db)
      try CashbackRule(
        accountId: lonely.id, month: MonthKey(year: 2026, month: 9),
        percent: CashbackPercent(e4: 50_000) ?? .zero
      ).insert(db)
      try ExpectedIncome(
        name: "Deposit back", totalE4: AmountE4(whole: 100), paymentMethodId: opened.id
      ).insert(db)

      func count(_ kind: ReconciliationKind, _ accounts: [PaymentMethod]) throws {
        let reconciliation = Reconciliation(
          date: day, reconciledAt: kind == .total ? nil : at, actualTotalRubE4: .zero, kind: kind)
        try reconciliation.insert(db)
        for account in accounts {
          try ReconciledBalance(
            reconciliationId: reconciliation.id, accountId: account.id,
            currency: account.mainCurrency, actualE4: AmountE4(whole: 100)
          ).insert(db)
        }
      }
      try count(.accounts, [lonely])
      try count(.accounts, [shared, used])
      try count(.opening, [opened])
      try count(.total, [older])

      let id = UUID()
      try CoreKit.Transaction(
        id: id, kind: .expense, occurredAt: at, amountE4: AmountE4(whole: 5),
        amountRubE4: AmountE4(whole: 5), paymentMethodId: binned.id, createdAt: at, updatedAt: at,
        deletedAt: at
      ).insert(db)
      try TransactionPart(
        transactionId: id, amountE4: AmountE4(whole: 5), amountRubE4: AmountE4(whole: 5)
      )
      .insert(db)
      try ScheduledPayment(
        name: "Gym", amountE4: AmountE4(whole: 10), paymentMethodId: planned.id
      ).insert(db)
    }
    return stack
  }

  @Test(arguments: [UInt64(1), 2, 3])
  func onlyWhatNothingPointsAtIsDeletedWithItsOwnCounts(seed: UInt64) throws {
    let stack = try Self.stack()
    var random = SeededRandom(seed: seed)
    var ids = try stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM payment_methods ORDER BY rowid")
        .compactMap(UUID.init(uuidString:))
    }
    ids.shuffle(using: &random)
    var deleted = 0
    var refused = 0
    for id in ids {
      let (before, pointedAt, refusesTheMain) = try stack.writer.read { db in
        (
          try ExactTables.read(db), try Self.isPointedAt(id, db: db),
          try Bool.fetchOne(
            db,
            sql: """
              SELECT is_default = 1 AND NOT EXISTS (
                SELECT 1 FROM payment_methods WHERE is_default = 1 AND archived = 0 AND id <> :id)
              FROM payment_methods WHERE id = :id
              """, arguments: ["id": id.uuidString]) ?? false
        )
      }
      let repository = AccountRepository(writer: stack.writer)
      if pointedAt || refusesTheMain {
        #expect(throws: AccountWriteError.self, "seed \(seed): \(id)") { try repository.delete(id) }
        #expect(try stack.writer.read { db in try ExactTables.read(db) } == before)
        refused += 1
        continue
      }
      try repository.delete(id)
      deleted += 1

      let quoted = "'\(id.uuidString)'"
      func column(_ table: String, _ name: String) -> Int {
        (before[table]?.columns.firstIndex(of: name) ?? -2) + 1
      }
      let accountId = column("payment_methods", "id")
      let account = column("reconciliation_balances", "payment_method_id")
      let owner = column("reconciliation_balances", "reconciliation_id")
      let reconciliationId = column("reconciliations", "id")
      let kind = column("reconciliations", "kind")
      var expected = before
      expected["payment_methods"]?.rows.removeAll { $0[accountId] == quoted }
      let balances = before["reconciliation_balances"]?.rows ?? []
      let counted = Set(balances.filter { $0[account] == quoted }.map { $0[owner] })
      let left = Set(balances.filter { $0[account] != quoted }.map { $0[owner] })
      expected["reconciliation_balances"]?.rows.removeAll { $0[account] == quoted }
      expected["reconciliations"]?.rows.removeAll { row in
        counted.contains(row[reconciliationId]) && !left.contains(row[reconciliationId])
          && row[kind] != "'total'"
      }
      // Its cards and the rules on it and on its cards go; an income expected on it stays,
      // on no account.
      let cardAccount = column("cards", "payment_method_id")
      let ruleAccount = column("cashback_rules", "payment_method_id")
      let incomeAccount = column("expected_income", "payment_method_id")
      expected["cards"]?.rows.removeAll { $0[cardAccount] == quoted }
      expected["cashback_rules"]?.rows.removeAll { $0[ruleAccount] == quoted }
      if var incomes = expected["expected_income"] {
        incomes.rows = incomes.rows.map { row in
          var row = row
          if row[incomeAccount] == quoted { row[incomeAccount] = "NULL" }
          return row
        }
        expected["expected_income"] = incomes
      }
      let after = try stack.writer.read { db in try ExactTables.read(db) }
      #expect(
        after == expected,
        "seed \(seed): \(PlanningUndoPropertyTests.difference(expected, after))")
      try stack.writer.read { (db: Database) throws in
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        #expect(
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM payment_methods WHERE is_default = 1 AND archived = 0")
            == 1, "seed \(seed): the accounts lost their main one")
      }
    }
    #expect(deleted == 5, "seed \(seed): \(deleted) deleted, not the five unused")
    #expect(refused >= 3, "seed \(seed): only \(refused) refused")
  }

  /// The main account, used by nothing, is still not deleted: the accounts are never left without
  /// a main one. Another account unused beside it is.
  @Test func theMainAccountStaysEvenUnused() throws {
    let stack = try TestSupport.makeStack()
    let main = PaymentMethod(name: "Main", kind: .card, currency: .rub, isDefault: true)
    let other = PaymentMethod(name: "Other", kind: .cash, currency: .rub)
    try stack.writer.write { db in
      try main.insert(db)
      try other.insert(db)
    }
    let before = try stack.writer.read { db in try ExactTables.read(db) }
    let repository = AccountRepository(writer: stack.writer)
    #expect(throws: AccountWriteError.isMain) { try repository.delete(main.id) }
    #expect(try stack.writer.read { db in try ExactTables.read(db) } == before)
    try repository.delete(other.id)
    #expect(
      try ReferenceRepository(writer: stack.writer).paymentMethods(includeArchived: true).map(\.id)
        == [main.id])
  }
}
