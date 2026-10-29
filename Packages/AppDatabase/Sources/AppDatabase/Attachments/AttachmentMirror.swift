import AppCore
import Foundation

/// The folder of attachments inside the folder the owner chose for copies (usually in iCloud
/// Drive): `<chosen folder>/attachments/aa/bb/<hash>`, the same layout as the local folder, so a
/// file is found by its name alone. Each file goes there once; a copy of the database only names
/// files and carries none.
///
/// Nothing is ever deleted from the mirror: the copies that are kept name files that may be gone
/// from this Mac, and the folder is the owner's.
public struct AttachmentMirror: Sendable {
  public static let folderName = "attachments"

  public struct Outcome: Equatable, Sendable {
    public var copied = 0
    public var alreadyThere = 0
    public var failed = 0
    public var copiedBytes: Int64 = 0

    public init() {}
  }

  public let folder: URL

  /// - Parameter chosenFolder: the folder of copies; the files go to a folder of their own inside.
  public init(chosenFolder: URL) {
    folder = chosenFolder.appendingPathComponent(Self.folderName, isDirectory: true)
  }

  private var store: AttachmentFileStore { AttachmentFileStore(root: folder) }

  /// Copies into the mirror every file of `local` that it does not hold. A file counts as there
  /// when one of the same size is there: the name is its digest, so the size is a cheap check
  /// that a copy cut short is done again. A copy is written under a name no list shows and put in
  /// place once whole.
  public func push(from local: AttachmentFileStore) -> Outcome {
    transfer(hashes: local.storedHashes(), from: local, into: store)
  }

  /// The other way: brings into `local` the files of the mirror it lacks, for a Mac that is set
  /// up from a copy. Content is checked against its name before it is kept.
  public func pull(into local: AttachmentFileStore, only wanted: Set<String>? = nil) -> Outcome {
    var hashes = store.storedHashes().subtracting(local.storedHashes())
    if let wanted { hashes.formIntersection(wanted) }
    var outcome = Outcome()
    for hash in hashes.sorted() {
      do {
        let data = try store.data(forHash: hash)
        try local.put(data, expecting: hash)
        outcome.copied += 1
        outcome.copiedBytes += Int64(data.count)
      } catch {
        outcome.failed += 1
      }
    }
    return outcome
  }

  private func transfer(
    hashes: Set<String>, from source: AttachmentFileStore, into target: AttachmentFileStore
  ) -> Outcome {
    let manager = FileManager.default
    var outcome = Outcome()
    for hash in hashes.sorted() {
      guard let from = source.url(forHash: hash), let to = target.url(forHash: hash) else {
        outcome.failed += 1
        continue
      }
      let size = Self.size(of: from)
      if let there = Self.size(of: to), there == size {
        outcome.alreadyThere += 1
        continue
      }
      let partial = to.deletingLastPathComponent()
        .appendingPathComponent(".\(hash).part-\(UUID().uuidString)")
      do {
        try manager.createDirectory(
          at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: from, to: partial)
        if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
        try manager.moveItem(at: partial, to: to)
        outcome.copied += 1
        outcome.copiedBytes += size ?? 0
      } catch {
        try? manager.removeItem(at: partial)
        outcome.failed += 1
      }
    }
    return outcome
  }

  private static func size(of url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
  }
}
