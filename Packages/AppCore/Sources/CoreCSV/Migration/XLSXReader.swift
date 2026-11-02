import CoreKit
import Foundation

/// Reads the first sheet of an Excel workbook (`.xlsx`, Office Open XML) into rows of text.
///
/// Cells are placed by their reference (`C5`), not by their order, because Excel leaves empty
/// cells out. Shared strings, inline strings, formula results and booleans read as text; a
/// number in a date format becomes `YYYY-MM-DD HH:MM` (the workbook's 1900 or 1904 epoch); any
/// other number becomes a plain decimal rounded to four places, read through `Decimal` so no
/// binary fraction creeps into an amount.
public enum XLSXReader {
  public enum Failure: Error, Equatable, Sendable {
    case noSheet
  }

  public static func firstSheet(_ zip: ZipEntries) throws -> [[String]] {
    let workbook = try zip.data("xl/workbook.xml") ?? []
    var date1904 = false
    var firstSheetRelation: String?
    XMLScanner.scan(workbook) { event in
      guard case .open(let name, let attributes, _) = event else { return }
      if name == "workbookPr", let flag = attributes["date1904"] {
        date1904 = flag == "1" || flag == "true"
      }
      if name == "sheet", firstSheetRelation == nil { firstSheetRelation = attributes["id"] }
    }
    let path = try sheetPath(zip, relation: firstSheetRelation)
    guard let sheet = try zip.data(path) else { throw Failure.noSheet }
    let strings = try sharedStrings(zip)
    let dateStyles = try dateStyleIndices(zip)
    return cells(of: sheet, strings: strings, dateStyles: dateStyles, date1904: date1904)
  }

  private static func sheetPath(_ zip: ZipEntries, relation: String?) throws -> String {
    if let relation, let rels = try zip.data("xl/_rels/workbook.xml.rels") {
      var target: String?
      XMLScanner.scan(rels) { event in
        guard case .open("Relationship", let attributes, _) = event, attributes["Id"] == relation
        else { return }
        target = attributes["Target"]
      }
      if let target {
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        if zip.contains(path) { return path }
      }
    }
    if let first = zip.names.first(where: {
      $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml")
    }) {
      return first
    }
    throw Failure.noSheet
  }

  private static func sharedStrings(_ zip: ZipEntries) throws -> [String] {
    guard let bytes = try zip.data("xl/sharedStrings.xml") else { return [] }
    var result: [String] = []
    var current = ""
    var inText = false
    // Phonetic hints (`rPh`) repeat a reading of East Asian text and are not part of it.
    var inPhonetic = false
    XMLScanner.scan(bytes) { event in
      switch event {
      case .open("si", _, _): current = ""
      case .close("si"): result.append(current)
      case .open("rPh", _, let selfClosing): inPhonetic = !selfClosing
      case .close("rPh"): inPhonetic = false
      case .open("t", _, let selfClosing): inText = !selfClosing
      case .close("t"): inText = false
      case .text(let text) where inText && !inPhonetic: current += text
      default: break
      }
    }
    return result
  }

  /// Positions in `cellXfs` whose number format shows a date.
  private static func dateStyleIndices(_ zip: ZipEntries) throws -> Set<Int> {
    guard let bytes = try zip.data("xl/styles.xml") else { return [] }
    var custom: [Int: String] = [:]
    var formats: [Int] = []
    var inCellFormats = false
    XMLScanner.scan(bytes) { event in
      switch event {
      case .open("numFmt", let attributes, _):
        if let id = attributes["numFmtId"].flatMap(Int.init) {
          custom[id] = attributes["formatCode"] ?? ""
        }
      case .open("cellXfs", _, let selfClosing): inCellFormats = !selfClosing
      case .close("cellXfs"): inCellFormats = false
      case .open("xf", let attributes, _) where inCellFormats:
        formats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
      default: break
      }
    }
    var result: Set<Int> = []
    for (index, id) in formats.enumerated() where isDateFormat(id: id, code: custom[id]) {
      result.insert(index)
    }
    return result
  }

