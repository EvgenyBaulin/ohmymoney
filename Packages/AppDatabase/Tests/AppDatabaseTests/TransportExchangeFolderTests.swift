import AppCore
import Foundation
import Testing

@testable import AppDatabase

/// An envelope-shaped test double, not encryption. Real AES-GCM is covered by the app tests.
private struct EnvelopeFixtureCodec: PayloadCodec {
  private let prefix = Data(SealedPayloadCodec.magic) + Data(repeating: 0, count: 12)
  func encode(_ plain: Data) throws -> Data { prefix + plain + Data(repeating: 0, count: 16) }
  func decode(_ stored: Data) throws -> Data {
    guard stored.starts(with: prefix), stored.count >= prefix.count + 16 else {
      throw SyncError.codec
    }
    return Data(stored.dropFirst(prefix.count).dropLast(16))
  }
}

private final class FileTransportFixture: ExchangeFileTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [String: Data] = [:]
  private var commitFailure = false
  private var loseReply = false

  func failNextCommit(afterSaving: Bool = false) {
    lock.withLock {
      commitFailure = true
      loseReply = afterSaving
    }
  }

  func files() throws -> [ExchangeFileInfo] {
    lock.withLock {
      bytes.keys.sorted().reversed().map {
        ExchangeFileInfo(name: $0, modified: Date(timeIntervalSince1970: 1_900_000_000))
      }
    }
  }

  func readFile(named name: String) throws -> Data {
    try lock.withLock {
      guard let value = bytes[name] else { throw ExchangeTransportError.missing }
      return value
    }
  }

  func writeFile(named name: String, data: Data, replacing: Bool) throws {
    try lock.withLock {
      if let old = bytes[name], !replacing, old != data {
        throw ExchangeTransportError.fileChanged
      }
      let fail = commitFailure
      commitFailure = false
      if !fail || loseReply { bytes[name] = data }
      if fail { throw ExchangeTransportError.unavailable }
    }
  }
}

@Suite("Encrypted remote files use the folder exchange without network access")
struct TransportExchangeFolderTests {
  private func device(_ id: String) throws -> TestDevice {
    try TestDevice(id, journalCodec: EnvelopeFixtureCodec(), snapshotCodec: EnvelopeFixtureCodec())
  }

