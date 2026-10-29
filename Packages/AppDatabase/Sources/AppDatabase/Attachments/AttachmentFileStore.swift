import AppCore
import CoreKit
import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#endif

/// The folder where the bytes of the attachments live, beside the database: one file per distinct
/// content, named by its SHA-256 and kept at `aa/bb/<hash>`.
///
/// A file is written under a temporary name inside the folder and moved into place, so a crash
/// never leaves half a file under the name of a hash; a file that is already there is not written
/// again. Content is never changed: no compression, no resizing.
public struct AttachmentFileStore: Sendable {
  public enum StoreError: Error, Equatable {
    case notADigest
    case hashMismatch
    case missing
  }

  public let root: URL
  private static let chunkSize = 1 << 20

  public init(root: URL) {
    self.root = root
  }

  private var temporary: URL { root.appendingPathComponent(".incoming", isDirectory: true) }

  public func url(forHash hash: String) -> URL? {
    AttachmentHash.relativePath(for: hash).map { root.appendingPathComponent($0, isDirectory: false) }
  }

  public func contains(hash: String) -> Bool {
    guard let url = url(forHash: hash) else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// The digest and size of a file, read in pieces.
  public static func digest(of file: URL) throws -> (hash: String, byteSize: Int64) {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    #if canImport(CryptoKit)
      var hasher = CryptoKit.SHA256()
      var size: Int64 = 0
      while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
        hasher.update(data: chunk)
        size += Int64(chunk.count)
      }
      return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    #else
      var stream = AttachmentHash.Stream()
      while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
        stream.update(chunk)
      }
      let size = stream.byteCount
      return (stream.finalize(), size)
    #endif
  }

  /// Stores a file by copying it: the original is not touched. Returns the digest and size. The
  /// file is copied once into the folder's own temporary area and hashed there, so what is named by
  /// the hash is exactly what was hashed even if the source changes meanwhile.
  public func put(fileAt source: URL) throws -> (hash: String, byteSize: Int64) {
    let manager = FileManager.default
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
    let staged = temporary.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: staged) }
    try manager.copyItem(at: source, to: staged)
    let (hash, size) = try Self.digest(of: staged)
    try place(staged, hash: hash)
    return (hash, size)
  }

  /// Stores bytes held in memory.
  public func put(_ data: Data) throws -> (hash: String, byteSize: Int64) {
    let manager = FileManager.default
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
    let staged = temporary.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: staged) }
    try data.write(to: staged)
    let hash = AttachmentHash.hexDigest(of: data)
    try place(staged, hash: hash)
    return (hash, Int64(data.count))
  }

  /// Stores bytes that must have the digest `hash` (the files of an archive or of a mirror): a
  /// content that does not is refused and nothing is written.
  public func put(_ data: Data, expecting hash: String) throws {
    guard AttachmentHash.isValid(hash) else { throw StoreError.notADigest }
    guard AttachmentHash.hexDigest(of: data) == hash.lowercased() else {
      throw StoreError.hashMismatch
    }
    if contains(hash: hash) { return }
    _ = try put(data)
  }

  private func place(_ staged: URL, hash: String) throws {
    guard let target = url(forHash: hash) else { throw StoreError.notADigest }
    let manager = FileManager.default
    if manager.fileExists(atPath: target.path) { return }
    try manager.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try manager.moveItem(at: staged, to: target)
      // A copy keeps the date of its source, which says nothing of when the file came here; the
      // sweep of files nobody names counts its delay from this moment.
      try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
    } catch {
      // Another writer placed the same content between the check and the move.
      if !manager.fileExists(atPath: target.path) { throw error }
    }
  }

  public func data(forHash hash: String) throws -> Data {
    guard let url = url(forHash: hash) else { throw StoreError.notADigest }
    guard contains(hash: hash) else { throw StoreError.missing }
    return try Data(contentsOf: url)
  }

  /// When the file was put into the folder; `nil` when it is not there.
  public func placedAt(hash: String) -> Date? {
    guard let url = url(forHash: hash) else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
      as? Date
  }

  /// Removes one file; no such file is no error.
  public func remove(hash: String) throws {
    guard let url = url(forHash: hash) else { throw StoreError.notADigest }
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  /// The digests of the files in the folder, from their names. Anything else in the folder is
  /// ignored.
  public func storedHashes() -> Set<String> {
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    var hashes = Set<String>()
    for case let file as URL in walker {
      let name = file.lastPathComponent
      guard AttachmentHash.isValid(name), let expected = url(forHash: name),
        expected.standardizedFileURL.path == file.standardizedFileURL.path
      else { continue }
      hashes.insert(name.lowercased())
    }
    return hashes
  }

  /// The bytes the files take.
  public func totalBytes() -> Int64 {
    storedHashes().reduce(0) { sum, hash in
      let size = url(forHash: hash).flatMap {
        (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int64
      }
      return sum + (size ?? 0)
    }
  }

  /// Empties the temporary area: what a crash left behind.
  public func clearIncoming() {
    try? FileManager.default.removeItem(at: temporary)
  }
}
