import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to schema 14 (`0014_import_year_questions_subscriptions`) only adds: a database of
/// the spending-rules release keeps every value, the new columns start empty, the new tables start
/// empty, and the import books, the plan of the year, the saved views and the subscription extras
/// go through the repositories, the export, the archive and the exchange between devices.
@Suite("The import, year and subscription tables come in without touching a value")
struct Migration0014Tests {
  private static let older = FilteredSchemaSource(upTo: "0013_spending_rules")
  static let moment = Date(timeIntervalSince1970: 1_790_000_000)
  static let operationId = "55555555-5555-4555-8555-555555555555"
  static let newTables = [
    "statement_profiles", "identity_items", "saved_views", "budget_month_exceptions",
    "event_budget_items", "event_templates", "subscription_terms", "subscription_usage",
    "subscription_users", "subscription_keep_groups",
  ]

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0014-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  // MARK: - The update

  @Test func aNewDatabaseHasTheColumnsEmptyAndTheTablesEmpty() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0017_attachments")
    #expect(stack.applied.onDisk == 17)
    try stack.writer.read { (db: Database) throws in
      for table in Self.newTables {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
      let operation = try db.columns(in: "transactions").map(\.name)
      for column in ["source", "bank_status", "posted_on", "dedup_key"] {
        #expect(operation.contains(column), "transactions.\(column)")
      }
      #expect(try db.columns(in: "transfers").map(\.name).contains("arrived_at"))
      let batch = try db.columns(in: "import_batches").map(\.name)
      for column in [
        "payment_method_id", "profile_id", "period_from", "period_to", "rows_declined",
        "rows_unparsed", "file_hash", "undone_at",
      ] {
        #expect(batch.contains(column), "import_batches.\(column)")
      }
    }
  }

