import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A migration set built in the test, so a renamed or a missing `Schema/` file can be
/// simulated without touching the repository.
private struct FixedSchemaSource: SchemaSource {
  let all: [SchemaMigration]
  func migrations() throws -> [SchemaMigration] { all }
}

@Suite("Saving an operation twice keeps its parts and their history")
struct PartReplacementTests {
  @Test func savingTwiceDoesNotDuplicateParts() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 1_000))
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 600), note: "first"),
      PartDraft(amount: AmountE4(whole: 400), note: "second"),
    ]
    let entry = try draft.materialize()
    try repository.save(entry)
    try repository.save(entry)

    let loaded = try #require(try repository.entry(id: entry.id))
    #expect(loaded.parts.count == 2)
    #expect(Set(loaded.parts.map(\.note)) == ["first", "second"])
    #expect(loaded.isBalanced)
  }

  @Test func savingWithFewerPartsDropsTheOnesThatWentAway() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 1_000))
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 600), note: "first"),
      PartDraft(amount: AmountE4(whole: 400), note: "second"),
    ]
    try repository.save(try draft.materialize())
    let id = try draft.materialize().id

    var merged = draft
    merged.parts = [PartDraft(amount: AmountE4(whole: 1_000), note: "merged")]
    try repository.save(try merged.materialize(id: id))

    let loaded = try #require(try repository.entry(id: id))
    #expect(loaded.parts.count == 1)
    #expect(loaded.parts[0].note == "merged")
  }

  /// Editing an expense that has already been paid back must not wipe the trail of the
  /// reimbursement: `reimbursement_links` cascade away with the part row.
  @Test func editingAnOperationKeepsTheReimbursementLinksOfItsParts() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 1_000), reimbursable: true, reimbursementStatus: .returned)
    ]
    let entry = try draft.materialize()
    try repository.save(entry)

    let back = try TestSupport.makeEntry(amount: 10_000_000, kind: .reimbursement, note: "back")
    try repository.save(back)
    let link = ReimbursementLink(
      reimbursementTxId: back.id, partId: entry.parts[0].id, amountE4: AmountE4(whole: 1_000))
    try stack.writer.write { db in try link.insert(db) }

    // The user fixes a typo in the note and saves again.
    var edited = TransactionDraft(entry: entry)
    edited.note = "dinner with Alex"
    try repository.save(try edited.materialize(id: entry.id))

    let links = try stack.writer.read { db in try ReimbursementLink.fetchAll(db) }
    #expect(links.count == 1)
    #expect(links.first?.partId == entry.parts[0].id)
  }

  @Test func savingTwiceKeepsTheStatusOfThePartsThatStay() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 500))
    draft.parts = [PartDraft(amount: AmountE4(whole: 500), reimbursable: true)]
    let entry = try draft.materialize()
    try repository.save(entry)
    try repository.writeOffPart(id: entry.parts[0].id)

    let reloaded = try #require(try repository.entry(id: entry.id))
    #expect(reloaded.parts[0].reimbursementStatus == .writtenOff)
    try repository.save(reloaded)

    let again = try #require(try repository.entry(id: entry.id))
    #expect(again.parts[0].reimbursementStatus == .writtenOff)
    #expect(again.parts.count == 1)
  }
}

