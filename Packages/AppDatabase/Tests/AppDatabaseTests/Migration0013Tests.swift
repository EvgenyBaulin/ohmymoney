import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to the spending rules (`0013_spending_rules`) only adds: a database of 2.0 keeps
/// every value, the new columns start at their defaults, the new tables start empty, and the
/// tags, rules, notes of days and the new columns go through the repositories, the export, the
/// archive and the exchange between devices.
@Suite("The spending rules come in without touching a value")
struct Migration0013Tests {
  private static let older = FilteredSchemaSource(upTo: "0012_sync")
  static let moment = Date(timeIntervalSince1970: 1_790_000_000)
  private static let newTables = ["tags", "part_tags", "rules", "day_notes"]

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0013-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  // MARK: - The update

  @Test func aNewDatabaseHasTheColumnsAtTheirDefaultsAndTheTablesEmpty() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0018_purchases")
    #expect(stack.applied.onDisk == 17)
    try stack.writer.read { (db: Database) throws in
      for table in Self.newTables {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
      let columns = try db.columns(in: "categories").map(\.name)
      #expect(columns.contains("basket"))
      #expect(try db.columns(in: "cards").map(\.name).contains("last4"))
      #expect(
        try db.columns(in: "transactions").first { $0.name == "one_off" }?.defaultValueSQL == "0")
    }
  }

  @Test func aDatabaseOf20KeepsEveryValueAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let account = UUID().uuidString
    let card = PaymentCard(
      accountId: UUID(uuidString: account)!, name: "Основная", aliases: ["main"], sort: 2)
    let operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
      amountE4: AmountE4(whole: 500), note: "кофе, \"латте\"")
    let category = CoreKit.Category(kind: .expense, name: "Еда", essential: true)
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: "INSERT INTO payment_methods (id, name) VALUES (?, 'Основной')",
          arguments: [account])
        try LegacyWriter.insert(card, db: db)
        try LegacyWriter.insert(operation, db: db)
        try LegacyWriter.insert(category, db: db)
        try db.execute(
          sql: "INSERT INTO settings (key, value) VALUES ('incomeSavings.proportions', '60/25/15')")
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0013_spending_rules", "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
          "0017_attachments",
          "0018_purchases",
        ])

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 5)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      #expect(try Int.fetchOne(db, sql: "SELECT one_off FROM transactions") == 0)
      #expect(
        try String.fetchOne(db, sql: "SELECT basket FROM categories WHERE name = 'Еда'") == nil)
      #expect(try String.fetchOne(db, sql: "SELECT last4 FROM cards") == nil)
      #expect(try String.fetchOne(db, sql: "SELECT details FROM cards") == nil)
      for table in Self.newTables {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource).isEmpty)
  }

  @Test func theSettingsOfIncomeAndSavingsStayInTheSettingsTable() throws {
    let stack = try TestSupport.makeStack()
    let repository = SpendingRulesRepository(writer: stack.writer)
    #expect(try repository.incomeSavings() == .standard)
    let custom = IncomeSavingsSettings(
      proportions: BudgetProportions(needs: 60, wants: 25, savings: 15)!, earningsOnly: true,
      trendNudgeEnabled: false, trendNudgeShown: "2026-Q3")
    try repository.save(custom)
    #expect(try repository.incomeSavings() == custom)
    // Back to the defaults: the keys go, the table holds nothing of them.
    try repository.save(.standard)
    #expect(try repository.incomeSavings() == .standard)
    let left = try stack.writer.read { (db: Database) throws in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM settings WHERE key LIKE 'incomeSavings.%'")
    }
    #expect(left == 0)
  }

  // MARK: - The new columns through the records

  @Test func theNewColumnsAreWrittenAndReadBack() throws {
    let stack = try TestSupport.makeStack()
    let account = PaymentMethod(name: "Счёт")
    var card = PaymentCard(
      accountId: account.id, name: "Карта", last4: "3230", details: "Visa, до 09/29")
    var category = CoreKit.Category(kind: .expense, name: "Кафе", basket: .wants)
    var operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
      amountE4: AmountE4(whole: 90), isOneOff: true)
    try stack.writer.write { db in
      try account.insert(db)
      try card.insert(db)
      try category.insert(db)
      try operation.insert(db)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try PaymentCard.fetchOne(db, key: card.id.uuidString) == card)
      #expect(try CoreKit.Category.fetchOne(db, key: category.id.uuidString) == category)
      #expect(try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString)?.isOneOff == true)
    }
    card.last4 = nil
    category.basket = nil
    operation.isOneOff = false
    try stack.writer.write { db in
      try card.update(db)
      try category.update(db)
      try operation.update(db)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try PaymentCard.fetchOne(db, key: card.id.uuidString)?.last4 == nil)
      #expect(try CoreKit.Category.fetchOne(db, key: category.id.uuidString)?.basket == nil)
      #expect(try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString)?.isOneOff == false)
    }
  }

  @Test func theOneOffMarkIsOneStepOfTheBulkEditAndItsUndo() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let entry = try TestSupport.makeEntry()
    try stack.writer.write { db in try entry.transaction.insert(db) }
    try stack.writer.write { db in for part in entry.parts { try part.insert(db) } }
    let before = try repository.modify(ids: [entry.id]) { entry in
      var marked = entry
      marked.transaction.isOneOff = true
      return marked
    }
    #expect(before.first?.transaction.isOneOff == false)
    #expect(try repository.entries(ids: [entry.id]).first?.transaction.isOneOff == true)
    _ = try repository.modify(ids: [entry.id], checkingCharges: false) { _ in before[0] }
    #expect(try repository.entries(ids: [entry.id]).first?.transaction.isOneOff == false)
  }
}

