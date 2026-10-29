import CoreKit
import Foundation

/// The files of the attachments inside a transfer archive: `attachments/aa/bb/<hash>`, each
/// listed in the manifest with its digest like every other entry. An archive that carries none is
/// an archive of the same format, and one that carries them opens in a build that knows nothing
/// of them: it reads the database and the CSV files and ignores the entries it has no use for.
public enum AttachmentArchive {
  public static let directory = "attachments/"

  public static func path(forHash hash: String) -> String? {
    AttachmentHash.relativePath(for: hash).map { directory + $0 }
  }

  /// The digest an entry path names, or `nil` for any other path.
  public static func hash(forPath path: String) -> String? {
    guard path.hasPrefix(directory) else { return nil }
    return AttachmentHash.hash(forRelativePath: String(path.dropFirst(directory.count)))
  }

  /// A file of a plan.
  public struct Entry: Equatable, Sendable {
    public let hash: String
    public let byteSize: Int64

    public init(hash: String, byteSize: Int64) {
      self.hash = hash
      self.byteSize = byteSize
    }
  }

  /// What goes into the archive and what does not, worked out before anything is read.
  public struct Plan: Equatable, Sendable {
    /// One entry per distinct content, newest first.
    public let included: [Entry]
    public let skipped: [Entry]

    public init(included: [Entry], skipped: [Entry]) {
      self.included = included
      self.skipped = skipped
    }

    public var includedBytes: Int64 { included.reduce(0) { $0 + $1.byteSize } }
    public var skippedBytes: Int64 { skipped.reduce(0) { $0 + $1.byteSize } }
    /// Everything fits.
    public var isComplete: Bool { skipped.isEmpty }
  }

  /// A plain zip addresses 32 bits and 65 535 entries. Each entry costs its two headers on top of
  /// its bytes.
  static let perEntryOverhead: Int64 = 30 + 46 + 2 * Int64(directory.count + 69)

  /// Chooses the files for an archive that already holds `baseBytes` in `baseEntries` entries
  /// (the database, the CSV files, the settings, the manifest). Distinct contents are taken newest
  /// first until the container would overflow; the rest are listed as skipped, so the owner is told
  /// what is left out before the archive is written.
  public static func plan(
    for attachments: [AttachedFile], baseBytes: Int64, baseEntries: Int,
    maximumBytes: Int64 = Int64(ZipWriter.maximumContainerSize),
    maximumEntries: Int = ZipWriter.maximumEntryCount
  ) -> Plan {
    var seen = Set<String>()
    var included: [Entry] = []
    var skipped: [Entry] = []
    var bytes = baseBytes + 22
    var entries = baseEntries
    for attachment in attachments.sorted(by: { $0.addedAt > $1.addedAt }) {
      guard seen.insert(attachment.contentHash).inserted else { continue }
      let entry = Entry(hash: attachment.contentHash, byteSize: attachment.byteSize)
      let cost = attachment.byteSize + perEntryOverhead
      if entries < maximumEntries, bytes + cost <= maximumBytes {
        included.append(entry)
        bytes += cost
        entries += 1
      } else {
        skipped.append(entry)
      }
    }
    return Plan(included: included, skipped: skipped)
  }
}

extension ArchiveOpener.OpenedArchive {
  /// The digests of the files the archive carries.
  public var attachmentHashes: [String] {
    files.keys.compactMap(AttachmentArchive.hash(forPath:)).sorted()
  }

  public func attachment(hash: String) -> Data? {
    AttachmentArchive.path(forHash: hash).flatMap { files[$0] }
  }
}