@Suite("Soft delete, owed parts and reimbursements")
struct TransactionRepositoryTests {
  @Test func softDeleteKeepsEveryFieldAndRestoreBringsThemBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 900), note: "gone")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 500), note: "a"),
      PartDraft(amount: AmountE4(whole: 400), note: "b"),
    ]
    let entry = try draft.materialize()
    try repository.save(entry)

    let moment = Date(timeIntervalSince1970: 1_789_000_500)
    try repository.softDelete(id: entry.id, at: moment)
    let deleted = try #require(try repository.entry(id: entry.id))
    #expect(deleted.transaction.deletedAt == moment)
    #expect(deleted.transaction.updatedAt == moment)
    #expect(deleted.parts.count == 2)
    #expect(try repository.entries(from: .distantPast, to: .distantFuture).isEmpty)

    let later = Date(timeIntervalSince1970: 1_789_000_600)
    try repository.restore(id: entry.id, at: later)
    let restored = try #require(try repository.entry(id: entry.id))
    #expect(restored.transaction.deletedAt == nil)
    #expect(restored.transaction.updatedAt == later)
    #expect(restored.parts.count == 2)
    #expect(restored.transaction.note == "gone")
  }

  @Test func owedPartsListsOnlyWhatIsStillWaiting() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)

    let waiting = try makeReimbursable(status: nil, note: "waiting", amount: 100)
    let expected = try makeReimbursable(status: .expected, note: "expected", amount: 200)
    let returned = try makeReimbursable(status: .returned, note: "returned", amount: 300)
    let written = try makeReimbursable(status: .writtenOff, note: "written", amount: 400)
    let mine = try TestSupport.makeEntry(note: "mine")
    for entry in [waiting, expected, returned, written, mine] {
      try repository.save(entry)
    }
    let deleted = try makeReimbursable(status: .expected, note: "deleted", amount: 500)
    try repository.save(deleted)
    try repository.softDelete(id: deleted.id)

    let owed = try repository.owedParts()
    #expect(Set(owed.map(\.note)) == ["waiting", "expected"])
  }

  @Test func applyWritesLinksStatusesAndExtras() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let owedEntry = try makeReimbursable(status: .expected, note: "lunch", amount: 1_000)
    try repository.save(owedEntry)

    let owed = try repository.owedParts()
    #expect(owed.count == 1)

    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: 1_200), closing: owed)
    var draft = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 1_200))
    draft.normalizeSinglePart()
    let reimbursement = try draft.materialize(id: reimbursementId)

    var surplusDraft = TransactionDraft(
      kind: .income, amount: try #require(outcome.surplus).amountE4)
    surplusDraft.normalizeSinglePart()
    let surplus = try surplusDraft.materialize()

    try repository.apply(outcome, reimbursement: reimbursement, extra: [surplus])

    let links = try stack.writer.read { db in try ReimbursementLink.fetchAll(db) }
    #expect(links.count == 1)
    #expect(links[0].partId == owedEntry.parts[0].id)
    #expect(links[0].amountE4 == AmountE4(whole: 1_000))

    let closed = try #require(try repository.entry(id: owedEntry.id))
    #expect(closed.parts[0].reimbursementStatus == .returned)
    #expect(try repository.owedParts().isEmpty)
    #expect(try repository.entry(id: reimbursementId) != nil)
    #expect(try repository.entry(id: surplus.id)?.parts.count == 1)
    #expect(try repository.count() == 3)
  }

  /// One bad insert must take the whole reimbursement with it: a half written one would
  /// close the part without recording the money.
  @Test func applyLeavesNothingBehindWhenOneInsertFails() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let owedEntry = try makeReimbursable(status: .expected, note: "lunch", amount: 1_000)
    try repository.save(owedEntry)

    let owed = try repository.owedParts()
    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: 1_200), closing: owed)
    var draft = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 1_200))
    draft.normalizeSinglePart()
    let reimbursement = try draft.materialize(id: reimbursementId)

    // The surplus lands in a category that is not in the database.
    var surplusDraft = TransactionDraft(kind: .income, amount: AmountE4(whole: 200))
    surplusDraft.parts = [PartDraft(categoryId: UUID(), amount: AmountE4(whole: 200))]
    let surplus = try surplusDraft.materialize()

    #expect(throws: (any Error).self) {
      try repository.apply(outcome, reimbursement: reimbursement, extra: [surplus])
    }

    #expect(try repository.entry(id: reimbursementId) == nil)
    #expect(try repository.entry(id: surplus.id) == nil)
    #expect(try stack.writer.read { db in try ReimbursementLink.fetchCount(db) } == 0)
    let untouched = try #require(try repository.entry(id: owedEntry.id))
    #expect(untouched.parts[0].reimbursementStatus == .expected)
    #expect(try repository.count() == 1)
  }

  @Test func applyRefusesExtraOperationsWhosePartsDoNotAddUp() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let owedEntry = try makeReimbursable(status: .expected, note: "lunch", amount: 1_000)
    try repository.save(owedEntry)

    let owed = try repository.owedParts()
    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: 1_000), closing: owed)
    var draft = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 1_000))
    draft.normalizeSinglePart()
    let reimbursement = try draft.materialize(id: reimbursementId)

    let broken = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_000_000),
      amountE4: AmountE4(whole: 100))
    let brokenPart = TransactionPart(
      transactionId: broken.id, amountE4: AmountE4(whole: 40))
    let extra = TransactionEntry(transaction: broken, parts: [brokenPart])

    #expect(throws: AppDatabase.DatabaseError.unbalancedParts) {
      try repository.apply(outcome, reimbursement: reimbursement, extra: [extra])
    }
    #expect(try repository.entry(id: broken.id) == nil)
    #expect(try repository.entry(id: reimbursementId) == nil)
  }

  @Test func entriesIncludeBothEndsOfTheRange() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    // 2026-09-01 00:00:00.000 UTC and the last millisecond of 2026-09-30.
    let start = Date(timeIntervalSince1970: 1_788_220_800)
    let end = Date(timeIntervalSince1970: 1_790_812_799.999)
    let before = try TestSupport.makeEntry(
      occurredAt: start.addingTimeInterval(-0.001), note: "before")
    let first = try TestSupport.makeEntry(occurredAt: start, note: "first")
    let last = try TestSupport.makeEntry(occurredAt: end, note: "last")
    let after = try TestSupport.makeEntry(
      occurredAt: end.addingTimeInterval(0.001), note: "after")
    for entry in [before, first, last, after] { try repository.save(entry) }

    let inside = try repository.entries(from: start, to: end)
    #expect(inside.map(\.transaction.note) == ["last", "first"])
    #expect(inside.allSatisfy { $0.parts.count == 1 })
  }

  @Test func entriesCarryTheirPartsAndNewestComesFirst() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    for index in 0..<5 {
      var draft = TransactionDraft(
        occurredAt: Date(timeIntervalSince1970: 1_789_000_000 + Double(index) * 86_400),
        amount: AmountE4(whole: 100), note: "day \(index)")
      draft.parts = [
        PartDraft(amount: AmountE4(whole: 60)), PartDraft(amount: AmountE4(whole: 40)),
      ]
      try repository.save(try draft.materialize())
    }

    let all = try repository.entries(from: .distantPast, to: .distantFuture)
    #expect(all.map(\.transaction.note) == ["day 4", "day 3", "day 2", "day 1", "day 0"])
    #expect(all.allSatisfy { $0.parts.count == 2 && $0.isBalanced })
    #expect(try repository.count() == 5)
  }

  /// Imported and generated rows share their instant, and the one written with them too.
  /// The order of such rows is the database's own — the row the index reaches first — and
  /// moves with the order they happened to be written in, so the lists and the tests that
  /// read the first of them would not agree from one database to the next. The id decides,
  /// the way the ledger decides (`Ledger`: the day, the instant, then the id).
  @Test func operationsOfTheSameInstantComeInTheOrderOfTheirIds() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let instant = Date(timeIntervalSince1970: 1_789_000_000)
    let ids = (1...5).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
    for index in [2, 0, 4, 1, 3] {
      var draft = TransactionDraft(
        occurredAt: instant, amount: AmountE4(whole: 100), note: "row \(index + 1)")
      draft.normalizeSinglePart()
      try repository.save(try draft.materialize(id: ids[index], now: instant))
    }

    let newestFirst = Array(ids.reversed())
    #expect(try repository.entries(from: .distantPast, to: .distantFuture).map(\.id) == newestFirst)
    #expect(try repository.recentEntries().map(\.id) == newestFirst)
  }

  private func makeReimbursable(
    status: ReimbursementStatus?, note: String, amount: Int64
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: amount), note: note)
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: amount), forWhom: .friends, reimbursable: true,
        reimbursementStatus: status, note: note)
    ]
    return try draft.materialize()
  }
}

