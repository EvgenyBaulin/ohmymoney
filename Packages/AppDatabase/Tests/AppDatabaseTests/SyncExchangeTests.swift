import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

@Suite("Changes of the books go out as journal files and come in from other devices")
struct SyncRecordingTests {
  @Test func nothingIsRecordedUntilTheAppTurnsRecordingOn() throws {
    let device = try TestDevice("mac", recording: false)
    try device.insertOperation("t1", note: "coffee")
    #expect(try device.outboxCount() == 0)
    #expect(device.exchange.isRecording == false)
  }

  @Test func aGeneratedDataSetWritesNoJournal() throws {
    // A data set is generated into a database nobody turned recording on for.
    let device = try TestDevice("mac", recording: false)
    try device.insertOperation("t1", note: "coffee")
    let folder = InMemoryFolder()
    let outcome = try device.exchange.exchange(with: folder)
    #expect(outcome.entriesWritten == 0)
    #expect(try folder.listNames().isEmpty)
  }

  @Test func writeEditAndDeleteAreRecordedWithTheirCascade() throws {
    let device = try TestDevice("mac")
    try device.insertOperation("t1", note: "coffee")
    #expect(try device.outboxCount() == 2)  // the operation and its part
    try device.sql("DELETE FROM sync_outbox")
    try device.setNote("t1", "tea")
    #expect(try device.outboxCount() == 1)
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("DELETE FROM transactions WHERE id = 't1'")
    #expect(try device.outboxCount() == 2)  // the operation and the part that went with it
  }

