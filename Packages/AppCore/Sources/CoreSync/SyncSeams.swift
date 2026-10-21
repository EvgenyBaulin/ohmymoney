import Foundation

// The seams. The platform layers (a security-scoped folder on iOS and macOS, the GRDB database)
// implement these; the core only calls them. Nothing in this target performs I/O.

/// The shared folder, as the exchange needs it. `put` + `rename` is the two-step write that keeps
/// a half-written file out of sight; an implementation may not make a file visible under its
/// final name any other way.
public protocol JournalFolder: Sendable {
  func listNames() throws -> [String]
  func read(name: String) throws -> Data
  /// Writes `data` whole under a temporary name (`SyncFormat.temporaryPrefix…`).
  func put(temporaryName: String, data: Data) throws
  /// Makes a finished temporary file appear under its final name, atomically.
  func rename(temporaryName: String, to name: String) throws
}

/// The database side. Receives the rows whose resolved value changed, other devices' versions
/// only (a device's own writes are already in its database). It must be an idempotent upsert:
/// a failed batch is offered again. Soft delete: `isDeleted` rows stay as rows.
/// Throwing leaves the exchange state untouched, so nothing is marked applied.
public protocol RecordApplier: Sendable {
  func apply(_ records: [ResolvedRecord]) throws
}

/// Where `SyncState` lives between runs (the app decides: a table, a file, defaults).
public protocol SyncStateStore: Sendable {
  func load() throws -> SyncState
  func save(_ state: SyncState) throws
}

/// What one run did. Counts and file names only: no amounts, no row contents (0054).
public struct SyncReport: Hashable, Sendable {
  public var filesApplied = 0
  public var filesAlreadyApplied = 0
  public var filesRefused: [String: SyncError] = [:]
  public var recordsChanged = 0
  public var conflictsOpen = 0

  /// `key=value` pairs for the log, nothing else.
  public var logPairs: [(String, Int)] {
    [
      ("files", filesApplied), ("skipped", filesAlreadyApplied),
      ("refused", filesRefused.count), ("records", recordsChanged), ("conflicts", conflictsOpen),
    ]
  }
}

/// Reads every journal in the folder, applies what is new, remembers it. Safe to run any number
/// of times, in any file order, after a crash at any point.
public struct SyncRun: Sendable {
  public let ownDeviceId: String
  public let codec: any PayloadCodec

  public init(ownDeviceId: String, codec: any PayloadCodec = IdentityCodec()) {
    self.ownDeviceId = ownDeviceId
    self.codec = codec
  }

  public func run(
    folder: any JournalFolder, applier: any RecordApplier, store: any SyncStateStore
  ) throws -> SyncReport {
    var state = try store.load()
    var report = SyncReport()
    var touched = Set<RecordKey>()
    for name in try folder.listNames().sorted() {
      guard SyncFormat.parse(fileName: name) != nil else { continue }
      let bytes = try folder.read(name: name)
      do {
        let file = try JournalCoder.decode(bytes, codec: codec)
        let wasApplied = state.isApplied(name: name)
        touched.formUnion(try state.ingest(file, name: name, bytes: bytes))
        if wasApplied { report.filesAlreadyApplied += 1 } else { report.filesApplied += 1 }
      } catch let error as SyncError {
        // A torn, newer or changed file: not applied, not remembered; the next run tries again.
        report.filesRefused[name] = error
      }
    }
    let changes = touched.sorted().compactMap { state.resolve($0) }
      .filter { $0.winner.stamp.deviceId != ownDeviceId }
    // The batch first, the memory after: a crash in between only repeats an idempotent upsert.
    try applier.apply(changes)
    try store.save(state)
    report.recordsChanged = changes.count
    report.conflictsOpen = state.conflicts().count
    return report
  }
}

/// Writes this device's journal files.
public struct JournalWriter: Sendable {
  public let deviceId: String
  public let deviceName: String
  public let codec: any PayloadCodec

  public init(deviceId: String, deviceName: String, codec: any PayloadCodec = IdentityCodec()) {
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.codec = codec
  }

  /// One file for `entries`, numbered after this device's last file in the folder. `nil` when
  /// there is nothing to write.
  @discardableResult
  public func write(_ entries: [SyncEntry], to folder: any JournalFolder) throws -> String? {
    guard !entries.isEmpty else { return nil }
    guard SyncDevice.isValid(id: deviceId), entries.allSatisfy(\.isWellFormed) else {
      throw SyncError.malformed
    }
    let last = try folder.listNames()
      .compactMap(SyncFormat.parse(fileName:))
      .filter { $0.deviceId == deviceId }
      .map(\.sequence).max()
    let file = JournalFile(
      deviceId: deviceId, deviceName: deviceName, sequence: (last ?? -1) + 1, entries: entries)
    let data = try JournalCoder.encode(file, codec: codec)
    let temporary = SyncFormat.temporaryPrefix + file.name
    try folder.put(temporaryName: temporary, data: data)
    try folder.rename(temporaryName: temporary, to: file.name)
    return file.name
  }
}

// MARK: - In-memory fakes

/// For tests and for layers built before their real storage exists.
public final class InMemoryFolder: JournalFolder, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: Data] = [:]
  public init() {}

  public func listNames() throws -> [String] { lock.withLock { files.keys.sorted() } }
  public func read(name: String) throws -> Data {
    try lock.withLock {
      guard let data = files[name] else { throw SyncError.malformed }
      return data
    }
  }
  public func put(temporaryName: String, data: Data) throws {
    lock.withLock { files[temporaryName] = data }
  }
  public func rename(temporaryName: String, to name: String) throws {
    try lock.withLock {
      guard let data = files.removeValue(forKey: temporaryName) else { throw SyncError.malformed }
      files[name] = data
    }
  }
  /// Test hook: a file as another device's crash could have left it.
  public func plant(name: String, data: Data) { lock.withLock { files[name] = data } }
}

public final class InMemoryApplier: RecordApplier, @unchecked Sendable {
  private let lock = NSLock()
  private var rows: [RecordKey: ResolvedRecord] = [:]
  private var failures = 0
  public init() {}

  public var records: [RecordKey: ResolvedRecord] { lock.withLock { rows } }
  /// The next `count` calls throw, changing nothing.
  public func failNext(_ count: Int = 1) { lock.withLock { failures = count } }

  public func apply(_ records: [ResolvedRecord]) throws {
    try lock.withLock {
      if failures > 0 {
        failures -= 1
        throw SyncError.malformed
      }
      for record in records { rows[record.key] = record }
    }
  }
}

public final class InMemoryStateStore: SyncStateStore, @unchecked Sendable {
  private let lock = NSLock()
  private var state = SyncState()
  public init() {}
  public func load() throws -> SyncState { lock.withLock { state } }
  public func save(_ state: SyncState) throws { lock.withLock { self.state = state } }
}