@Suite("Foreign keys, migrations and backups")
struct StorageIntegrityTests {
  @Test func foreignKeysAreReallyOn() throws {
    let stack = try TestSupport.makeStack()
    let flag = try stack.writer.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
    #expect(flag == 1)

    let orphan = TransactionPart(transactionId: UUID(), amountE4: AmountE4(whole: 10))
    #expect(throws: (any Error).self) {
      try stack.writer.write { db in try orphan.insert(db) }
    }
  }

  /// `Schema/0001` says `PRAGMA foreign_keys = ON`, and it says nothing: a migration runs
  /// inside a transaction, where SQLite ignores that pragma. What turns the keys on is the
  /// connection (`Configuration.foreignKeysEnabled`), and any other runner of these files —
  /// the Windows port — has to do the same. Should this test ever fail, the line in the file
  /// has started to matter and this account of it is wrong.
  @Test func theSchemaFilesDoNotTurnTheForeignKeysOn() throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = false
    let queue = try DatabaseQueue(configuration: configuration)
    var migrator = DatabaseMigrator()
    for migration in try TestSupport.schemaSource.migrations() {
      migrator.registerMigration(migration.name) { db in try db.execute(sql: migration.sql) }
    }
    try migrator.migrate(queue)

    let flag = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
    #expect(flag == 0, "the schema's own pragma turned the foreign keys on")
  }

  @Test func foreignKeysAreOnInAFileBackedStackToo() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let flag = try stack.writer.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
    #expect(flag == 1)
    let mode = try stack.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
    #expect(mode == "wal")
  }

  /// A write that returned has reached the disk, not only the system's cache: the log is
  /// synced at every commit, with the flush macOS needs to get past the drive's own cache.
  /// GRDB sets NORMAL on the writer when it turns WAL on, so the setting is read back from the
  /// writer itself, where the commits happen.
  @Test func aCommitIsSyncedToTheDisk() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (synchronous, fullSync) = try stack.writer.writeWithoutTransaction { db in
      (
        try Int.fetchOne(db, sql: "PRAGMA synchronous"),
        try Int.fetchOne(db, sql: "PRAGMA fullfsync")
      )
    }
    #expect(synchronous == 2, "the writer commits at synchronous \(synchronous ?? -1), not FULL")
    #expect(fullSync == 1, "a sync stops at the drive's cache")
  }

  @Test func purgingAnOperationTakesItsPartsAndLinksWithIt() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 1_000))
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 600)), PartDraft(amount: AmountE4(whole: 400)),
    ]
    let entry = try draft.materialize()
    try repository.save(entry)
    let back = try TestSupport.makeEntry(amount: 6_000_000, kind: .reimbursement)
    try repository.save(back)
    try stack.writer.write { db in
      try ReimbursementLink(
        reimbursementTxId: back.id, partId: entry.parts[0].id,
        amountE4: AmountE4(whole: 600)
      ).insert(db)
    }

    try repository.purge(id: entry.id)
    let parts = try stack.writer.read { db in try TransactionPart.fetchCount(db) }
    let links = try stack.writer.read { db in try ReimbursementLink.fetchCount(db) }
    #expect(parts == 1)  // only the reimbursement's own part is left
    #expect(links == 0)
  }

  /// Purging is the undo of an entry just typed. A debt payment moved its debt right after
  /// it was saved, and that movement goes too: the foreign key alone would only cut the
  /// link and leave the debt reduced by a payment that never happened.
  @Test func purgingADebtPaymentTakesItsMovementOffTheDebt() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let references = ReferenceRepository(writer: stack.writer)
    let loan = Debt(direction: .iOwe, type: .loan, name: "Bank loan", paymentsAreExpenses: true)
    try references.save(loan)
    let opening = DebtEntry(
      debtId: loan.id, date: DateOnly(year: 2026, month: 1, day: 10),
      amountE4: AmountE4(whole: 100_000), kind: .borrowed)
    try references.save(opening)
    var draft = TransactionDraft(amount: AmountE4(whole: 7_000), note: "loan", debtId: loan.id)
    draft.normalizeSinglePart()
    let payment = try draft.materialize()
    try repository.save(payment)
    try references.save(
      DebtEntry(
        debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 18),
        amountE4: AmountE4(whole: -7_000), kind: .payment, transactionId: payment.id))

    try repository.purge(id: payment.id)

    #expect(try repository.entry(id: payment.id) == nil)
    #expect(try references.debtEntries(debtId: loan.id) == [opening])
  }

  /// A debt's journal read on its own and read with the planning book comes in one order:
  /// by day, and the lines of one day as they were written. SQL leaves the ties of `ORDER BY
  /// date` to the plan — today's SQLite happens to hand them over in the order they were
  /// written, and neither reader relies on that any more.
  @Test func aDebtsJournalComesInOneOrderFromBothReaders() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let loan = Debt(direction: .iOwe, type: .loan, name: "Bank loan")
    try references.save(loan)
    let day = DateOnly(year: 2026, month: 9, day: 18)
    for whole in [100_000, -7_000, -3_000] {
      try references.save(
        DebtEntry(
          debtId: loan.id, date: day, amountE4: AmountE4(whole: Int64(whole)),
          kind: whole > 0 ? .borrowed : .payment))
    }

    let alone = try references.debtEntries(debtId: loan.id).map(\.amountE4)
    let inTheBook = try PlanningRepository(writer: stack.writer).book().debtEntries
      .filter { $0.debtId == loan.id }.map(\.amountE4)
    #expect(inTheBook == [100_000, -7_000, -3_000].map { AmountE4(whole: Int64($0)) })
    #expect(alone == inTheBook, "the two readers put the lines of one day in different orders")
  }

  @Test func archivedCategoriesCannotBeDeletedWhileAPartUsesThem() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 100))
    draft.parts = [PartDraft(categoryId: fixture.category.id, amount: AmountE4(whole: 100))]
    try repository.save(try draft.materialize())

    #expect(throws: (any Error).self) {
      try stack.writer.write { db in
        try db.execute(
          sql: "DELETE FROM categories WHERE id = ?", arguments: [fixture.category.id.uuidString])
      }
    }
  }

  /// A build whose `Schema/` no longer holds a migration the database has already run
  /// must refuse to open it, not write into a schema it cannot see.
  @Test func openingADatabaseMigratedBeyondTheKnownSchemaIsRefused() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = stack.url
    #expect(try stack.appliedMigrations() == TestSupport.schemaSource.migrations().map(\.name))

    #expect(throws: AppDatabase.DatabaseError.self) {
      _ = try DatabaseStack(url: url, schema: FixedSchemaSource(all: []))
    }
  }

  @Test func renamingAMigrationFileIsCaught() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = stack.url
    let renamed = try TestSupport.schemaSource.migrations().map {
      SchemaMigration(name: "0002_" + $0.name, sql: $0.sql)
    }

    #expect(throws: AppDatabase.DatabaseError.self) {
      _ = try DatabaseStack(url: url, schema: FixedSchemaSource(all: renamed))
    }
  }

  @Test func reopeningTheSameSchemaChangesNothing() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(try TestSupport.makeEntry(note: "kept"))
    let url = stack.url

    let reopened = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    #expect(try reopened.appliedMigrations() == TestSupport.schemaSource.migrations().map(\.name))
    #expect(try TransactionRepository(writer: reopened.writer).count() == 1)
  }

  @Test func aBackupIsAnIndependentDatabaseAndTheOriginalKeepsWorking() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(try TestSupport.makeEntry(note: "before the backup"))

    let copyURL = directory.appendingPathComponent("backups/snapshot.sqlite")
    try stack.backup(to: copyURL)
    #expect(try stack.integrityCheckPassed())
    #expect(FileManager.default.fileExists(atPath: copyURL.path))

    // The original keeps taking writes.
    try repository.save(try TestSupport.makeEntry(note: "after the backup"))
    #expect(try repository.count() == 2)

    let copy = try DatabaseStack(url: copyURL, schema: TestSupport.schemaSource)
    let copied = TransactionRepository(writer: copy.writer)
    #expect(try copied.count() == 1)
    #expect(try copied.recentEntries().first?.transaction.note == "before the backup")
    #expect(try copy.integrityCheckPassed())
    #expect(try copy.appliedMigrations() == TestSupport.schemaSource.migrations().map(\.name))

    // Writing into the copy leaves the original alone.
    try copied.save(try TestSupport.makeEntry(note: "only in the copy"))
    #expect(try copied.count() == 2)
    #expect(try repository.count() == 2)
    #expect(
      try repository.recentEntries().map(\.transaction.note).contains("only in the copy")
        == false)
  }

  /// Opening a snapshot to check it leaves a `-wal` beside it. The next backup replaces
  /// the file, and the leftover must not be able to resurrect what used to be there.
  @Test func aBackupOverAnOpenedSnapshotDoesNotInheritItsWal() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(try TestSupport.makeEntry(note: "one"))
    let copyURL = directory.appendingPathComponent("backups/snapshot.sqlite")
    try stack.backup(to: copyURL)

    // The owner opens the snapshot to look at it, which puts it into WAL mode, and even
    // writes into it.
    let opened = try DatabaseStack(url: copyURL, schema: TestSupport.schemaSource)
    try TransactionRepository(writer: opened.writer)
      .save(try TestSupport.makeEntry(note: "only in the snapshot"))
    #expect(try TransactionRepository(writer: opened.writer).count() == 2)

    try repository.save(try TestSupport.makeEntry(note: "two"))
    try stack.backup(to: copyURL)

    let reopened = try DatabaseStack(url: copyURL, schema: TestSupport.schemaSource)
    let notes = try TransactionRepository(writer: reopened.writer)
      .recentEntries().map(\.transaction.note)
    #expect(Set(notes) == ["one", "two"])
    #expect(try reopened.integrityCheckPassed())
  }

  @Test func everyExportedTableExistsInTheSchema() throws {
    let stack = try TestSupport.makeStack()
    let tables = try stack.writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    let exported = try ExportRepository(writer: stack.writer).rowCounts()
    #expect(exported.isEmpty == false)
    #expect(exported.keys.allSatisfy(Set(tables).contains))
    #expect(exported.values.allSatisfy { $0 == 0 })
  }

  @Test func aBackupTakenTwiceOverwritesTheOlderSnapshot() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = TransactionRepository(writer: stack.writer)
    try repository.save(try TestSupport.makeEntry(note: "one"))
    let copyURL = directory.appendingPathComponent("backups/snapshot.sqlite")
    try stack.backup(to: copyURL)

    try repository.save(try TestSupport.makeEntry(note: "two"))
    try stack.backup(to: copyURL)

    let copy = try DatabaseStack(url: copyURL, schema: TestSupport.schemaSource)
    #expect(try TransactionRepository(writer: copy.writer).count() == 2)
    #expect(try copy.integrityCheckPassed())
  }

  /// What the transfer archive carries — the copy, the CSV tables and their row counts — comes
  /// from one read: the counts are those of the copy written and of the files returned.
  @Test func theSnapshotOfAnArchiveCountsTheCopyItWritesAndTheFilesItReturns() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try TransactionRepository(writer: stack.writer).save(try TestSupport.makeEntry(note: "one"))
    let url = directory.appendingPathComponent("archive/snapshot.sqlite")

    let snapshot = try ExportRepository(writer: stack.writer).snapshot(to: url)

    #expect(snapshot.rowCounts["transactions"] == 1)
    #expect(snapshot.tables.map(\.fileName) == ExportTables.all.map(\.fileName))
    for table in snapshot.tables {
      let rows = try CSVReader.rows(from: table.data)
      #expect(rows.count - 1 == snapshot.rowCounts[table.name], "\(table.name)")
    }
    let copy = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    #expect(try ExportRepository(writer: copy.writer).rowCounts() == snapshot.rowCounts)
    #expect(try copy.integrityCheckPassed())
  }

  /// The check of a copy looks at the copy. `integrityCheckPassed()` asks the live database,
  /// which says nothing about a file that was cut short or is not a database at all.
  @Test func aCopyIsCheckedByItselfNotByTheDatabaseItCameFrom() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try TransactionRepository(writer: stack.writer).save(try TestSupport.makeEntry(note: "one"))
    let copyURL = directory.appendingPathComponent("backups/snapshot.sqlite")
    try stack.backup(to: copyURL)
    #expect(DatabaseStack.integrityCheckPassed(at: copyURL))

    // Cut short, the way a copy ends on a full disk.
    let whole = try Data(contentsOf: copyURL)
    try whole.prefix(whole.count / 2).write(to: copyURL)
    #expect(DatabaseStack.integrityCheckPassed(at: copyURL) == false)
    #expect(try stack.integrityCheckPassed(), "the live database is fine all along")

    try Data("not a database at all".utf8).write(to: copyURL)
    #expect(DatabaseStack.integrityCheckPassed(at: copyURL) == false)

    #expect(
      DatabaseStack.integrityCheckPassed(at: directory.appendingPathComponent("gone.sqlite"))
        == false)
  }

  /// An empty file opens as an empty database, and `PRAGMA integrity_check` calls an empty
  /// database «ok». A copy of the owner's database always has tables, so an empty one is not
  /// a copy.
  @Test func anEmptyFileIsNotACopy() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-db-tests").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appendingPathComponent("empty.sqlite")
    FileManager.default.createFile(atPath: empty.path, contents: Data())

    #expect(DatabaseStack.integrityCheckPassed(at: empty) == false)
  }

  /// A database this build refuses to open — a newer build migrated it — is still copied whole
  /// before a restore replaces it, without a migration applied or a row written; a file SQLite
  /// cannot read at all says so by throwing.
  @Test func aDatabaseThisBuildDoesNotOpenIsCopiedAsItIs() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try TransactionRepository(writer: stack.writer).save(try TestSupport.makeEntry(note: "one"))
    try stack.close()
    let future = FixedSchemaSource(
      all: try TestSupport.schemaSource.migrations() + [
        SchemaMigration(name: "9999_future", sql: "CREATE TABLE future_things (id INTEGER)")
      ])
    try DatabaseStack(url: stack.url, schema: future).close()
    #expect(throws: AppDatabase.DatabaseError.self) {
      _ = try DatabaseStack(url: stack.url, schema: TestSupport.schemaSource)
    }

    let copyURL = directory.appendingPathComponent("backups/before-restore.sqlite")
    try DatabaseStack.backup(fileAt: stack.url, to: copyURL)

    let copy = try DatabaseStack(url: copyURL, schema: future)
    #expect(try TransactionRepository(writer: copy.writer).count() == 1)
    #expect(try copy.appliedMigrations().contains("9999_future"))

    let garbage = directory.appendingPathComponent("garbage.sqlite")
    try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: garbage)
    #expect(throws: (any Error).self) {
      try DatabaseStack.backup(
        fileAt: garbage, to: directory.appendingPathComponent("backups/garbage.sqlite"))
    }
  }

  /// A file about to take the place of the database is checked by the rules its opening will
  /// apply: the integrity check alone lets a sound database of a newer build through, and this
  /// build refuses to open that one only after the database it replaced is gone.
  @Test func aFileIsCheckedByTheRulesItsOpeningWillApply() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sound = directory.appendingPathComponent("backups/sound.sqlite")
    try stack.backup(to: sound)
    #expect(try DatabaseStack.check(fileAt: sound, schema: TestSupport.schemaSource) == .sound)

    let future = FixedSchemaSource(
      all: try TestSupport.schemaSource.migrations() + [
        SchemaMigration(name: "9999_future", sql: "CREATE TABLE future_things (id INTEGER)")
      ])
    try DatabaseStack(url: sound, schema: future).close()
    let newer = directory.appendingPathComponent("backups/newer.sqlite")
    try DatabaseStack.backup(fileAt: sound, to: newer)
    #expect(DatabaseStack.integrityCheckPassed(at: newer), "sound, as far as SQLite can tell")
    #expect(
      try DatabaseStack.check(fileAt: newer, schema: TestSupport.schemaSource) == .newerSchema)
    #expect(try DatabaseStack.check(fileAt: newer, schema: future) == .sound)

    let garbage = directory.appendingPathComponent("garbage.sqlite")
    try Data("not a database at all".utf8).write(to: garbage)
    #expect(
      try DatabaseStack.check(fileAt: garbage, schema: TestSupport.schemaSource) == .damaged)
    let gone = directory.appendingPathComponent("gone.sqlite")
    #expect(try DatabaseStack.check(fileAt: gone, schema: TestSupport.schemaSource) == .damaged)
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!left.contains { $0.hasPrefix("garbage.sqlite-") || $0.hasPrefix("gone.sqlite") })
  }

  /// A check that left a `-wal` or a `-shm` beside the copy would hand the next file of that
  /// name a log that is not its own. The folder is left as it was found.
  @Test func checkingACopyLeavesNothingBesideIt() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = directory.appendingPathComponent("backups", isDirectory: true)
    let copyURL = folder.appendingPathComponent("snapshot.sqlite")
    try stack.backup(to: copyURL)

    #expect(DatabaseStack.integrityCheckPassed(at: copyURL))
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(left == ["snapshot.sqlite"])
  }
}