  /// Built-in date formats (14–22, 27–36, 45–47, 50–58) or a format code that writes a day or
  /// a year once quoted text and `[…]` sections (colours, locales) are taken out.
  static func isDateFormat(id: Int, code: String?) -> Bool {
    if let code {
      var plain = ""
      var inQuote = false
      var inBracket = false
      for character in code {
        switch character {
        case "\"": inQuote.toggle()
        case "[" where !inQuote: inBracket = true
        case "]" where !inQuote: inBracket = false
        default: if !inQuote && !inBracket { plain.append(character) }
        }
      }
      let lower = plain.lowercased()
      return lower.contains("y") || lower.contains("d")
    }
    return (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id)
      || (50...58).contains(id)
  }

  private static func cells(
    of sheet: [UInt8], strings: [String], dateStyles: Set<Int>, date1904: Bool
  ) -> [[String]] {
    var rows: [Int: [Int: String]] = [:]
    var rowNumber = 0
    var nextColumn = 0
    var column = 0
    var type = ""
    var style = 0
    var value = ""
    var inValue = false
    var inCell = false
    XMLScanner.scan(sheet) { event in
      switch event {
      case .open("row", let attributes, _):
        rowNumber = attributes["r"].flatMap(Int.init) ?? rowNumber + 1
        nextColumn = 0
      case .open("c", let attributes, let selfClosing):
        column = attributes["r"].flatMap(columnIndex) ?? nextColumn
        nextColumn = column + 1
        type = attributes["t"] ?? "n"
        style = attributes["s"].flatMap(Int.init) ?? 0
        value = ""
        inCell = !selfClosing
      case .open("v", _, let selfClosing), .open("t", _, let selfClosing):
        inValue = inCell && !selfClosing
      case .close("v"), .close("t"):
        inValue = false
      case .text(let text) where inValue:
        value += text
      case .close("c"):
        inCell = false
        let text = cellText(
          value, type: type, isDate: dateStyles.contains(style), strings: strings,
          date1904: date1904)
        if !text.isEmpty { rows[rowNumber, default: [:]][column] = text }
      default: break
      }
    }
    return rows.keys.sorted().map { number in
      let cells = rows[number] ?? [:]
      let width = (cells.keys.max() ?? -1) + 1
      return (0..<width).map { cells[$0] ?? "" }
    }
  }

  private static func cellText(
    _ raw: String, type: String, isDate: Bool, strings: [String], date1904: Bool
  ) -> String {
    switch type {
    case "s":
      guard let index = Int(raw.trimmingCharacters(in: .whitespaces)), index >= 0,
        index < strings.count
      else { return "" }
      return strings[index]
    case "inlineStr", "str", "e":
      return raw
    case "b":
      return raw == "1" ? "TRUE" : "FALSE"
    default:
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      guard let number = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
      else { return trimmed }
      if isDate { return serialDate(number, date1904: date1904) ?? trimmed }
      let rounded = DecimalMath.round(number, scale: 4)
      return NSDecimalNumber(decimal: rounded).stringValue
    }
  }

  /// `C5` → 2 (columns from zero).
  static func columnIndex(_ reference: String) -> Int? {
    var index = 0
    var sawLetter = false
    for scalar in reference.unicodeScalars {
      guard let ascii = scalar.isASCII ? UInt8(scalar.value) : nil else { return nil }
      if ascii >= 65, ascii <= 90 {
        index = index * 26 + Int(ascii - 64)
        sawLetter = true
      } else if ascii >= 97, ascii <= 122 {
        index = index * 26 + Int(ascii - 96)
        sawLetter = true
      } else {
        break
      }
    }
    return sawLetter ? index - 1 : nil
  }

  /// A spreadsheet serial day (with its fraction for the time) as `YYYY-MM-DD HH:MM`, or
  /// `YYYY-MM-DD` at midnight. The 1900 system counts from 1899-12-30 (which absorbs Excel's
  /// fictitious 29 February 1900 for every date after it); the 1904 system from 1904-01-01.
  static func serialDate(_ serial: Decimal, date1904: Bool) -> String? {
    guard serial >= 1, serial < 2_958_466 else { return nil }
    let whole = DecimalMath.round(serial, scale: 0, mode: .down)
    let days = NSDecimalNumber(decimal: whole).intValue
    let minutes = NSDecimalNumber(
      decimal: DecimalMath.round((serial - whole) * 1440, scale: 0)
    ).intValue
    let epoch = date1904 ? -24_107 : -25_569
    let day = StatementCivil.date(dayNumber: epoch + days + minutes / 1440)
    let minute = minutes % 1440
    guard minute != 0 else { return day.iso }
    return day.iso + " " + two(minute / 60) + ":" + two(minute % 60)
  }

  private static func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
