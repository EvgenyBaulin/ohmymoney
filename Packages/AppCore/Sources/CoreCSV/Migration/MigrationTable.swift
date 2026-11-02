import CoreKit
import Foundation

/// A table read from another application's export: the row of column names and the rows under
/// it, every cell as text. A spreadsheet's date cell arrives already written as
/// `YYYY-MM-DD HH:MM`, a number as a plain decimal, so the rest of the reading does not care
/// where the table came from.
public struct MigrationTable: Sendable, Hashable {
  public var header: [String]
  public var rows: [[String]]
  /// Rows above the header that were skipped (a title, an export date).
  public var skippedAbove: Int

  public init(header: [String], rows: [[String]], skippedAbove: Int = 0) {
    self.header = header
    self.rows = rows
    self.skippedAbove = skippedAbove
  }

  /// The cell of a row, empty when the row is shorter than the header.
  public func cell(_ row: [String], _ column: Int?) -> String {
    guard let column, column >= 0, column < row.count else { return "" }
    return row[column].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// What identifies a layout of columns, for remembering how it was mapped: the names folded
  /// (case, «ё», blanks) and joined, then hashed. Two exports of one application share it.
  public var signature: String {
    let folded = header.map { NameKey.fold(StatementText.collapse($0)) }
    return "h1:" + StatementText.fnv1a(folded.joined(separator: "\u{1F}"))
  }
}

/// What a file turned out to be.
public enum MigrationFileReading: Sendable, Equatable {
  case table(MigrationTable, usedLegacyEncoding: Bool)
  /// A Numbers document: its format is closed. The person exports it to CSV or Excel first.
  case numbers
  /// An Excel file of before 2007 (`.xls`): saved again as `.xlsx` or CSV, it reads.
  case legacyExcel
  /// Nothing that reads as a table with a header.
  case unreadable
}

public enum MigrationTableReader {
  /// Reads a file of another application. `fileName` only helps to tell a Numbers document
  /// from an Excel one; the content decides everything else.
  public static func read(_ data: Data, fileName: String = "") -> MigrationFileReading {
    let bytes = [UInt8](data)
    let suffix = (fileName as NSString).pathExtension.lowercased()
    if suffix == "numbers" { return .numbers }
    if bytes.count >= 4, bytes[0] == 0xD0, bytes[1] == 0xCF, bytes[2] == 0x11, bytes[3] == 0xE0 {
      return .legacyExcel
    }
    if ZipEntries.looksLikeZip(bytes) {
      guard let zip = try? ZipEntries(bytes) else { return .unreadable }
      if zip.contains("Index/Document.iwa") || zip.names.contains(where: { $0.hasPrefix("Index/") })
      {
        return .numbers
      }
      guard let cells = try? XLSXReader.firstSheet(zip) else { return .unreadable }
      return table(from: cells).map { .table($0, usedLegacyEncoding: false) } ?? .unreadable
    }
    let decoded = decodeText(bytes)
    let rows = StatementDelimitedReader.rows(
      in: decoded.text, delimiter: delimiter(of: decoded.text))
    return table(from: rows).map { .table($0, usedLegacyEncoding: decoded.usedLegacyEncoding) }
      ?? .unreadable
  }

  /// UTF-16 with a byte-order mark (Excel's «Unicode text»), else UTF-8, else windows-1251.
  static func decodeText(_ bytes: [UInt8]) -> StatementTextDecoder.Decoded {
    if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
      return StatementTextDecoder.Decoded(
        text: utf16(Array(bytes.dropFirst(2)), littleEndian: true), usedLegacyEncoding: false)
    }
    if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
      return StatementTextDecoder.Decoded(
        text: utf16(Array(bytes.dropFirst(2)), littleEndian: false), usedLegacyEncoding: false)
    }
    return StatementTextDecoder.decode(Data(bytes))
  }

  private static func utf16(_ bytes: [UInt8], littleEndian: Bool) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var index = 0
    while index + 1 < bytes.count {
      let pair =
        littleEndian
        ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
        : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
      units.append(pair)
      index += 2
    }
    return String(decoding: units, as: UTF16.self)
  }

  /// The separator the first lines use most outside quotes: comma, semicolon or tab.
  static func delimiter(of text: String) -> Unicode.Scalar {
    var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
    var inQuotes = false
    var lines = 0
    for scalar in text.unicodeScalars {
      if scalar == "\"" { inQuotes.toggle() }
      if inQuotes { continue }
      if scalar == "\n" {
        lines += 1
        if lines >= 20 { break }
      }
      if counts[scalar] != nil { counts[scalar, default: 0] += 1 }
    }
    let best = counts.max { ($0.value, $0.key == "," ? 1 : 0) < ($1.value, $1.key == "," ? 1 : 0) }
    return (best?.value ?? 0) > 0 ? best?.key ?? "," : ","
  }

  /// Finds the header among the first rows: the first row with at least two filled cells, most
  /// of them words rather than numbers or dates, and a row of data under it. Rows above it are
  /// a title or an export date and are skipped; empty rows below are dropped.
  static func table(from rows: [[String]]) -> MigrationTable? {
    let trimmed = rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    for (index, row) in trimmed.prefix(15).enumerated() {
      let filled = row.filter { !$0.isEmpty }
      guard filled.count >= 2 else { continue }
      let words = filled.filter { cell in
        StatementAmount.parse(cell) == nil && MigrationDates.parse(cell, order: .dayFirst) == nil
      }
      guard words.count * 3 >= filled.count * 2 else { continue }
      let below = trimmed[(index + 1)...].filter { $0.contains { !$0.isEmpty } }
      guard !below.isEmpty else { continue }
      var header = row
      while header.last?.isEmpty == true { header.removeLast() }
      return MigrationTable(header: header, rows: below, skippedAbove: index)
    }
    return nil
  }
}
