import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The files of the attachments: kept by the digest of their content, once however many rows name
/// them, removed only with their last row, and never changed.
@Suite("The folder of attachments and the rules over it")
struct AttachmentStoreTests {
  private struct Rig {
    let stack: DatabaseStack
    let service: AttachmentService
    let folder: URL
    let owner = UUID()

    init() throws {
      stack = try TestSupport.makeStack()
      folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ohmymoney-attachments-\(UUID().uuidString)", isDirectory: true)
      service = AttachmentService(
        repository: AttachmentRepository(writer: stack.writer),
        store: AttachmentFileStore(root: folder))
      // The owner row: a check of the database would otherwise call its files lost.
      try stack.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO transactions (id, kind, occurred_at, amount_e4, amount_rub_e4, created_at, updated_at)
            VALUES (?, 'expense', '2026-10-20 10:00:00.000', 1, 1, '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000')
            """, arguments: [owner.uuidString])
        try db.execute(
          sql:
            "INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4) VALUES (?, ?, 1, 1)",
          arguments: [UUID().uuidString, owner.uuidString])
      }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func add(
      _ text: String, name: String = "a.jpg", kind: AttachmentKind = .receipt, at now: Date = Date()
    ) throws -> AttachedFile {
      try service.add(
        data: Data(text.utf8), fileName: name, to: .transaction, id: owner, kind: kind, now: now)
    }
  }

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func theSameContentIsKeptOnceAndGoesWithItsLastRow() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let first = try rig.add("photo", name: "one.jpg")
    let second = try rig.add("photo", name: "two.jpg")
    #expect(first.contentHash == second.contentHash && first.id != second.id)
    #expect(rig.service.store.storedHashes() == [first.contentHash])
    #expect(try rig.service.repository.references(toHash: first.contentHash) == 2)

    try rig.service.delete(ids: [first.id])
    #expect(rig.service.store.contains(hash: first.contentHash), "another row still names it")
    try rig.service.delete(ids: [second.id])
    #expect(!rig.service.store.contains(hash: first.contentHash))
    #expect(rig.service.store.storedHashes().isEmpty)
  }

  @Test func theFileIsKeptByteForByteAndInTwoLevelsOfFolders() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let bytes = Data((0..<5000).map { UInt8($0 % 251) })
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-source-\(UUID().uuidString).bin")
    try bytes.write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let added = try rig.service.add(
      fileAt: source, to: .transaction, id: rig.owner, kind: .warranty)
    #expect(added.byteSize == 5000)
    #expect(added.contentHash == AttachmentHash.hexDigest(of: bytes))
    #expect(try rig.service.store.data(forHash: added.contentHash) == bytes)
    let url = try #require(rig.service.store.url(forHash: added.contentHash))
    #expect(
      url.path.hasSuffix(
        "/\(added.contentHash.prefix(2))/\(added.contentHash.dropFirst(2).prefix(2))/\(added.contentHash)"
      ))
    #expect(FileManager.default.fileExists(atPath: source.path), "the original is not moved")
    let (digest, size) = try AttachmentFileStore.digest(of: source)
    #expect(
      digest == added.contentHash && size == 5000, "the streaming digest agrees with the core's")
  }

  @Test func aFileOfAnySizeIsHashedInPieces() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    // Larger than one piece of the reader.
    let bytes = Data(repeating: 7, count: (1 << 20) * 2 + 123)
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-big-\(UUID().uuidString).bin")
    try bytes.write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let added = try rig.service.add(fileAt: source, to: .transaction, id: rig.owner)
    #expect(added.byteSize == Int64(bytes.count))
    #expect(added.contentHash == AttachmentHash.hexDigest(of: bytes))
  }

  @Test func contentThatDoesNotMatchItsNameIsRefused() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    #expect(throws: AttachmentFileStore.StoreError.hashMismatch) {
      try rig.service.store.put(Data("x".utf8), expecting: String(repeating: "0", count: 64))
    }
    #expect(throws: AttachmentFileStore.StoreError.notADigest) {
      try rig.service.store.put(Data("x".utf8), expecting: "../etc/passwd")
    }
    #expect(rig.service.store.storedHashes().isEmpty)
  }

  @Test func theTrashHoldsThirtyDaysAndThenTheFileGoes() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let file = try rig.add("scan", kind: .document, at: now)
    try rig.service.moveToTrash(id: file.id, now: now)
    #expect(try rig.service.repository.attachments(of: .transaction, id: rig.owner).isEmpty)
    #expect(try rig.service.repository.trash().map(\.id) == [file.id])

    let day = 86_400.0
    #expect(try rig.service.applyRetention(now: now.addingTimeInterval(29 * day)).isEmpty)
    #expect(rig.service.store.contains(hash: file.contentHash))
    let actions = try rig.service.applyRetention(now: now.addingTimeInterval(30 * day))
    #expect(actions == [.delete(id: file.id)])
    #expect(try rig.service.repository.all().isEmpty)
    #expect(!rig.service.store.contains(hash: file.contentHash))
  }

  @Test func restoringFromTheTrashBringsTheFileBack() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let file = try rig.add("scan", at: now)
    try rig.service.moveToTrash(id: file.id, now: now)
    try rig.service.restoreFromTrash(id: file.id)
    #expect(try rig.service.repository.attachments(of: .transaction, id: rig.owner).count == 1)
    #expect(try rig.service.applyRetention(now: now.addingTimeInterval(90 * 86_400)).isEmpty)
  }

  @Test func receiptPhotosAreKeptForeverUntilTheOwnerTurnsItOff() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let photo = try rig.add("receipt", kind: .receipt, at: now)
    let card = try rig.add("card", kind: .warranty, at: now)
    #expect(try rig.service.repository.settings().keepReceiptsForever)
    #expect(try rig.service.applyRetention(now: now.addingTimeInterval(400 * 86_400)).isEmpty)

    var settings = try rig.service.repository.settings()
    settings.keepReceiptsForever = false
    try rig.service.repository.save(settings)
    let week = now.addingTimeInterval(7 * 86_400)
    let actions = try rig.service.applyRetention(now: week)
    #expect(
      actions == [.moveToTrash(id: photo.id, at: week)], "only the receipt photo, after a week")
    #expect(try rig.service.repository.trash().map(\.id) == [photo.id])
    #expect(try rig.service.repository.attachment(id: card.id)?.trashedAt == nil)
    // The next run, a month later, deletes it.
    _ = try rig.service.applyRetention(now: week.addingTimeInterval(30 * 86_400))
    #expect(try rig.service.repository.attachment(id: photo.id) == nil)
    #expect(!rig.service.store.contains(hash: photo.contentHash))
    #expect(rig.service.store.contains(hash: card.contentHash))
  }

  @Test func theDailySweepKeepsEveryReceiptWhileTheSettingIsOn() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let photo = try rig.add("receipt", kind: .receipt, at: now)
    let report = try rig.service.dailySweep(now: now.addingTimeInterval(90 * 86_400))
    #expect(report.isEmpty)
    #expect(try rig.service.repository.attachment(id: photo.id)?.trashedAt == nil)
  }

  @Test func theDailySweepTrashesOldReceiptsAndDeletesTheTrashButNotWarrantiesOrDocuments() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    var settings = try rig.service.repository.settings()
    settings.keepReceiptsForever = false
    settings.trashDays = 10
    try rig.service.repository.save(settings)
    let old = try rig.add("old receipt", kind: .receipt, at: now)
    let pinned = try rig.add("pinned receipt", kind: .receipt, at: now)
    var pin = pinned
    pin.keepForever = true
    try rig.service.repository.update(pin)
    let fresh = try rig.add("fresh receipt", kind: .receipt, at: now.addingTimeInterval(86_400 * 6))
    let warranty = try rig.add("warranty", kind: .warranty, at: now)
    let document = try rig.add("document", kind: .document, at: now)

    // A week and a day in: the old receipt goes to the trash and nothing else moves.
    let week = now.addingTimeInterval(8 * 86_400)
    #expect(try rig.service.dailySweep(now: week) == .init(movedToTrash: 1))
    #expect(try rig.service.repository.trash().map(\.id) == [old.id])
    #expect(rig.service.store.contains(hash: old.contentHash), "still shown in the trash")

    // Ten days after the move: deleted with its file; the rest stays, whatever its age.
    let later = week.addingTimeInterval(10 * 86_400)
    let report = try rig.service.dailySweep(now: later)
    #expect(report.deleted == 1)
    #expect(!rig.service.store.contains(hash: old.contentHash))
    #expect(try rig.service.repository.attachment(id: pinned.id)?.trashedAt == nil)
    #expect(try rig.service.repository.attachment(id: warranty.id)?.trashedAt == nil)
    #expect(try rig.service.repository.attachment(id: document.id)?.trashedAt == nil)
    _ = fresh
  }

  @Test func aRestoredOldCopyNamesAFileThatIsGoneWithoutAnError() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let file = try rig.add("old receipt", at: now)
    let pinned = try rig.add("pinned", at: now)
    var row = try #require(try rig.service.repository.attachment(id: pinned.id))
    row.keepForever = true
    try rig.service.repository.update(row)
    // The files were removed after the copy was made; the rows come back with the copy.
    try rig.service.store.remove(hash: file.contentHash)
    try rig.service.store.remove(hash: pinned.contentHash)
    #expect(rig.service.availability(of: file) == .removedByRule)
    #expect(rig.service.availability(of: row) == .missing)
    // The check of the database does not call it damage.
    let report = try DatabaseCheck.run(rig.stack.writer)
    #expect(report.isHealthy, "\(report.findings)")
    // Retention and the sweep run without trouble over rows whose files are not there.
    _ = try rig.service.applyRetention(now: now)
    #expect(try rig.service.sweepOrphanFiles() == 0)
  }

  @Test func theSweepRemovesTheFilesNoRowNames() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let kept = try rig.add("kept")
    _ = try rig.service.store.put(Data("stray".utf8))
    #expect(rig.service.store.storedHashes().count == 2)
    #expect(try rig.service.sweepOrphanFiles() == 1)
    #expect(rig.service.store.storedHashes() == [kept.contentHash])
  }

  @Test func theDelayedSweepWaitsForTheFilesToGetOldNoMatterHowOldTheirSourceWas() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let kept = try rig.add("kept")
    // A photo from 2019 attached today: the copy keeps the old date of its source.
    try FileManager.default.createDirectory(at: rig.folder, withIntermediateDirectories: true)
    let source = rig.folder.appendingPathComponent("old.jpg")
    try Data("old photo".utf8).write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_550_000_000)], ofItemAtPath: source.path)
    let stray = try rig.service.store.put(fileAt: source)
    #expect(try rig.service.sweepOrphanFiles(olderThanDays: 30) == 0)
    #expect(rig.service.store.contains(hash: stray.hash))
    // Thirty days later it goes, and the file with a row never does.
    let later = Date().addingTimeInterval(31 * 86_400)
    #expect(try rig.service.sweepOrphanFiles(olderThanDays: 30, now: later) == 1)
    #expect(rig.service.store.storedHashes() == [kept.contentHash])
  }

  @Test func aRowThisBuildCannotReadStillProtectsItsFile() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let future = try rig.service.store.put(Data("from a newer build".utf8))
    try rig.stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO attachments (id, owner_kind, owner_id, content_hash, file_name, byte_size, added_at)
          VALUES ('not-a-uuid', 'debt', 'o', ?, 'f', 1, '2026-10-29 10:00:00.000')
          """, arguments: [future.hash])
    }
    #expect(try rig.service.repository.all().isEmpty, "this build does not read it")
    #expect(try rig.service.sweepOrphanFiles() == 0, "but it does not delete its file")
    #expect(rig.service.store.contains(hash: future.hash))
  }

  @Test func filesLeftWithoutAnOwnerAreReportedAndNeverDeleted() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let file = try rig.add("receipt")
    try rig.stack.writer.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(
        sql: """
          INSERT INTO attachments (id, owner_kind, owner_id, content_hash, file_name, byte_size, added_at)
          VALUES (?, 'asset', ?, ?, 'x', 1, '2026-10-29 10:00:00.000')
          """,
        arguments: [UUID().uuidString, UUID().uuidString, file.contentHash])
    }
    let report = try DatabaseCheck.run(rig.stack.writer)
    let finding = try #require(report.findings.first { $0.rule == .attachmentWithoutOwner })
    // The row is the owner's and may wait for an owner still on its way from another device.
    #expect(finding.count == 1 && !finding.isRepairable)
    #expect(try DatabaseCheck.repair(rig.stack.writer) == 0)
    #expect(try DatabaseCheck.run(rig.stack.writer).findings.count == 1)
    #expect(try rig.service.repository.all().count == 2)
  }

  @Test func aNewFileOrAnswerCountsAsAChangeWorthACopy() {
    #expect(DatabaseStack.dataTables.contains("attachments"))
    #expect(DatabaseStack.dataTables.contains("week_answers"))
  }

  @Test func theWeekHasOneAnswerAndTheLastOneWins() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let repository = rig.service.repository
    try repository.save(WeekAnswer(week: "2026-W44", mood: 2, answeredAt: now))
    try repository.save(
      WeekAnswer(week: "2026-W44", mood: 4, answeredAt: now.addingTimeInterval(60)))
    try repository.save(WeekAnswer(week: "2026-W45", mood: 9, answeredAt: now))
    #expect(try repository.answers().map(\.week) == ["2026-W44", "2026-W45"])
    #expect(try repository.answer(week: "2026-W44")?.mood == 4)
    #expect(try repository.answer(week: "2026-W45")?.mood == 5, "a mood is held between 1 and 5")
    #expect(try repository.answer(week: "2026-W46") == nil)
  }

  @Test func theSettingsRoundTripAndTheDefaultsHold() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let repository = rig.service.repository
    #expect(try repository.settings() == AttachmentSettings())
    let changed = AttachmentSettings(
      keepReceiptsForever: false, trashDays: 10, mirror: false, withAttachmentsInArchive: false)
    try repository.save(changed)
    #expect(try repository.settings() == changed)
  }

  @Test func theOperationKeepsItsWarrantyAndReturnTerm() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    var operation = try #require(
      try rig.stack.writer.read { db in
        try CoreKit.Transaction.fetchOne(db, key: rig.owner.uuidString)
      })
    operation.warrantyUntil = DateOnly(year: 2028, month: 10, day: 29)
    operation.warrantyWhere = "папка «Техника»"
    operation.returnUntil = DateOnly(year: 2026, month: 11, day: 12)
    try rig.stack.writer.write { db in try operation.update(db) }
    let read = try #require(
      try rig.stack.writer.read { db in
        try CoreKit.Transaction.fetchOne(db, key: rig.owner.uuidString)
      })
    #expect(read.warrantyUntil == operation.warrantyUntil)
    #expect(read.warrantyWhere == "папка «Техника»")
    #expect(read.returnUntil == operation.returnUntil)
    // Blank text reads as none.
    try rig.stack.writer.write { db in
      try db.execute(sql: "UPDATE transactions SET warranty_where = '  '")
    }
    let blank = try #require(
      try rig.stack.writer.read { db in
        try CoreKit.Transaction.fetchOne(db, key: rig.owner.uuidString)
      })
    #expect(blank.warrantyWhere == nil)
  }

  @Test func theExportHasOneRowPerFileAndNoBytes() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let file = try rig.add("receipt, \"quoted\"")
    let export = ExportRepository(writer: rig.stack.writer)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-export-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let snapshot = try export.snapshot(to: url)
    #expect(snapshot.rowCounts["attachments"] == 1)
    #expect(snapshot.rowCounts["week_answers"] == nil, "the answers are not in the CSV")
    let table = try #require(snapshot.tables.first { $0.name == "attachments" })
    let rows = try CSVReader.dictionaries(from: table.data)
    #expect(rows.count == 1 && rows[0]["content_hash"] == file.contentHash)
    #expect(rows[0]["byte_size"] == String(file.byteSize))
  }
}