  @Test func theTablesThatTravelAreExactlyTheTablesWithTriggers() throws {
    let device = try TestDevice("mac")
    try device.stack.writer.read { db in
      let triggered = Set(
        try String.fetchAll(
          db,
          sql:
            "SELECT DISTINCT tbl_name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync\\_%' ESCAPE '\\'"
        ))
      #expect(triggered == Set(SyncTables.followed.keys))
      for table in SyncTables.followed.keys {
        let names = try String.fetchAll(
          db,
          sql:
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? AND name LIKE 'sync\\_%' ESCAPE '\\'",
          arguments: [table])
        #expect(names.count == 3, "\(table)")
        let pk = try db.primaryKey(table).columns
        #expect(pk == [SyncTables.followed[table]!], "\(table)")
      }
      // A new table must be decided on: followed, or deliberately left out.
      let all = Set(
        try String.fetchAll(
          db,
          sql:
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE 'grdb\\_%' ESCAPE '\\'"
        ))
      let leftOut: Set<String> = [
        "settings", "rates", "ml_models", "category_feedback", "identity_items",
      ]
      #expect(
        all.subtracting(SyncTables.followed.keys).subtracting(SyncTables.bookkeeping) == leftOut)
    }
  }

  @Test func theEntryCarriesTheWholeRowAndItsBase() throws {
    let device = try TestDevice("mac")
    let folder = InMemoryFolder()
    try device.insertOperation("t1", note: "coffee", amount: 2_500_000)
    try device.stamp("2026-10-22T10:00:05Z")
    #expect(try device.exchange.flush(to: folder) == 2)
    #expect(try device.outboxCount() == 0)
    let first = try JournalCoder.decode(
      try folder.read(name: SyncFormat.fileName(deviceId: "mac", sequence: 0)))
    let operation = try #require(first.entries.first { $0.table == "transactions" })
    #expect(operation.op == .created)
    #expect(operation.base == nil)
    #expect(operation.fields["amount_e4"] == .int(2_500_000))
    #expect(operation.fields["note"] == .string("coffee"))
    #expect(operation.fields["deleted_at"] == .null)
    #expect(operation.updatedAt.text == "2026-10-22T10:00:05Z")

    // Two edits before the next file are one change; it is built on the version just written.
    try device.setNote("t1", "tea")
    try device.setNote("t1", "tea with milk")
    try device.stamp("2026-10-22T10:01:00Z")
    #expect(try device.exchange.flush(to: folder) == 1)
    let second = try JournalCoder.decode(
      try folder.read(name: SyncFormat.fileName(deviceId: "mac", sequence: 1)))
    #expect(second.entries.count == 1)
    #expect(second.entries[0].op == .updated)
    #expect(second.entries[0].fields["note"] == .string("tea with milk"))
    #expect(
      second.entries[0].base == VersionStamp(updatedAt: operation.updatedAt, deviceId: "mac"))
  }

  @Test func ownEditsInTheSameSecondStillOrder() throws {
    let device = try TestDevice("mac")
    let folder = InMemoryFolder()
    try device.insertOperation("t1", note: "a")
    try device.stamp("2026-10-22T10:00:05Z")
    try device.exchange.flush(to: folder)
    try device.setNote("t1", "b")
    try device.stamp("2026-10-22T10:00:05Z")
    try device.exchange.flush(to: folder)
    let second = try JournalCoder.decode(
      try folder.read(name: SyncFormat.fileName(deviceId: "mac", sequence: 1)))
    #expect(second.entries[0].updatedAt.text == "2026-10-22T10:00:06Z")
  }

  @Test func aSoftDeleteAndAHardDeleteAreDeletesOfTheirOwnKind() throws {
    let device = try TestDevice("mac")
    let folder = InMemoryFolder()
    try device.insertOperation("t1", note: "a")
    try device.insertOperation("t2", note: "b")
    try device.exchange.flush(to: folder)
    try device.sql(
      "UPDATE transactions SET deleted_at = '2026-10-22 10:00:00.000' WHERE id = 't1'")
    try device.sql("DELETE FROM transactions WHERE id = 't2'")
    try device.exchange.flush(to: folder)
    let file = try JournalCoder.decode(
      try folder.read(name: SyncFormat.fileName(deviceId: "mac", sequence: 1)))
    let soft = try #require(file.entries.first { $0.uuid == "t1" })
    #expect(soft.op == .deleted)
    #expect(soft.fields["note"] == .string("a"), "a soft delete carries the row as it stands")
    let hard = try #require(file.entries.first { $0.uuid == "t2" })
    #expect(hard.op == .deleted && hard.fields.isEmpty)
  }

  @Test func aFolderThatRefusesTheFileLeavesTheOutboxAsItWas() throws {
    let device = try TestDevice("mac")
    let folder = FlakyFolder()
    try device.insertOperation("t1", note: "a")
    folder.mode = .cannotWrite
    #expect(throws: SyncFailure.folderNotWritable) { try device.exchange.exchange(with: folder) }
    #expect(try device.outboxCount() == 2)
    #expect(try folder.base.listNames().isEmpty)
    folder.mode = .ok
    let outcome = try device.exchange.exchange(with: folder)
    #expect(outcome.entriesWritten == 2)
    #expect(try device.outboxCount() == 0)
  }
}

