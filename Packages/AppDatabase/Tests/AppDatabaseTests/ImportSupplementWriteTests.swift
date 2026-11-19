import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// «Дополнить» from an imported screenshot or receipt: the empty fields of the operation and the
/// file land in one write, never as a second operation, and one revert takes both back.
@Suite("Supplementing an operation from an import: one write, one undo")
struct ImportSupplementWriteTests {
  private let day = DateOnly(year: 2026, month: 9, day: 15)
  private let calendar = CalendarContext.utc
  private let instant = Date(timeIntervalSince1970: 1_790_000_000)

  private struct Rig {
    let stack: DatabaseStack
    let repository: TransactionRepository
    let service: AttachmentService
    let folder: URL
    let fixture: ReferenceFixture

    init() throws {
      stack = try TestSupport.makeStack()
      fixture = try TestSupport.seedReferences(stack)
      repository = TransactionRepository(writer: stack.writer)
      folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ohmymoney-supplement-\(UUID().uuidString)", isDirectory: true)
      service = AttachmentService(
        repository: AttachmentRepository(writer: stack.writer),
        store: AttachmentFileStore(root: folder))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func count() throws -> Int {
      try stack.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0
      }
    }

    func files(of id: UUID) throws -> [AttachedFile] {
      try service.repository.attachments(of: .transaction, id: id)
    }
  }

  /// An expense typed without a time (the app's noon), no note, on the fixture's account.
  private func operation(
    _ rig: Rig, parts: [Int64] = [1_000], note: String? = nil
  ) throws -> TransactionEntry {
    let id = UUID()
    let total = parts.reduce(0, +)
    let transaction = Transaction(
      id: id, kind: .expense, occurredAt: calendar.noon(of: day),
      amountE4: AmountE4(whole: total), note: note,
      paymentMethodId: rig.fixture.paymentMethod.id, createdAt: instant, updatedAt: instant)
    let entry = TransactionEntry(
      transaction: transaction,
      parts: parts.map {
        TransactionPart(
          transactionId: id, categoryId: rig.fixture.category.id, amountE4: AmountE4(whole: $0))
      })
    try rig.repository.save(entry)
    return try #require(try rig.repository.entry(id: id))
  }

  private func screenshot(
    _ rig: Rig, bytes: String = "screenshot-bytes",
    time: TimeOfDay? = TimeOfDay(hour: 9, minute: 41)
  ) -> RecognizedPurchase {
    RecognizedPurchase(
      amount: AmountE4(whole: 1_000), day: day, time: time, merchant: "Кофейня", mcc: "5814",
      accountID: rig.fixture.paymentMethod.id,
      file: RecognizedFile(data: Data(bytes.utf8), fileName: "screen.png", mediaType: "image/png"))
  }

  @Test func supplementFillsTheEmptyFieldsAndAttachesTheFileInOneWrite() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let entry = try operation(rig)
    let operations = try rig.count()

