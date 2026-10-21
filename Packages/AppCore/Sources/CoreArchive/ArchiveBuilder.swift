import CoreKit
import Foundation

/// Assembles a transfer archive: the caller hands over the files, the builder computes the
/// digests, writes `manifest.json` and seals the container if a password was given.
///
/// The result is deterministic. `manifest.json` comes first, the remaining entries follow
/// in sorted path order, so the same data exported twice yields the same bytes and a
/// difference between two archives always means a difference in the data.
public struct ArchiveBuilder: Sendable {
  /// Everything about the archive that the files themselves do not say.
  public struct Metadata: Equatable, Sendable {
    public let appVersion: String
    public let schemaVersion: Int
    public let createdAt: DateOnly
    public let platform: String
    /// Row count per table, as counted in the database that produced the CSV files.
    public let rowCounts: [String: Int]

    public init(
      appVersion: String, schemaVersion: Int, createdAt: DateOnly, platform: String,
      rowCounts: [String: Int]
    ) {
      self.appVersion = appVersion
      self.schemaVersion = schemaVersion
      self.createdAt = createdAt
      self.platform = platform
      self.rowCounts = rowCounts
    }
  }

  public let metadata: Metadata
  private var files: [String: Data] = [:]

  public init(metadata: Metadata) {
    self.metadata = metadata
  }

  public var paths: [String] { files.keys.sorted() }

  /// - Note: `manifest.json` is produced by the builder and cannot be supplied.
  public mutating func add(path: String, data: Data) throws {
    guard path != ArchivePaths.manifest else {
      throw ZipWriterError.invalidPath(path)
    }
    guard files.updateValue(data, forKey: path) == nil else {
      throw ZipWriterError.duplicatePath(path)
    }
  }

  public mutating func add(path: String, text: String) throws {
    try add(path: path, data: Data(text.utf8))
  }

  public mutating func add(files newFiles: [String: Data]) throws {
    for path in newFiles.keys.sorted() {
      try add(path: path, data: newFiles[path] ?? Data())
    }
  }

  /// The manifest exactly as it will be written, useful for verifying an export in place.
  public func manifest() -> ArchiveManifest {
    var checksums: [String: String] = [:]
    for (path, data) in files {
      checksums[path] = SHA256.hexDigest(data)
    }
    return ArchiveManifest(
      appVersion: metadata.appVersion,
      schemaVersion: metadata.schemaVersion,
      createdAt: metadata.createdAt,
      platform: metadata.platform,
      rowCounts: metadata.rowCounts,
      checksums: checksums)
  }

  /// The plain container. Everything inside is readable by any zip tool: without a
  /// password the data lies in the open, which the application has to say out loud.
  public func build() throws -> Data {
    var writer = ZipWriter(modified: metadata.createdAt)
    try writer.add(path: ArchivePaths.manifest, data: try manifest().encoded())
    for path in files.keys.sorted() {
      try writer.add(path: path, data: files[path] ?? Data())
    }
    return try writer.finish()
  }

  /// The sealed container: `EncryptionHeader` followed by the sealed zip. The cipher is
  /// injected, so this package stays free of Apple frameworks.
  public func build(
    password: String, cipher: ArchiveCipher, salt: [UInt8], nonce: [UInt8],
    iterations: Int = EncryptionHeader.recommendedIterations
  ) throws -> Data {
    try EncryptionHeader.seal(
      payload: try build(), password: password, cipher: cipher, salt: salt, nonce: nonce,
      iterations: iterations)
  }

  /// Same, with salt and nonce drawn from the caller's generator. A nonce must never be
  /// reused with the same key, so the source has to be a real random source in the app.
  public func build<Source: RandomSource>(
    password: String, cipher: ArchiveCipher, random: inout Source,
    iterations: Int = EncryptionHeader.recommendedIterations
  ) throws -> Data {
    let salt = EncryptionHeader.makeSalt(using: &random)
    let nonce = EncryptionHeader.makeNonce(using: &random)
    return try build(
      password: password, cipher: cipher, salt: salt, nonce: nonce, iterations: iterations)
  }
}
