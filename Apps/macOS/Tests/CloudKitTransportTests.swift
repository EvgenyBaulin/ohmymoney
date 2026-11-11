import AppCore
import AppDatabase
import CloudKit
import XCTest

@testable import OhMyMoney

private final class CloudFileTestTransport: ExchangeFileTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: Data] = [:]

  func files() throws -> [ExchangeFileInfo] {
    lock.withLock {
      stored.keys.sorted().reversed().map { ExchangeFileInfo(name: $0, modified: Date()) }
    }
  }

  func readFile(named name: String) throws -> Data {
    try lock.withLock {
      guard let data = stored[name] else { throw ExchangeTransportError.missing }
      return data
    }
  }

  func writeFile(named name: String, data: Data, replacing: Bool) throws {
    try lock.withLock {
      if let old = stored[name], !replacing, old != data {
        throw ExchangeTransportError.fileChanged
      }
      stored[name] = data
    }
  }
}

private final class PausedCloudTestTransport: ExchangeFileTransport, @unchecked Sendable {
  let entered: XCTestExpectation
  private let lock = NSLock()
  private let released = DispatchSemaphore(value: 0)
  private var didPause = false

  init(entered: XCTestExpectation) { self.entered = entered }

  func resume() { released.signal() }

  func files() throws -> [ExchangeFileInfo] {
    let pause = lock.withLock {
      if didPause { return false }
      didPause = true
      return true
    }
    if pause {
      entered.fulfill()
      guard released.wait(timeout: .now() + .seconds(10)) == .success else {
        throw ExchangeTransportError.unavailable
      }
    }
    return []
  }

  func readFile(named name: String) throws -> Data { throw ExchangeTransportError.missing }
  func writeFile(named name: String, data: Data, replacing: Bool) throws {}
}

/// Runs on Mac, iPhone and iPad without a container, entitlements, an account or network.
@MainActor
final class CloudKitTransportTests: XCTestCase {
  private let key = SyncKey(bytes: Array(0..<32))!

  private func codec(_ purpose: SyncKey.Purpose) -> RecoveryPayloadCodec {
    RecoveryPayloadCodec(store: InMemorySyncKeyStore(key), purpose: purpose)
  }

  func testShippingBuildCannotBeEnabledByAStoredSetting() throws {
    let suite = "cloudkit-disabled-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertNil(CloudKitSync.makeFolder(defaults: defaults))
    #if !OHMYMONEY_CLOUDKIT
      defaults.set(true, forKey: CloudKitSync.enabledKey)
      defaults.set("iCloud.synthetic.unprovisioned", forKey: CloudKitSync.containerKey)
      XCTAssertFalse(CloudKitSync.isCompiledIn)
      XCTAssertNil(CloudKitSync.makeFolder(defaults: defaults))
    #else
      XCTAssertTrue(CloudKitSync.isCompiledIn)
      defaults.set(true, forKey: CloudKitSync.enabledKey)
      XCTAssertNil(CloudKitSync.makeFolder(defaults: defaults), "no default container")
    #endif
  }

