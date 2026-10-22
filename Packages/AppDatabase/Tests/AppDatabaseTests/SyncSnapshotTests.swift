import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

@Suite("The copy of the whole database in the shared folder")
struct SyncSnapshotTests {
  private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-snapshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func deviceWithHistory(_ id: String) throws -> TestDevice {
    let device = try TestDevice(id, recording: false)
    let set = TestSupport.sample(months: 2)
    try TransactionRepository(writer: device.stack.writer).insert(TestSupport.batch(set))
    try device.exchange.setRecording(true)
    return device
  }

  private let day = Date(timeIntervalSince1970: 1_900_000_000)

  @Test func theNameIsNotTheLiveDatabasesAndNotAJournalFiles() {
    let name = SyncSnapshotName.fileName(deviceId: "mac-1")
    #expect(SyncSnapshotName.parse(name) == "mac-1")
    #expect(SyncFormat.parse(fileName: name) == nil)
    #expect(!name.hasSuffix(".sqlite"))
    for other in [
      "finance.sqlite", "finance.sqlite-wal", "finance.sqlite-shm", "snapshot-.ohmymoney-snapshot",
      "snapshot-a b.ohmymoney-snapshot", "journal-mac-0000000001.json",
      "../snapshot-x.ohmymoney-snapshot",
    ] {
      #expect(SyncSnapshotName.parse(other) == nil, "\(other)")
    }
  }

  @Test func aSnapshotIsWrittenVerifiedAndHoldsTheBooksWithoutTheBookkeeping() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let mac = try deviceWithHistory("mac")
    _ = try mac.exchange.exchange(with: InMemoryFolder())  // seeds: bookkeeping is not empty
    #expect(try mac.count("sync_heads") > 0)
    let folder = DirectoryJournalFolder(url: shared)

    #expect(try mac.exchange.snapshotIfDue(to: folder, now: day))