// MARK: - Tags, rules, notes, applying rules to the past

@Suite("Tags, rules and notes of days are written in single steps with their undo")
struct SpendingRulesRepositoryTests {
  private let moment = Migration0013Tests.moment

  private func prepared() throws -> (DatabaseStack, SpendingRulesRepository, TransactionEntry) {
    let stack = try TestSupport.makeStack()
    let written = try TestSupport.makeEntry()
    try stack.writer.write { db in
      try written.transaction.insert(db)
      for part in written.parts { try part.insert(db) }
    }
    // As the database holds it: instants to the millisecond.
    let entry = try stack.writer.read { db in
      try #require(try TransactionRepository.entries(ids: [written.id], db: db).first)
    }
    return (stack, SpendingRulesRepository(writer: stack.writer), entry)
  }

  @Test func aTagIsAttachedRenamedMergedAndDeletedAndEachStepComesBack() throws {
    let (_, repository, entry) = try prepared()
    let part = entry.parts[0].id
    var book = TagBook()
    let resolved = book.resolving(names: ["#Отпуск", "#турция"], now: moment)
    book = resolved.book
    book.links = book.attaching(resolved.ids, to: part)
    let empty = TagBook()
    try repository.apply(TagEdit(before: empty, after: book))
    #expect(try repository.tagBook().sorted == book.sorted)

    // A rule that adds the tag follows a merge and goes with a deleted tag.
    let vacation = resolved.ids[0]
    let turkey = resolved.ids[1]
    let rule = Rule(
      name: "Отпуск", conditions: [.textContains("отель")], actions: [.addTag(turkey)],
      createdAt: moment)
    try repository.append(rule)

    let merge = try #require(book.merging(turkey, into: vacation))
    let applied = try repository.apply(merge, merged: (turkey, vacation))
    #expect(try repository.tagBook().sorted == merge.after.sorted)
    #expect(try repository.rules().first?.actions == [.addTag(vacation)])
    #expect(applied.rulesBefore.count == 1)
    try repository.undo(applied)
    #expect(try repository.tagBook().sorted == book.sorted)
    #expect(try repository.rules().first?.actions == [.addTag(turkey)])

    let deletion = try #require(book.deleting(turkey))
    let deleted = try repository.apply(deletion)
    #expect(try repository.rules().isEmpty, "a rule left with no action goes")
    #expect(try repository.tagBook().links.count == 1)
    try repository.undo(deleted)
    #expect(try repository.rules().count == 1)
    #expect(try repository.tagBook().sorted == book.sorted)

    let renamed = try #require(book.renaming(vacation, to: "Каникулы").edit)
    try repository.apply(renamed)
    #expect(try repository.tagBook().tag(vacation)?.name == "Каникулы")
    try repository.undo(AppliedTagEdit(edit: renamed, rulesBefore: [], rulesRemoved: []))
    #expect(try repository.tagBook().sorted == book.sorted)
  }

