import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to 1.2 (`0005_cards`) keeps a database of 1.1 whole: every row and every value it
/// had is still there byte for byte, the money of every account is where it was, and the only
/// values it fills are new — a card for every live card account, the mode of every compared
/// count, the month the plan of a goal counts from. A first count stays a starting point: no
/// difference is computed again and no operation is written. An update that stops leaves the
/// file of 1.1 as it was.
@Suite("A database of 1.1 survives the update to 1.2 whole")
struct Migration0005Tests {
  private static let context = MigrationContext.tests

  /// The schema of 1.2: the update to it is the migrations up to `0005_cards`; what the update
  /// to 1.3 does is `Migration0006Tests`.
  private static let schema = FilteredSchemaSource(upTo: "0005_cards")

  /// The columns 0005 adds to the tables of 1.1, all empty on every older row but the two the
  /// step fills.
  private static let added: [String: [String]] = [
    "transactions": ["card_id", "cashback_currency", "cashback_e4"],
    "scheduled_payments": ["card_id", "event_id"],
    "expected_income": ["payment_method_id"],
    "debts": ["deleted_at"],
    "reconciliations": ["origin"],
  ]

  // MARK: 1. Every value

  @Test func everyValueOfOnePointOneIsKept() throws {
    let book = try OnePointOneBook(named: "kept")
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db) }
    let sums = try book.read(Self.sums)
    #expect(before.count == 29)
    for (table, old) in before {
      #expect(!old.rows.isEmpty, "\(table) has no rows to compare")
    }

    let stack = try DatabaseStack(
      url: book.url, schema: Self.schema, context: Self.context)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().count == 5)
    #expect(try stack.appliedMigrations().last == "0005_cards")
    #expect(stack.applied.applied == 1)
    try stack.writer.read { db in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table) changed")
      }
      for (table, columns) in Self.added {
        for column in columns {
          #expect(
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NOT NULL")
              == 0, "\(table).\(column) was filled")
        }
      }
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cashback_rules") == 0)
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      #expect(try Self.sums(db) == sums)
    }
    #expect(try DatabaseStack.check(fileAt: book.url, schema: Self.schema) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: Self.schema) == [])
    // Every row of the new tables and columns reads. (The whole snapshot is read from the file of
    // 1.3, which has the banks it names: `Migration0006Tests`.)
    _ = try stack.writer.read { db in try PaymentCard.fetchAll(db) }
    _ = try stack.writer.read { db in try CashbackRule.fetchAll(db) }
  }

  // MARK: 2. The money

  /// The balances the ledger makes of the updated file are the ones it made of the same history
  /// before: for every account and currency, at every count's moment and now; and so are the
  /// rows of the ledger and every month's figures.
  @Test func theMoneyOfEveryAccountStaysWhereItWas() async throws {
    let book = try OnePointOneBook(named: "money")
    defer { book.remove() }
    // Read through the whole snapshot, which names the banks too: the file goes on to 1.3.
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }

    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)
    let calendar = TestSupport.sampleCalendar
    let now = calendar.startOfDay(calendar.adding(days: 1, to: book.set.lastDay))
    let after = Self.balances(loaded, now: now)
    let before = Self.balances(book.dataset, now: now)
    #expect(Set(after.keys) == Set(before.keys))
    #expect(before.keys.count > 10)
    var moments = Set(loaded.planning.reconciliations.compactMap(\.reconciledAt))
    moments.insert(now)
    for key in before.keys {
      #expect(after[key]?.amountE4 == before[key]?.amountE4, "\(key)")
      for moment in moments {
        #expect(after.balance(key, at: moment) == before.balance(key, at: moment), "\(key)")
      }
    }
    let lowerCaseRubles = BalanceKey(accountId: book.lowerCase.id, currency: .rub)
    #expect(after.hasHistory(lowerCaseRubles), "the card in lower case lost its purchase")

    let ledgerAfter = Ledger(dataset: loaded, calendar: calendar)
    let ledgerBefore = Ledger(dataset: book.dataset, calendar: calendar)
    #expect(ledgerAfter.rows.count == ledgerBefore.rows.count)
    #expect(Set(ledgerAfter.rows) == Set(ledgerBefore.rows))
    #expect(Self.monthTotals(ledgerAfter) == Self.monthTotals(ledgerBefore))
    #expect(!Self.monthTotals(ledgerBefore).isEmpty)
  }

  // MARK: 3. The cards

  @Test func oneCardForEveryLiveCardAccount() throws {
    let book = try OnePointOneBook(named: "cards")
    defer { book.remove() }
    let accounts = try book.read { db in
      try Row.fetchAll(
        db, sql: "SELECT id, name, kind, archived FROM payment_methods ORDER BY rowid")
    }
    let stored = Dictionary(
      uniqueKeysWithValues: accounts.map { row -> (UUID, String) in
        let text: String = row["id"]
        return (UUID(uuidString: text)!, text)
      })
    let plan = CardsMigration.plan(
      accounts: accounts.map { row in
        let text: String = row["id"]
        let kind: String = row["kind"]
        let archived: Int = row["archived"]
        return MigratingCardAccount(
          id: UUID(uuidString: text)!, name: row["name"], kind: PaymentMethodKind(rawValue: kind),
          archived: archived != 0)
      })
    #expect(plan == CardsMigration.plan(accounts: book.migratingAccounts))
    #expect(plan.skipped == 1)
    #expect(plan.cards.contains { $0.accountId == book.visa.id && $0.name == "Visa" })
    #expect(plan.cards.contains { $0.accountId == book.lowerCase.id && $0.name == "Сбер" })
    #expect(!plan.cards.contains { $0.accountId == book.archivedCard.id })

    let stack = try DatabaseStack(
      url: book.url, schema: Self.schema, context: Self.context)
    defer { try? stack.close() }
    #expect(TestSupport.cardsStep(stack.applied.dataSteps) == book.cardsStep)
    #expect(stack.applied.dataSteps["cardsCreated"] == plan.cards.count)
    #expect(stack.applied.dataSteps["cardsSkipped"] == 1)
    #expect(TestSupport.accountsStep(stack.applied.dataSteps) == [:], "0004 ran again")
    try stack.writer.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, payment_method_id, name, aliases, sort, archived FROM cards ORDER BY rowid"
      )
      #expect(rows.count == plan.cards.count)
      for (row, card) in zip(rows, plan.cards) {
        #expect(row["id"] == card.id.uuidString)
        #expect(row["id"] == CardsMigration.cardId(forAccount: card.accountId).uuidString)
        // The key of the account as it is stored: in lower case where it is so.
        #expect(row["payment_method_id"] == stored[card.accountId])
        #expect(row["name"] == card.name)
        #expect(row["aliases"] == "")
        #expect(row["sort"] == 0)
        #expect(row["archived"] == 0)
      }
      #expect(
        try String.fetchOne(
          db, sql: "SELECT payment_method_id FROM cards WHERE name = 'Сбер'") == book.lowerCaseText)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE card_id IS NOT NULL")
          == 0)
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scheduled_payments WHERE card_id IS NOT NULL") == 0)
    }
    // Every card reads, and names its account.
    let cards = try stack.writer.read { db in try PaymentCard.fetchAll(db) }
    #expect(Set(cards) == Set(plan.cards))
  }

  // MARK: 4. The counts

  @Test func recordsDifferenceFollowsTheSheet() throws {
    let book = try OnePointOneBook(named: "counts")
    defer { book.remove() }
    let before = try book.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, expected_e4, difference_e4, transaction_id FROM reconciliation_balances
          ORDER BY rowid
          """)
    }
    let operationsBefore = try book.read { db in
      try TestSupport.contents(db)["transactions"]
    }

    let stack = try DatabaseStack(
      url: book.url, schema: Self.schema, context: Self.context)
    defer { try? stack.close() }
    let modes = try stack.writer.read { db in
      Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(
          db, sql: "SELECT id, records_difference FROM reconciliation_balances"
        ).map { row -> (String, Int?) in (row["id"], row["records_difference"]) })
    }
    for (letter, records) in [
      ("A", 1), ("B", 1), ("C", 0), ("D", 1), ("E", 1), ("F", 0), ("G", 0), ("H", 1), ("I", 1),
    ] {
      let row = try #require(book.rows[letter])
      #expect(modes[row.id.uuidString] == .some(records), "\(letter)")
    }
    for (id, records) in book.expectedModes {
      #expect(modes[id.uuidString] == .some(records ? 1 : 0))
    }
    // Openings, starting points and every row not compared on a sheet keep no mode.
    let compared = Set(book.expectedModes.keys.map(\.uuidString))
    for (id, mode) in modes where !compared.contains(id) {
      #expect(mode == nil, "\(id) got a mode")
    }
    #expect(
      TestSupport.cardsStep(stack.applied.dataSteps)["countsRecorded"]
        == book.expectedModes.values.filter { $0 }.count)
    #expect(TestSupport.cardsStep(stack.applied.dataSteps)["countsKept"] == 3)

    // No expected balance, difference or operation of a count changed, and no operation of a
    // difference came or went.
    try stack.writer.read { db in
      let after = try Row.fetchAll(
        db,
        sql: """
          SELECT id, expected_e4, difference_e4, transaction_id FROM reconciliation_balances
          ORDER BY rowid
          """)
      #expect(after == before)
      let operations = try TestSupport.contents(
        db, columns: ["transactions": operationsBefore?.columns ?? []])
      #expect(operations["transactions"] == operationsBefore)
      // The model of the counts reads back with its mode.
      let read = try ReconciledBalance.fetchAll(db)
      let a = try #require(book.rows["A"])
      let c = try #require(book.rows["C"])
      #expect(read.first { $0.id == a.id }?.recordsDifference == true)
      #expect(read.first { $0.id == c.id }?.recordsDifference == false)
      #expect(read.filter { $0.expectedE4 == nil }.allSatisfy { $0.recordsDifference == nil })
    }
  }

  /// A goal that had a plan counts it from the month of the update; one without keeps none;
  /// nothing else of a goal changes.
  @Test func aPlannedGoalStartsItsPlanInTheUpdateMonth() throws {
    let book = try OnePointOneBook(named: "goals")
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db)["goals"] }
    let stack = try DatabaseStack(
      url: book.url, schema: Self.schema,
      context: MigrationContext(mainAccountName: "Main account", updateMonth: "2026-09"))
    defer { try? stack.close() }
    let goals = try stack.writer.read { db in try Goal.fetchAll(db) }
    let planned = try #require(goals.first { $0.id == book.goals[0].id })
    let archived = try #require(goals.first { $0.id == book.goals[1].id })
    let unplanned = try #require(goals.first { $0.id == book.goals[2].id })
    #expect(planned.planStartMonth == MonthKey(year: 2026, month: 9))
    #expect(archived.planStartMonth == MonthKey(year: 2026, month: 9))
    #expect(unplanned.planStartMonth == nil)
    for goal in goals {
      #expect(
        (goal.planStartMonth != nil) == ((goal.monthlyPlanE4?.raw ?? 0) > 0), "\(goal.name)")
    }
    #expect(stack.applied.dataSteps["goalPlansStarted"] == book.cardsStep["goalPlansStarted"])
    #expect(book.cardsStep["goalPlansStarted"] ?? 0 >= 2)
    try stack.writer.read { db in
      let after = try TestSupport.contents(db, columns: ["goals": before?.columns ?? []])
      #expect(after["goals"] == before)
    }
  }

  /// The first read after the update sees what the update added. A reader connection opened
  /// before the update keeps the schema it read then, and a `SELECT *` it prepares takes the
  /// columns of that schema: the mode of every count and the month of every plan would read as
  /// none until the next read.
  @Test func theFirstReadAfterTheUpdateSeesItsColumns() throws {
    let book = try OnePointOneBook(named: "first-read")
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: Self.schema, context: Self.context)
    defer { try? stack.close() }
    let counts = try stack.writer.read { db in try ReconciledBalance.fetchAll(db) }
    let a = try #require(book.rows["A"])
    #expect(counts.first { $0.id == a.id }?.recordsDifference == true)
    let goals = try stack.writer.read { db in try Goal.fetchAll(db) }
    #expect(
      goals.first { $0.id == book.goals[0].id }?.planStartMonth == MonthKey(year: 2026, month: 9))
  }

  // MARK: 5–6. A stop, and the attempt after it

  @Test func aStopInTheStepLeavesTheOnePointOneFile() throws {
    let book = try OnePointOneBook(named: "stop")
    defer { book.remove() }
    let before = try book.keep(as: "before.sqlite")
    var stopping = Self.context
    stopping.failAfterSQL = true

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: {
        try DatabaseStack(url: book.url, schema: Self.schema, context: stopping)
      })
    #expect(failure.migration == "0005_cards")
    #expect(failure.from == 4)
    #expect(failure.to == 5)
    #expect(failure.underlying is MigrationDataSteps.StoppedOnPurpose)
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url))
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: Self.schema)
        == ["0005_cards"])
  }

  /// The SQL of the update fails at its very end, after every table, trigger and column it adds
  /// was made: none of them is left.
  @Test func aStatementThatFailsAtTheEndOfTheSQLLeavesNothing() throws {
    let book = try OnePointOneBook(named: "broken-tail")
    defer { book.remove() }
    let before = try book.keep(as: "before.sqlite")
    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: {
        try DatabaseStack(
          url: book.url, schema: FailingAtTheEnd(migration: "0005_cards"), context: Self.context)
      })
    #expect(failure.migration == "0005_cards")
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url))
    let objects = try book.read { db in
      try String.fetchSet(db, sql: "SELECT name FROM sqlite_master")
    }
    #expect(objects.isDisjoint(with: ["cards", "cashback_rules", "idx_cards_account"]))
    #expect(!objects.contains { $0.hasPrefix("card_of_account_") })
  }

  @Test func theAttemptAfterAStopGivesWhatAnUntouchedUpdateGives() throws {
    let book = try OnePointOneBook(named: "retry")
    defer { book.remove() }
    let twin = try book.keep(as: "twin.sqlite")
    var stopping = Self.context
    stopping.failAfterSQL = true
    #expect(throws: DatabaseStack.MigrationFailure.self) {
      try DatabaseStack(url: book.url, schema: Self.schema, context: stopping)
    }

    let retried = try DatabaseStack(
      url: book.url, schema: Self.schema, context: Self.context)
    let direct = try DatabaseStack(
      url: twin, schema: Self.schema, context: Self.context)
    #expect(retried.applied.dataSteps == direct.applied.dataSteps)
    #expect(retried.applied.dataSteps["goalPlansStarted"] == book.cardsStep["goalPlansStarted"])
    let left = try retried.writer.read { db in try ExactTables.read(db) }
    let right = try direct.writer.read { db in try ExactTables.read(db) }
    try retried.close()
    try direct.close()
    #expect(left == right)
    #expect(try DatabaseStack.sameData(fileAt: book.url, as: twin))
  }

  // MARK: 7–8. A file of 1.0.0

  /// A file of 1.0.0 goes through both steps in one open: the accounts get their main account
  /// as before, the card accounts their cards, and no count gets a mode — 1.0.0 counted one
  /// total.
  @Test func aOnePointZeroFileGoesThroughBothSteps() throws {
    let book = try LegacyBook(named: "both-steps")
    defer { book.remove() }
    let accounts = try book.read { db in
      try Row.fetchAll(
        db, sql: "SELECT id, name, kind, archived FROM payment_methods ORDER BY rowid")
    }
    let plan = CardsMigration.plan(
      accounts: accounts.map { row in
        let text: String = row["id"]
        let kind: String = row["kind"]
        let archived: Int = row["archived"]
        return MigratingCardAccount(
          id: UUID(uuidString: text)!, name: row["name"], kind: PaymentMethodKind(rawValue: kind),
          archived: archived != 0)
      })

    let stack = try DatabaseStack(
      url: book.url, schema: Self.schema, context: Self.context)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().count == 5)
    #expect(stack.applied.applied == 2)
    #expect(
      TestSupport.accountsStep(stack.applied.dataSteps)
        == [
          "mainKept": 1, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 2,
          "assigned": book.unassignedCount,
        ])
    #expect(TestSupport.cardsStep(stack.applied.dataSteps) == book.cardsStep)
    #expect(stack.applied.dataSteps["cardsCreated"] == plan.cards.count)
    #expect(plan.cards.count > 0)
    #expect(stack.applied.dataSteps["countsRecorded"] == 0)
    #expect(stack.applied.dataSteps["countsKept"] == 0)
    let cards = try stack.writer.read { db in try PaymentCard.fetchAll(db) }
    #expect(Set(cards.map(\.id)) == Set(plan.cards.map(\.id)))
    #expect(cards.count == plan.cards.count)
    try stack.writer.read { (db: Database) throws in
      #expect(
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM reconciliation_balances WHERE records_difference IS NOT NULL")
          == 0)
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  /// The step of the cards stops after the step of the accounts landed: the file keeps the
  /// update to 1.1 whole — exactly what 1.1 makes of it — and the next attempt gives what an
  /// untouched update gives.
  @Test func aStopInTheSecondStepKeepsTheFirst() throws {
    let book = try LegacyBook(named: "second-step")
    defer { book.remove() }
    let folder = book.url.deletingLastPathComponent()
    let firstOnly = folder.appendingPathComponent("first-only.sqlite")
    let untouched = folder.appendingPathComponent("untouched.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: firstOnly)
    try DatabaseStack.backup(fileAt: book.url, to: untouched)
    let made = UUID()
    let context = MigrationContext(
      mainAccountName: "Основной счёт", makeId: { made }, updateMonth: "2026-09")
    var stopping = context
    stopping.failAfterSQLOf = "0005_cards"

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: {
        try DatabaseStack(url: book.url, schema: Self.schema, context: stopping)
      })
    #expect(failure.migration == "0005_cards")
    #expect(failure.from == 3)
    #expect(failure.to == 5)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: Self.schema)
        == ["0005_cards"])
    try DatabaseStack(
      url: firstOnly, schema: FilteredSchemaSource(upTo: "0004_accounts"), context: context
    ).close()
    #expect(try DatabaseStack.sameData(fileAt: book.url, as: firstOnly))

    let retried = try DatabaseStack(
      url: book.url, schema: Self.schema, context: context)
    let direct = try DatabaseStack(
      url: untouched, schema: Self.schema, context: context)
    #expect(
      TestSupport.cardsStep(retried.applied.dataSteps)
        == TestSupport.cardsStep(direct.applied.dataSteps))
    #expect(TestSupport.accountsStep(retried.applied.dataSteps) == [:])
    let left = try retried.writer.read { db in try ExactTables.read(db) }
    let right = try direct.writer.read { db in try ExactTables.read(db) }
    try retried.close()
    try direct.close()
    #expect(left == right)
  }

  // MARK: 9. An archive of 1.1

  /// The archive of a 1.1 book — its database and the 21 files of that export — opens where
  /// schema 5 is supported, and its database is updated exactly as the file itself is.
  @Test func anArchiveOfSchemaFourIsUpdatedLikeAFile() throws {
    let book = try OnePointOneBook(named: "archive")
    defer { book.remove() }
    let folder = book.url.deletingLastPathComponent()
    let snapshot = try book.keep(as: "snapshot.sqlite")
    let database = try Data(contentsOf: snapshot)
    let files = Array(ExportTables.all.prefix(21))
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.1.2", schemaVersion: 4, createdAt: DateOnly(year: 2026, month: 9, day: 26),
        platform: "macOS",
        rowCounts: try book.read { db in
          var counts: [String: Int] = [:]
          for table in files {
            let name = String(table.fileName.dropLast(4))
            counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)") ?? 0
          }
          return counts
        }))
    try builder.add(path: ArchivePaths.database, data: database)
    try book.read { db in
      for table in files {
        let name = String(table.fileName.dropLast(4))
        let known = Set(try db.columns(in: name).map(\.name))
        let columns = table.columns.compactMap { column in
          known.contains(column) ? column : known.contains(column + "_e4") ? column + "_e4" : nil
        }
        var csv = CSVWriter(columns: columns)
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \(name)") {
          csv.append(
            columns.map { column in
              let raw: DatabaseValue = row[column]
              return raw.isNull ? "" : (String.fromDatabaseValue(raw) ?? "\(raw)")
            })
        }
        try builder.add(path: ArchivePaths.csv(table: name), data: csv.data())
      }
    }
    try builder.add(path: ArchivePaths.settings, text: #"{"language":"ru"}"#)
    let container = try builder.build()

    #expect(throws: CoreError.self) { try ArchiveOpener.open(container, supportedSchemaVersion: 3) }
    let opened = try ArchiveOpener.open(container, supportedSchemaVersion: 5)
    #expect(opened.manifest.schemaVersion == 4)
    #expect(opened.csvTables.count == 21)

    let staged = folder.appendingPathComponent("imported.sqlite")
    try (opened.database ?? Data()).write(to: staged)
    #expect(try DatabaseStack.check(fileAt: staged, schema: Self.schema) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: staged, schema: Self.schema)
        == ["0005_cards"])
    let imported = try DatabaseStack(
      url: staged, schema: Self.schema, context: Self.context)
    let file = try DatabaseStack(
      url: book.url, schema: Self.schema, context: Self.context)
    #expect(imported.applied.dataSteps == file.applied.dataSteps)
    #expect(TestSupport.cardsStep(imported.applied.dataSteps) == book.cardsStep)
    let left = try imported.writer.read { db in try ExactTables.read(db) }
    let right = try file.writer.read { db in try ExactTables.read(db) }
    try imported.close()
    try file.close()
    #expect(left == right)
  }

  // MARK: 10. One id in two cases

  /// A key is compared as the text it is stored as, so a hand edit that left one UUID in two
  /// cases made two rows: two accounts, two counts, two sheets. The update keeps them apart:
  /// the card goes to the card account, not to the other row of its UUID, and every compared
  /// count gets the mode of its own operation and of its own sheet — none is left without one.
  @Test func oneIdInTwoCasesKeepsItsRowsApart() throws {
    let url = OnePointOneBook.freshURL(named: "two-cases")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let account = UUID()
    let cash = account.uuidString.lowercased()
    let visa = account.uuidString
    let sheetId = UUID()
    let sheet = sheetId.uuidString
    let otherSheet = sheetId.uuidString.lowercased()
    let countId = UUID()
    // On the sheet: a count whose difference is alive, and one of the same UUID whose
    // difference is in the bin. On the other sheet of the same UUID: a count alone, no
    // operation, not at zero.
    let recording = countId.uuidString.lowercased()
    let keeping = countId.uuidString
    let alone = UUID().uuidString
    let live = UUID().uuidString
    let binned = UUID().uuidString

    let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0004_accounts"))
    try old.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
          VALUES (?, 'Cash', 'cash', 'RUB', '', 1, 0), (?, 'Visa', 'card', 'RUB', '', 0, 0);
          INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
            payment_method_id, created_at, updated_at, deleted_at)
          VALUES (?, 'expense', '2026-08-10 18:00:00.000', 'RUB', 5000000, 5000000, ?,
                  '2026-08-10 18:00:00.000', '2026-08-10 18:00:00.000', NULL),
                 (?, 'income', '2026-08-10 18:00:00.000', 'RUB', 3000000, 3000000, ?,
                  '2026-08-10 18:00:00.000', '2026-08-10 18:00:00.000',
                  '2026-08-10 18:10:00.000');
          INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind)
          VALUES (?, '2026-08-10', 0, '2026-08-10 18:00:00.000', 'accounts'),
                 (?, '2026-08-11', 0, '2026-08-11 18:00:00.000', 'accounts');
          INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id,
            currency, actual_e4, expected_e4, difference_e4, transaction_id)
          VALUES (?, ?, ?, 'RUB', 5000000, 10000000, -5000000, ?),
                 (?, ?, ?, 'RUB', 13000000, 10000000, 3000000, ?),
                 (?, ?, ?, 'RUB', 3000000, 5000000, -2000000, NULL);
          """,
        arguments: [
          cash, visa, live, visa, binned, cash, sheet, otherSheet,
          recording, sheet, visa, live, keeping, sheet, cash, binned, alone, otherSheet, visa,
        ])
    }
    try old.close()

    let stack = try DatabaseStack(url: url, schema: Self.schema, context: Self.context)
    defer { try? stack.close() }
    #expect(
      TestSupport.cardsStep(stack.applied.dataSteps)
        == TestSupport.cardsStep(cardsCreated: 1, countsRecorded: 1, countsKept: 2))
    try stack.writer.read { db in
      let cards = try Row.fetchAll(db, sql: "SELECT id, payment_method_id, name FROM cards")
      #expect(cards.count == 1)
      let card = try #require(cards.first)
      #expect(card["id"] == CardsMigration.cardId(forAccount: account).uuidString)
      #expect(card["payment_method_id"] == visa, "the card went to the cash account")
      #expect(card["name"] == "Visa")

      let modes = Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(
          db, sql: "SELECT id, records_difference FROM reconciliation_balances"
        ).map { row -> (String, Int?) in (row["id"], row["records_difference"]) })
      #expect(modes[recording] == .some(1), "the count with its operation alive")
      #expect(modes[keeping] == .some(0), "the count with its operation in the bin")
      #expect(modes[alone] == .some(0), "the count alone on the other sheet")
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  // MARK: Helpers

  private static func balances(_ dataset: Dataset, now: Date) -> AccountBalances {
    AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: now, calendar: TestSupport.sampleCalendar)
  }

  /// The money of the database, summed per currency, as the dry run of the update sums it:
  /// operations, their parts, the money back linked to them, the lines of the debt journals,
  /// the transfers and the counts.
  private static func sums(_ db: Database) throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    func add(_ label: String, _ sql: String) throws {
      for row in try Row.fetchAll(db, sql: sql) {
        let key: String? = row[0]
        result["\(label) \(key ?? "-")"] = row[1]
      }
    }
    try add("transactions", "SELECT currency, SUM(amount_e4) FROM transactions GROUP BY 1")
    try add("transactions rub", "SELECT 'RUB', SUM(amount_rub_e4) FROM transactions")
    try add("parts rub", "SELECT 'RUB', SUM(amount_rub_e4) FROM transaction_parts")
    try add("links", "SELECT 'RUB', SUM(amount_e4) FROM reimbursement_links")
    try add("debt entries", "SELECT 'all', SUM(amount_e4) FROM debt_entries")
    try add("sent", "SELECT from_currency, SUM(from_amount_e4) FROM transfers GROUP BY 1")
    try add("received", "SELECT to_currency, SUM(to_amount_e4) FROM transfers GROUP BY 1")
    try add("counted", "SELECT currency, SUM(actual_e4) FROM reconciliation_balances GROUP BY 1")
    try add(
      "differences", "SELECT currency, SUM(difference_e4) FROM reconciliation_balances GROUP BY 1")
    return result
  }

  /// Every month's spending and income, and each month's money per category and kind.
  private static func monthTotals(_ ledger: Ledger) -> [String: AmountE4] {
    var totals: [String: AmountE4] = [:]
    let calendar = TestSupport.sampleCalendar
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

/// The schema of this tree with a statement that fails appended to one migration: the SQL of
/// that migration stops at its very end, after everything it makes was made.
private struct FailingAtTheEnd: SchemaSource {
  let migration: String

  func migrations() throws -> [SchemaMigration] {
    try FilteredSchemaSource(upTo: "0005_cards").migrations().map { current in
      guard current.name == migration else { return current }
      return SchemaMigration(
        name: current.name,
        sql: current.sql
          + "\nINSERT INTO cards (id, payment_method_id, name) VALUES (NULL, NULL, NULL);\n")
    }
  }
}
