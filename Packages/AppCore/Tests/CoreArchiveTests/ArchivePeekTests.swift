import CoreKit
import Foundation
import Testing

@testable import CoreArchive

/// The preview of Finder reads only the start of an archive: the manifest of one without a
/// password, nothing but «encrypted» of one with a password.
@Suite("A glance at an archive tells its day, version and operations, or that it is encrypted")
struct ArchivePeekTests {
  private func archive(rowCounts: [String: Int], extra: Int = 0) throws -> ArchiveBuilder {
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "2.7.0", schemaVersion: 19,
        createdAt: DateOnly(year: 2026, month: 11, day: 1), platform: "macOS",
        rowCounts: rowCounts))
    for (table, rows) in rowCounts {
      let body = (0..<rows).map { "\($0)" }.joined(separator: "\n")
      try builder.add(path: ArchivePaths.csv(table: table), text: "id\n" + body + "\n")
    }
    if extra > 0 {
      try builder.add(path: ArchivePaths.database, data: Data(repeating: 7, count: extra))
    }
    return builder
  }

  @Test func aPlainArchiveTellsItsDayVersionAndOperations() throws {
    let data = try archive(rowCounts: ["transactions": 3, "categories": 2]).build()
    let result = ArchivePeek.read(prefix: data)
    #expect(
      result
        == .plain(
          ArchivePeek.Facts(
            createdAt: DateOnly(year: 2026, month: 11, day: 1), appVersion: "2.7.0",
            schemaVersion: 19, operations: 3, tables: 2)))
  }

  /// Only the start of a big file is read: the database after the manifest is never needed.
  @Test func theStartOfABigArchiveIsEnough() throws {
    let data = try archive(rowCounts: ["transactions": 1], extra: 600_000).build()
    #expect(data.count > ArchivePeek.prefixByteCount)
    guard case .plain(let facts) = ArchivePeek.read(prefix: data.prefix(4_096)) else {
      Issue.record("the manifest was not read from the start of the file")
      return
    }
    #expect(facts.operations == 1)
  }

  /// An export of a report has tables, no operations: no number is made up for it.
  @Test func aFileWithoutOperationsSaysNoCount() throws {
    let data = try archive(rowCounts: ["report": 4]).build()
    guard case .plain(let facts) = ArchivePeek.read(prefix: data) else {
      Issue.record("not read")
      return
    }
    #expect(facts.operations == nil)
    #expect(facts.tables == 1)
  }

  @Test func aFileWithAPasswordIsOnlyEncrypted() throws {
    let data = try archive(rowCounts: ["transactions": 3]).build(
      password: "secret", cipher: TestCipher(), salt: repeated(1, 16), nonce: repeated(2, 12),
      iterations: 1)
    #expect(ArchivePeek.read(prefix: data) == .encrypted)
    #expect(ArchivePeek.read(prefix: data.prefix(8)) == .encrypted)
  }

  @Test func anythingElseIsUnreadable() throws {
    #expect(ArchivePeek.read(prefix: Data()) == .unreadable)
    #expect(ArchivePeek.read(prefix: Data("id,name\n1,A\n".utf8)) == .unreadable)
    // A zip whose first entry is not the manifest is not one of ours.
    var writer = ZipWriter()
    try writer.add(path: "notes.txt", text: "hello")
    #expect(ArchivePeek.read(prefix: try writer.finish()) == .unreadable)
    // The start of an archive cut inside its manifest.
    let data = try archive(rowCounts: ["transactions": 3]).build()
    #expect(ArchivePeek.read(prefix: data.prefix(40)) == .unreadable)
  }
}