@Suite("Another device's files change this database, once and in any order")
struct SyncApplyTests {
  @Test func anOperationWrittenOnOneDeviceReadsTheSameOnTheOther() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "coffee", amount: 2_500_000)
    _ = try mac.exchange.exchange(with: folder)
    let outcome = try phone.exchange.exchange(with: folder)
    #expect(outcome.recordsApplied == 2)
    #expect(outcome.filesApplied == 1)
    #expect(try phone.books() == mac.books())
    #expect(try phone.outboxCount() == 0, "what came in is not written out again")
    #expect(try folder.listNames() == [SyncFormat.fileName(deviceId: "mac", sequence: 0)])
  }

  @Test func theSecondExchangeChangesNothing() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "coffee")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    let before = try phone.books()
    let again = try phone.exchange.exchange(with: folder)
    #expect(again.filesApplied == 0 && again.recordsApplied == 0 && again.entriesWritten == 0)
    #expect(try phone.books() == before)
  }

  @Test func anEditBuiltOnWhatTheOtherDeviceHasIsTakenNotAConflict() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "coffee")
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.setNote("t1", "coffee with milk")
    try phone.stamp("2026-10-22T10:05:00Z")
    _ = try phone.exchange.exchange(with: folder)
    let outcome = try mac.exchange.exchange(with: folder)
    #expect(outcome.conflictsOpen == 0)
    #expect(try mac.note("t1") == "coffee with milk")
  }

  @Test func theSameFilesInAnyOrderGiveTheSameBooks() throws {
    let source = try TestDevice("mac")
    let folder = InMemoryFolder()
    try source.insertOperation("t1", note: "a")
    try source.stamp("2026-10-22T10:00:00Z")
    _ = try source.exchange.exchange(with: folder)
    try source.setNote("t1", "b")
    try source.insertOperation("t2", note: "c")
    try source.stamp("2026-10-22T10:01:00Z")
    _ = try source.exchange.exchange(with: folder)
    try source.sql("DELETE FROM transactions WHERE id = 't1'")
    try source.stamp("2026-10-22T10:02:00Z")
    _ = try source.exchange.exchange(with: folder)

    // One device sees the files one at a time, in order; another sees the last two first.
    let names = try folder.listNames()
    #expect(names.count == 3)
    func view(_ order: [[String]]) throws -> TestDevice {
      let device = try TestDevice("phone")
      let seen = InMemoryFolder()
      for batch in order {
        for name in batch { seen.plant(name: name, data: try folder.read(name: name)) }
        _ = try device.exchange.exchange(with: seen)
      }
      return device
    }
    let inOrder = try view([[names[0]], [names[1]], [names[2]]])
    let lastFirst = try view([[names[2], names[1]], [names[0]]])
    let allAtOnce = try view([names])
    #expect(try inOrder.books() == source.books())
    #expect(try lastFirst.books() == source.books())
    #expect(try allAtOnce.books() == source.books())
  }

  @Test func aPartMayComeBeforeItsOperation() throws {
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    let at = SyncInstant("2026-10-22T10:00:00Z")!
    let part = SyncEntry(
      table: "transaction_parts", uuid: "p1", op: .created,
      fields: [
        "id": .string("p1"), "transaction_id": .string("t1"), "amount_e4": .int(10),
        "amount_rub_e4": .int(10), "for_whom": .string("me"),
        "category_source": .string("manual"), "reimbursable": .int(0),
      ], updatedAt: at)
    let operation = SyncEntry(
      table: "transactions", uuid: "t1", op: .created,
      fields: [
        "id": .string("t1"), "kind": .string("expense"),
        "occurred_at": .string("2026-10-20 10:00:00.000"), "currency": .string("RUB"),
        "amount_e4": .int(10), "amount_rub_e4": .int(10),
        "created_at": .string("2026-10-20 10:00:00.000"),
        "updated_at": .string("2026-10-20 10:00:00.000"), "rate_provisional": .int(0),
      ], updatedAt: at)
    try JournalWriter(deviceId: "mac", deviceName: "Mac").write([part, operation], to: folder)
    let outcome = try phone.exchange.exchange(with: folder)
    #expect(outcome.recordsApplied == 2)
    #expect(try phone.count("transaction_parts") == 1)
  }

  @Test func aKeyThatPointsNowhereStopsTheBatchAndNothingIsHalfApplied() throws {
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    let at = SyncInstant("2026-10-22T10:00:00Z")!
    let part = SyncEntry(
      table: "transaction_parts", uuid: "p1", op: .created,
      fields: [
        "id": .string("p1"), "transaction_id": .string("missing"), "amount_e4": .int(10),
        "amount_rub_e4": .int(10),
      ], updatedAt: at)
    try JournalWriter(deviceId: "mac", deviceName: "Mac").write([part], to: folder)
    #expect(throws: SyncFailure.database) { try phone.exchange.exchange(with: folder) }
    #expect(try phone.count("transaction_parts") == 0)
    #expect(try phone.count("sync_state") == 0, "the file is not remembered as applied")
    // The operation arrives in a later file: the same exchange now succeeds.
    let operation = SyncEntry(
      table: "transactions", uuid: "missing", op: .created,
      fields: [
        "id": .string("missing"), "kind": .string("expense"),
        "occurred_at": .string("2026-10-20 10:00:00.000"), "currency": .string("RUB"),
        "amount_e4": .int(10), "amount_rub_e4": .int(10),
        "created_at": .string("2026-10-20 10:00:00.000"),
        "updated_at": .string("2026-10-20 10:00:00.000"), "rate_provisional": .int(0),
      ], updatedAt: at)
    try JournalWriter(deviceId: "tablet", deviceName: "Tablet").write([operation], to: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("transaction_parts") == 1)
  }

  @Test func aRowThatBreaksARuleIsPutOffAlone() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    // Both devices made an operation with the same external key — a rule of the books.
    try phone.sql(
      """
      INSERT INTO transactions (id, kind, occurred_at, amount_e4, amount_rub_e4, external_id,
        created_at, updated_at)
      VALUES ('local', 'expense', '2026-10-20', 1, 1, 'sched:x', '2026-10-20', '2026-10-20')
      """)
    try phone.sql("DELETE FROM sync_outbox")
    try mac.sql(
      """
      INSERT INTO transactions (id, kind, occurred_at, amount_e4, amount_rub_e4, external_id,
        created_at, updated_at)
      VALUES ('remote', 'expense', '2026-10-20', 1, 1, 'sched:x', '2026-10-20', '2026-10-20')
      """)
    try mac.insertOperation("fine", note: "ok")
    _ = try mac.exchange.exchange(with: folder)
    let outcome = try phone.exchange.exchange(with: folder)
    #expect(outcome.deferred == 1)
    #expect(try phone.note("fine") == "ok", "the other rows of the batch were taken")
    #expect(try phone.count("transactions") == 2)
    // Offered again, still put off, nothing lost and nothing duplicated.
    let again = try phone.exchange.exchange(with: folder)
    #expect(again.deferred == 1)
    #expect(try phone.count("transactions") == 2)
  }

  @Test func aRowWithAWaitingEditOfMineIsNotOverwritten() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "a")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.setNote("t1", "from mac")
    _ = try mac.exchange.exchange(with: folder)
    // The phone edits the row between its flush and the batch coming in.
    try phone.setNote("t1", "from phone")
    var state = try DatabaseSyncStateStore(writer: phone.stack.writer).load()
    for name in try folder.listNames() {
      let data = try folder.read(name: name)
      state.appliedForTest(try JournalCoder.decode(data), name: name, bytes: data)
    }
    let record = try #require(state.resolve(RecordKey(table: "transactions", uuid: "t1")))
    let applier = DatabaseRecordApplier(writer: phone.stack.writer, ownDeviceId: "phone")
    try applier.apply([record])
    #expect(applier.takeTally().deferred == 1)
    #expect(try phone.note("t1") == "from phone")
    #expect(try phone.outboxCount() == 1, "the edit of mine still waits for its file")
  }
}