@Suite("Settings keep the order the owner chose")
struct SettingsOrderTests {
  @Test func enabledCurrenciesComeBackInTheOrderTheyWereSet() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    let chosen = [CurrencyCode("RUB"), CurrencyCode("THB"), CurrencyCode("USD")]
    try settings.setEnabledCurrencies(chosen)
    #expect(try settings.enabledCurrencies() == chosen)

    // Re-ordering replaces the old order instead of adding to it.
    let reordered = [CurrencyCode("USD"), CurrencyCode("RUB")]
    try settings.setEnabledCurrencies(reordered)
    #expect(try settings.enabledCurrencies() == reordered)
  }

  /// There is no limit any more: twelve currencies are twelve on, in their order.
  @Test func everyCurrencyChosenIsKeptOn() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    // The ruble is the default currency, which stays on.
    let twelve = [CurrencyCode.rub] + (1...11).map { CurrencyCode("C\($0)") }
    try settings.setEnabledCurrencies(twelve)
    #expect(try settings.enabledCurrencies() == twelve)
  }
}

@Suite("Rates: one by hand or imported wins over the bank's, and every source keeps its row")
struct RateRepositoryTests {
  /// A rate entered by hand must not be pushed aside by the one the bank published for
  /// the same day, whichever of the two landed in the table first.
  @Test func aManualRateWinsOverTheBankRateForTheSameDay() throws {
    for manualFirst in [true, false] {
      let stack = try TestSupport.makeStack()
      let repository = RateRepository(writer: stack.writer)
      let day = DateOnly(year: 2026, month: 9, day: 18)
      let bank = Rate(
        date: day, currency: .usd, rubPerUnit: Decimal(string: "81.43")!, source: .cbr)
      let byHand = Rate(
        date: day, currency: .usd, rubPerUnit: Decimal(string: "90.5")!, source: .manual)
      try repository.save(manualFirst ? [byHand, bank] : [bank, byHand])

      let chosen = try #require(try repository.rate(for: .usd, on: day))
      #expect(chosen.source == .manual)
      #expect(chosen.rubPerUnit == byHand.rubPerUnit)
    }
  }

