import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The readable version of a copy: the files of the export, made of a database file of any age.
@Suite("The readable version of a copy of the database")
struct ReadableCopyTests {
  private static func folder() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-readable-tests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// A file of the current schema with one operation, and the same file as a closed copy.
  private static func currentCopy() throws -> (copy: URL, export: [ExportRepository.Table]) {
    let directory = try folder()
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("live.sqlite"), schema: TestSupport.schemaSource)
    try TransactionRepository(writer: stack.writer).insert([TestSupport.makeEntry(note: "tea")])
    let copy = directory.appendingPathComponent("copy.sqlite")
    try stack.backup(to: copy)
    let export = try ExportRepository(writer: stack.writer).tables()
    try stack.close()
    return (copy, export)
  }

  /// A file as the build of 1.5 (schema up to `0007`) left it, with one operation.
  private static func oldCopy() throws -> URL {
    let directory = try folder()
    let url = directory.appendingPathComponent("old.sqlite")
    let stack = try DatabaseStack(
      url: url, schema: FilteredSchemaSource(upTo: "0006_banks"))
    let entry = try TestSupport.makeEntry(note: "tea")
    try stack.writer.write { db in
      try LegacyWriter.insert(entry.transaction, db: db)
      for part in entry.parts { try LegacyWriter.insert(part, db: db) }
    }
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }
    try stack.close()
    return url
  }

  @Test func aCopyOfTheCurrentSchemaIsWrittenAsTheExportWritesIt() throws {
    let (copy, export) = try Self.currentCopy()
    let tables = try ReadableCopy.tables(ofFileAt: copy, schema: TestSupport.schemaSource)
    #expect(tables.map(\.fileName) == export.map(\.fileName))
    for (made, wanted) in zip(tables, export) {
      #expect(made.data == wanted.data, "\(wanted.fileName)")
    }
  }

  @Test func aCopyOfAnOlderSchemaHasOnlyWhatItHeld() throws {
    let old = try Self.oldCopy()
    let tables = try ReadableCopy.tables(ofFileAt: old, schema: TestSupport.schemaSource)
    let names = Set(tables.map(\.fileName))
    // The tables of 0007 to 0009 were not there; those of 0001 are.
    #expect(!names.contains("assets.csv") && !names.contains("allocation_rules.csv"))
    #expect(names.contains("transactions.csv") && names.contains("banks.csv"))
    let methods = try #require(tables.first { $0.fileName == "payment_methods.csv" })
    let header = try #require(try CSVReader.rows(from: methods.data).first)
    #expect(header.contains("bank_id"))
    #expect(!header.contains("cushion") && !header.contains("credit_limit"))
    let transactions = try #require(tables.first { $0.fileName == "transactions.csv" })
    let rows = try CSVReader.dictionaries(from: transactions.data)
    #expect(rows.count == 1)
    #expect(rows.first?["note"] == "tea")
    #expect(rows.first?["amount"] == "250")
  }

  @Test func theCopyItselfIsLeftAsItWas() throws {
    let old = try Self.oldCopy()
    let folder = old.deletingLastPathComponent().path
    let before = try Data(contentsOf: old)
    let files = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
    _ = try ReadableCopy.tables(ofFileAt: old, schema: TestSupport.schemaSource)
    #expect(try Data(contentsOf: old) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == files)
  }

  @Test func everyFileIsWholeSoPandasAndAnyReaderTakeItWithoutOptions() throws {
    let old = try Self.oldCopy()
    let (current, _) = try Self.currentCopy()
    var written: [URL] = []
    for file in [old, current] {
      let out = try Self.folder()
      for table in try ReadableCopy.tables(ofFileAt: file, schema: TestSupport.schemaSource) {
        // Rows as long as the header: what `read_csv` needs.
        let rows = try CSVReader.rows(from: table.data)
        let width = try #require(rows.first?.count)
        #expect(rows.allSatisfy { $0.count == width }, "\(table.fileName)")
        let url = out.appendingPathComponent(table.fileName)
        try table.data.write(to: url)
        written.append(url)
      }
    }
    // With pandas at hand (`make pyenv`), the very same files are read with it as well.
    guard let python = Self.python else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments =
      ["-c", "import sys, pandas\nfor p in sys.argv[1:]: pandas.read_csv(p)"]
      + written.map(\.path)
    let pipe = Pipe()
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(String(decoding: output, as: UTF8.self))")
  }

  /// The venv of `make pyenv`, when there is one.
  private static var python: String? {
    if let path = ProcessInfo.processInfo.environment["OHMYMONEY_PYTHON"], !path.isEmpty {
      return path
    }
    let fallback = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Developer/OhMyMoney/pyenv/bin/python").path
    return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
  }

  @Test func aFileOfAnOlderSchemaIsReadInAScratchFileAndLeftAsItWas() throws {
    let old = try Self.oldCopy()
    let before = try Data(contentsOf: old)
    let dataset = try DatabaseStack.dataset(ofOlderFileAt: old, schema: TestSupport.schemaSource)
    #expect(dataset.entries.count == 1)
    #expect(try Data(contentsOf: old) == before)
    // A file of the current schema reads as it is; a damaged one is refused.
    let (current, _) = try Self.currentCopy()
    #expect(try DatabaseStack.dataset(fileAt: current).entries.count == 1)
    let junk = old.deletingLastPathComponent().appendingPathComponent("junk.sqlite")
    try Data("not a database".utf8).write(to: junk)
    #expect(throws: (any Error).self) {
      try DatabaseStack.dataset(ofOlderFileAt: junk, schema: TestSupport.schemaSource)
    }
  }

  @Test func aTableNotInTheCopyIsNotWrittenAndAColumnNotInItIsCut() throws {
    let table = ExportRepository.Table(
      fileName: "x.csv", data: Data("id,amount,newer\n1,2.5,z\n".utf8))
    #expect(try ReadableCopy.cut(table, to: nil) == nil)
    let cut = try #require(try ReadableCopy.cut(table, to: ["id", "amount_e4"]))
    #expect(String(decoding: cut.data, as: UTF8.self) == "id,amount\n1,2.5\n")
    #expect(try ReadableCopy.cut(table, to: ["id", "amount", "newer"])?.data == table.data)
  }
}
