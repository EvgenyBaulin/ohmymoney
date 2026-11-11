import AppCore
import AppDatabase
import CloudKit
import Foundation

/// No container is constructed unless both the build and this device explicitly opt in.
/// The container identifier is supplied after provisioning; it has no shipping default.
enum CloudKitSync {
  static let enabledKey = "sync.cloudKit.enabled"
  static let containerKey = "sync.cloudKit.container"

  static var isCompiledIn: Bool {
    #if OHMYMONEY_CLOUDKIT
      true
    #else
      false
    #endif
  }

  static func makeFolder(defaults: UserDefaults) -> TransportExchangeFolder? {
    #if OHMYMONEY_CLOUDKIT
      guard defaults.bool(forKey: enabledKey),
        let identifier = defaults.string(forKey: containerKey),
        identifier.hasPrefix("iCloud."), identifier.count > "iCloud.".count
      else { return nil }
      return TransportExchangeFolder(
        transport: CloudKitFileTransport(
          database: CKContainer(identifier: identifier).privateCloudDatabase))
    #else
      return nil
    #endif
  }
}

/// The CloudKit wire contract. Only identifiers, an envelope version and an encrypted asset
/// leave the device. Record names are the existing journal/snapshot file names.
enum CloudKitExchangeSchema {
  static let zoneName = "OhMyMoneyExchangeV1"
  static let recordType = "OMMExchangeFile"
  static let payloadKey = "payload"
  static let versionKey = "formatVersion"
  static let kindKey = "kind"
  static let version = 1

  static func kind(for name: String) throws -> String {
    if SyncFormat.parse(fileName: name) != nil { return "journal" }
    if SyncSnapshotName.parse(name) != nil { return "snapshot" }
    throw ExchangeTransportError.malformed
  }

  static func validate(_ record: CKRecord) throws {
    guard record.recordType == recordType,
      record.recordID.zoneID.zoneName == zoneName,
      record.recordID.zoneID.ownerName == CKCurrentUserDefaultName,
      (record[versionKey] as? NSNumber) == NSNumber(value: version),
      (record[kindKey] as? String) == (try kind(for: record.recordID.recordName))
    else { throw ExchangeTransportError.malformed }
  }

  static func payload(of record: CKRecord) throws -> Data {
    try validate(record)
    guard let asset = record[payloadKey] as? CKAsset, let url = asset.fileURL else {
      throw ExchangeTransportError.malformed
    }
    let data = try Data(contentsOf: url)
    guard SealedPayloadCodec.isSealed(data),
      data.count >= SealedPayloadCodec.magic.count + SealedPayloadCodec.nonceByteCount
        + SealedPayloadCodec.tagByteCount
    else { throw ExchangeTransportError.malformed }
    return data
  }
}

/// A blocking adapter for the exchange's blocking folder seam. CloudKit callbacks run on
/// its own queues; the caller must run off the main thread. SDK errors
/// are reduced to fixed errors here so server descriptions cannot enter the app's logs.
private final class CloudKitFileTransport: ExchangeFileTransport, @unchecked Sendable {
  private typealias Page = (
    matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
    queryCursor: CKQueryOperation.Cursor?
  )

