import AppCore
import Foundation
import Testing

@testable import AppDatabase

/// Checks the database wiring, not cryptography. The app tests use real AES-GCM.
private struct MarkedCodec: PayloadCodec {
  let marker: Data
  func encode(_ plain: Data) throws -> Data { marker + plain }
  func decode(_ stored: Data) throws -> Data {
    guard stored.starts(with: marker) else { throw SyncError.codec }
    return Data(stored.dropFirst(marker.count))
  }
}

@Suite("The database exchange uses the supplied journal and snapshot codecs")
struct SyncCodecIntegrationTests {
  @Test func encryptionFailureKeepsTheOutboxAndWritesNoFile() throws {
    struct MissingKey: PayloadCodec {
      func encode(_ plain: Data) throws -> Data { throw SyncError.codec }
      func decode(_ stored: Data) throws -> Data { throw SyncError.codec }
    }
    let device = try TestDevice("mac", journalCodec: MissingKey())
    try device.insertOperation("t1", note: "synthetic")
    let pending = try device.outboxCount()
    #expect(pending > 0)
    let folder = InMemoryFolder()
    #expect(throws: SyncError.codec) { try device.exchange.flush(to: folder) }
    #expect(try device.outboxCount() == pending)
    #expect(try folder.listNames().isEmpty)
  }

  @Test func journalEncodingAndDecodingUseTheCodec() throws {
    let codec = MarkedCodec(marker: Data("synthetic-journal".utf8))
    let mac = try TestDevice("mac", journalCodec: codec)
    let phone = try TestDevice("phone", journalCodec: codec)
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "synthetic")
    #expect(try mac.exchange.flush(to: folder) > 0)
    for name in try folder.listNames() {
      #expect(try folder.read(name: name).starts(with: codec.marker))
    }
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.note("t1") == "synthetic")
    let stranger = try TestDevice("stranger")
    let refused = try stranger.exchange.exchange(with: folder)
    #expect(refused.filesDamaged > 0)
    #expect(try stranger.note("t1") == nil)
  }

  @Test func snapshotEncodingAndVerificationUseTheCodec() throws {
    let codec = MarkedCodec(marker: Data("synthetic-snapshot".utf8))
    let mac = try TestDevice("mac", snapshotCodec: codec)
    try mac.insertOperation("t1", note: "synthetic")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-codec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = DirectoryJournalFolder(url: directory)
    #expect(try mac.exchange.snapshotIfDue(to: folder, force: true))
    let info = try #require(try SyncSnapshots.newest(in: folder))
    #expect(
      try Data(contentsOf: directory.appendingPathComponent(info.name)).starts(with: codec.marker))
    let fetched = directory.appendingPathComponent("verified.sqlite")
    try SyncSnapshots.fetchVerified(
      info, from: folder, to: fetched, schema: TestSupport.schemaSource, codec: codec)
    #expect(try DatabaseStack.check(fileAt: fetched, schema: TestSupport.schemaSource) == .sound)
    #expect(throws: SyncSnapshotError.damaged) {
      try SyncSnapshots.fetchVerified(
        info, from: folder, to: fetched, schema: TestSupport.schemaSource,
        codec: MarkedCodec(marker: Data("foreign".utf8)))
    }
    #expect(!FileManager.default.fileExists(atPath: fetched.path))
  }
}