  @Test func aLinkIsOneRowAndDisappearsWithItsPartOrItsTag() throws {
    let (stack, repository, entry) = try prepared()
    let part = entry.parts[0].id
    let tag = Tag(name: "подарки", createdAt: moment)
    try stack.writer.write { db in try tag.insert(db) }
    try repository.attach([PartTag(partId: part, tagId: tag.id)])
    try repository.attach([PartTag(partId: part, tagId: tag.id)])
    #expect(try repository.tagBook().links.count == 1)
    #expect(try repository.tagIds(ofParts: [part]) == [part: [tag.id]])
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tag.id.uuidString])
    }
    #expect(try repository.tagBook().links.isEmpty)
  }

  @Test func theRulesKeepTheirOrderAndTheOrderComesBack() throws {
    let (_, repository, _) = try prepared()
    let a = try repository.append(
      Rule(
        name: "A", conditions: [.weekdays([6, 7])], actions: [.setQuality(.bad)], createdAt: moment)
    )
    let b = try repository.append(
      Rule(
        name: "B", conditions: [.amountAbove(AmountE4(whole: 5_000))],
        actions: [.setForWhom(.partner)], createdAt: moment))
    let c = try repository.append(
      Rule(
        name: "C", conditions: [.timeBetween(fromMinute: 1_320, toMinute: 360)],
        actions: [.setQuality(.neutral)], createdAt: moment))
    #expect(try repository.rules().map(\.name) == ["A", "B", "C"])
    let was = try repository.reorder([c.id, a.id])
    #expect(try repository.rules().map(\.name) == ["C", "A", "B"])
    try repository.restoreOrder(was)
    #expect(try repository.rules().map(\.name) == ["A", "B", "C"])
    let gone = try repository.deleteRules(ids: [b.id])
    #expect(gone.map(\.name) == ["B"])
    try repository.save(gone)
    #expect(try repository.rules().map(\.id) == [a.id, b.id, c.id])
    // The stored form reads back to the same conditions.
    #expect(try repository.rules() == [a, b, c])
  }

  @Test func aRuleOfANewerBuildIsLeftOutOfTheListAndStaysInTheDatabase() throws {
    let (stack, repository, _) = try prepared()
    try repository.append(
      Rule(
        name: "Known", conditions: [.weekdays([1])], actions: [.setQuality(.good)],
        createdAt: moment))
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO rules (id, name, position, conditions, actions, created_at, updated_at)
          VALUES (?, 'Future', 5, '[{"type":"somethingNew"}]', '[]', '2026-10-22 10:00:00.000',
            '2026-10-22 10:00:00.000')
          """, arguments: [UUID().uuidString])
    }
    #expect(try repository.rules().map(\.name) == ["Known"])
    let csv = try ExportRepository(writer: stack.writer).tables().first { $0.name == "rules" }
    let rows = try CSVReader.dictionaries(from: try #require(csv).data)
    #expect(rows.count == 2, "the export carries it whole")
    #expect(rows.contains { $0["conditions"] == #"[{"type":"somethingNew"}]"# })
  }

  @Test func theNoteOfADayIsWrittenReplacedDeletedAndRestored() throws {
    let (_, repository, _) = try prepared()
    let day = DateOnly(year: 2026, month: 10, day: 12)
    let first = try repository.setNote("День рождения мамы", on: day, at: moment)
    #expect(first.before == nil && first.after?.text == "День рождения мамы")
    let second = try repository.setNote(
      "  День рождения мамы, звонок  ", on: day, at: moment.addingTimeInterval(60))
    #expect(second.after?.text == "День рождения мамы, звонок")
    #expect(second.after?.id == first.after?.id, "one note per day")
    #expect(try repository.dayNotes().count == 1)
    let removed = try repository.setNote("   ", on: day)
    #expect(removed.after == nil)
    #expect(try repository.note(on: day) == nil)
    try repository.restore(second.after, on: day)
    #expect(try repository.note(on: day) == second.after)
    try repository.restore(nil, on: day)
    #expect(try repository.dayNotes().isEmpty)
  }

  @Test func applyingRulesToThePastIsOneStepAndOneUndo() throws {
    let (stack, repository, entry) = try prepared()
    let tag = Tag(name: "кофе", createdAt: moment)
    try stack.writer.write { db in try tag.insert(db) }
    var after = entry
    after.parts[0].quality = .bad
    after.parts[0].qualitySource = .manual
    after.transaction.updatedAt = entry.transaction.updatedAt.addingTimeInterval(5)
    let link = PartTag(partId: entry.parts[0].id, tagId: tag.id)
    let commit = RuleBackfillCommit(
      writes: [after], tagLinksToAdd: [link],
      undo: RuleBackfillUndo(entries: [entry], tagLinksToRemove: [link]))

    let applied = try repository.apply(commit)
    #expect(applied.written == 1 && applied.linksAdded == 1 && applied.stale.isEmpty)
    let written = try stack.writer.read { (db: Database) throws in
      try TransactionRepository.entries(ids: [entry.id], db: db)
    }
    #expect(written.first?.parts.first?.quality == .bad)
    #expect(try repository.tagBook().links == [link])

    try repository.undo(applied.undo)
    let restored = try stack.writer.read { (db: Database) throws in
      try TransactionRepository.entries(ids: [entry.id], db: db)
    }
    #expect(restored.first == entry, "every value as it was, updatedAt included")
    #expect(try repository.tagBook().links.isEmpty)
  }

  @Test func anOperationEditedAfterThePreviewIsLeftAlone() throws {
    let (stack, repository, entry) = try prepared()
    let tag = Tag(name: "кофе", createdAt: moment)
    try stack.writer.write { db in
      try tag.insert(db)
      try db.execute(
        sql: "UPDATE transactions SET note = 'edited by hand' WHERE id = ?",
        arguments: [entry.id.uuidString])
    }
    var after = entry
    after.parts[0].quality = .bad
    let link = PartTag(partId: entry.parts[0].id, tagId: tag.id)
    let commit = RuleBackfillCommit(
      writes: [after], tagLinksToAdd: [link],
      undo: RuleBackfillUndo(entries: [entry], tagLinksToRemove: [link]))
    let applied = try repository.apply(commit)
    #expect(applied.stale == [entry.id])
    #expect(applied.written == 0 && applied.linksAdded == 0)
    let now = try stack.writer.read { (db: Database) throws in
      try TransactionRepository.entries(ids: [entry.id], db: db)
    }
    #expect(now.first?.transaction.note == "edited by hand")
    #expect(now.first?.parts.first?.quality != .bad)
  }
}

// MARK: - The export, the archive and the exchange

@Suite("The new tables travel in the export, the archive and between devices")
struct SpendingRulesTravelTests {
  /// `realIds`: UUIDs for the operation and its part, which the export reads; the exchange tests
  /// are content with short ids.
  private func fill(
    _ device: TestDevice, operation givenOperation: String = "t1", realIds: Bool = false
  ) throws -> String {
    var operation = givenOperation
    var part = "\(operation)-part"
    if realIds {
      operation = UUID().uuidString
      part = UUID().uuidString
      try device.sql(
        """
        INSERT INTO transactions
          (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
        VALUES (?, 'expense', '2026-10-20 10:00:00.000', 1000000, 1000000, 'coffee',
                '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000')
        """, [operation])
      try device.sql(
        "INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4) VALUES (?, ?, 1000000, 1000000)",
        [part, operation])
    } else {
      try device.insertOperation(operation, note: "coffee")
    }
    let tag = UUID().uuidString
    try device.sql(
      "INSERT INTO tags (id, name, archived, created_at) VALUES (?, 'Отпуск', 0, '2026-10-22 10:00:00.000')",
      [tag])
    try device.sql(
      "INSERT INTO part_tags (id, part_id, tag_id) VALUES (?, ?, ?)", [part + ":" + tag, part, tag])
    try device.sql(
      """
      INSERT INTO rules (id, name, position, conditions, actions, created_at, updated_at)
      VALUES (?, 'Кофе', 0, '[{"text":"кофе","type":"textContains"}]', ?, '2026-10-22 10:00:00.000',
        '2026-10-22 10:00:00.000')
      """, [UUID().uuidString, #"[{"id":"\#(tag)","type":"addTag"}]"#])
    try device.sql(
      "INSERT INTO day_notes (id, day, text, created_at, updated_at) VALUES (?, '2026-10-12', 'мама', '2026-10-22 10:00:00.000', '2026-10-22 10:00:00.000')",
      [UUID().uuidString])
    try device.sql("UPDATE transactions SET one_off = 1 WHERE id = ?", [operation])
    return tag
  }

  @Test func theFourNewFilesAreInTheExportAfterSettingsWithTheirHeaders() throws {
    let names = ExportTables.all.map(\.fileName)
    #expect(names.count == 49)
    #expect(
      Array(names[30..<35]) == [
        "settings.csv", "tags.csv", "part_tags.csv", "rules.csv", "day_notes.csv",
      ])
    #expect(ExportTables.tags.columns == ["id", "name", "archived", "created_at"])
    #expect(ExportTables.partTags.columns == ["id", "part_id", "tag_id"])
    #expect(ExportTables.dayNotes.columns == ["id", "day", "text", "created_at", "updated_at"])
    #expect(ExportTables.transactions.columns[28] == "one_off")
    #expect(ExportTables.categories.columns.last == "basket")
    #expect(Array(ExportTables.cards.columns.dropLast().suffix(2)) == ["last4", "details"])
  }

  @Test func theExportCarriesTheRowsAndTheCountsAgree() throws {
    let device = try TestDevice("mac", recording: false)
    let tag = try fill(device, realIds: true)
    let export = ExportRepository(writer: device.stack.writer)
    let counts = try export.rowCounts()
    for name in ["tags", "part_tags", "rules", "day_notes"] {
      #expect(counts[name] == 1, "\(name)")
    }
    let tables = try export.tables()
    func rows(_ name: String) throws -> [[String: String]] {
      try CSVReader.dictionaries(from: try #require(tables.first { $0.name == name }).data)
    }
    #expect(try rows("tags").first?["name"] == "Отпуск")
    #expect(try rows("tags").first?["archived"] == "false")
    #expect(try rows("part_tags").first?["id"]?.hasSuffix(":" + tag) == true)
    #expect(try rows("rules").first?["enabled"] == "true")
    #expect(try rows("rules").first?["actions"] == #"[{"id":"\#(tag)","type":"addTag"}]"#)
    #expect(try rows("day_notes").first?["day"] == "2026-10-12")
    #expect(try rows("transactions").first?["one_off"] == "true")
  }

  @Test func theArchiveCarriesTheNewTablesAndItsDatabaseHoldsThem() throws {
    let device = try TestDevice("mac", recording: false)
    _ = try fill(device, realIds: true)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-0013-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshotURL = folder.appendingPathComponent("snapshot.sqlite")
    let snapshot = try ExportRepository(writer: device.stack.writer).snapshot(to: snapshotURL)
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "2.1.0", schemaVersion: device.stack.applied.onDisk,
        createdAt: DateOnly(year: 2026, month: 10, day: 22), platform: "macOS",
        rowCounts: snapshot.rowCounts))
    try builder.add(path: ArchivePaths.database, data: try Data(contentsOf: snapshotURL))
    for table in snapshot.tables {
      try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
    }
    try builder.add(path: ArchivePaths.settings, data: Data(#"{"language":"ru"}"#.utf8))
    let opened = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 17)
    #expect(opened.csvTables.count == 49)
    #expect(opened.manifest.schemaVersion == 18)
    #expect(opened.manifest.rowCounts["tags"] == 1)
    #expect(opened.manifest.rowCounts["rules"] == 1)
    let inside = folder.appendingPathComponent("inside.sqlite")
    try (opened.database ?? Data()).write(to: inside)
    #expect(try DatabaseStack.sameData(fileAt: inside, as: snapshotURL))
    let restored = try DatabaseStack(url: inside, schema: TestSupport.schemaSource)
    defer { try? restored.close() }
    let repository = SpendingRulesRepository(writer: restored.writer)
    #expect(try repository.tagBook().tags.map(\.name) == ["Отпуск"])
    #expect(try repository.rules().count == 1)
    #expect(try repository.dayNotes().count == 1)
  }

  @Test func theNewTablesFollowTheExchangeAndArriveEqual() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    _ = try fill(mac)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    for table in ["tags", "part_tags", "rules", "day_notes"] {
      #expect(try phone.count(table) == 1, Comment(rawValue: table))
    }
    #expect(try phone.books() == mac.books())
    #expect(try phone.outboxCount() == 0)
    let oneOff = try phone.stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT one_off FROM transactions WHERE id = 't1'")
    }
    #expect(oneOff == 1, "a column of an old table travels with its row")
  }

  @Test func anEditAndADeleteOfTheNewRowsTravelToo() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    _ = try fill(mac)
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)

    try mac.sql("UPDATE tags SET name = 'Каникулы'")
    try mac.sql("UPDATE rules SET enabled = 0, position = 3")
    try mac.sql("UPDATE day_notes SET text = 'мама, звонок'")
    try mac.stamp("2026-10-22T11:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.books() == mac.books())

    // Deleting a tag takes its links with it, on both devices.
    try mac.sql("DELETE FROM tags")
    try mac.stamp("2026-10-22T12:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("tags") == 0)
    #expect(try phone.count("part_tags") == 0)
    #expect(try phone.books() == mac.books())
  }

  @Test func aLinkThatArrivesBeforeItsTagWaitsAndIsTakenAtTheNextExchange() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    _ = try fill(mac)
    _ = try mac.exchange.exchange(with: folder)
    // Two exchanges give the same result however the files are ordered.
    _ = try phone.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("part_tags") == 1)
    #expect(try phone.books() == mac.books())
  }
}

extension TagBook {
  /// The same book with tags and links in the order of their ids, for comparing what the
  /// database reads (by date, then id) with what the model built.
  fileprivate var sorted: TagBook {
    TagBook(
      tags: tags.sorted { $0.id.uuidString < $1.id.uuidString },
      links: links.sorted {
        ($0.partId.uuidString, $0.tagId.uuidString) < ($1.partId.uuidString, $1.tagId.uuidString)
      })
  }
}