  private let database: CKDatabase
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitExchangeSchema.zoneName, ownerName: CKCurrentUserDefaultName)
  private let zoneLock = NSLock()
  private var zoneReady = false

  init(database: CKDatabase) {
    self.database = database
  }

  func files() throws -> [ExchangeFileInfo] {
    try sanitized {
      try prepareZone()
      var page: Page = try wait { completion in
        database.fetch(
          withQuery: CKQuery(
            recordType: CloudKitExchangeSchema.recordType, predicate: NSPredicate(value: true)),
          inZoneWith: zoneID,
          desiredKeys: [CloudKitExchangeSchema.versionKey, CloudKitExchangeSchema.kindKey],
          completionHandler: completion)
      }
      var files: [ExchangeFileInfo] = []
      while true {
        for (_, result) in page.matchResults {
          let record = try result.get()
          try CloudKitExchangeSchema.validate(record)
          guard let modified = record.modificationDate else {
            throw ExchangeTransportError.malformed
          }
          files.append(ExchangeFileInfo(name: record.recordID.recordName, modified: modified))
        }
        guard let cursor = page.queryCursor else { return files }
        page = try wait { completion in
          database.fetch(
            withCursor: cursor,
            desiredKeys: [CloudKitExchangeSchema.versionKey, CloudKitExchangeSchema.kindKey],
            completionHandler: completion)
        }
      }
    }
  }

  func readFile(named name: String) throws -> Data {
    try sanitized {
      _ = try CloudKitExchangeSchema.kind(for: name)
      try prepareZone()
      guard let record = try fetch(name) else { throw ExchangeTransportError.missing }
      return try CloudKitExchangeSchema.payload(of: record)
    }
  }

  func writeFile(named name: String, data: Data, replacing: Bool) throws {
    try sanitized {
      let kind = try CloudKitExchangeSchema.kind(for: name)
      guard !replacing || kind == "snapshot", SealedPayloadCodec.isSealed(data),
        data.count >= SealedPayloadCodec.magic.count + SealedPayloadCodec.nonceByteCount
          + SealedPayloadCodec.tagByteCount
      else { throw ExchangeTransportError.malformed }
      try prepareZone()
      let existing = try fetch(name)
      if let existing, !replacing {
        guard try CloudKitExchangeSchema.payload(of: existing) == data else {
          throw ExchangeTransportError.fileChanged
        }
        return
      }
      let record =
        existing
        ?? CKRecord(
          recordType: CloudKitExchangeSchema.recordType,
          recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
      if existing != nil { try CloudKitExchangeSchema.validate(record) }
      let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("ohmymoney-cloud-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: scratch) }
      let file = scratch.appendingPathComponent("payload")
      try data.write(to: file, options: .atomic)
      record[CloudKitExchangeSchema.payloadKey] = CKAsset(fileURL: file)
      record[CloudKitExchangeSchema.versionKey] = NSNumber(value: CloudKitExchangeSchema.version)
      record[CloudKitExchangeSchema.kindKey] = kind as NSString
      do {
        let _: CKRecord = try wait { completion in
          database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
          ) { result in
            completion(
              Result {
                let results = try result.get()
                guard let saved = results.saveResults[record.recordID] else {
                  throw ExchangeTransportError.unavailable
                }
                return try saved.get()
              })
          }
        }
      } catch {
        // A concurrent create or a lost reply is success only for exactly the same journal.
        if !replacing, let saved = try? fetch(name),
          (try? CloudKitExchangeSchema.payload(of: saved)) == data
        {
          return
        }
        throw error
      }
    }
  }

  private func prepareZone() throws {
    try zoneLock.withLock {
      guard !zoneReady else { return }
      do {
        let _: CKRecordZone = try wait { completion in
          database.fetch(withRecordZoneID: zoneID) { zone, error in
            if let error {
              completion(.failure(error))
            } else if let zone {
              completion(.success(zone))
            } else {
              completion(.failure(ExchangeTransportError.unavailable))
            }
          }
        }
      } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
        let _: CKRecordZone = try wait { completion in
          database.save(CKRecordZone(zoneID: zoneID)) { zone, error in
            if let error {
              completion(.failure(error))
            } else if let zone {
              completion(.success(zone))
            } else {
              completion(.failure(ExchangeTransportError.unavailable))
            }
          }
        }
      }
      zoneReady = true
    }
  }

  private func fetch(_ name: String) throws -> CKRecord? {
    do {
      return try wait { completion in
        database.fetch(withRecordID: CKRecord.ID(recordName: name, zoneID: zoneID)) {
          record, error in
          if let error {
            completion(.failure(error))
          } else if let record {
            completion(.success(record))
          } else {
            completion(.failure(ExchangeTransportError.unavailable))
          }
        }
      }
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }

  private func sanitized<T>(_ body: () throws -> T) throws -> T {
    guard !Thread.isMainThread else { throw ExchangeTransportError.mainThread }
    do { return try body() } catch let error as ExchangeTransportError { throw error } catch {
      // A deleted zone is retried on the next exchange, as are account and network failures.
      zoneLock.withLock { zoneReady = false }
      throw ExchangeTransportError.unavailable
    }
  }

  private func wait<T: Sendable>(
    _ start: (@escaping @Sendable (Result<T, any Error>) -> Void) -> Void
  ) throws -> T {
    let reply = CloudKitReply<T>()
    start { reply.finish($0) }
    return try reply.get()
  }
}

/// The SDK owns the callback queue; a lock protects the handoff to the blocking folder caller.
private final class CloudKitReply<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var result: Result<Value, any Error>?

  func finish(_ result: Result<Value, any Error>) {
    lock.withLock { self.result = result }
    ready.signal()
  }

  func get() throws -> Value {
    guard ready.wait(timeout: .now() + .seconds(60)) == .success else {
      throw ExchangeTransportError.unavailable
    }
    return try lock.withLock {
      guard let result else { throw ExchangeTransportError.unavailable }
      return try result.get()
    }
  }
}