  @Test func aDatabaseOfTheSpendingRulesReleaseKeepsEveryValueAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let account = UUID()
    let other = UUID()
    let operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Self.moment, amountE4: AmountE4(whole: 500),
      note: "кофе, \"латте\"", paymentMethodId: account)
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        for id in [account, other] {
          try db.execute(
            sql: "INSERT INTO payment_methods (id, name) VALUES (?, ?)",
            arguments: [id.uuidString, id.uuidString])
        }
        try LegacyWriter.insert(operation, db: db)
        try db.execute(
          sql: """
            INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
              from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at)
            VALUES (?, '2026-10-01 10:00:00.000', ?, 'RUB', 100000, ?, 'RUB', 100000,
              '2026-10-01 10:00:00.000', '2026-10-01 10:00:00.000')
            """,
          arguments: [UUID().uuidString, account.uuidString, other.uuidString])
        try db.execute(
          sql: """
            INSERT INTO import_batches (id, source_file_name, imported_at, rows_total, rows_imported,
              rows_skipped) VALUES (?, 'старый.csv', '2026-09-01 10:00:00.000', 10, 8, 2)
            """,
          arguments: [UUID().uuidString])
        try db.execute(
          sql: "INSERT INTO settings (key, value) VALUES ('planning.monthBuffer', '50000000')")
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0014_import_year_questions_subscriptions", "0015_bank_conditions", "0016_rate_source",
          "0017_attachments",
        ])

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 4)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      let row = try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [operation.id.uuidString]))
      for column in ["source", "bank_status", "posted_on", "dedup_key"] {
        let value: DatabaseValue = row[column]
        #expect(value.isNull, Comment(rawValue: column))
      }
      #expect(try String.fetchOne(db, sql: "SELECT arrived_at FROM transfers") == nil)
      #expect(try Int.fetchOne(db, sql: "SELECT rows_declined FROM import_batches") == 0)
      #expect(try String.fetchOne(db, sql: "SELECT profile_id FROM import_batches") == nil)
      for table in Self.newTables {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource).isEmpty)
    // An old import row reads in the list of imports with empty ids and no period.
    let imports = try StatementImportRepository(writer: stack.writer).imports()
    #expect(imports.count == 1)
    #expect(imports.first?.record.fileName == "старый.csv")
    #expect(imports.first?.record.accountID == "")
    #expect(imports.first?.record.periodFrom == nil)
    #expect(imports.first?.isUndone == false)
  }

  // MARK: - The new columns through the records

  @Test func theNewColumnsAreWrittenAndReadBack() throws {
    let stack = try TestSupport.makeStack()
    var operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Self.moment, amountE4: AmountE4(whole: 90), source: "statement",
      bankStatus: "pending", postedOn: DateOnly(year: 2026, month: 10, day: 3),
      dedupKey: "v1:00ff")
    let account = PaymentMethod(name: "Счёт")
    let other = PaymentMethod(name: "Другой")
    let arrived = Date(timeIntervalSince1970: 1_790_200_000)
    var transfer = Transfer(
      occurredAt: Self.moment, fromAccountId: account.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 10), toAccountId: other.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 10), arrivedAt: arrived)
    try stack.writer.write { db in
      try account.insert(db)
      try other.insert(db)
      try operation.insert(db)
      try transfer.insert(db)
    }
    try stack.writer.read { (db: Database) throws in
      let read = try #require(try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString))
      #expect(read.source == "statement")
      #expect(read.bankStatus == "pending")
      #expect(read.postedOn == DateOnly(year: 2026, month: 10, day: 3))
      #expect(read.dedupKey == "v1:00ff")
      let moved = try #require(try Transfer.fetchOne(db, key: transfer.id.uuidString))
      #expect(abs((moved.arrivedAt ?? .distantPast).timeIntervalSince(arrived)) < 0.01)
    }
    operation.source = nil
    operation.dedupKey = nil
    transfer.arrivedAt = nil
    try stack.writer.write { db in
      try operation.update(db)
      try transfer.update(db)
    }
    try stack.writer.read { (db: Database) throws in
      let read = try #require(try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString))
      #expect(read.source == nil && read.dedupKey == nil)
      #expect(try Transfer.fetchOne(db, key: transfer.id.uuidString)?.arrivedAt == nil)
    }
  }

  @Test func aPanelEditKeepsWhereAStatementLineCameFrom() throws {
    var entry = try TestSupport.makeEntry()
    entry.transaction.source = "statement"
    entry.transaction.bankStatus = "posted"
    entry.transaction.postedOn = DateOnly(year: 2026, month: 10, day: 4)
    entry.transaction.dedupKey = "v1:abcd"
    var edited = try TestSupport.makeEntry()
    edited.transaction.id = entry.transaction.id
    let rebased = edited.rebased(onto: entry)
    #expect(rebased.transaction.source == "statement")
    #expect(rebased.transaction.bankStatus == "posted")
    #expect(rebased.transaction.postedOn == DateOnly(year: 2026, month: 10, day: 4))
    #expect(rebased.transaction.dedupKey == "v1:abcd")
  }

  // MARK: - The import books

  @Test func anImportIsRecordedListedFoundByItsFileAndUndone() throws {
    let stack = try TestSupport.makeStack()
    let repository = StatementImportRepository(writer: stack.writer)
    let account = PaymentMethod(name: "Райф")
    try stack.writer.write { db in try account.insert(db) }
    let id = UUID().uuidString
    let record = StatementImportRecord(
      id: id, accountID: account.id.uuidString, profileID: "raiffeisen-csv-v1",
      fileName: "выписка, \"сентябрь\".csv", importedAt: Self.moment,
      periodFrom: DateOnly(year: 2026, month: 9, day: 1),
      periodTo: DateOnly(year: 2026, month: 9, day: 30), rowCount: 40, newCount: 30,
      duplicateCount: 8, declinedCount: 1, unparsedCount: 1)
    try repository.record(record, fileHash: "abc123")
    let listed = try repository.imports()
    #expect(listed.count == 1)
    #expect(listed[0].record.id == id)
    #expect(listed[0].record.accountID == account.id.uuidString)
    #expect(listed[0].record.profileID == "raiffeisen-csv-v1")
    #expect(listed[0].record.fileName == "выписка, \"сентябрь\".csv")
    #expect(listed[0].record.periodFrom == record.periodFrom)
    #expect(listed[0].record.periodTo == record.periodTo)
    #expect(listed[0].record.newCount == 30 && listed[0].record.duplicateCount == 8)
    #expect(listed[0].record.declinedCount == 1 && listed[0].record.unparsedCount == 1)
    #expect(listed[0].fileHash == "abc123")
    #expect(try repository.liveImport(withHash: "abc123")?.id == id)
    #expect(try repository.liveImport(withHash: "other") == nil)

    try repository.markUndone(id: id, at: Self.moment)
    #expect(try repository.imports().first?.isUndone == true)
    #expect(try repository.liveImport(withHash: "abc123") == nil)
    try repository.clearUndone(id: id)
    #expect(try repository.imports().first?.isUndone == false)

    // Writing the same import again replaces its row.
    var again = record
    again.newCount = 31
    try repository.record(again, fileHash: "abc123")
    #expect(try repository.imports().count == 1)
    #expect(try repository.imports().first?.record.newCount == 31)

    // The account going away empties the link; the import stays.
    try stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM payment_methods WHERE id = ?", arguments: [account.id.uuidString])
    }
    #expect(try repository.imports().first?.record.accountID == "")
  }

  @Test func anImportIdThatIsNoUUIDIsRefused() throws {
    let stack = try TestSupport.makeStack()
    let repository = StatementImportRepository(writer: stack.writer)
    let record = StatementImportRecord(
      id: "not-an-id", accountID: "", profileID: "x", fileName: "f.csv", importedAt: Self.moment,
      periodFrom: nil, periodTo: nil, rowCount: 0, newCount: 0, duplicateCount: 0,
      declinedCount: 0, unparsedCount: 0)
    #expect(throws: UnreadableValue.self) { try repository.record(record) }
  }

  @Test func whatAnAccountHoldsFindsTheLinesOfTheBankAndHeldOnesAreUpgraded() throws {
    let stack = try TestSupport.makeStack()
    let repository = StatementImportRepository(writer: stack.writer)
    let account = PaymentMethod(name: "Райф")
    let place = Place(name: "Пятёрочка")
    let batch = UUID()
    let line = CoreKit.Transaction(
      kind: .expense, occurredAt: Self.moment, amountE4: AmountE4(whole: 250), note: "PYATEROCHKA",
      placeId: place.id, paymentMethodId: account.id, importBatchId: batch, source: "statement",
      bankStatus: "pending", dedupKey: "v1:1111")
    let typed = CoreKit.Transaction(
      kind: .expense, occurredAt: Self.moment, amountE4: AmountE4(whole: 90),
      paymentMethodId: account.id)
    let income = CoreKit.Transaction(
      kind: .income, occurredAt: Self.moment, amountE4: AmountE4(whole: 1000),
      paymentMethodId: account.id, source: "statement", dedupKey: "v1:2222")
    let deleted = CoreKit.Transaction(
      kind: .expense, occurredAt: Self.moment, amountE4: AmountE4(whole: 5),
      paymentMethodId: account.id, deletedAt: Self.moment, source: "statement",
      dedupKey: "v1:3333")
    try stack.writer.write { db in
      try account.insert(db)
      try place.insert(db)
      try db.execute(
        sql:
          "INSERT INTO import_batches (id, source_file_name, imported_at) VALUES (?, 'f', '2026-10-01 10:00:00.000')",
        arguments: [batch.uuidString])
      for operation in [line, typed, income, deleted] { try operation.insert(db) }
    }
    let existing = try repository.existing(account: account.id)
    #expect(Set(existing.map(\.key.value)) == ["v1:1111", "v1:2222"])
    let held = try #require(existing.first { $0.key.value == "v1:1111" })
    #expect(held.id == line.id.uuidString)
    #expect(held.status == .pending)
    #expect(held.amount == AmountE4(whole: -250))
    #expect(held.placeKey == "пятерочка")
    #expect(existing.first { $0.key.value == "v1:2222" }?.amount == AmountE4(whole: 1000))
    #expect(existing.first { $0.key.value == "v1:2222" }?.status == .posted)

    let manual = try repository.manualEntries(
      account: account.id, from: DateOnly(year: 2000, month: 1, day: 1),
      to: DateOnly(year: 2100, month: 1, day: 1))
    #expect(manual.map(\.id) == [typed.id.uuidString])
    #expect(manual.first?.amount == AmountE4(whole: -90))

    let rows = try repository.operations(ofImport: batch.uuidString)
    #expect(rows.map(\.operationId) == [line.id])
    #expect(rows.first?.touched == false)

    // The bank posted the held line.
    let day = DateOnly(year: 2026, month: 10, day: 5)
    let undo = try repository.apply([
      StatementStatusWrite(operationId: line.id, status: .posted, postedOn: day)
    ])
    let upgraded = try #require(
      try repository.existing(account: account.id).first { $0.id == line.id.uuidString })
    #expect(upgraded.status == .posted)
    #expect(undo.first?.status == .pending && undo.first?.postedOn == nil)
    // Its row was edited, so undoing the import would ask about it.
    #expect(try repository.operations(ofImport: batch.uuidString).first?.touched == true)
    _ = try repository.apply(undo)
    #expect(
      try repository.existing(account: account.id).first { $0.id == line.id.uuidString }?.status
        == .pending)
  }

  @Test func theDeduplicatorWorksOnWhatTheDatabaseGivesBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = StatementImportRepository(writer: stack.writer)
    let account = PaymentMethod(name: "Райф")
    let incoming = ImportedOperation(
      profileID: "p", sourceIndex: 0,
      moment: StatementMoment(day: DateOnly(year: 2026, month: 10, day: 1), minuteOfDay: 600),
      amount: AmountE4(whole: -300), description: "Кофе")
    let key = StatementDedupKey(account: "1234", operation: incoming)
    let stored = CoreKit.Transaction(
      kind: .expense, occurredAt: Self.moment, amountE4: AmountE4(whole: 300),
      paymentMethodId: account.id, source: "statement", dedupKey: key.value)
    try stack.writer.write { db in
      try account.insert(db)
      try stored.insert(db)
    }
    let diff = StatementDeduplicator.diff(
      incoming: [incoming, incoming], account: "1234",
      existing: try repository.existing(account: account.id))
    // One of the two identical lines is already there, the other is new.
    #expect(diff.duplicateIndices.count == 1 && diff.newIndices.count == 1)
  }

  @Test func whoTheOwnerIsIsKeptReplacedAndNeverExportedOrSent() throws {
    let device = try TestDevice("mac")
    let repository = StatementImportRepository(writer: device.stack.writer)
    let identity = StatementIdentity(
      phones: ["+7 900 000-00-01", " +7 900 000-00-01 "], names: ["Иван Петрович С"],
      contractNumbers: ["5012345"], cardMasks: ["*3230"])
    try repository.save(identity)
    let read = try repository.identity()
    #expect(read.phones == ["+7 900 000-00-01"])
    #expect(read.names == ["Иван Петрович С"])
    #expect(read.contractNumbers == ["5012345"] && read.cardMasks == ["*3230"])
    // Rows already there keep their row.
    let ids = try device.stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM identity_items ORDER BY id")
    }
    let before = try repository.save(
      StatementIdentity(phones: ["+7 900 000-00-01"], names: [], contractNumbers: [], cardMasks: [])
    )
    #expect(before.names == ["Иван Петрович С"])
    #expect(try repository.identity().names.isEmpty)
    let left = try device.stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM identity_items")
    }
    #expect(left.count == 1 && ids.contains(left[0]))
    // Not in the export, not in the exchange.
    #expect(!ExportTables.all.map(\.fileName).contains("identity_items.csv"))
    #expect(SyncTables.followed["identity_items"] == nil)
    #expect(try device.outboxCount() == 0)
    // And it prints redacted.
    #expect(!"\(read)".contains("900"))
  }

  @Test func theOwnersProfilesAreSavedReadAndDeleted() throws {
    let stack = try TestSupport.makeStack()
    let repository = StatementImportRepository(writer: stack.writer)
    let profile = StatementProfile(
      id: "my-tracker-csv-v1", bankName: "Мой трекер", fileNamesTheBank: false,
      layout: .delimited(
        StatementDelimitedLayout(
          delimiter: ";", requiredHeaders: ["Дата", "Сумма"],
          columns: [.moment: "Дата", .amount: "Сумма"], amountStyle: .signed,
          descriptionFields: [.title])),
      descriptionRules: [])
    try repository.save(profile)
    #expect(try repository.profiles() == [profile])
    var renamed = profile
    renamed.bankName = "Трекер"
    try repository.save(renamed)
    #expect(try repository.profiles() == [renamed])
    try repository.deleteProfile(id: profile.id)
    #expect(try repository.profiles().isEmpty)
  }

  // MARK: - The plan of the year

  private func insertBudget(_ db: Database) throws -> UUID {
    let id = UUID()
    try db.execute(
      sql: "INSERT INTO budgets (id, scope, amount_e4) VALUES (?, 'bad_total', 50000000)",
      arguments: [id.uuidString])
    return id
  }

  private func insertEvent(_ db: Database) throws -> UUID {
    let id = UUID()
    try db.execute(
      sql:
        "INSERT INTO events (id, name, start_date, end_date) VALUES (?, 'Переезд', '2026-11-01', '2026-11-03')",
      arguments: [id.uuidString])
    return id
  }

  @Test func aMonthLimitIsSetReplacedRemovedAndRestored() throws {
    let stack = try TestSupport.makeStack()
    let repository = YearPlanRepository(writer: stack.writer)
    let budget = try stack.writer.write { db in try insertBudget(db) }
    let december = MonthKey(year: 2026, month: 12)
    #expect(
      try repository.setLimit(AmountE4(whole: 20_000), budget: budget, month: december).isEmpty)
    let first = try repository.data().monthExceptions
    #expect(first.count == 1 && first[0].amountE4 == AmountE4(whole: 20_000))
    let replaced = try repository.setLimit(AmountE4(whole: 25_000), budget: budget, month: december)
    #expect(replaced == first)
    #expect(try repository.data().monthExceptions.map(\.amountE4) == [AmountE4(whole: 25_000)])
    let removed = try repository.removeLimit(budget: budget, month: december)
    #expect(removed.count == 1)
    #expect(try repository.data().monthExceptions.isEmpty)
    try repository.restoreLimits(budget: budget, month: december, to: replaced)
    #expect(try repository.data().monthExceptions == first)
    // The limit going away takes its exceptions with it.
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM budgets WHERE id = ?", arguments: [budget.uuidString])
    }
    #expect(try repository.data().monthExceptions.isEmpty)
  }

  @Test func theArticlesOfAnEventAreSetInOneStepAndComeBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = YearPlanRepository(writer: stack.writer)
    let event = try stack.writer.write { db in try insertEvent(db) }
    let movers = EventBudgetItem(
      eventId: event, title: "Грузчики", plannedE4: AmountE4(whole: 10_000), sort: 0)
    let boxes = EventBudgetItem(
      eventId: event, title: "Коробки", plannedE4: AmountE4(whole: 2_000), sort: 1)
    #expect(try repository.setItems([movers, boxes], ofEvent: event).isEmpty)
    #expect(try repository.items(ofEvent: event) == [movers, boxes])
    #expect(try repository.data().items(of: event) == [movers, boxes])
    var smaller = movers
    smaller.plannedE4 = AmountE4(whole: 9_000)
    let before = try repository.setItems([smaller], ofEvent: event)
    #expect(before == [movers, boxes])
    #expect(try repository.items(ofEvent: event) == [smaller])
    _ = try repository.setItems(before, ofEvent: event)
    #expect(try repository.items(ofEvent: event) == [movers, boxes])
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM events WHERE id = ?", arguments: [event.uuidString])
    }
    #expect(try repository.data().eventItems.isEmpty)
  }

  @Test func theOwnersTemplatesAreSavedReplacedDeletedAndTheReadyOnesRefused() throws {
    let stack = try TestSupport.makeStack()
    let repository = YearPlanRepository(writer: stack.writer)
    let template = EventTemplate(
      id: UUID().uuidString, name: "Свадьба, \"малая\"", isBuiltIn: false, eventKind: .holiday,
      totalE4: AmountE4(whole: 300_000),
      lines: [
        EventTemplateLine(title: "Зал", shareBp: 6_000),
        EventTemplateLine(title: "Кольца", shareBp: 4_000),
      ])
    #expect(try repository.save(template) == nil)
    #expect(try repository.templates() == [template])
    var changed = template
    changed.name = "Свадьба"
    #expect(try repository.save(changed) == template)
    #expect(try repository.templates() == [changed])
    let builtIn = try #require(EventTemplates.builtIn(id: "builtin.moving"))
    _ = try repository.save(builtIn)
    #expect(try repository.templates().count == 1, "a ready template is never stored")
    #expect(try repository.deleteTemplate(id: template.id) == changed)
    #expect(try repository.templates().isEmpty)
    // A template a newer build wrote with lines this one can not read is left out, not lost.
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO event_templates (id, name, lines, created_at, updated_at)
          VALUES ('x', 'Будущий', 'not json', '2026-10-01 10:00:00.000', '2026-10-01 10:00:00.000')
          """)
    }
    #expect(try repository.templates().isEmpty)
    #expect(try ExportRepository(writer: stack.writer).rowCounts()["event_templates"] == 1)
  }

  @Test func theBufferAndItsMarksLiveInTheSettings() throws {
    let stack = try TestSupport.makeStack()
    let repository = YearPlanRepository(writer: stack.writer)
    let buffer = MonthBufferSettings(
      amount: AmountE4(whole: 5_000), incomeAtSet: AmountE4(whole: 100_000))
    #expect(try repository.save(buffer: buffer) == MonthBufferSettings())
    let marks: Set<UUID> = [UUID(), UUID()]
    #expect(try repository.save(bufferMarks: marks).isEmpty)
    let data = try repository.data()
    #expect(data.buffer == buffer)
    #expect(data.bufferMarks == marks)
    // Off: the keys go.
    #expect(try repository.save(buffer: MonthBufferSettings()) == buffer)
    #expect(try repository.save(bufferMarks: []) == marks)
    let left = try stack.writer.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM settings WHERE key LIKE 'planning.monthBuffer%'")
    }
    #expect(left == 0)
  }

  // MARK: - Subscriptions

  private func insertPayment(_ db: Database) throws -> UUID {
    let id = UUID()
    try db.execute(
      sql:
        "INSERT INTO scheduled_payments (id, name, kind, amount_e4) VALUES (?, 'Музыка', 'subscription', 3990000)",
      arguments: [id.uuidString])
    return id
  }

  @Test func theTermsOfASubscriptionAreSavedAndNeutralTermsLeaveNoRow() throws {
    let stack = try TestSupport.makeStack()
    let repository = SubscriptionRepository(writer: stack.writer)
    let payment = try stack.writer.write { db in try insertPayment(db) }
    let terms = SubscriptionTerms(
      paymentId: payment, yearlyPlanE4: AmountE4(whole: 3_000), monthlyPlanE4: AmountE4(whole: 399),
      floating: true, tolerancePercent: 15, serviceType: .music, needed: true,
      yearlyReminderOff: true, ownerUses: false)
    let saved = try repository.save(terms)
    #expect(saved.termsBefore == nil)
    #expect(try repository.book().terms == [terms])
    #expect(try repository.book().terms(of: payment) == terms)
    let back = try repository.save(SubscriptionTerms(paymentId: payment))
    #expect(back.termsBefore == terms)
    #expect(try repository.book().terms.isEmpty)
    let count = try stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM subscription_terms")
    }
    #expect(count == 0)
  }

  @Test func daysOfUsePeopleAndKeptGroupsAreWrittenOnceAndComeBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = SubscriptionRepository(writer: stack.writer)
    let first = try stack.writer.write { db in try insertPayment(db) }
    let second = try stack.writer.write { db in try insertPayment(db) }
    let people = [Person(name: "Анна"), Person(name: "Борис")]
    try stack.writer.write { db in for person in people { try person.insert(db) } }

    let day = DateOnly(year: 2026, month: 10, day: 10)
    let mark = try #require(try repository.markUsed(payment: first, on: day))
    #expect(try repository.markUsed(payment: first, on: day) == nil, "a day is marked once")
    #expect(try repository.book().usage == [mark])
    #expect(try repository.removeUsage(ids: [mark.id]) == [mark])
    #expect(try repository.book().usage.isEmpty)
    try repository.restore(usage: [mark])
    #expect(try repository.book().usage == [mark])

    #expect(
      try repository.setUsers(payment: first, people: people.map(\.id) + [people[0].id]).isEmpty)
    #expect(try repository.book().people(of: first) == people.map(\.id))
    let before = try repository.setUsers(payment: first, people: [people[1].id])
    #expect(before.count == 2)
    #expect(try repository.book().people(of: first) == [people[1].id])
    try repository.restore(users: before, payment: first)
    #expect(try repository.book().people(of: first) == people.map(\.id))

    let group = KeepGroup(type: .music, paymentIds: [first, second])
    let kept = try repository.keep(group)
    #expect(kept == group)
    let again = try repository.keep(KeepGroup(type: .music, paymentIds: [second, first]))
    #expect(again.id == group.id, "the same group is no second row")
    #expect(try repository.book().keepGroups == [group])
    #expect(try repository.removeKeepGroup(id: group.id) == group)
    #expect(try repository.book().keepGroups.isEmpty)
    try repository.restore(keepGroup: group)
    #expect(try repository.book().keepGroups == [group])
    // The bytes of the group are stable: the ids sorted.
    let stored = try stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT payment_ids FROM subscription_keep_groups")
    }
    #expect(
      stored == "[\"" + [first, second].map(\.uuidString).sorted().joined(separator: "\",\"")
        + "\"]")

    // A payment going away takes its extras with it.
    try stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM scheduled_payments WHERE id = ?", arguments: [first.uuidString])
    }
    let book = try repository.book()
    #expect(book.usage.isEmpty && book.users.isEmpty)
  }

  // MARK: - Saved views

  @Test func theSavedViewsAreReplacedAsABookAndComeBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = SavedViewsRepository(writer: stack.writer)
    var book = SavedViewsBook()
    let report = SavedReport(
      name: "Кафе за квартал", kind: .expensesByCategory, period: .floating(.lastMonth))
    book.add(report)
    #expect(try repository.replace(with: book) == SavedViewsBook())
    #expect(try repository.book() == book)
    var changed = book
    changed.rename(report.id, to: "Кафе")
    #expect(try repository.replace(with: changed) == book)
    #expect(try repository.book().reports.map(\.name) == ["Кафе"])
    changed.remove(report.id)
    _ = try repository.replace(with: changed)
    #expect(try repository.book().reports.isEmpty)
    // A row of a newer build that this one can not read stays where it is.
    try stack.writer.write { db in
      try db.execute(
        sql:
          "INSERT INTO saved_views (id, kind, name, payload) VALUES (?, 'chart', 'Будущее', '{}')",
        arguments: [UUID().uuidString])
    }
    _ = try repository.replace(with: SavedViewsBook())
    #expect(try ExportRepository(writer: stack.writer).rowCounts()["saved_views"] == nil)
    let kept = try stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM saved_views")
    }
    #expect(kept == 1)
  }

  // MARK: - The dataset

  @Test func theDatasetCarriesTheNewBooksFromOneRead() throws {
    let stack = try TestSupport.makeStack()
    let year = YearPlanRepository(writer: stack.writer)
    let subscriptions = SubscriptionRepository(writer: stack.writer)
    let views = SavedViewsRepository(writer: stack.writer)
    let (budget, payment) = try stack.writer.write { db in
      (try insertBudget(db), try insertPayment(db))
    }
    try year.setLimit(AmountE4(whole: 1), budget: budget, month: MonthKey(year: 2026, month: 12))
    try year.save(buffer: MonthBufferSettings(amount: AmountE4(whole: 7)))
    try subscriptions.save(SubscriptionTerms(paymentId: payment, needed: true))
    var book = SavedViewsBook()
    book.add(SavedReport(name: "Р", kind: .expensesByCategory, period: .floating(.lastMonth)))
    try views.replace(with: book)

    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    #expect(dataset.yearPlan.monthExceptions.count == 1)
    #expect(dataset.yearPlan.buffer.amount == AmountE4(whole: 7))
    #expect(dataset.subscriptions.terms(of: payment)?.needed == true)
    #expect(dataset.savedViews == book)
    // A copy of the dataset carries the same shelf.
    #expect(dataset.upserting([]).subscriptions == dataset.subscriptions)
    #expect(Dataset.empty.subscriptions == .empty && Dataset.empty.yearPlan == .empty)
  }

  // MARK: - Export and archive

  @Test func theNewFilesAreInTheExportAfterTheNotesOfDaysWithTheirHeaders() throws {
    let names = ExportTables.all.map(\.fileName)
    #expect(names.count == 45)
    #expect(
      Array(names[35..<42]) == [
        "budget_month_exceptions.csv", "event_budget_items.csv", "event_templates.csv",
        "subscription_terms.csv", "subscription_usage.csv", "subscription_users.csv",
        "subscription_keep_groups.csv",
      ])
    #expect(ExportTables.subscriptionTerms.columns.first == "payment_id")
    #expect(
      Array(ExportTables.transactions.columns.dropLast(3).suffix(4)) == [
        "source", "bank_status", "posted_on", "dedup_key",
      ])
    #expect(ExportTables.transfers.columns.last == "arrived_at")
    for name in ["saved_views", "identity_items", "statement_profiles", "import_batches"] {
      #expect(!names.contains(name + ".csv"), "\(name) is not exported")
    }
  }

  private func filled(_ device: TestDevice) throws {
    try device.sql(
      """
      INSERT INTO transactions
        (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
      VALUES (?, 'expense', '2026-10-20 10:00:00.000', 1000000, 1000000, 'coffee',
              '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000')
      """, [Self.operationId])
    try device.sql(
      "INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4) VALUES (?, ?, 1000000, 1000000)",
      [UUID().uuidString, Self.operationId])
    try device.sql(
      "UPDATE transactions SET source = 'statement', bank_status = 'posted', posted_on = '2026-10-21', dedup_key = 'v1:ff' WHERE id = '55555555-5555-4555-8555-555555555555'"
    )
    let payment = "11111111-1111-4111-8111-111111111111"
    let person = "22222222-2222-4222-8222-222222222222"
    let budget = "33333333-3333-4333-8333-333333333333"
    let event = "44444444-4444-4444-8444-444444444444"
    try device.sql("INSERT INTO people (id, name) VALUES (?, 'Анна')", [person])
    try device.sql(
      "INSERT INTO scheduled_payments (id, name, kind, amount_e4) VALUES (?, 'Музыка', 'subscription', 3990000)",
      [payment])
    try device.sql(
      "INSERT INTO budgets (id, scope, amount_e4) VALUES (?, 'bad_total', 1)", [budget])
    try device.sql(
      "INSERT INTO events (id, name, start_date, end_date) VALUES (?, 'Переезд', '2026-11-01', '2026-11-03')",
      [event])
    try device.sql(
      "INSERT INTO subscription_terms (payment_id, floating, tolerance_percent, service_type) VALUES (?, 1, 15, 'music')",
      [payment])
    try device.sql(
      "INSERT INTO subscription_usage (id, payment_id, day) VALUES ('u1', ?, '2026-10-10')",
      [payment])
    try device.sql(
      "INSERT INTO subscription_users (id, payment_id, person_id) VALUES ('s1', ?, ?)",
      [payment, person])
    try device.sql(
      "INSERT INTO subscription_keep_groups (id, type, payment_ids) VALUES ('g1', 'music', ?)",
      ["[\"" + payment + "\"]"])
    try device.sql(
      "INSERT INTO budget_month_exceptions (id, budget_id, month, amount_e4) VALUES ('b1', ?, '2026-12', 5)",
      [budget])
    try device.sql(
      "INSERT INTO event_budget_items (id, event_id, title, planned_e4, sort) VALUES ('e1', ?, 'Грузчики', 7, 0)",
      [event])
    try device.sql(
      "INSERT INTO event_templates (id, name, lines, created_at, updated_at) VALUES ('tpl', 'Шаблон', '[]', '2026-10-22 10:00:00.000', '2026-10-22 10:00:00.000')"
    )
    try device.sql(
      "INSERT INTO saved_views (id, kind, name, payload, sort_order) VALUES ('v1', 'report', 'Р', '{}', 0)"
    )
    try device.sql(
      "INSERT INTO statement_profiles (id, bank_name, payload, created_at, updated_at) VALUES ('my-v1', 'Б', '{}', '2026-10-22 10:00:00.000', '2026-10-22 10:00:00.000')"
    )
    try device.sql(
      "INSERT INTO identity_items (id, kind, value, created_at) VALUES ('i1', 'phone', '+7 900 000-00-01', '2026-10-22 10:00:00.000')"
    )
  }

  @Test func theExportCarriesTheRowsAndTheIdentityStaysOut() throws {
    let device = try TestDevice("mac", recording: false)
    try filled(device)
    let export = ExportRepository(writer: device.stack.writer)
    let counts = try export.rowCounts()
    for name in [
      "budget_month_exceptions", "event_budget_items", "event_templates", "subscription_terms",
      "subscription_usage", "subscription_users", "subscription_keep_groups",
    ] {
      #expect(counts[name] == 1, "\(name)")
    }
    let tables = try export.tables()
    func rows(_ name: String) throws -> [[String: String]] {
      try CSVReader.dictionaries(from: try #require(tables.first { $0.name == name }).data)
    }
    let terms = try #require(try rows("subscription_terms").first)
    #expect(
      terms["floating"] == "true" && terms["needed"] == "false" && terms["owner_uses"] == "true")
    #expect(terms["tolerance_percent"] == "15" && terms["yearly_plan"] == "")
    #expect(try rows("budget_month_exceptions").first?["amount"] == "0.0005")
    #expect(try rows("event_budget_items").first?["planned"] == "0.0007")
    #expect(try rows("transactions").first?["dedup_key"] == "v1:ff")
    #expect(try rows("transactions").first?["posted_on"] == "2026-10-21")
    let text = tables.map { String(decoding: $0.data, as: UTF8.self) }.joined()
    #expect(!text.contains("900 000-00-01"), "the numbers of the owner's contracts are in no CSV")
  }

  @Test func theArchiveCarriesTheNewTablesAndItsDatabaseHoldsThem() throws {
    let device = try TestDevice("mac", recording: false)
    try filled(device)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-0014-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshotURL = folder.appendingPathComponent("snapshot.sqlite")
    let snapshot = try ExportRepository(writer: device.stack.writer).snapshot(to: snapshotURL)
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "2.2.0", schemaVersion: device.stack.applied.onDisk,
        createdAt: DateOnly(year: 2026, month: 10, day: 22), platform: "macOS",
        rowCounts: snapshot.rowCounts))
    try builder.add(path: ArchivePaths.database, data: try Data(contentsOf: snapshotURL))
    for table in snapshot.tables {
      try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
    }
    try builder.add(path: ArchivePaths.settings, data: Data(#"{"language":"ru"}"#.utf8))
    let opened = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 17)
    #expect(opened.csvTables.count == 45)
    #expect(opened.manifest.schemaVersion == 17)
    #expect(opened.manifest.rowCounts["subscription_terms"] == 1)
    let inside = folder.appendingPathComponent("inside.sqlite")
    try (opened.database ?? Data()).write(to: inside)
    #expect(try DatabaseStack.sameData(fileAt: inside, as: snapshotURL))
    let restored = try DatabaseStack(url: inside, schema: TestSupport.schemaSource)
    defer { try? restored.close() }
    // The database inside the archive holds what the CSV leaves out.
    let identity = try StatementImportRepository(writer: restored.writer).identity()
    #expect(identity.phones == ["+7 900 000-00-01"])
    let kept = try restored.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM saved_views")
    }
    #expect(kept == 1)
    #expect(try SubscriptionRepository(writer: restored.writer).book().terms.count == 1)
  }

  // MARK: - The exchange

  @Test func theNewTablesFollowTheExchangeAndArriveEqual() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try filled(mac)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    for table in [
      "budget_month_exceptions", "event_budget_items", "event_templates", "subscription_terms",
      "subscription_usage", "subscription_users", "subscription_keep_groups", "saved_views",
      "statement_profiles",
    ] {
      #expect(try phone.count(table) == 1, Comment(rawValue: table))
    }
    #expect(try phone.books() == mac.books())
    #expect(try phone.count("identity_items") == 0, "who the owner is never travels")
    #expect(try phone.outboxCount() == 0)
    let row = try phone.stack.writer.read { db in
      try Row.fetchOne(
        db,
        sql:
          "SELECT dedup_key, posted_on FROM transactions WHERE id = '55555555-5555-4555-8555-555555555555'"
      )
    }
    #expect(row?["dedup_key"] == "v1:ff" && row?["posted_on"] == "2026-10-21")
  }

  @Test func anEditAndADeleteOfTheNewRowsTravelToo() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try filled(mac)
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)

    // The key of subscription_terms is the payment itself.
    try mac.sql("UPDATE subscription_terms SET needed = 1, tolerance_percent = 20")
    try mac.sql("UPDATE saved_views SET name = 'Кафе'")
    try mac.sql("UPDATE budget_month_exceptions SET amount_e4 = 9")
    try mac.stamp("2026-10-22T11:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.books() == mac.books())
    let needed = try phone.stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT needed FROM subscription_terms")
    }
    #expect(needed == 1)

    // Deleting the payment takes its extras with it, on both devices.
    try mac.sql("DELETE FROM scheduled_payments")
    try mac.stamp("2026-10-22T12:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("subscription_terms") == 0)
    #expect(try phone.count("subscription_usage") == 0)
    #expect(try phone.books() == mac.books())
  }
}