    let result = try rig.service.supplement(
      rig.repository, id: entry.id, with: screenshot(rig), kind: .other, calendar: calendar,
      now: instant)
    guard case .written(let write) = result else {
      Issue.record("expected a write")
      return
    }
    #expect(write.filled == [.note, .time, .mcc])
    #expect(try rig.count() == operations, "no second operation")
    let stored = try #require(try rig.repository.entry(id: entry.id))
    #expect(stored.transaction.note == "Кофейня")
    #expect(stored.transaction.mcc == "5814")
    #expect(stored.transaction.occurredAt == calendar.moment(day, hour: 9, minute: 41))
    #expect(stored.transaction.amountE4 == entry.transaction.amountE4)
    let files = try rig.files(of: entry.id)
    #expect(files.map(\.id) == [write.attached?.id])
    #expect(files.first?.fileName == "screen.png")
    #expect(rig.service.store.contains(hash: try #require(files.first).contentHash))
  }

  @Test func oneRevertTakesBackTheFieldsAndTheFileTogether() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let entry = try operation(rig)
    guard
      case .written(let write) = try rig.service.supplement(
        rig.repository, id: entry.id, with: screenshot(rig), kind: .other, calendar: calendar,
        now: instant)
    else {
      Issue.record("expected a write")
      return
    }
    try rig.repository.revert(write)
    let back = try #require(try rig.repository.entry(id: entry.id))
    #expect(back.transaction.note == nil)
    #expect(back.transaction.mcc == nil)
    #expect(back.transaction.occurredAt == entry.transaction.occurredAt)
    #expect(try rig.files(of: entry.id).isEmpty)
    #expect(try rig.service.repository.attachment(id: try #require(write.attached).id) == nil)
  }

  @Test func whatTheOwnerWroteStaysAndOnlyTheFileIsAdded() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    var entry = try operation(rig, note: "Обед с Аней")
    _ = try rig.repository.edit(id: entry.id, at: instant, calendar: calendar) { fresh in
      var changed = fresh
      changed.transaction.occurredAt = calendar.moment(day, hour: 18, minute: 15)
      changed.transaction.mcc = "5812"
      return changed
    }
    entry = try #require(try rig.repository.entry(id: entry.id))
    guard
      case .written(let write) = try rig.service.supplement(
        rig.repository, id: entry.id, with: screenshot(rig), kind: .other, calendar: calendar,
        now: instant)
    else {
      Issue.record("expected a write")
      return
    }
    #expect(write.edit == nil)
    #expect(write.filled.isEmpty)
    #expect(write.attached != nil)
    #expect(try rig.repository.entry(id: entry.id) == entry)
    try rig.repository.revert(write)
    #expect(try rig.files(of: entry.id).isEmpty)
    #expect(try rig.repository.entry(id: entry.id) == entry)
  }

  @Test func theSameFileIsNotAttachedTwice() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let entry = try operation(rig)
    _ = try rig.service.supplement(
      rig.repository, id: entry.id, with: screenshot(rig), kind: .other, calendar: calendar,
      now: instant)
    let again = try rig.service.supplement(
      rig.repository, id: entry.id, with: screenshot(rig), kind: .other, calendar: calendar,
      now: instant)
    guard case .written(let write) = again else {
      Issue.record("expected a write")
      return
    }
    #expect(write.isEmpty)
    #expect(try rig.files(of: entry.id).count == 1)
    // The import sees who already holds the picture.
    let holders = try rig.service.operations(
      holding: Data("screenshot-bytes".utf8), in: rig.repository)
    #expect(holders == [entry.id])
  }

  @Test func aSplitOperationKeepsItsParts() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let entry = try operation(rig, parts: [600, 400])
    _ = try rig.service.supplement(
      rig.repository, id: entry.id, with: screenshot(rig), kind: .other, calendar: calendar,
      now: instant)
    let stored = try #require(try rig.repository.entry(id: entry.id))
    #expect(stored.parts.map(\.id) == entry.parts.map(\.id))
    #expect(stored.parts.map(\.amountE4) == entry.parts.map(\.amountE4))
    #expect(stored.parts.map(\.categoryId) == entry.parts.map(\.categoryId))
    #expect(stored.transaction.note == "Кофейня")
  }

  @Test func aDeletedOperationGetsNothingAndLeavesNoFileBehind() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let entry = try operation(rig)
    _ = try rig.repository.softDelete(id: entry.id, at: instant)
    let result = try rig.service.supplement(
      rig.repository, id: entry.id, with: screenshot(rig), kind: .other, calendar: calendar,
      now: instant)
    #expect(result == .gone)
    #expect(try rig.service.repository.all().isEmpty)
    #expect(rig.service.store.storedHashes().isEmpty)
  }

  /// The two halves stand or fall together: a row of the file that cannot go in takes the
  /// filled fields back with it.
  @Test func aFileThatCannotBeWrittenLeavesTheOperationAsItWas() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let entry = try operation(rig)
    let other = try operation(rig)
    let taken = try rig.service.add(
      data: Data("another".utf8), fileName: "a.png", to: .transaction, id: other.id, now: instant)
    let (hash, size) = try rig.service.store.put(Data("screenshot-bytes".utf8))
    // The same row id as an existing row: the insert fails inside the write.
    let clash = AttachedFile(
      id: taken.id, ownerKind: .transaction, ownerId: entry.id, contentHash: hash,
      fileName: "screen.png", byteSize: size, addedAt: instant)
    #expect(throws: (any Error).self) {
      try rig.repository.supplement(
        id: entry.id, with: screenshot(rig), attaching: clash, at: instant, calendar: calendar)
    }
    #expect(try rig.repository.entry(id: entry.id) == entry)
    #expect(try rig.files(of: entry.id).isEmpty)
  }

  @Test func aDeletedHolderOrATrashedFileHoldsNothing() throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let entry = try operation(rig)
    let row = try rig.service.add(
      data: Data("picture".utf8), fileName: "p.png", to: .transaction, id: entry.id, now: instant)
    #expect(
      try rig.service.operations(holding: Data("picture".utf8), in: rig.repository)
        == [entry.id])
    try rig.service.moveToTrash(id: row.id, now: instant)
    #expect(try rig.service.operations(holding: Data("picture".utf8), in: rig.repository).isEmpty)
    try rig.service.restoreFromTrash(id: row.id)
    _ = try rig.repository.softDelete(id: entry.id, at: instant)
    #expect(try rig.service.operations(holding: Data("picture".utf8), in: rig.repository).isEmpty)
  }
}