  func testWireRecordContainsOnlyTheEnvelopeAndIdentifiers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("payload")
    let plain = Data("{\"note\":\"synthetic private note\"}".utf8)
    let sealed = try codec(.journal).encode(plain)
    try sealed.write(to: file)
    let record = CKRecord(
      recordType: CloudKitExchangeSchema.recordType,
      recordID: CKRecord.ID(
        recordName: SyncFormat.fileName(deviceId: "mac", sequence: 0),
        zoneID: CKRecordZone.ID(
          zoneName: CloudKitExchangeSchema.zoneName, ownerName: CKCurrentUserDefaultName)))
    record[CloudKitExchangeSchema.versionKey] = NSNumber(value: CloudKitExchangeSchema.version)
    record[CloudKitExchangeSchema.kindKey] = "journal" as NSString
    record[CloudKitExchangeSchema.payloadKey] = CKAsset(fileURL: file)
    XCTAssertEqual(
      Set(record.allKeys()),
      Set([
        CloudKitExchangeSchema.versionKey, CloudKitExchangeSchema.kindKey,
        CloudKitExchangeSchema.payloadKey,
      ]))
    XCTAssertEqual(try CloudKitExchangeSchema.payload(of: record), sealed)
    XCTAssertEqual(try codec(.journal).decode(sealed), plain)
    XCTAssertNil(sealed.range(of: Data("synthetic private note".utf8)))
    XCTAssertThrowsError(try codec(.snapshot).decode(sealed))
    record[CloudKitExchangeSchema.versionKey] = NSNumber(value: 2)
    XCTAssertThrowsError(try CloudKitExchangeSchema.payload(of: record))
    record[CloudKitExchangeSchema.versionKey] = NSNumber(value: 1.5)
    XCTAssertThrowsError(try CloudKitExchangeSchema.payload(of: record))
    record[CloudKitExchangeSchema.versionKey] = NSNumber(value: 1)
    record[CloudKitExchangeSchema.kindKey] = "snapshot" as NSString
    XCTAssertThrowsError(try CloudKitExchangeSchema.payload(of: record))
    record[CloudKitExchangeSchema.kindKey] = "journal" as NSString
    try plain.write(to: file)
    XCTAssertThrowsError(try CloudKitExchangeSchema.payload(of: record))
    for name in ["finance.sqlite", "finance.sqlite-wal", "finance.sqlite-shm", "../payload"] {
      XCTAssertThrowsError(try CloudKitExchangeSchema.kind(for: name))
    }
  }

  func testCoordinatorUsesTheRemoteFolderWithRealEncryptionAndNoBookmark() async throws {
    let mac = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let phone = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    defer {
      try? mac.close()
      try? phone.close()
    }
    let suite = "cloudkit-coordinator-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = CloudFileTestTransport()
    let folder = TransportExchangeFolder(transport: transport)
    func coordinator(_ stack: DatabaseStack, id: String) throws -> SyncCoordinator {
      let exchange = try SyncExchange(
        writer: stack.writer, deviceId: id, deviceName: "Synthetic",
        journalCodec: codec(.journal), snapshotCodec: codec(.snapshot))
      try exchange.setRecording(true)
      return SyncCoordinator(
        exchange: exchange, bookmarks: BookmarkStore(key: "cloudkit-bookmark-\(suite)-\(id)"),
        defaults: defaults, snapshotCodec: codec(.snapshot), remoteFolder: folder)
    }
    let sender = try coordinator(mac, id: "mac")
    let receiver = try coordinator(phone, id: "phone")
    var draft = TransactionDraft(
      occurredAt: Date(timeIntervalSince1970: 1_789_000_000),
      amount: AmountE4(whole: 1), note: "synthetic encrypted note")
    draft.normalizeSinglePart()
    let saved = try TransactionRepository(writer: mac.writer).save(try draft.materialize())
    XCTAssertTrue(sender.hasFolder)
    XCTAssertNil(sender.folderName)
    await sender.syncNow()
    XCTAssertNotNil(sender.lastOutcome)
    XCTAssertTrue(sender.lastOutcome?.snapshotWritten == true)
    await receiver.syncNow()
    XCTAssertNotNil(receiver.lastOutcome)
    XCTAssertEqual(
      try TransactionRepository(writer: phone.writer).entry(id: saved.id)?.transaction.note,
      "synthetic encrypted note")
    await receiver.syncNow()
    XCTAssertEqual(receiver.lastOutcome?.recordsApplied, 0)
    for info in try transport.files() {
      let stored = try transport.readFile(named: info.name)
      XCTAssertTrue(SealedPayloadCodec.isSealed(stored))
      XCTAssertNil(stored.range(of: Data("synthetic encrypted note".utf8)))
    }
    let snapshot = try XCTUnwrap(SyncSnapshots.newest(in: folder))
    let verified = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: verified) }
    try SyncSnapshots.fetchVerified(
      snapshot, from: folder, to: verified, schema: BundleSchemaSource(bundle: .main),
      codec: codec(.snapshot))
    XCTAssertEqual(
      try DatabaseStack.check(fileAt: verified, schema: BundleSchemaSource(bundle: .main)), .sound)
  }

  func testCancelledShutdownStillWaitsForTheRemoteExchangeBeforeClosingTheDatabase() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    defer { try? stack.close() }
    let suite = "cloudkit-shutdown-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let entered = expectation(description: "remote request started")
    let transport = PausedCloudTestTransport(entered: entered)
    let coordinator = SyncCoordinator(
      exchange: try SyncExchange(writer: stack.writer, deviceId: "mac", deviceName: "Synthetic"),
      defaults: defaults, remoteFolder: TransportExchangeFolder(transport: transport))
    let running = Task { await coordinator.syncNow() }
    await fulfillment(of: [entered], timeout: 5)
    let stopping = expectation(description: "shutdown started")
    var didStop = false
    let shutdown = Task {
      stopping.fulfill()
      await coordinator.stop()
      didStop = true
    }
    shutdown.cancel()
    await fulfillment(of: [stopping], timeout: 5)
    XCTAssertFalse(didStop, "the database must stay open while the remote call waits")
    transport.resume()
    await running.value
    await shutdown.value
    XCTAssertTrue(didStop)
    XCTAssertNotNil(coordinator.lastOutcome)
  }
}
