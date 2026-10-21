import AppCore
import CoreCSV
import Foundation
import GRDB

/// The readable version of a copy of the database: the files of «Экспорт», made from a database
/// file nobody has open and of whatever schema that file has.
///
/// The files are written in the format of today, the one `pandas.read_csv` reads without
/// parameters. A copy of the current schema is exported as it is. A copy written before an
/// update has an older schema: it is updated in a scratch file of its own — never the copy — and
/// that file is exported, so every value is written the way the export writes it; then the files
/// are cut down to the schema the copy had. A table the copy did not have is not written, and a
/// column the copy did not have is left out, so no file shows a value the copy never held. The
/// scratch file goes afterwards.
public enum ReadableCopy {
  /// Every file of the readable version of the database file at `url`, the schema of which is
  /// brought up to `schema` in a scratch file only.
  public static func tables(
    ofFileAt url: URL, schema: any SchemaSource
  ) throws -> [ExportRepository.Table] {
    let had = try DatabaseStack.tableColumns(fileAt: url)
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent(
      "ohmymoney-readable-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: scratch) }
    let file = scratch.appendingPathComponent("copy.sqlite")
    try DatabaseStack.backup(fileAt: url, to: file)
    let stack = try DatabaseStack(
      url: file, schema: schema, context: MigrationContext(mainAccountName: "Main account"))
    let whole: [ExportRepository.Table]
    do {
      whole = try ExportRepository(writer: stack.writer).tables()
      try stack.close()
    } catch {
      try? stack.close()
      throw error
    }
    return try whole.compactMap { try cut($0, to: had[$0.name]) }
  }

  /// The table as the copy had it: nil when the copy had no such table, the table itself when
  /// it had every column, else only the columns it had.
  static func cut(
    _ table: ExportRepository.Table, to columns: [String]?
  ) throws -> ExportRepository.Table? {
    guard let columns else { return nil }
    let had = Set(columns)
    let rows = try CSVReader.rows(from: table.data)
    guard let header = rows.first else { return table }
    // A column of the file is the column of the table, or the table's `_e4` one.
    let kept = header.indices.filter {
      had.contains(header[$0]) || had.contains(header[$0] + "_e4")
    }
    guard kept.count < header.count else { return table }
    var csv = CSVWriter(columns: kept.map { header[$0] })
    for row in rows.dropFirst() { csv.append(kept.map { row[$0] }) }
    return ExportRepository.Table(fileName: table.fileName, data: csv.data())
  }
}

extension DatabaseStack {
  /// What the numbers are made of for a database file nobody has open whose schema is older than
  /// this build's: a copy written before an update, an archive of an earlier version. The file is
  /// copied into a scratch folder, brought up to `schema` there and read; the file itself is
  /// never opened for writing and the scratch folder goes afterwards. A file of a newer schema
  /// is refused, as the opening of the database refuses it.
  public static func dataset(
    ofOlderFileAt url: URL, schema: any SchemaSource
  ) throws -> Dataset {
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent(
      "ohmymoney-older-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: scratch) }
    let file = scratch.appendingPathComponent("older.sqlite")
    try backup(fileAt: url, to: file)
    let stack = try DatabaseStack(
      url: file, schema: schema, context: MigrationContext(mainAccountName: "Main account"))
    defer { try? stack.close() }
    return try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
  }
}
