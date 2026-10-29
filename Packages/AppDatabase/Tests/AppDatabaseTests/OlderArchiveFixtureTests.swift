import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

#if canImport(CryptoKit)
  import CryptoKit
#endif

/// Transfer archives written by the code of the 1.0.0 release itself — its snapshot, its CSV
/// export, its `ArchiveBuilder`, its AES-GCM through CryptoKit —, kept as files beside the
/// tests (`Tests/Fixtures`, how they were made in `archive-1.0.0.txt`). An archive this build
/// writes in the old shape would not do: a change of the format made both in the builder and in
/// the opener would pass unseen. This build opens them, plain and sealed, takes the database
/// inside through the update, and keeps every value the 1.0.0 files carried.
@Suite("An archive written by 1.0.0 imports into this build")
struct OlderArchiveFixtureTests {
  private static var fixtures: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // AppDatabaseTests
      .deletingLastPathComponent()  // Tests
      .appendingPathComponent("Fixtures", isDirectory: true)
  }

  private static func plain() throws -> ArchiveOpener.OpenedArchive {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("archive-1.0.0.zip"))
    return try ArchiveOpener.open(data, supportedSchemaVersion: 4)
  }

  /// The plain archive opens, its checksums and row counts check out, and it says it is 1.0.0's:
  /// schema 3, the 18 files of that export, the settings it kept.
  @Test func thePlainArchiveOpens() throws {
    let opened = try Self.plain()
    #expect(opened.manifest.appVersion == "1.0.0")
    #expect(opened.manifest.schemaVersion == 3)
    #expect(opened.manifest.formatVersion == 1)
    #expect(opened.csvTables.count == 18)
    #expect(
      Set(opened.csvTables)
        == Set(ExportTables.all.prefix(18).map { String($0.fileName.dropLast(4)) }))
    let settings =
      try JSONSerialization.jsonObject(with: try #require(opened.settings)) as? [String: String]
    #expect(settings?["language"] == "ru")
    #expect(settings?["theme.accent"] == "green")
  }

  #if canImport(CryptoKit)
    /// The sealed archive opens with its password and gives back exactly the files of the plain
    /// one; a wrong password is refused.
    @Test func theSealedArchiveOpensWithItsPassword() throws {
      let data = try Data(
        contentsOf: Self.fixtures.appendingPathComponent("archive-1.0.0-sealed.zip"))
      #expect(ArchiveOpener.isEncrypted(data))
      let opened = try ArchiveOpener.open(
        data, password: "пароль 1.0.0", cipher: AESGCMCipher(), supportedSchemaVersion: 4)
      #expect(opened == (try Self.plain()))
      #expect(throws: CoreError.self) {
        try ArchiveOpener.open(
          data, password: "пароль 1.0.1", cipher: AESGCMCipher(), supportedSchemaVersion: 4)
      }
    }
  #endif

  /// The database inside is sound, asks for the update, and after it holds every row the
  /// manifest counted — the accounts one more when the update made the main one.
  @Test func theDatabaseInsideIsUpdatedWithEveryRow() throws {
    let opened = try Self.plain()
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-archive-1.0.0-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("finance.sqlite")
    try (opened.database ?? Data()).write(to: url)
    #expect(try DatabaseStack.check(fileAt: url, schema: TestSupport.schemaSource) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource) == [
        "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
        "0009_credit_and_allocation",
        "0010_scenarios",
        "0011_travel",
        "0012_sync",
        "0013_spending_rules",
        "0014_import_year_questions_subscriptions",
        "0015_bank_conditions",
        "0016_rate_source",
      ])

    let stack = try DatabaseStack(
      url: url, schema: TestSupport.schemaSource,
      context: MigrationContext(mainAccountName: "Основной счёт"))
    defer { try? stack.close() }
    let created = stack.applied.dataSteps["mainCreated"] ?? 0
    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    for (table, count) in opened.manifest.rowCounts {
      #expect(counts[table] == count + (table == "payment_methods" ? created : 0), "\(table)")
    }
    try stack.writer.read { (db: Database) throws in
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL") == 0)
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM payment_methods WHERE is_default = 1 AND archived = 0")
          == 1)
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
    _ = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
  }

  /// Every cell of the 18 files 1.0.0 wrote is the cell this build exports from the updated
  /// database, column for column — but the two values the update fills: the account of an
  /// operation that had none, and which account is main.
  @Test func everyCellOfTheOlderFilesIsExportedAgain() throws {
    let opened = try Self.plain()
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-archive-1.0.0-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("finance.sqlite")
    try (opened.database ?? Data()).write(to: url)
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    let main = try #require(
      try stack.writer.read { db in
        try String.fetchOne(db, sql: "SELECT id FROM payment_methods WHERE is_default = 1")
      })
    let today = Dictionary(
      uniqueKeysWithValues: try ExportRepository(writer: stack.writer).tables().map {
        (String($0.fileName.dropLast(4)), $0.data)
      })

    for table in opened.csvTables {
      let olderFile = try #require(opened.csv(table: table))
      let newerFile = try #require(today[table])
      let older = try CSVReader.dictionaries(from: olderFile)
      let newer = try CSVReader.dictionaries(from: newerFile)
      let columns = try CSVReader.rows(from: olderFile).first ?? []
      let key = table == "rates" ? ["date", "currency", "source"] : ["id"]
      func identity(_ row: [String: String]) -> String {
        key.map { row[$0] ?? "" }.joined(separator: "|")
      }
      let byKey = Dictionary(
        newer.map { (identity($0), $0) }, uniquingKeysWith: { first, _ in first })
      #expect(
        newer.count == older.count
          + (table == "payment_methods" && byKey.count > older.count ? 1 : 0))
      for row in older {
        guard let now = byKey[identity(row)] else {
          Issue.record("\(table): a row of 1.0.0 is not exported: \(identity(row))")
          continue
        }
        for column in columns {
          var expected = row[column]
          if table == "transactions", column == "payment_method_id", expected == "" {
            expected = main
          }
          if table == "payment_methods", column == "is_default" {
            expected = row["id"] == main ? "true" : "false"
          }
          #expect(now[column] == expected, "\(table).\(column) of \(identity(row))")
        }
      }
    }
  }
}

#if canImport(CryptoKit)
  /// AES-256-GCM through CryptoKit, as the app seals and opens archives; for the tests only.
  struct AESGCMCipher: ArchiveCipher {
    func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
      let sealed = try AES.GCM.seal(
        plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
      return sealed.ciphertext + sealed.tag
    }

    func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
      let tagLength = EncryptionHeader.tagByteCount
      guard sealed.count >= tagLength else { throw CoreError.invalidArchive(reason: .truncated) }
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(tagLength),
        tag: sealed.suffix(tagLength))
      do {
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
      } catch {
        throw CoreError.invalidArchive(reason: .wrongPassword)
      }
    }
  }
#endif