  @Test func anImportedRateAlsoWinsOverTheBank() throws {
    let stack = try TestSupport.makeStack()
    let repository = RateRepository(writer: stack.writer)
    let day = DateOnly(year: 2026, month: 9, day: 18)
    try repository.save([
      Rate(date: day, currency: .usd, rubPerUnit: Decimal(string: "81.43")!, source: .cbr),
      Rate(date: day, currency: .usd, rubPerUnit: Decimal(string: "80")!, source: .imported),
    ])

    let chosen = try #require(try repository.rate(for: .usd, on: day))
    #expect(chosen.source == .imported)
  }

  @Test func theBankItselfWinsOverItsMirror() throws {
    let stack = try TestSupport.makeStack()
    let repository = RateRepository(writer: stack.writer)
    let day = DateOnly(year: 2026, month: 9, day: 18)
    try repository.save([
      Rate(
        date: day, currency: .usd, rubPerUnit: Decimal(string: "81.40")!, source: .cbrMirror),
      Rate(date: day, currency: .usd, rubPerUnit: Decimal(string: "81.43")!, source: .cbr),
    ])

    let chosen = try #require(try repository.rate(for: .usd, on: day))
    #expect(chosen.source == .cbr)
    #expect(chosen.rubPerUnit == Decimal(string: "81.43")!)
  }

