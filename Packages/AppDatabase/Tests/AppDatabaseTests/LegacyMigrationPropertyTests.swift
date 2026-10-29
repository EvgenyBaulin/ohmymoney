import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update of an older database, tried on many databases drawn at random: whatever an older
/// build left — main accounts flagged twice or not at all, archived ones flagged, currencies
/// NULL, blank or in lower case, operations without an account in the bin and out of it, zero
/// amounts, reconciliations without their moment — every value it held is still there byte for
/// byte, the only changes are the two fills the update is allowed, they land where an
/// independent reading of the rule puts them, and opening the file again changes nothing more.
@Suite("Older databases drawn at random survive the update value for value")
struct LegacyMigrationPropertyTests {
  private static let context = MigrationContext(mainAccountName: "Основной счёт")

  /// The two values the update may change of an older database.
  private static let fills = ["payment_methods": "is_default", "transactions": "payment_method_id"]

  /// The columns the update adds to the tables an older build had, with the value every older
  /// row gets.
  private static let added: [String: [String: String]] = [
    "payment_methods": ["group_id": "NULL", "sort": "0", "other_currencies": "''"],
    "transactions": ["account_currency": "NULL", "account_amount_e4": "NULL"],
    "transaction_parts": ["refund_of_part_id": "NULL"],
    "reconciliations": ["kind": "'total'"],
    "goals": ["currency": "'RUB'"],
    "debt_entries": [
      "payment_method_id": "NULL", "occurred_at": "NULL", "account_currency": "NULL",
      "account_amount_e4": "NULL",
    ],
    "templates": ["archived": "0"],
  ]

  /// The columns the update to 1.2 adds, empty on every older row: nothing an older row had is
  /// a card, a cashback, an event of a payment, an account of an expectation, a deletion or an
  /// origin. The plan of a goal is not here: a goal with a plan gets the month of the update.
  private static let addedByTheCards: [String: [String]] = [
    "transactions": ["card_id", "cashback_currency", "cashback_e4"],
    "scheduled_payments": ["card_id", "event_id"],
    "expected_income": ["payment_method_id"],
    "debts": ["deleted_at"],
    "reconciliations": ["origin"],
  ]

  /// Forty databases of every shape of the main account's flags, with and without operations
  /// that have no account.
  static let seeds: [UInt64] = Array(1...40)

  /// Every value of every older row is kept byte for byte, but for the two fills; the fills are
  /// exactly those the rule gives; the columns the update adds hold their defaults; no table
  /// loses or gains a row but the accounts, which gain the one the update made, if it made one.
  @Test(arguments: seeds)
  func everyOlderValueIsKeptAndOnlyTheFillsChange(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let before = try book.read { db in try ExactTables.read(db) }
    let brokenBefore = try book.read { db in
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
    }
    let expectedMain = MainAccountModel.main(
      accounts: book.accounts, operations: book.operationAccounts)

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 14, "seed \(seed)")