  @Test func temporaryBytesStayLocalAndJournalRetriesAreImmutable() throws {
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    let name = SyncFormat.fileName(deviceId: "mac", sequence: 0)
    let temporary = SyncFormat.temporaryPrefix + name
    let data = try EnvelopeFixtureCodec().encode(Data("synthetic".utf8))
    try folder.put(temporaryName: temporary, data: data)
    #expect(try transport.files().isEmpty)
    #expect(try folder.listNames().isEmpty)
    transport.failNextCommit(afterSaving: true)
    #expect(throws: ExchangeTransportError.unavailable) {
      try folder.rename(temporaryName: temporary, to: name)
    }
    try folder.rename(temporaryName: temporary, to: name)
    #expect(try folder.read(name: name) == data)
    try folder.put(temporaryName: temporary, data: data + Data([1]))
    #expect(throws: ExchangeTransportError.fileChanged) {
      try folder.rename(temporaryName: temporary, to: name)
    }
    #expect(try folder.read(name: name) == data)
  }

  @Test func plaintextTruncatedEnvelopesAndNonExchangeNamesNeverReachTheTransport() throws {
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    let name = SyncFormat.fileName(deviceId: "mac", sequence: 0)
    for data in [Data("{}".utf8), Data(SealedPayloadCodec.magic)] {
      #expect(throws: SyncError.codec) {
        try folder.put(temporaryName: SyncFormat.temporaryPrefix + name, data: data)
      }
    }
    for invalid in ["finance.sqlite", "finance.sqlite-wal", "finance.sqlite-shm", "../x"] {
      #expect(throws: SyncFolderError.refusedName) { try folder.read(name: invalid) }
      #expect(throws: SyncFolderError.refusedName) {
        try folder.put(temporaryName: SyncFormat.temporaryPrefix + invalid, data: Data())
      }
      #expect(throws: SyncFolderError.refusedName) {
        try folder.rename(temporaryName: SyncFormat.temporaryPrefix + name, to: invalid)
      }
    }
    #expect(try transport.files().isEmpty)
  }

  @Test func failedCommitRetainsTheOutboxAndARepeatAppliesOnlyOnce() throws {
    let transport = FileTransportFixture()
    let macFolder = TransportExchangeFolder(transport: transport)
    let phoneFolder = TransportExchangeFolder(transport: transport)
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.insertOperation("t1", note: "synthetic")
    let pending = try mac.outboxCount()
    transport.failNextCommit()
    #expect(throws: SyncFailure.folderNotWritable) { try mac.exchange.exchange(with: macFolder) }
    #expect(try mac.outboxCount() == pending)
    #expect(try transport.files().isEmpty)
    _ = try mac.exchange.exchange(with: macFolder)
    #expect(try mac.outboxCount() == 0)
    _ = try phone.exchange.exchange(with: phoneFolder)
    #expect(try phone.books() == mac.books())
    let repeated = try phone.exchange.exchange(with: phoneFolder)
    #expect(repeated.recordsApplied == 0 && repeated.entriesWritten == 0)
    #expect(try phone.count("transactions") == 1)
  }

  @Test func remotePlaintextIsNeverAppliedOrRemembered() throws {
    let transport = FileTransportFixture()
    let name = SyncFormat.fileName(deviceId: "mac", sequence: 0)
    try transport.writeFile(named: name, data: Data("{}".utf8), replacing: false)
    let phone = try device("phone")
    #expect(throws: SyncFailure.filesNotReadable) {
      try phone.exchange.exchange(with: TransportExchangeFolder(transport: transport))
    }
    #expect(try phone.count("transactions") == 0)
    #expect(
      try DatabaseSyncStateStore(writer: phone.stack.writer).load().appliedFileNames.isEmpty)
  }

  @Test func newerJournalVersionsStayUnapplied() throws {
    let transport = FileTransportFixture()
    let name = SyncFormat.fileName(deviceId: "mac", sequence: 0)
    try transport.writeFile(
      named: name,
      data: EnvelopeFixtureCodec().encode(Data("{\"formatVersion\":999}".utf8)), replacing: false)
    let phone = try device("phone")
    let outcome = try phone.exchange.exchange(with: TransportExchangeFolder(transport: transport))
    #expect(outcome.filesFromNewerVersion == 1)
    #expect(outcome.recordsApplied == 0)
    #expect(
      try DatabaseSyncStateStore(writer: phone.stack.writer).load().appliedFileNames.isEmpty)
  }

  @Test func snapshotsAndJournalsCannotCrossTheirSeams() throws {
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    let journal = SyncFormat.fileName(deviceId: "mac", sequence: 0)
    let snapshot = SyncSnapshotName.fileName(deviceId: "mac")
    let sealed = try EnvelopeFixtureCodec().encode(Data("synthetic".utf8))
    try transport.writeFile(named: journal, data: sealed, replacing: false)
    try transport.writeFile(named: snapshot, data: sealed, replacing: true)
    #expect(try folder.listNames() == [journal])
    #expect(try folder.snapshots().map(\.name) == [snapshot])
    #expect(throws: SyncFolderError.refusedName) { try folder.read(name: snapshot) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: SyncFolderError.refusedName) {
      try folder.putSnapshot(named: journal, from: file)
    }
    #expect(throws: SyncFolderError.refusedName) {
      try folder.fetchSnapshot(named: journal, to: file)
    }
    try Data("SQLite format 3\0synthetic".utf8).write(to: file)
    #expect(throws: SyncError.codec) { try folder.putSnapshot(named: snapshot, from: file) }
    #expect(try transport.readFile(named: snapshot) == sealed)
  }

  @Test func lostCommitReplyCanBeRetriedWithoutLosingChanges() throws {
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.insertOperation("t1", note: "synthetic")
    transport.failNextCommit(afterSaving: true)
    #expect(throws: SyncFailure.folderNotWritable) { try mac.exchange.exchange(with: folder) }
    #expect(try mac.outboxCount() > 0)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: TransportExchangeFolder(transport: transport))
    #expect(try phone.books() == mac.books())
    #expect(try phone.exchange.conflicts().isEmpty)
    #expect(try mac.outboxCount() == 0)
  }

  @Test func competingEditsWaitForTheOwnersChoice() throws {
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.insertOperation("t1", note: "initial")
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.setNote("t1", "mac edit")
    try mac.stamp("2026-10-22T10:01:00Z")
    try phone.setNote("t1", "phone edit")
    try phone.stamp("2026-10-22T10:02:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try mac.exchange.exchange(with: folder)
    #expect(try mac.note("t1") == "mac edit")
    #expect(try phone.note("t1") == "phone edit")
    let conflict = try #require(try mac.exchange.conflicts().first)
    #expect(conflict.key == RecordKey(table: "transactions", uuid: "t1"))
    try mac.exchange.takeTheirs(conflict.key)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try mac.note("t1") == "phone edit")
    #expect(try mac.exchange.conflicts().isEmpty)
    #expect(try phone.exchange.conflicts().isEmpty)
  }

  @Test func snapshotsReplaceWholeFilesAndAreVerifiedWithTheExistingCodec() throws {
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    let mac = try device("mac")
    try mac.insertOperation("t1", note: "first")
    #expect(try mac.exchange.snapshotIfDue(to: folder, force: true))
    let first = try #require(try SyncSnapshots.newest(in: folder))
    let oldBytes = try transport.readFile(named: first.name)
    try mac.setNote("t1", "second")
    transport.failNextCommit()
    #expect(throws: ExchangeTransportError.unavailable) {
      try mac.exchange.snapshotIfDue(to: folder, force: true)
    }
    #expect(try transport.readFile(named: first.name) == oldBytes)
    #expect(try mac.exchange.snapshotIfDue(to: folder, force: true))
    #expect(try folder.snapshots().count == 1)
    #expect(try folder.listNames().isEmpty)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try SyncSnapshots.fetchVerified(
      first, from: folder, to: file, schema: TestSupport.schemaSource, codec: EnvelopeFixtureCodec()
    )
    #expect(try DatabaseStack.check(fileAt: file, schema: TestSupport.schemaSource) == .sound)
  }

  @Test func changingStorageCarriesExactHistoryAndRefusesMissingFiles() throws {
    let mac = try device("mac")
    let source = InMemoryFolder()
    try mac.insertOperation("t1", note: "synthetic")
    _ = try mac.exchange.exchange(with: source)
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    #expect(throws: SyncFailure.folderNotReadable) { try mac.exchange.prepareRemoteFolder(folder) }
    try mac.exchange.prepareRemoteFolder(folder, copyingFrom: source)
    try mac.exchange.prepareRemoteFolder(folder, copyingFrom: source)
    for name in try source.listNames() {
      #expect(try folder.read(name: name) == source.read(name: name))
    }
    let phone = try device("phone")
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.books() == mac.books())
    #expect(try mac.exchange.exchange(with: folder).filesDamaged == 0)
  }

  @Test func changingStorageDoesNotSendLegacyPlaintext() throws {
    let mac = try TestDevice("mac")
    let source = InMemoryFolder()
    try mac.insertOperation("t1", note: "synthetic")
    _ = try mac.exchange.exchange(with: source)
    let transport = FileTransportFixture()
    let folder = TransportExchangeFolder(transport: transport)
    #expect(throws: SyncFailure.filesNotReadable) {
      try mac.exchange.prepareRemoteFolder(folder, copyingFrom: source)
    }
    #expect(try transport.files().isEmpty)
    #expect(try mac.note("t1") == "synthetic")
  }
}
