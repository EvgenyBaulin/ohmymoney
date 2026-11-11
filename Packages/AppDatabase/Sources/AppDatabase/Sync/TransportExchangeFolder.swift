import AppCore
import Foundation

/// A second kind of exchange folder: remote encrypted files behind the same seams as disk.
/// Temporary journal bytes stay on this device until rename commits them to the transport.
/// In particular, flush cannot retire the outbox before the remote commit succeeds.
public final class TransportExchangeFolder: JournalFolder, SnapshotFolder, @unchecked Sendable {
  private let transport: any ExchangeFileTransport
  private let lock = NSLock()
  private var pending: [String: Data] = [:]

  public init(transport: any ExchangeFileTransport) {
    self.transport = transport
  }

  public func listNames() throws -> [String] {
    try transport.files().map(\.name).filter { SyncFormat.parse(fileName: $0) != nil }.sorted()
  }

  public func read(name: String) throws -> Data {
    guard SyncFormat.parse(fileName: name) != nil else { throw SyncFolderError.refusedName }
    return try Self.checked(transport.readFile(named: name))
  }

  public func put(temporaryName: String, data: Data) throws {
    guard temporaryName.hasPrefix(SyncFormat.temporaryPrefix),
      SyncFormat.parse(fileName: String(temporaryName.dropFirst(SyncFormat.temporaryPrefix.count)))
        != nil
    else { throw SyncFolderError.refusedName }
    let sealed = try Self.checked(data)
    lock.withLock { pending[temporaryName] = sealed }
  }

  public func rename(temporaryName: String, to name: String) throws {
    guard SyncFormat.parse(fileName: name) != nil,
      temporaryName == SyncFormat.temporaryPrefix + name
    else { throw SyncFolderError.refusedName }
    // Serializes a retry with another writer using this folder. The transport never calls back
    // into the folder; holding the lock through its commit cannot expose an unfinished file.
    try lock.withLock {
      guard let data = pending[temporaryName] else { throw SyncFolderError.notWritable }
      try transport.writeFile(named: name, data: data, replacing: false)
      pending.removeValue(forKey: temporaryName)
    }
  }

  public func snapshots() throws -> [SyncSnapshotInfo] {
    try transport.files().compactMap {
      guard SyncSnapshotName.parse($0.name) != nil else { return nil }
      return SyncSnapshotInfo(name: $0.name, modified: $0.modified)
    }
  }

  public func putSnapshot(named name: String, from file: URL) throws {
    guard SyncSnapshotName.parse(name) != nil else { throw SyncFolderError.refusedName }
    try transport.writeFile(
      named: name, data: Self.checked(Data(contentsOf: file)), replacing: true)
  }

  public func fetchSnapshot(named name: String, to file: URL) throws {
    guard SyncSnapshotName.parse(name) != nil else { throw SyncFolderError.refusedName }
    let data = try Self.checked(transport.readFile(named: name))
    try data.write(to: file, options: .withoutOverwriting)
  }

  /// Copies original bytes when moving an existing exchange to another storage service.
  /// Re-encrypting an old file under its old name would violate its immutable fingerprint.
  public func importJournals(from source: any JournalFolder) throws {
    let present = Set(try listNames())
    for name in try source.listNames().sorted()
    where SyncFormat.parse(fileName: name) != nil && !present.contains(name) {
      try transport.writeFile(
        named: name, data: Self.checked(source.read(name: name)), replacing: false)
    }
  }

  /// The transport has no key: this checks the envelope, while the exchange authenticates it.
  private static func checked(_ data: Data) throws -> Data {
    guard SealedPayloadCodec.isSealed(data),
      data.count >= SealedPayloadCodec.magic.count + SealedPayloadCodec.nonceByteCount
        + SealedPayloadCodec.tagByteCount
    else { throw SyncError.codec }
    return data
  }
}

extension SyncExchange {
  /// Switching storage must carry the original journal history, including unresolved versions.
  /// Refuse an incomplete switch instead of reseeding rows and discarding conflict ancestry.
  public func prepareRemoteFolder(
    _ folder: TransportExchangeFolder, copyingFrom source: (any JournalFolder)? = nil
  ) throws {
    let known = try DatabaseSyncStateStore(writer: writer).load().appliedFileNames
    do {
      if let source { try folder.importJournals(from: source) }
      guard known.isSubset(of: Set(try folder.listNames())) else {
        throw SyncFailure.folderNotReadable
      }
    } catch SyncError.codec {
      throw SyncFailure.filesNotReadable
    } catch {
      throw SyncFailure.folderNotReadable
    }
  }
}