extension SyncState {
  /// Test hook: ingest without the engine.
  fileprivate mutating func appliedForTest(_ file: JournalFile, name: String, bytes: Data) {
    _ = try? ingest(file, name: name, bytes: bytes)
  }
}

@Suite("A change made apart waits for the owner (0518)")
struct SyncConflictFlowTests {
  /// Both devices hold the same operation; then each edits it before seeing the other.
  private func apart() throws -> (mac: TestDevice, phone: TestDevice, folder: InMemoryFolder) {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "coffee", amount: 2_500_000)
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.sql("UPDATE transactions SET note = 'coffee 250', amount_e4 = 2500000 WHERE id = 't1'")
    try mac.stamp("2026-10-22T10:05:00Z")
    try phone.sql(
      "UPDATE transactions SET note = 'coffee 300', amount_e4 = 3000000, amount_rub_e4 = 3000000 WHERE id = 't1'"
    )
    try phone.stamp("2026-10-22T10:06:00Z")
    return (mac, phone, folder)
  }

  @Test func theOtherSideWaitsAndTheSumsKeepMyVersion() throws {
    let (mac, phone, folder) = try apart()
    _ = try mac.exchange.exchange(with: folder)
    let outcome = try phone.exchange.exchange(with: folder)
    #expect(outcome.conflictsOpen == 1)
    // The phone's version is the later one, yet the phone keeps its own and the Mac its own.
    #expect(try phone.note("t1") == "coffee 300")
    let macOutcome = try mac.exchange.exchange(with: folder)
    #expect(macOutcome.conflictsOpen == 1)
    #expect(try mac.note("t1") == "coffee 250")
    let amount = try mac.stack.writer.read { db in
      try Int64.fetchOne(db, sql: "SELECT amount_rub_e4 FROM transactions WHERE id = 't1'")
    }
    #expect(amount == 2_500_000, "the other side's amount is in no sum")
  }

  @Test func theListShowsWhatDiffers() throws {
    let (mac, phone, folder) = try apart()
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    let conflict = try #require(phone.exchange.conflicts().first)
    #expect(conflict.key == RecordKey(table: "transactions", uuid: "t1"))
    #expect(conflict.mine.fields["note"] == .string("coffee 300"))
    #expect(conflict.theirs.fields["note"] == .string("coffee 250"))
    #expect(conflict.differingFields.contains("note"))
    #expect(conflict.differingFields.contains("amount_rub_e4"))
    #expect(!conflict.mine.isDeleted && !conflict.theirs.isDeleted)
  }

  @Test func keepingMineSettlesItOnBothDevices() throws {
    let (mac, phone, folder) = try apart()
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    let key = RecordKey(table: "transactions", uuid: "t1")
    try phone.exchange.keepMine(key)
    #expect(try phone.exchange.conflicts().isEmpty, "answered at once, before any file")
    _ = try phone.exchange.exchange(with: folder)
    let outcome = try mac.exchange.exchange(with: folder)
    #expect(outcome.conflictsOpen == 0)
    #expect(try mac.note("t1") == "coffee 300", "the Mac now has the phone's version")
    #expect(try phone.note("t1") == "coffee 300")
    #expect(try phone.exchange.conflicts().isEmpty)
    #expect(try mac.books() == phone.books())
  }

  @Test func takingTheirsChangesTheRowAndSettlesItEverywhere() throws {
    let (mac, phone, folder) = try apart()
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    let key = RecordKey(table: "transactions", uuid: "t1")
    try phone.exchange.takeTheirs(key)
    #expect(try phone.note("t1") == "coffee 250")
    _ = try phone.exchange.exchange(with: folder)
    let outcome = try mac.exchange.exchange(with: folder)
    #expect(outcome.conflictsOpen == 0)
    #expect(try mac.note("t1") == "coffee 250")
    #expect(try mac.books() == phone.books())
    #expect(try phone.exchange.conflicts().isEmpty)
  }

  @Test func choosingForARowThatIsNotInConflictIsRefused() throws {
    let phone = try TestDevice("phone")
    #expect(throws: SyncChoiceError.notInConflict) {
      try phone.exchange.keepMine(RecordKey(table: "transactions", uuid: "none"))
    }
  }

  @Test func theSameChangeMadeOnBothDevicesIsSettledWithoutAsking() throws {
    let (mac, phone, folder) = try apart()
    try mac.setNote("t1", "same")
    try phone.setNote("t1", "same")
    try mac.sql(
      "UPDATE transactions SET amount_e4 = 5, amount_rub_e4 = 5, updated_at = 'u' WHERE id = 't1'")
    try phone.sql(
      "UPDATE transactions SET amount_e4 = 5, amount_rub_e4 = 5, updated_at = 'u' WHERE id = 't1'")
    try mac.stamp("2026-10-22T10:07:00Z")
    try phone.stamp("2026-10-22T10:08:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try mac.exchange.exchange(with: folder)  // the smaller id answers
    _ = try phone.exchange.exchange(with: folder)
    #expect(try mac.exchange.conflicts().isEmpty)
    #expect(try phone.exchange.conflicts().isEmpty)
    // And it stays settled: nothing is written once the two agree.
    let before = try folder.listNames()
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try folder.listNames() == before)
  }

  @Test func aDeleteMadeApartFromAnEditIsAConflictToo() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "coffee")
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.setNote("t1", "edited")
    try mac.stamp("2026-10-22T10:05:00Z")
    try phone.sql("UPDATE transactions SET deleted_at = '2026-10-22 10:06:00.000' WHERE id = 't1'")
    try phone.stamp("2026-10-22T10:06:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try mac.exchange.exchange(with: folder)
    let conflict = try #require(mac.exchange.conflicts().first)
    #expect(conflict.theirs.isDeleted && !conflict.mine.isDeleted)
    #expect(try mac.note("t1") == "edited")
    let alive = try mac.stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT deleted_at FROM transactions WHERE id = 't1'")
    }
    #expect(alive == nil, "the delete is not applied until the owner says so")
  }
}

