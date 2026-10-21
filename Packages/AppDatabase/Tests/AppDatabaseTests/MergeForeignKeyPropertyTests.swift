import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A merge of two rows of a reference book keeps every foreign key: whatever pointed at the
/// row merged away points at the one it was merged into — in every table and column the schema
/// says points at that book, found from the schema itself —, the balances counted on an account
/// stay its history, nothing else of any row changes, and no key points nowhere. Checked on
/// pairs drawn at random from a history with accounts, for people, places, events and accounts,
/// and for the merge of accounts that works out their balances.
@Suite("A merge keeps every foreign key and changes nothing else")
struct MergeForeignKeyPropertyTests {
  /// The one column a merge of accounts leaves pointing at the account merged away: the balances
  /// counted on it are what it held then, its history.
  private static let keptOnMerge: Set<String> = ["reconciliation_balances.payment_method_id"]

  /// Every column of the schema that points at `table`, as `table.column`.
  private static func pointing(at parent: String, db: Database) throws -> [(String, String)] {
    var found: [(String, String)] = []
    let tables = try String.fetchAll(
      db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    for table in tables {
      for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
      where (key["table"] as String) == parent {
        found.append((table, key["from"]))
      }
    }
    return found
  }

  /// The tables as they must be after the merge by the model: every pointing column but the
  /// kept ones reads `target` where it read `source`. The book's own table is left out; it is
  /// checked apart.
  private static func expected(
    _ before: [String: ExactTable], book: String, source: UUID, target: UUID,
    pointing: [(String, String)], kept: Set<String>
  ) -> [String: ExactTable] {
    var tables = before
    tables[book] = nil
    let old = "'\(source.uuidString)'"
    let new = "'\(target.uuidString)'"
    for (table, column) in pointing where !kept.contains("\(table).\(column)") {
      guard var contents = tables[table], let index = contents.columns.firstIndex(of: column)
      else { continue }
      contents.rows = contents.rows.map { row in
        var row = row
        if row[index + 1] == old { row[index + 1] = new }
        return row
      }
      tables[table] = contents
    }
    return tables
  }

  private static func withoutBook(
    _ tables: [String: ExactTable], _ book: String
  ) -> [String: ExactTable] {
    var tables = tables
    tables[book] = nil
    return tables
  }

  /// The history with a card on every account, its rules, operations and a payment that name
  /// it, a rule of each account's own on a month no other account has — so no two rules meet on
  /// one key after a merge — and an income expected on an account: the rows that point at the
  /// accounts and move with them.
  static func stackWithCards() throws -> DatabaseStack {
    let stack = try PlanningUndoPropertyTests.stack()
    try stack.writer.write { db in
      let accounts = try String.fetchAll(db, sql: "SELECT id FROM payment_methods ORDER BY rowid")
      let category = try String.fetchOne(
        db, sql: "SELECT id FROM categories WHERE kind = 'expense' ORDER BY rowid LIMIT 1")
      for (index, account) in accounts.enumerated() {
        let card = UUID().uuidString
        try db.execute(
          sql: "INSERT INTO cards (id, payment_method_id, name) VALUES (?, ?, ?)",
          arguments: [card, account, "Card \(index)"])
        let month = String(format: "%04d-%02d", 2026 + index / 12, index % 12 + 1)
        try db.execute(
          sql: """
            INSERT INTO cashback_rules (id, payment_method_id, card_id, category_id, month,
              percent_e4)
            VALUES (?, ?, ?, ?, NULL, 50000), (?, ?, NULL, NULL, ?, 10000)
            """,
          arguments: [
            UUID().uuidString, account, card, category, UUID().uuidString, account, month,
          ])
        try db.execute(
          sql: """
            UPDATE transactions SET card_id = ?
            WHERE id IN (
              SELECT id FROM transactions WHERE payment_method_id = ? ORDER BY rowid LIMIT 5)
            """,
          arguments: [card, account])
        try db.execute(
          sql: """
            UPDATE scheduled_payments SET card_id = ?
            WHERE id IN (
              SELECT id FROM scheduled_payments WHERE payment_method_id = ? ORDER BY rowid
              LIMIT 1)
            """,
          arguments: [card, account])
      }
      try db.execute(
        sql: """
          UPDATE expected_income SET payment_method_id = (
            SELECT id FROM payment_methods ORDER BY rowid LIMIT 1)
          """)
    }
    // Only accounts of one bank merge: every account is filed under one.
    try TestSupport.fileUnderOneBank(try ids("payment_methods", stack), stack: stack)
    return stack
  }

  private static func ids(_ table: String, _ stack: DatabaseStack) throws -> [UUID] {
    try stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY rowid").compactMap(
        UUID.init(uuidString:))
    }
  }

  /// People, places and events: pairs drawn at random, merged, checked against the model.
  @Test(arguments: ["people", "places", "events"])
  func aMergeOfAReferenceBookMovesEveryKeyAndNothingElse(book: String) throws {
    var random = SeededRandom(seed: UInt64(book.count) * 7_919)
    for round in 0..<6 {
      let stack = try PlanningUndoPropertyTests.stack()
      let rows = try Self.ids(book, stack)
      guard rows.count >= 2 else {
        Issue.record("\(book) has fewer than two rows")
        return
      }
      let source = rows[random.int(in: 0..<rows.count)]
      var target = rows[random.int(in: 0..<rows.count)]
      while target == source { target = rows[random.int(in: 0..<rows.count)] }
      let (before, pointing) = try stack.writer.read { db in
        (try ExactTables.read(db), try Self.pointing(at: book, db: db))
      }
      let references = ReferenceRepository(writer: stack.writer)
      switch book {
      case "people": try references.mergePerson(source, into: target)
      case "places": try references.mergePlace(source, into: target)
      default: try references.mergeEvent(source, into: target)
      }
      let after = try stack.writer.read { db in try ExactTables.read(db) }
      let model = Self.expected(
        before, book: book, source: source, target: target, pointing: pointing, kept: [])
      #expect(
        Self.withoutBook(after, book) == model,
        "\(book), round \(round): \(PlanningUndoPropertyTests.difference(model, Self.withoutBook(after, book)))"
      )
      try stack.writer.read { (db: Database) throws in
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        #expect(
          try Bool.fetchOne(
            db, sql: "SELECT archived FROM \(book) WHERE id = ?", arguments: [source.uuidString])
            == true)
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(book)") == rows.count)
      }
    }
  }

  /// Accounts merged the way the settings merged them before balances: every key moves but the
  /// counted balances, which stay the history of the account merged away; when a transfer
  /// between the two in one currency would become one from an account to itself, the merge is
  /// refused whole and nothing changes.
  @Test func aMergeOfAccountsMovesEveryKeyButTheCounts() throws {
    var random = SeededRandom(seed: 31)
    var merged = 0
    for round in 0..<10 {
      let stack = try Self.stackWithCards()
      let rows = try Self.ids("payment_methods", stack)
      let source = rows[random.int(in: 0..<rows.count)]
      var target = rows[random.int(in: 0..<rows.count)]
      while target == source { target = rows[random.int(in: 0..<rows.count)] }
      let (before, pointing, blocked) = try stack.writer.read { db in
        (
          try ExactTables.read(db), try Self.pointing(at: "payment_methods", db: db),
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS (SELECT 1 FROM transfers
                WHERE from_currency = to_currency
                  AND from_payment_method_id IN (?, ?) AND to_payment_method_id IN (?, ?))
              """,
            arguments: [source.uuidString, target.uuidString, source.uuidString, target.uuidString])
            ?? false
        )
      }
      let references = ReferenceRepository(writer: stack.writer)
      if blocked {
        #expect(throws: (any Error).self) {
          try references.mergePaymentMethod(source, into: target)
        }
        #expect(
          try stack.writer.read { db in try ExactTables.read(db) } == before, "round \(round)")
        continue
      }
      try references.mergePaymentMethod(source, into: target)
      merged += 1
      let after = try stack.writer.read { db in try ExactTables.read(db) }
      let model = Self.expected(
        before, book: "payment_methods", source: source, target: target, pointing: pointing,
        kept: Self.keptOnMerge)
      #expect(
        Self.withoutBook(after, "payment_methods") == model,
        "round \(round): \(PlanningUndoPropertyTests.difference(model, Self.withoutBook(after, "payment_methods")))"
      )
      try stack.writer.read { (db: Database) throws in
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        #expect(
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM payment_methods WHERE is_default = 1 AND archived = 0")
            == 1, "round \(round): the accounts lost their main one")
      }
    }
    #expect(merged > 0)
  }

  /// Accounts merged with their balances worked out (`AccountMerge.plan`): the transfers
  /// between the two in one currency go and their fees lose the key to them; every other key
  /// moves as in any merge; the counted balances stay the source's history; one opening
  /// reconciliation counts what the plan says and the source at zero; nothing else changes.
  @Test(arguments: Array(UInt64(41)...UInt64(52)))
  func aMergeOfAccountsWithTheirBalancesKeepsEveryKey(seed: UInt64) throws {
    var random = SeededRandom(seed: seed)
    let stack = try Self.stackWithCards()
    let calendar = TestSupport.sampleCalendar
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    let accounts = dataset.paymentMethods
    let source = accounts[random.int(in: 0..<accounts.count)]
    var target = accounts[random.int(in: 0..<accounts.count)]
    while target.id == source.id { target = accounts[random.int(in: 0..<accounts.count)] }
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let balances = AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries,
      debts: Dictionary(uniqueKeysWithValues: dataset.debts.map { ($0.id, $0) }),
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: accounts,
      tree: CategoryTree(dataset.categories), now: at, calendar: calendar)
    let plan = AccountMerge.plan(
      source: source, target: target, transfers: dataset.transfers, balances: balances, at: at
    ).plan

    // The transfers of one currency between the two, found in the database as it was — not
    // taken from the plan: they go, and their fees let go of them.
    let (before, pointing, between) = try stack.writer.read { db in
      (
        try ExactTables.read(db), try Self.pointing(at: "payment_methods", db: db),
        try String.fetchAll(
          db,
          sql: """
            SELECT id FROM transfers WHERE from_currency = to_currency
              AND ((from_payment_method_id = :s AND to_payment_method_id = :t)
                OR (from_payment_method_id = :t AND to_payment_method_id = :s))
            """, arguments: ["s": source.id.uuidString, "t": target.id.uuidString])
      )
    }
    try AccountRepository(writer: stack.writer).merge(plan, calendar: calendar)
    let after = try stack.writer.read { db in try ExactTables.read(db) }

    var model = Self.expected(
      before, book: "payment_methods", source: source.id, target: target.id, pointing: pointing,
      kept: Self.keptOnMerge)
    #expect(
      Set(between) == Set(plan.deletedTransferIds.map(\.uuidString)),
      "seed \(seed): the plan deletes other transfers than those between the two")
    let deleted = Set(between.map { "'\($0)'" })
    if var transfers = model["transfers"] {
      transfers.rows.removeAll { deleted.contains($0[1]) }
      model["transfers"] = transfers
    }
    let fees = Set(
      between.compactMap(UUID.init(uuidString:)).map {
        "'\(OperationLink.transferFee($0).externalId)'"
      })
    if var operations = model["transactions"],
      let key = operations.columns.firstIndex(of: "external_id")
    {
      operations.rows = operations.rows.map { row in
        var row = row
        if fees.contains(row[key + 1]) { row[key + 1] = "NULL" }
        return row
      }
      model["transactions"] = operations
    }
    // The opening reconciliation and its counts are new rows, checked apart.
    var got = Self.withoutBook(after, "payment_methods")
    let newReconciliations =
      (got["reconciliations"]?.rows.count ?? 0) - (model["reconciliations"]?.rows.count ?? 0)
    got["reconciliations"]?.rows.removeLast(max(0, newReconciliations))
    let newBalances =
      (got["reconciliation_balances"]?.rows.count ?? 0)
      - (model["reconciliation_balances"]?.rows.count ?? 0)
    got["reconciliation_balances"]?.rows.removeLast(max(0, newBalances))
    #expect(got == model, "seed \(seed): \(PlanningUndoPropertyTests.difference(model, got))")

    let counted = plan.opening.count + plan.sourceZero.filter { plan.opening[$0] == nil }.count
    #expect(newReconciliations == (counted > 0 ? 1 : 0), "seed \(seed)")
    #expect(newBalances == counted, "seed \(seed)")
    try stack.writer.read { (db: Database) throws in
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty, "seed \(seed)")
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM payment_methods WHERE is_default = 1 AND archived = 0")
          == 1, "seed \(seed)")
      #expect(
        try Bool.fetchOne(
          db, sql: "SELECT archived FROM payment_methods WHERE id = ?",
          arguments: [source.id.uuidString]) == true)
      for key in plan.sourceZero where plan.opening[key] == nil {
        #expect(
          try Int64.fetchOne(
            db,
            sql: """
              SELECT b.actual_e4 FROM reconciliation_balances b
              JOIN reconciliations r ON r.id = b.reconciliation_id
              WHERE r.kind = 'opening' AND b.payment_method_id = ? AND b.currency = ?
              ORDER BY r.rowid DESC LIMIT 1
              """, arguments: [key.accountId.uuidString, key.currency.code]) == 0,
          "seed \(seed): the source is not counted at zero")
      }
    }

    // The money: in every currency the merged account is counted at, it holds what the two
    // held together before — each balance worked out on the history as it was and again on the
    // history as the merge left it —, and the source holds nothing.
    let merged = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 2) }
    let balancesAfter = AccountBalances.build(
      entries: merged.entries, transfers: merged.transfers,
      debtEntries: merged.planning.debtEntries,
      debts: Dictionary(uniqueKeysWithValues: merged.debts.map { ($0.id, $0) }),
      reconciliations: merged.planning.reconciliations,
      balances: merged.planning.reconciledBalances, accounts: merged.paymentMethods,
      tree: CategoryTree(merged.categories), now: at, calendar: calendar)
    for key in plan.opening.keys {
      let from = BalanceKey(accountId: source.id, currency: key.currency)
      let together =
        (balances.balance(key, at: at) ?? .zero) + (balances.balance(from, at: at) ?? .zero)
      #expect(
        balancesAfter.balance(key, at: at) == together,
        "seed \(seed): \(key.currency.code) is not what the two held together")
    }
    for key in plan.sourceZero {
      #expect(
        balancesAfter.balance(key, at: at) == .zero,
        "seed \(seed): the source still holds \(key.currency.code)")
    }
  }

  /// The check of the money above says something: most of the drawn pairs are counted, so the
  /// merged account gets an opening count to compare.
  @Test func mostDrawnMergesCountTheMergedAccount() throws {
    var counted = 0
    let seeds = UInt64(41)...UInt64(52)
    for seed in seeds {
      var random = SeededRandom(seed: seed)
      let stack = try PlanningUndoPropertyTests.stack()
      let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
      let accounts = dataset.paymentMethods
      let source = accounts[random.int(in: 0..<accounts.count)]
      var target = accounts[random.int(in: 0..<accounts.count)]
      while target.id == source.id { target = accounts[random.int(in: 0..<accounts.count)] }
      let at = Date(timeIntervalSince1970: 1_790_000_000)
      let balances = AccountBalances.build(
        entries: dataset.entries, transfers: dataset.transfers,
        debtEntries: dataset.planning.debtEntries,
        debts: Dictionary(uniqueKeysWithValues: dataset.debts.map { ($0.id, $0) }),
        reconciliations: dataset.planning.reconciliations,
        balances: dataset.planning.reconciledBalances, accounts: accounts,
        tree: CategoryTree(dataset.categories), now: at, calendar: TestSupport.sampleCalendar)
      let plan = AccountMerge.plan(
        source: source, target: target, transfers: dataset.transfers, balances: balances, at: at
      ).plan
      if !plan.opening.isEmpty { counted += 1 }
    }
    #expect(counted * 2 >= seeds.count, "only \(counted) of \(seeds.count) merges were counted")
  }
}