    let names = try FileManager.default.contentsOfDirectory(atPath: shared.path)
    #expect(names == [SyncSnapshotName.fileName(deviceId: "mac")])
    let file = shared.appendingPathComponent(names[0])
    #expect(try DatabaseStack.check(fileAt: file, schema: TestSupport.schemaSource) == .sound)
    let copy = try DatabaseQueue(path: file.path)
    for (table, _) in SyncTables.followed {
      let theirs = try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"\(table)\"")! }
      #expect(theirs == (try mac.count(table)), "\(table)")
    }
    for table in SyncTables.bookkeeping {
      let rows = try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
      #expect(rows == 0, "\(table) stays on the device")
    }
    // The live database is untouched by the copy.
    #expect(try mac.count("sync_heads") > 0)
  }

  @Test func aSnapshotIsWrittenAtMostOncePerDayAndAfterSeeding() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let mac = try deviceWithHistory("mac")
    let folder = DirectoryJournalFolder(url: shared)
    _ = try mac.exchange.seedIfNeeded()  // seeding asks for a snapshot

    #expect(try mac.exchange.snapshotIfDue(to: folder, now: day))
    #expect(try !mac.exchange.snapshotIfDue(to: folder, now: day.addingTimeInterval(3_600)))
    #expect(try mac.exchange.snapshotIfDue(to: folder, now: day.addingTimeInterval(86_400)))
    #expect(try !mac.exchange.snapshotIfDue(to: folder, now: day.addingTimeInterval(86_400 + 60)))
    #expect(try mac.exchange.snapshotIfDue(to: folder, now: day, force: true))
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).count == 1)

    // A replaced database asks for a fresh one.
    _ = try mac.exchange.databaseWasReplaced()
    #expect(try mac.exchange.snapshotIfDue(to: folder, now: day.addingTimeInterval(86_400 + 120)))
  }

  @Test func aDeviceWithNothingOfTheOwnersWritesNoSnapshot() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let phone = try TestDevice("phone")
    #expect(!phone.exchange.holdsOwnerData)
    #expect(try !phone.exchange.snapshotIfDue(to: DirectoryJournalFolder(url: shared), now: day))
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
  }

  @Test func theFolderTakesOnlyJournalNamesAndTheSnapshotName() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let folder = DirectoryJournalFolder(url: shared)
    let local = shared.deletingLastPathComponent().appendingPathComponent(
      "local-\(UUID().uuidString)")
    try Data("x".utf8).write(to: local)
    defer { try? FileManager.default.removeItem(at: local) }
    for name in ["finance.sqlite", "finance.sqlite-wal", "finance.sqlite-shm", "notes.txt", "../x"]
    {
      #expect(throws: SyncFolderError.refusedName) {
        try folder.putSnapshot(named: name, from: local)
      }
      #expect(throws: SyncFolderError.refusedName) {
        try folder.fetchSnapshot(named: name, to: local.appendingPathExtension("out"))
      }
      #expect(throws: SyncFolderError.refusedName) { try folder.read(name: name) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
    try folder.putSnapshot(named: SyncSnapshotName.fileName(deviceId: "mac"), from: local)
    try folder.putSnapshot(named: SyncSnapshotName.fileName(deviceId: "mac"), from: local)
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).count == 1)
    // The journal still refuses it as a journal file.
    #expect(throws: SyncFolderError.refusedName) {
      try folder.read(name: SyncSnapshotName.fileName(deviceId: "mac"))
    }
  }

  @Test func aWholeExchangeAndSnapshotLeaveOnlyTheseNamesInTheFolder() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let mac = try deviceWithHistory("mac")
    let folder = DirectoryJournalFolder(url: shared)
    _ = try mac.exchange.exchange(with: folder)
    _ = try mac.exchange.snapshotIfDue(to: folder, now: day)
    for name in try FileManager.default.contentsOfDirectory(atPath: shared.path) {
      #expect(SyncFormat.parse(fileName: name) != nil || SyncSnapshotName.parse(name) != nil)
      #expect(!name.hasSuffix(".sqlite") && !name.hasSuffix("-wal") && !name.hasSuffix("-shm"))
    }
  }

  @Test func anEmptyDeviceCanTakeTheSnapshotAndThenFollowTheJournal() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let mac = try deviceWithHistory("mac")
    let folder = DirectoryJournalFolder(url: shared)
    _ = try mac.exchange.exchange(with: folder)
    _ = try mac.exchange.snapshotIfDue(to: folder, now: day)

    let info = try #require(try SyncSnapshots.newest(in: folder))
    let staged = shared.deletingLastPathComponent()
      .appendingPathComponent("staged-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: staged) }
    try SyncSnapshots.fetchVerified(
      info, from: folder, to: staged, schema: TestSupport.schemaSource)

    // The staged file becomes the phone's database; the app opens it at the next launch.
    let phoneStack = try DatabaseStack(url: staged, schema: TestSupport.schemaSource)
    let phone = try SyncExchange(writer: phoneStack.writer, deviceId: "phone", deviceName: "Phone")
    try phone.setRecording(true)
    _ = try phone.databaseWasReplaced(bootstrappedFromSnapshot: true)
    #expect(phone.holdsOwnerData)

    let outcome = try phone.exchange(with: folder)
    #expect(outcome.entriesWritten == 0, "nothing is sent back")
    #expect(outcome.conflictsOpen == 0)
    #expect(outcome.filesApplied >= 1)
    // Rows of the snapshot now carry the versions of the journal: an edit builds on them.
    #expect(
      try phoneStack.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_heads")! }
        > 0)
    for table in SyncTables.followed.keys {
      let mine = try phoneStack.writer.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"\(table)\"")!
      }
      #expect(mine == (try mac.count(table)), "\(table)")
    }
    try phoneStack.close()
  }

  @Test func aDamagedOrForeignFileIsNotTakenAsTheBooks() throws {
    let shared = try makeFolder()
    defer { try? FileManager.default.removeItem(at: shared) }
    let folder = DirectoryJournalFolder(url: shared)
    let name = SyncSnapshotName.fileName(deviceId: "mac")
    try Data("this is not a database".utf8).write(to: shared.appendingPathComponent(name))
    let info = try #require(try SyncSnapshots.newest(in: folder))
    let staged = shared.deletingLastPathComponent()
      .appendingPathComponent("staged-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: staged) }

    #expect(throws: SyncSnapshotError.damaged) {
      try SyncSnapshots.fetchVerified(
        info, from: folder, to: staged, schema: TestSupport.schemaSource)
    }
    #expect(!FileManager.default.fileExists(atPath: staged.path), "the bad copy is not left")
    #expect(try SyncSnapshots.newest(in: DirectoryJournalFolder(url: try makeFolder())) == nil)
  }
}