@Suite("Failures of the exchange are named and lose nothing")
struct SyncFailureTests {
  @Test func aMissingFolderIsNamed() throws {
    let device = try TestDevice("mac")
    let folder = FlakyFolder()
    folder.mode = .missing
    try device.insertOperation("t1", note: "a")
    #expect(throws: SyncFailure.folderMissing) { try device.exchange.exchange(with: folder) }
    #expect(try device.outboxCount() == 2)
  }

  @Test func anUnreadableFolderIsNamed() throws {
    let device = try TestDevice("mac")
    let folder = FlakyFolder()
    folder.mode = .cannotRead
    #expect(throws: SyncFailure.folderNotReadable) { try device.exchange.exchange(with: folder) }
  }

  @Test func aTornFileIsLeftAloneAndCounted() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "a")
    _ = try mac.exchange.exchange(with: folder)
    let name = SyncFormat.fileName(deviceId: "mac", sequence: 0)
    let whole = try folder.read(name: name)
    let torn = InMemoryFolder()
    torn.plant(name: name, data: whole.prefix(whole.count / 2))
    torn.plant(name: ".writing-\(name)", data: whole)
    let outcome = try phone.exchange.exchange(with: torn)
    #expect(outcome.filesDamaged == 1)
    #expect(outcome.recordsApplied == 0)
    #expect(try phone.count("transactions") == 0)
    // The whole file arrives later (renamed over the cut one by the other device's retry).
    torn.plant(name: name, data: whole)
    let later = try phone.exchange.exchange(with: torn)
    #expect(later.recordsApplied == 2)
  }

  @Test func aFileFromANewerBuildIsReportedAndTheRestStillComesIn() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "a")
    _ = try mac.exchange.exchange(with: folder)
    let future = Data(#"{"deviceId":"tablet","entries":[],"formatVersion":99,"sequence":0}"#.utf8)
    folder.plant(name: SyncFormat.fileName(deviceId: "tablet", sequence: 0), data: future)
    let outcome = try phone.exchange.exchange(with: folder)
    #expect(outcome.filesFromNewerVersion == 1)
    #expect(try phone.note("t1") == "a")
  }

  @Test func thePhoneAfterTheArchiveReachesTheMacsState() throws {
    // The phone starts from a copy of the Mac's books (the transfer archive), then reads every
    // journal: it ends where the Mac is.
    let mac = try TestDevice("mac")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "a")
    try mac.insertOperation("t2", note: "b")
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    try mac.setNote("t1", "a2")
    try mac.sql("DELETE FROM transactions WHERE id = 't2'")
    try mac.stamp("2026-10-22T10:05:00Z")
    _ = try mac.exchange.exchange(with: folder)

    let phone = try TestDevice("phone")  // empty: the archive step is the books before the journal
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.note("t1") == "a2")
    #expect(try phone.count("transactions") == 1)
    #expect(try phone.books() == mac.books())
  }
}
