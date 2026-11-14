import CoreKit
import Foundation
import Testing

@testable import CoreArchive

@Suite("The plan of attachments counts the zip bytes of an entry exactly")
struct AttachmentPlanSizeTests {
  /// An entry costs its local header, its central-directory record and its name twice; if the
  /// plan counts one byte short per name, a container planned to the limit overflows when written.
  @Test func theOverheadOfAnEntryIsWhatTheZipWriterWrites() throws {
    let hash = String(repeating: "ab", count: 32)
    let content = Data(repeating: 7, count: 100)
    let empty = try ZipWriter().finish().count
    var writer = ZipWriter()
    try writer.add(path: AttachmentArchive.path(forHash: hash)!, data: content)
    let written = try writer.finish().count - empty
    #expect(Int64(written) == Int64(content.count) + AttachmentArchive.perEntryOverhead)
  }

  /// A plan filled to the last byte it allows must be a container the writer still accepts.
  @Test func aPlanToTheLimitFitsTheWriter() throws {
    let rows = (0..<50).map { index -> AttachedFile in
      let hash = AttachmentHash.hexDigest(of: Data("file \(index)".utf8))
      return AttachedFile(
        ownerKind: .transaction, ownerId: UUID(), contentHash: hash, fileName: "x.jpg",
        byteSize: 10, kind: .receipt,
        addedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
    }
    let empty = try ZipWriter().finish().count
    let limit = Int64(empty) + 50 * (10 + AttachmentArchive.perEntryOverhead)
    let plan = AttachmentArchive.plan(
      for: rows, baseBytes: 0, baseEntries: 0, maximumBytes: limit)
    #expect(plan.isComplete)
    var writer = ZipWriter()
    for entry in plan.included {
      try writer.add(
        path: AttachmentArchive.path(forHash: entry.hash)!, data: Data(count: Int(entry.byteSize)))
    }
    #expect(Int64(try writer.finish().count) <= limit)
  }
}
