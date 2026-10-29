import CoreKit
import Foundation
import Testing

@testable import CoreArchive

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func attachment(
  kind: AttachmentKind = .receipt, hash: String = String(repeating: "a", count: 64),
  addedDaysAgo: Double = 0, trashedDaysAgo: Double? = nil, keepForever: Bool = false,
  now: Date = t0, size: Int64 = 10
) -> AttachedFile {
  AttachedFile(
    ownerKind: .transaction, ownerId: UUID(), contentHash: hash, fileName: "x.jpg",
    byteSize: size, kind: kind, addedAt: now.addingTimeInterval(-addedDaysAgo * day),
    trashedAt: trashedDaysAgo.map { now.addingTimeInterval(-$0 * day) }, keepForever: keepForever)
}

@Suite("The name of a file is the digest of its content")
struct AttachmentHashTests {
  @Test func hashesMatchTheKnownVectors() {
    #expect(
      AttachmentHash.hexDigest(of: Data("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    var stream = AttachmentHash.Stream()
    stream.update(Data("a".utf8))
    stream.update(Data("bc".utf8))
    #expect(stream.byteCount == 3)
    #expect(stream.finalize() == AttachmentHash.hexDigest(of: Data("abc".utf8)))
  }

  @Test func onlyAFullDigestNamesAFile() {
    let good = String(repeating: "ab", count: 32)
    #expect(AttachmentHash.isValid(good))
    #expect(AttachmentHash.isValid(good.uppercased()))
    #expect(!AttachmentHash.isValid(String(good.dropLast())))
    #expect(!AttachmentHash.isValid(String(repeating: "g", count: 64)))
    #expect(AttachmentHash.relativePath(for: "../" + good) == nil)
    #expect(AttachmentHash.relativePath(for: good) == "ab/ab/" + good)
    #expect(AttachmentHash.hash(forRelativePath: "ab/ab/" + good) == good)
    #expect(AttachmentHash.hash(forRelativePath: "cd/ab/" + good) == nil)
    #expect(AttachmentHash.hash(forRelativePath: "../../" + good) == nil)
  }
}

@Suite("Retention: the week, the trash and the files nothing names")
struct AttachmentRetentionTests {
  @Test func receiptsAreKeptForeverByDefault() {
    let old = attachment(addedDaysAgo: 400)
    #expect(AttachmentRetention.actions(for: [old], settings: AttachmentSettings(), now: t0) == [])
  }

  @Test func aReceiptPhotoGoesToTheTrashAfterAWeekWhenNotKept() {
    let settings = AttachmentSettings(keepReceiptsForever: false)
    let fresh = attachment(addedDaysAgo: 6.9)
    let due = attachment(addedDaysAgo: 7)
    let pinned = attachment(addedDaysAgo: 100, keepForever: true)
    let warranty = attachment(kind: .warranty, addedDaysAgo: 100)
    let actions = AttachmentRetention.actions(
      for: [fresh, due, pinned, warranty], settings: settings, now: t0)
    #expect(actions == [.moveToTrash(id: due.id, at: t0)])
  }

  @Test func theTrashIsEmptiedAfterTheDaysTheOwnerChose() {
    let settings = AttachmentSettings(trashDays: 30)
    let waiting = attachment(trashedDaysAgo: 29)
    let expired = attachment(trashedDaysAgo: 30)
    let pinnedButTrashed = attachment(trashedDaysAgo: 31, keepForever: true)
    let actions = AttachmentRetention.actions(
      for: [waiting, expired, pinnedButTrashed], settings: settings, now: t0)
    #expect(actions == [.delete(id: expired.id), .delete(id: pinnedButTrashed.id)])
    #expect(AttachmentRetention.daysLeftInTrash(waiting, settings: settings, now: t0) == 1)
    #expect(AttachmentRetention.daysLeftInTrash(expired, settings: settings, now: t0) == 0)
    #expect(AttachmentRetention.daysLeftInTrash(attachment(), settings: settings, now: t0) == nil)
  }

  @Test func aLateRunStartsTheClockOfTheTrashNow() {
    // Three months off: the photo goes to the trash today, it is not deleted without being shown.
    let settings = AttachmentSettings(keepReceiptsForever: false)
    let old = attachment(addedDaysAgo: 90)
    #expect(
      AttachmentRetention.actions(for: [old], settings: settings, now: t0)
        == [.moveToTrash(id: old.id, at: t0)])
  }

  @Test func aRestoredOldCopyIsNotDamage() {
    let normal = attachment()
    let pinned = attachment(keepForever: true)
    #expect(AttachmentRetention.availability(of: normal, fileExists: true) == .present)
    #expect(AttachmentRetention.availability(of: normal, fileExists: false) == .removedByRule)
    #expect(AttachmentRetention.availability(of: pinned, fileExists: false) == .missing)
  }

  @Test func settingsReadTheirDefaultsFromNothing() {
    let settings = AttachmentSettings(storedValues: [:])
    #expect(settings.keepReceiptsForever)
    #expect(settings.trashDays == 30)
    #expect(settings.mirror)
    #expect(settings.withAttachmentsInArchive)
    let off = AttachmentSettings(
      storedValues: AttachmentSettings(
        keepReceiptsForever: false, trashDays: 5, mirror: false, withAttachmentsInArchive: false
      ).storedValues)
    #expect(!off.keepReceiptsForever && off.trashDays == 5 && !off.mirror)
    #expect(!off.withAttachmentsInArchive)
    #expect(AttachmentSettings(storedValues: ["attachments.trashDays": "abc"]).trashDays == 30)
  }
}

@Suite("Files with several rows are kept once")
struct AttachmentReferencesTests {
  @Test func aFileGoesOnlyWithItsLastRow() {
    let shared = String(repeating: "1", count: 64)
    let alone = String(repeating: "2", count: 64)
    let a = attachment(hash: shared)
    let b = attachment(hash: shared)
    let c = attachment(hash: alone)
    let all = [a, b, c]
    #expect(AttachmentReferences.counts(all) == [shared: 2, alone: 1])
    #expect(AttachmentReferences.filesFreed(deleting: [a.id], from: all) == [])
    #expect(AttachmentReferences.filesFreed(deleting: [a.id, b.id], from: all) == [shared])
    #expect(AttachmentReferences.filesFreed(deleting: [c.id], from: all) == [alone])
  }

