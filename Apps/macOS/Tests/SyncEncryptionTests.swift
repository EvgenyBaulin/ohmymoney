import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

final class SyncEncryptionTests: XCTestCase {
  private let key = SyncKey(bytes: Array(0..<32))!

  private func codec(_ key: SyncKey?, purpose: SyncKey.Purpose = .journal) -> RecoveryPayloadCodec {
    RecoveryPayloadCodec(store: InMemorySyncKeyStore(key), purpose: purpose)
  }

  func testRoundTripAndForeignKeyRefusal() throws {
    let plain = Data("{\"version\":1,\"synthetic\":true}".utf8)
    let sealed = try codec(key).encode(plain)
    XCTAssertTrue(SealedPayloadCodec.isSealed(sealed))
    XCTAssertEqual(try codec(key).decode(sealed), plain)
    XCTAssertThrowsError(try codec(SyncKey(bytes: Array(repeating: 99, count: 32))!).decode(sealed))
    XCTAssertThrowsError(try codec(nil).decode(sealed))
    var changed = sealed
    changed[changed.count - 1] ^= 1
    XCTAssertThrowsError(try codec(key).decode(changed))
  }

  func testLegacyJournalAndSnapshotStillRead() throws {
    let json = Data("{\"version\":1}".utf8)
    XCTAssertEqual(try codec(nil).decode(json), json)
    let sqlite = Data("SQLite format 3\0synthetic fixture".utf8)
    XCTAssertEqual(try codec(nil, purpose: .snapshot).decode(sqlite), sqlite)
    XCTAssertThrowsError(try codec(nil).decode(sqlite))
    XCTAssertThrowsError(try codec(key, purpose: .snapshot).decode(json))
    XCTAssertThrowsError(try codec(key).decode(Data("OMMSEAL2".utf8)))
  }

  func testSnapshotUsesAnotherDerivedKeyAndFreshNonces() throws {
    let plain = Data("SQLite format 3\0synthetic fixture".utf8)
    let snapshots = codec(key, purpose: .snapshot)
    let first = try snapshots.encode(plain)
    XCTAssertNotEqual(first, try snapshots.encode(plain))
    XCTAssertEqual(try snapshots.decode(first), plain)
    XCTAssertThrowsError(try codec(key).decode(first))
  }

  func testRecoveryWordsReplaceTheKeyUsedByAnExistingCodec() throws {
    let store = InMemorySyncKeyStore()
    let reader = RecoveryPayloadCodec(store: store, purpose: .journal)
    let sealed = try codec(key).encode(Data("{}".utf8))
    XCTAssertThrowsError(try reader.decode(sealed))
    try store.recover(from: key.recoveryWords.joined(separator: " "))
    XCTAssertEqual(try reader.decode(sealed), Data("{}".utf8))
    XCTAssertThrowsError(try store.recover(from: "not a recovery code"))
    XCTAssertEqual(store.load(), key)
  }

  func testWritingWaitsForTheRecoveryKeyAndNeverInventsOneForAnotherDevice() throws {
    let store = InMemorySyncKeyStore()
    let writer = RecoveryPayloadCodec(store: store, purpose: .journal)
    XCTAssertThrowsError(try writer.encode(Data("{}".utf8)))
    XCTAssertNil(store.load(), "joining a folder must not silently create a different key")
    let saved = try store.keyCreatingIfNeeded().key
    let first = try writer.encode(Data("{}".utf8))
    _ = try writer.encode(Data("{}".utf8))
    XCTAssertEqual(store.load(), saved)
    XCTAssertEqual(saved.recoveryWords.count, 24)
    XCTAssertEqual(try codec(saved).decode(first), Data("{}".utf8))
  }

  func testAnUnreadableKeyIsNeverReplacedWithANewOne() {
    struct Unreadable: SyncKeyStoring {
      enum Failure: Error, Equatable { case locked, unexpectedSave }
      func load() -> SyncKey? { nil }
      func read() throws -> SyncKey? { throw Failure.locked }
      func save(_ key: SyncKey) throws { throw Failure.unexpectedSave }
    }
    let codec = RecoveryPayloadCodec(store: Unreadable(), purpose: .journal)
    XCTAssertThrowsError(try codec.encode(Data("{}".utf8))) {
      XCTAssertEqual($0 as? Unreadable.Failure, .locked)
    }
  }

  func testAES256GCMNISTVector() throws {
    // NIST SP 800-38D, AES-256-GCM, zero key/IV and one zero block.
    let cipher = CryptoKitArchiveCipher()
    let plain = Data(repeating: 0, count: 16)
    let secret = Data(repeating: 0, count: 32)
    let nonce = Data(repeating: 0, count: 12)
    let sealed = try cipher.seal(plaintext: plain, key: secret, nonce: nonce)
    let hex = sealed.map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(hex, "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")
    XCTAssertEqual(try cipher.open(sealed: sealed, key: secret, nonce: nonce), plain)
  }

  @MainActor
  func testProductionWiringEncryptsTheJournalAndTheDatabaseSnapshot() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    defer { try? stack.close() }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-encryption-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "sync-encryption-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let coordinator = try XCTUnwrap(
      SyncWiring.makeCoordinator(
        writer: stack.writer, isRealDatabase: true, defaults: defaults, deviceName: "Synthetic",
        protected: SyncProtectedFolders(fixed: []), language: nil,
        keyStore: InMemorySyncKeyStore(key)))
    let exchange = try XCTUnwrap(coordinator.exchange)
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO transactions
            (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
          VALUES ('synthetic', 'expense', '2026-11-01 10:00:00.000', 10000, 10000,
                  'synthetic note', '2026-11-01 10:00:00.000', '2026-11-01 10:00:00.000')
          """)
    }
    let folder = DirectoryJournalFolder(url: directory)
    XCTAssertGreaterThan(try exchange.flush(to: folder), 0)
    let journalName = try XCTUnwrap(
      folder.listNames().first { SyncFormat.parse(fileName: $0) != nil })
    let journal = try folder.read(name: journalName)
    XCTAssertTrue(SealedPayloadCodec.isSealed(journal))
    XCTAssertTrue(
      try JournalCoder.decode(journal, codec: codec(key)).entries.contains {
        $0.uuid == "synthetic"
      })
    XCTAssertTrue(try exchange.snapshotIfDue(to: folder, force: true))
    let snapshot = try XCTUnwrap(SyncSnapshots.newest(in: folder))
    let sealed = try Data(contentsOf: directory.appendingPathComponent(snapshot.name))
    XCTAssertTrue(SealedPayloadCodec.isSealed(sealed))
    let fetched = directory.appendingPathComponent("verified.sqlite")
    try SyncSnapshots.fetchVerified(
      snapshot, from: folder, to: fetched, schema: BundleSchemaSource(bundle: .main),
      codec: codec(key, purpose: .snapshot))
    XCTAssertEqual(
      try DatabaseStack.check(fileAt: fetched, schema: BundleSchemaSource(bundle: .main)), .sound)
  }
}
