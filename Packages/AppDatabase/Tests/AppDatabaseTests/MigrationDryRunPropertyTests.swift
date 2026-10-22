import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A class of ours, only so the test can find the build's products beside its own bundle.
private final class DryRunToolAnchor: NSObject {}

/// `make migration-dry-run` on databases drawn at random: whatever odd values an older build
/// left, the update tried on a copy comes out «equal», the output holds counts and words of its
/// own only — never a name, a note or an amount of the history — and the original file is the
/// same byte for byte, with nothing left beside it.
@Suite("The dry run of the update, on databases drawn at random")
struct MigrationDryRunPropertyTests {
  private var tool: URL {
    Bundle(for: DryRunToolAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ohmymoney-migration-dry-run")
  }

  private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
    try #require(FileManager.default.fileExists(atPath: tool.path), "no tool at \(tool.path)")
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// Every line the tool prints is one of its own kinds of line: a table and its counts, a
  /// word and «equal» or «differ», a count of a step. Nothing else can leak a value.
  private static var allowedLine: Regex<AnyRegexOutput> { MigrationDryRunPathTests.allowedLine }

  @Test(arguments: [UInt64(301), 302, 303, 304, 305, 306, 307, 308])
  func anOlderDatabaseComesOutEqualAndTellsNothingOfItsData(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed, brokenLinks: seed % 4 == 0)
    defer { book.remove() }
    let folder = book.url.deletingLastPathComponent()
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    let bytes = try Data(contentsOf: book.url)

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "seed \(seed): \(output)")
    #expect(output.contains("schema: 3 -> 13 (applied 10)"), "seed \(seed)")
    #expect(output.contains("result: equal"), "seed \(seed)")
    #expect(output.contains("loads: ok"), "seed \(seed)")
    // The update gives no account the terms of a credit card, and every open debt it finds is
    // one to review.
    #expect(output.contains("\ncredit cards after: 0\n"), "seed \(seed)")
    let review = try book.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM debts WHERE closed = 0") ?? -1
    }
    #expect(output.contains("\ndebts to review after: \(review)\n"), "seed \(seed)")
    #expect(!output.contains(book.marker), "seed \(seed): the output names a row")
    let known = Set(book.accounts.map(\.id))
    let missing = book.operationAccounts.filter { $0.account.map { !known.contains($0) } ?? false }
    #expect(
      output.contains(
        "operations on an account that is not there: \(missing.count) before, \(missing.count) after"
      ),
      "seed \(seed)")
    for line in output.split(separator: "\n") {
      #expect(line.wholeMatch(of: Self.allowedLine) != nil, "seed \(seed): «\(line)»")
    }
    #expect(try Data(contentsOf: book.url) == bytes, "seed \(seed): the original changed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == files)
  }

  /// A database the update already went through is tried again as it is: nothing to apply,
  /// nothing changes, everything equal.
  @Test func anUpdatedDatabaseComesOutEqualWithNothingApplied() throws {
    let book = try RandomLegacyDatabase(seed: 309)
    defer { book.remove() }
    let stack = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
    try stack.close()

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "\(output)")
    #expect(output.contains("schema: 13 -> 13 (applied 0)"))
    #expect(output.contains("data step: none"))
    #expect(output.contains("result: equal"))
  }

  /// A file that is not a database is refused as a copy that could not be read, and says no
  /// more than that.
  @Test func aFileThatIsNotADatabaseStopsTheRun() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-dry-run-garbage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let garbage = folder.appendingPathComponent("finance.sqlite")
    try Data(repeating: 0x5A, count: 10_000).write(to: garbage)

    let (status, output) = try run([garbage.path, TestSupport.schemaDirectory.path])

    #expect(status == 3, "\(output)")
    #expect(!output.contains("result: equal"))
  }

  /// A database whose last rows sit only in its log — a crash, a power cut — is tried with them:
  /// the copy takes the `-wal` along, the rows are counted before and after, and the original
  /// with its log is left as it was.
  @Test func aDatabaseWithRowsOnlyInItsLogIsTriedWithThem() throws {
    let book = try RandomLegacyDatabase(seed: 311, operations: 20, accounts: 1...3)
    defer { book.remove() }
    let folder = book.url.deletingLastPathComponent()
    let source = folder.appendingPathComponent("source/finance.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: source)
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }
    let writer = try DatabaseQueue(path: source.path, configuration: configuration)
    try writer.write { db in
      for index in 0..<17 {
        try db.execute(
          sql: """
            INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
              payment_method_id, created_at, updated_at)
            VALUES (?, 'expense', '2026-09-01 10:00:00.000', 'RUB', ?, ?, NULL,
              '2026-09-01 10:00:00.000', '2026-09-01 10:00:00.000')
            """,
          arguments: [UUID().uuidString, index * 100 + 1, index * 100 + 1])
      }
    }
    let total = try writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0
    }
    let crashed = folder.appendingPathComponent("crashed/finance.sqlite")
    try FileManager.default.createDirectory(
      at: crashed.deletingLastPathComponent(), withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
      try FileManager.default.copyItem(atPath: source.path + suffix, toPath: crashed.path + suffix)
    }
    try writer.close()
    let bytes = try [
      ("", Data(contentsOf: crashed)),
      ("-wal", Data(contentsOf: URL(fileURLWithPath: crashed.path + "-wal"))),
    ]

    let (status, output) = try run([crashed.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "\(output)")
    let line =
      "  " + "transactions".padding(toLength: 26, withPad: " ", startingAt: 0)
      + " \(total) -> \(total)"
    #expect(output.contains(line), "\(output)")
    #expect(output.contains("result: equal"))
    for (suffix, data) in bytes {
      #expect(
        try Data(contentsOf: URL(fileURLWithPath: crashed.path + suffix)) == data, "\(suffix)")
    }
  }

  /// A database with an instant no reader can make sense of — a hand edit, another program —
  /// does not stop the tool: the update is tried, the copy does not load, the run says «failed»
  /// and «differ», and not one value of the row it could not read reaches the output.
  @Test func anUnreadableInstantIsAFailedLoadNotACrash() throws {
    let book = try RandomLegacyDatabase(seed: 312, operations: 10, accounts: 1...2)
    defer { book.remove() }
    let queue = try DatabaseQueue(path: book.url.path)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
            note, created_at, updated_at)
          VALUES ('\(UUID().uuidString)', 'expense', '2026-09-01 10:00:00.000', 'RUB', 777777,
            777777, 'secret note \(book.marker)', 'not a moment', 'not a moment')
          """)
    }
    try queue.close()

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 1, "\(output)")
    #expect(output.contains("loads: failed"))
    #expect(output.contains("result: differ"))
    for secret in [book.marker, "777777", "not a moment", "secret note"] {
      #expect(!output.contains(secret), "the output names «\(secret)»")
    }
  }
}