    try stack.writer.read { db in
      let after = try ExactTables.read(db, columns: before.mapValues(\.columns))
      // Every table keeps its rows, in their order; the accounts gain the one made, if any.
      for (table, old) in before {
        let gained = table == "payment_methods" && expectedMain == .created ? 1 : 0
        #expect(after[table]?.rows.count == old.rows.count + gained, "seed \(seed): \(table)")
      }
      // Every value but the fills, byte for byte.
      for (table, old) in before {
        var oldTable = old
        var newTable = try #require(after[table])
        if let column = Self.fills[table] {
          oldTable = oldTable.dropping(column)
          newTable = newTable.dropping(column)
        }
        if table == "payment_methods", expectedMain == .created {
          newTable.rows.removeLast()
        }
        #expect(newTable == oldTable, "seed \(seed): \(table) changed")
      }

      // The fills: the main account alone is flagged; an operation without an account has it.
      let main: String
      switch expectedMain {
      case .existing(let id):
        main = id
      case .created:
        let made = try #require(
          try Row.fetchOne(
            db, sql: "SELECT * FROM payment_methods ORDER BY rowid DESC LIMIT 1"))
        main = made["id"]
        #expect(made["name"] == "Основной счёт")
        #expect(made["kind"] == "account")
        #expect(made["currency"] == "RUB")
        #expect(made["is_default"] == 1)
        #expect(made["archived"] == 0)
      case .none:
        main = ""
      }
      let flagged = try String.fetchAll(
        db, sql: "SELECT id FROM payment_methods WHERE is_default = 1 ORDER BY rowid")
      #expect(flagged == (main.isEmpty ? [] : [main]), "seed \(seed): main account")
      let accountsAfter = try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(
          db, sql: "SELECT id, payment_method_id FROM transactions"
        ).map { row -> (String, String?) in (row["id"], row["payment_method_id"]) })
      for operation in book.operationAccounts {
        #expect(
          accountsAfter[operation.id] == .some(operation.account ?? main),
          "seed \(seed): operation \(operation.id)")
      }

      // What the update added holds its defaults in every older row.
      for (table, columns) in Self.addedByTheCards {
        for column in columns {
          #expect(
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NOT NULL")
              == 0, "seed \(seed): \(table).\(column)")
        }
      }
      for (table, columns) in Self.added {
        let values = try ExactTables.read(db, columns: [table: Array(columns.keys.sorted())])
        let contents = try #require(values[table])
        let olderRows = before[table]?.rows.count ?? 0
        for (column, value) in columns {
          #expect(
            contents.values(of: column).prefix(olderRows).allSatisfy { $0 == value },
            "seed \(seed): \(table).\(column)")
        }
      }
      // The update breaks no key; the ones an older build broke stay what they were.
      #expect(
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count == brokenBefore,
        "seed \(seed)")
    }
  }

  /// The counts the update reports are the counts of what it did: which rule chose the main
  /// account, how many flags it cleared, how many operations it gave an account.
  @Test(arguments: seeds)
  func theCountsOfTheDataStepAreWhatItDid(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let expectedMain = MainAccountModel.main(
      accounts: book.accounts, operations: book.operationAccounts)
    let flaggedBefore = book.accounts.filter(\.isDefault).map(\.id)
    let cards = try Self.cardsStep(of: book)

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }

    var expected = [
      "mainKept": 0, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 0, "assigned": 0,
    ]
    switch expectedMain {
    case .existing(let id):
      let wasFlagged = flaggedBefore.contains(id)
      expected["mainKept"] = wasFlagged ? 1 : 0
      expected["mainChosen"] = wasFlagged ? 0 : 1
      expected["defaultsCleared"] = flaggedBefore.filter { $0 != id }.count
      expected["assigned"] = book.operationAccounts.filter { $0.account == nil }.count
    case .created:
      expected["mainCreated"] = 1
      expected["defaultsCleared"] = flaggedBefore.count
      expected["assigned"] = book.operationAccounts.filter { $0.account == nil }.count
    case .none:
      break
    }
    #expect(TestSupport.accountsStep(stack.applied.dataSteps) == expected, "seed \(seed)")
    #expect(TestSupport.cardsStep(stack.applied.dataSteps) == cards, "seed \(seed)")
    #expect(stack.applied.dataSteps.count == 16, "seed \(seed)")
    // Every account with a name sits under a bank, and the step counted exactly those.
    let (banks, filed, loose) = try stack.writer.read { db in
      (
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM banks") ?? -1,
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payment_methods WHERE bank_id IS NOT NULL")
          ?? -1,
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM payment_methods
            WHERE bank_id IS NULL AND length(trim(name)) > 0
            """) ?? -1
      )
    }
    #expect(stack.applied.dataSteps["banksCreated"] == banks, "seed \(seed)")
    #expect(stack.applied.dataSteps["accountsFiled"] == filed, "seed \(seed)")
    #expect(loose == 0, "seed \(seed)")
  }

  /// The counts the step of the cards gives a drawn file, read from it before the update: a card
  /// for every live account of the kind «card» with a name, and a start for every goal plan. A
  /// file of 1.0.0 has no sheet of accounts, so no count gets a mode.
  private static func cardsStep(of book: RandomLegacyDatabase) throws -> [String: Int] {
    try book.read { db in
      var accounts: [MigratingCardAccount] = []
      for row in try Row.fetchAll(
        db, sql: "SELECT id, name, kind, archived FROM payment_methods ORDER BY rowid")
      {
        guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
        let kind: String? = row["kind"]
        let archived: Int64? = row["archived"]
        accounts.append(
          MigratingCardAccount(
            id: id, name: row["name"] ?? "", kind: kind.flatMap(PaymentMethodKind.init(rawValue:)),
            archived: (archived ?? 0) != 0))
      }
      let plan = CardsMigration.plan(accounts: accounts)
      let planned =
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM goals WHERE monthly_plan_e4 > 0") ?? 0
      return TestSupport.cardsStep(
        cardsCreated: plan.cards.count, cardsSkipped: plan.skipped, goalPlansStarted: planned)
    }
  }

  /// Opened again, the updated file applies nothing and changes nothing — not even through the
  /// repair of the main account every start runs, which finds nothing to put right.
  @Test(arguments: seeds)
  func openingTheUpdatedFileAgainChangesNothing(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    do {
      let stack = try DatabaseStack(
        url: book.url, schema: TestSupport.schemaSource, context: Self.context)
      try stack.close()
    }
    let snapshot = book.url.deletingLastPathComponent().appendingPathComponent("first.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: snapshot)

    let again = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    #expect(again.applied.applied == 0)
    #expect(again.applied.dataSteps.isEmpty)
    #expect(try AccountRepository(writer: again.writer).ensureMainAccount() == nil, "seed \(seed)")
    try again.close()
    #expect(try DatabaseStack.sameData(fileAt: snapshot, as: book.url), "seed \(seed)")
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: TestSupport.schemaSource) == [])
  }

  /// The fill of the accounts changes no figure of any month: the ledger of the updated file as
  /// loaded equals the ledger of the same history with the accounts it had before the update.
  /// That the history itself is what the older file held is the next two tests' part.
  @Test(arguments: seeds)
  func theFillOfTheAccountsMovesNoFigure(seed: UInt64) async throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }

    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)
    var older = loaded
    let accountBefore = Dictionary(
      uniqueKeysWithValues: book.operationAccounts.map { ($0.id, $0.account) })
    older.entries = loaded.entries.map { entry in
      var entry = entry
      let old = accountBefore[entry.id.uuidString] ?? nil
      entry.transaction.paymentMethodId = old.flatMap(UUID.init(uuidString:))
      return entry
    }
    let known = Set(book.accounts.map(\.id))
    older.paymentMethods = loaded.paymentMethods.filter { known.contains($0.id.uuidString) }

    let calendar = TestSupport.sampleCalendar
    let after = Ledger(dataset: loaded, calendar: calendar)
    let before = Ledger(dataset: older, calendar: calendar)
    #expect(
      LedgerFigures.of(after, calendar: calendar) == LedgerFigures.of(before, calendar: calendar))
    #expect(loaded.entries.count == book.operationAccounts.filter(\.live).count)
    #expect(loaded.paymentMethods.filter { $0.isMain && !$0.archived }.count <= 1)
  }

  /// The money of every month, counted in SQL on the older file before the update and on the
  /// updated file after it, by a rule of its own: the operations' rubles by kind and month, the
  /// parts' rubles and own amounts by month, category and currency, the links of money back by
  /// operation. Every figure is the same.
  @Test(arguments: seeds)
  func theMoneyOfEveryMonthIsWhatTheOlderFileHeld(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let before = try book.read { db in try OlderFigures.read(db) }
    #expect(!before.isEmpty || book.operationAccounts.isEmpty)
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    let after = try stack.writer.read { db in try OlderFigures.read(db) }
    #expect(after == before, "seed \(seed)")
  }

  /// What the app loads from the updated file is what the older file held, operation by
  /// operation and part by part, read out of the older file in SQL before the update: kind,
  /// moment, currency, amount, rubles, and each part's category, amounts, for whom, «за другого»
  /// and its state. With the fill moving no figure (above), the ledger of every month is the
  /// ledger of the history 1.0.0 kept.
  @Test(arguments: seeds)
  func theLoadReadsWhatTheOlderFileHeld(seed: UInt64) async throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let older = try book.read { db in try OlderOperations.read(db) }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)

    #expect(Set(loaded.entries.map(\.id.uuidString)) == Set(older.keys), "seed \(seed)")
    for entry in loaded.entries {
      guard let old = older[entry.id.uuidString] else { continue }
      let label = "seed \(seed), operation \(entry.id)"
      #expect(entry.transaction.kind.rawValue == old.kind, "\(label)")
      #expect(
        (entry.transaction.occurredAt.timeIntervalSince1970 * 1_000).rounded() == old.millisecond,
        "\(label)")
      #expect(entry.transaction.currency.code == old.currency.uppercased(), "\(label)")
      #expect(entry.transaction.amountE4.raw == old.amount, "\(label)")
      #expect(entry.transaction.amountRubE4.raw == old.rubles, "\(label)")
      let parts = entry.parts.map { part in
        OlderOperations.Part(
          id: part.id.uuidString, category: part.categoryId?.uuidString,
          amount: part.amountE4.raw, rubles: part.amountRubE4.raw, forWhom: part.forWhom.rawValue,
          reimbursable: part.reimbursable, status: part.reimbursementStatus?.rawValue)
      }
      #expect(parts == old.parts, "\(label): parts")
    }
  }

  /// A large history — thousands of operations, a third of them without an account — goes
  /// through the same way, and every one of them ends on an account.
  @Test func aLargeOlderDatabaseIsUpdatedWhole() throws {
    let book = try RandomLegacyDatabase(
      seed: 4_242, operations: 4_000, accounts: 3...6, flags: RandomLegacyDatabase.Flags.none,
      unassigned: true)
    defer { book.remove() }
    let before = try book.read { db in try ExactTables.read(db) }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    try stack.writer.read { db in
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL")
          == 0)
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM payment_methods WHERE is_default = 1 AND archived = 0")
          == 1)
      let after = try ExactTables.read(db, columns: before.mapValues(\.columns))
      for (table, old) in before where Self.fills[table] == nil {
        #expect(after[table] == old, "\(table) changed")
      }
    }
    #expect(stack.applied.dataSteps["assigned"] ?? 0 > 100)
  }

  /// A file with keys an older build left pointing nowhere is updated all the same, and the
  /// update adds no broken key of its own.
  @Test(arguments: [UInt64(7), 11, 19, 23])
  func anOlderFileWithBrokenKeysIsUpdated(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed, brokenLinks: true)
    defer { book.remove() }
    let broken = try book.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count }
    #expect(broken >= 2)
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().count == 17)
    let after = try stack.writer.read { db in
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
    }
    #expect(after == broken)
  }

  /// An older database that was installed and never used — its categories and settings, no
  /// account and no operation — gets no account from the update: the setup of the accounts
  /// makes the first one, and the counts say that nothing was chosen.
  @Test func anOlderDatabaseWithNothingRecordedGetsNoAccount() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-unused-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("finance.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    do {
      let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0003_model"))
      try old.writer.write { db in
        for category in TestSupport.sample(months: 1).categories where category.parentId == nil {
          try LegacyWriter.insert(category, db: db)
        }
        try db.execute(sql: "INSERT INTO settings (key, value) VALUES ('app.language', 'ru')")
      }
      try old.close()
    }
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(
      TestSupport.accountsStep(stack.applied.dataSteps)
        == ["mainKept": 0, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 0, "assigned": 0])
    #expect(TestSupport.cardsStep(stack.applied.dataSteps) == TestSupport.cardsStep())
    #expect(
      try ReferenceRepository(writer: stack.writer).paymentMethods(includeArchived: true).isEmpty)
    #expect(try AccountRepository(writer: stack.writer).ensureMainAccount() == nil)
  }

  /// The choice of the main account, written apart from the code, agrees with the rule of the
  /// core on thousands of drawn account lists — flags, archive, use and order of writing. The
  /// rowids are drawn apart from the order of the list the core is given, so «the first written
  /// on a tie» is the smaller rowid, not the first in the list.
  @Test func theRuleOfTheCoreAgreesWithTheModelOnDrawnAccounts() {
    var random = SeededRandom(seed: 20_260_926)
    var listOrderDiffered = 0
    for round in 0..<3_000 {
      var accounts: [RandomLegacyDatabase.Account] = []
      var rowids: Set<Int64> = []
      for _ in 0..<random.int(in: 0...5) {
        var rowid = Int64(random.int(in: 1...40))
        while !rowids.insert(rowid).inserted { rowid = Int64(random.int(in: 1...40)) }
        accounts.append(
          RandomLegacyDatabase.Account(
            id: UUID().uuidString, rowid: rowid,
            archived: random.chance(1, outOf: 3), isDefault: random.chance(1, outOf: 3)))
      }
      if accounts.map(\.rowid) != accounts.map(\.rowid).sorted() { listOrderDiffered += 1 }
      var operations: [(id: String, account: String?, live: Bool)] = []
      for _ in 0..<random.int(in: 0...8) {
        let account =
          accounts.isEmpty || random.chance(1, outOf: 4)
          ? nil : accounts[random.int(in: 0..<accounts.count)].id
        operations.append((UUID().uuidString, account, !random.chance(1, outOf: 5)))
      }
      // Ties are what the rule is about: now and then every account is used as often.
      if random.chance(1, outOf: 3) {
        operations.removeAll { $0.account != nil }
        for account in accounts {
          operations += [
            (UUID().uuidString, account.id, true), (UUID().uuidString, account.id, true),
          ]
        }
      }
      var live: [UUID: Int] = [:]
      for operation in operations where operation.live {
        if let account = operation.account { live[UUID(uuidString: account)!, default: 0] += 1 }
      }
      let plan = AccountsMigration.plan(
        accounts: accounts.map {
          MigratingAccount(
            id: UUID(uuidString: $0.id)!, name: "x", archived: $0.archived,
            isDefault: $0.isDefault, rowid: $0.rowid)
        },
        liveOperations: live, unassigned: operations.filter { $0.account == nil }.count,
        operations: operations.count, mainAccountName: "Main", makeId: { UUID() })
      let model = MainAccountModel.main(accounts: accounts, operations: operations)
      switch model {
      case .existing(let id):
        #expect(plan.mainId?.uuidString == id && plan.created == nil, "round \(round)")
      case .created:
        #expect(plan.created != nil && plan.mainId == plan.created?.id, "round \(round)")
      case .none:
        #expect(plan.mainId == nil && plan.created == nil, "round \(round)")
      }
      let flaggedOthers = accounts.filter { $0.isDefault && $0.id != plan.mainId?.uuidString }
      #expect(
        Set(plan.clearDefault.map(\.uuidString)) == Set(flaggedOthers.map(\.id)), "round \(round)")
      let unassigned = operations.contains { $0.account == nil }
      #expect(plan.assignUnassignedTo == (unassigned ? plan.mainId : nil), "round \(round)")
    }
    #expect(listOrderDiffered > 1_000, "the rowids followed the list")
  }
}

/// The money of an older or an updated file by month, counted in SQL straight from the stored
/// values: nothing of the app's reading in between.
enum OlderFigures {
  static func read(_ db: Database) throws -> [String: Int64] {
    var figures: [String: Int64] = [:]
    func add(_ label: String, _ sql: String) throws {
      for row in try Row.fetchAll(db, sql: sql) {
        let key: String = row[0] ?? "-"
        figures["\(label) \(key)"] = row[1]
      }
    }
    try add(
      "operations",
      """
      SELECT kind || ' ' || substr(occurred_at, 1, 7) || ' ' || coalesce(period_month, '-'),
        SUM(amount_rub_e4) FROM transactions WHERE deleted_at IS NULL GROUP BY 1
      """)
    try add(
      "operations in their currency",
      """
      SELECT upper(trim(currency)) || ' ' || substr(occurred_at, 1, 7), SUM(amount_e4)
      FROM transactions WHERE deleted_at IS NULL GROUP BY 1
      """)
    try add(
      "parts",
      """
      SELECT t.kind || ' ' || substr(t.occurred_at, 1, 7) || ' ' || coalesce(p.category_id, '-')
        || ' ' || p.for_whom || ' ' || p.reimbursable || ' ' || coalesce(p.reimbursement_status, '-'),
        SUM(p.amount_rub_e4)
      FROM transaction_parts p JOIN transactions t ON t.id = p.transaction_id
      WHERE t.deleted_at IS NULL GROUP BY 1
      """)
    try add(
      "parts in their currency",
      """
      SELECT upper(trim(t.currency)) || ' ' || coalesce(p.goal_id, '-') || ' '
        || coalesce(p.event_id, '-'), SUM(p.amount_e4)
      FROM transaction_parts p JOIN transactions t ON t.id = p.transaction_id
      WHERE t.deleted_at IS NULL GROUP BY 1
      """)
    try add(
      "money back",
      "SELECT reimbursement_tx_id || ' ' || part_id, SUM(amount_e4) FROM reimbursement_links GROUP BY 1"
    )
    try add(
      "debt journal",
      "SELECT debt_id || ' ' || kind, SUM(amount_e4) FROM debt_entries GROUP BY 1")
    return figures
  }
}

/// The live operations of an older file and their parts, read in SQL straight from the stored
/// values.
enum OlderOperations {
  struct Part: Equatable {
    var id: String
    var category: String?
    var amount: Int64
    var rubles: Int64
    var forWhom: String
    var reimbursable: Bool
    var status: String?
  }

  struct Operation {
    var kind: String
    var millisecond: Double
    var currency: String
    var amount: Int64
    var rubles: Int64
    var parts: [Part]
  }

  static func read(_ db: Database) throws -> [String: Operation] {
    var operations: [String: Operation] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT id, kind, occurred_at, currency, amount_e4, amount_rub_e4 FROM transactions
        WHERE deleted_at IS NULL
        """)
    {
      operations[row["id"]] = Operation(
        kind: row["kind"], millisecond: millisecond(of: row["occurred_at"]),
        currency: (row["currency"] as String? ?? "RUB"), amount: row["amount_e4"],
        rubles: row["amount_rub_e4"], parts: [])
    }
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT transaction_id, id, category_id, amount_e4, amount_rub_e4, for_whom, reimbursable,
          reimbursement_status
        FROM transaction_parts ORDER BY rowid
        """)
    {
      let owner: String = row["transaction_id"]
      guard operations[owner] != nil else { continue }
      operations[owner]?.parts.append(
        Part(
          id: row["id"], category: row["category_id"], amount: row["amount_e4"],
          rubles: row["amount_rub_e4"], forWhom: row["for_whom"],
          reimbursable: (row["reimbursable"] as Int64) != 0, status: row["reimbursement_status"]))
    }
    return operations
  }

  /// `YYYY-MM-DD HH:MM:SS.SSS` in UTC, as milliseconds since 1970.
  static func millisecond(of text: String) -> Double {
    let digits = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(
      from: DateComponents(
        year: digits[0], month: digits[1], day: digits[2], hour: digits[3], minute: digits[4],
        second: digits[5]))!
    return date.timeIntervalSince1970 * 1_000 + Double(digits.count > 6 ? digits[6] : 0)
  }
}

/// The figures of every month a ledger gives: my spending, income, and the money of each kind
/// and category.
enum LedgerFigures {
  static func of(_ ledger: Ledger, calendar: CalendarContext) -> [String: AmountE4] {
    var totals: [String: AmountE4] = [:]
    for month in Set(ledger.rows.map(\.month)) {
      let days = DayRange(month.firstDay, calendar.adding(days: -1, to: month.next.firstDay))
      totals["\(month.iso) my expenses"] = ledger.expenses(in: days)
      totals["\(month.iso) income"] = ledger.income(attributedTo: [month])
    }
    for row in ledger.rows {
      let key = "\(row.month.iso) \(row.kind.rawValue) \(row.categoryId?.uuidString ?? "-")"
      totals[key, default: .zero] += row.contribution
    }
    return totals
  }
}