  @Test func orphansAndAbsencesAreTheTwoSidesOfTheSame() {
    let named = String(repeating: "3", count: 64)
    let stray = String(repeating: "4", count: 64)
    let lost = String(repeating: "5", count: 64)
    let rows = [attachment(hash: named), attachment(hash: lost)]
    #expect(AttachmentReferences.orphanFiles(stored: [named, stray], attachments: rows) == [stray])
    #expect(AttachmentReferences.absentFiles(stored: [named, stray], attachments: rows) == [lost])
  }
}

@Suite("The attachments in a transfer archive")
struct AttachmentArchiveTests {
  @Test func pathsRoundTripAndRefuseAnythingElse() {
    let hash = String(repeating: "ef", count: 32)
    let path = AttachmentArchive.path(forHash: hash)
    #expect(path == "attachments/ef/ef/" + hash)
    #expect(path.flatMap(AttachmentArchive.hash(forPath:)) == hash)
    #expect(AttachmentArchive.hash(forPath: "data/csv/x.csv") == nil)
    #expect(AttachmentArchive.hash(forPath: "attachments/../" + hash) == nil)
  }

  @Test func theSizeIsKnownBeforeAnythingIsRead() {
    let a = attachment(hash: String(repeating: "a", count: 64), addedDaysAgo: 3, size: 600)
    let same = attachment(hash: String(repeating: "a", count: 64), addedDaysAgo: 2, size: 600)
    let b = attachment(hash: String(repeating: "b", count: 64), addedDaysAgo: 1, size: 500)
    let big = attachment(hash: String(repeating: "c", count: 64), addedDaysAgo: 0, size: 5_000)
    let plan = AttachmentArchive.plan(
      for: [a, same, b, big], baseBytes: 0, baseEntries: 0, maximumBytes: 2_000, maximumEntries: 10)
    // Newest first; the one that does not fit is named, the rest go in; equal content is one entry.
    #expect(plan.included.map(\.hash) == [b.contentHash, a.contentHash])
    #expect(plan.skipped.map(\.hash) == [big.contentHash])
    #expect(plan.includedBytes == 1_100)
    #expect(plan.skippedBytes == 5_000)
    #expect(!plan.isComplete)
  }

  @Test func theNumberOfEntriesIsLimitedToo() {
    let rows = (0..<5).map { index in
      attachment(hash: String(repeating: String(index), count: 64), addedDaysAgo: Double(index))
    }
    let plan = AttachmentArchive.plan(for: rows, baseBytes: 0, baseEntries: 3, maximumEntries: 5)
    #expect(plan.included.count == 2 && plan.skipped.count == 3)
  }

  @Test func anArchiveWithFilesOpensAndOneWithoutDoesToo() throws {
    let content = Data("receipt".utf8)
    let hash = AttachmentHash.hexDigest(of: content)
    func archive(withFiles: Bool) throws -> ArchiveOpener.OpenedArchive {
      var builder = ArchiveBuilder(
        metadata: ArchiveBuilder.Metadata(
          appVersion: "2.4.0", schemaVersion: 17,
          createdAt: DateOnly(year: 2026, month: 10, day: 29), platform: "macOS", rowCounts: [:]))
      try builder.add(path: ArchivePaths.database, data: Data("db".utf8))
      if withFiles {
        try builder.add(path: AttachmentArchive.path(forHash: hash)!, data: content)
      }
      return try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 18)
    }
    let with = try archive(withFiles: true)
    #expect(with.manifest.formatVersion == 1)
    #expect(with.attachmentHashes == [hash])
    #expect(with.attachment(hash: hash) == content)
    #expect(with.database == Data("db".utf8))
    let without = try archive(withFiles: false)
    #expect(without.attachmentHashes.isEmpty)
    #expect(without.manifest.formatVersion == with.manifest.formatVersion)
  }
}