  /// The four sources live in the same primary key, so nothing is ever overwritten.
  @Test func everySourceKeepsItsOwnRowForTheSameDay() throws {
    let stack = try TestSupport.makeStack()
    let repository = RateRepository(writer: stack.writer)
    let day = DateOnly(year: 2026, month: 9, day: 18)
    let sources: [RateSource] = [.cbr, .cbrMirror, .manual, .imported]
    try repository.save(
      sources.map {
        Rate(date: day, currency: .usd, rubPerUnit: Decimal(string: "81.43")!, source: $0)
      })

    #expect(try repository.rates(for: .usd).count == 4)
  }

  /// A protected rate for an older day must not shadow the bank rate of a newer one.
  @Test func theNewerDayStillWinsOverAnOlderManualRate() throws {
    let stack = try TestSupport.makeStack()
    let repository = RateRepository(writer: stack.writer)
    try repository.save([
      Rate(
        date: DateOnly(year: 2026, month: 9, day: 17), currency: .usd,
        rubPerUnit: Decimal(string: "90.5")!, source: .manual),
      Rate(
        date: DateOnly(year: 2026, month: 9, day: 18), currency: .usd,
        rubPerUnit: Decimal(string: "81.43")!, source: .cbr),
    ])

    let chosen = try #require(
      try repository.rate(for: .usd, on: DateOnly(year: 2026, month: 9, day: 19)))
    #expect(chosen.date == DateOnly(year: 2026, month: 9, day: 18))
    #expect(chosen.source == .cbr)
  }

  /// What the bank said about a day it published nothing on outlives the session: the day is
  /// not asked about again on the next launch, and the table reads it.
  @Test func aDayTheBankAnsweredForWithAnEarlierOneIsKept() throws {
    let stack = try TestSupport.makeStack()
    let repository = RateRepository(writer: stack.writer)
    let saturday = DateOnly(year: 2026, month: 9, day: 19)
    let sunday = DateOnly(year: 2026, month: 9, day: 20)
    let monday = DateOnly(year: 2026, month: 9, day: 21)
    try repository.save([
      Rate(date: saturday, currency: .usd, rubPerUnit: Decimal(string: "82.77")!, source: .cbr)
    ])
    #expect(try repository.table().needsFetch(currency: .usd, on: sunday))

    try repository.noteUnpublished(monday, holding: saturday)
    try repository.noteUnpublished(sunday, holding: saturday)
    try repository.noteUnpublished(sunday, holding: saturday)
    // Nonsense is not kept: a publication is always before the day it holds on.
    try repository.noteUnpublished(saturday, holding: sunday)

    let reopened = RateRepository(writer: stack.writer)
    #expect(try reopened.unpublishedDays() == [sunday: saturday, monday: saturday])
    let table = try reopened.table()
    #expect(!table.needsFetch(currency: .usd, on: sunday))
    #expect(table.resolve(.usd, on: monday)?.isProvisional == false)
    #expect(
      try SettingsRepository(writer: stack.writer).string(RateRepository.unpublishedDaysKey)
        == "2026-09-20>2026-09-19,2026-09-21>2026-09-19")
  }

  @Test func aDamagedListOfDaysOffOnlyLosesTheDamagedPairs() {
    let days = RateRepository.decodeUnpublishedDays(
      "2026-09-20>2026-09-19,garbage,2026-09-22>2026-09-23,2026-01-05>2025-12-31,")
    #expect(
      days == [
        DateOnly(year: 2026, month: 9, day: 20): DateOnly(year: 2026, month: 9, day: 19),
        DateOnly(year: 2026, month: 1, day: 5): DateOnly(year: 2025, month: 12, day: 31),
      ])
    #expect(RateRepository.decodeUnpublishedDays(nil).isEmpty)
  }
}
