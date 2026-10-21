import Foundation

/// Errors raised while parsing a CSV file. Kept separate from `CoreError`, which is the
/// frozen error type of `CoreKit`: these describe problems specific to reading a CSV
/// byte stream, not the calculation core.
public enum CSVError: Error, Equatable, Sendable {
  /// The bytes are not valid UTF-8 once a leading BOM (if any) is removed.
  case invalidEncoding
  /// A data row has a different number of fields than the header row.
  case columnCountMismatch(expected: Int, found: Int, row: Int)
  /// The header row names a column twice, so a row cannot be read by column name.
  case duplicateColumn(name: String)
}

/// Reads RFC 4180 CSV data: quoted fields may contain commas, quotes and newlines, a
/// quote inside a quoted field is written doubled, and `\n`, `\r\n` and `\r` are all
/// accepted as line endings. A leading UTF-8 byte-order mark is skipped if present, so
/// files coming from tools that add one (Numbers, Excel) still read correctly. A blank
/// line is no record, as for `pandas.read_csv`: an editor that adds an empty last line does
/// not break the file (a quoted empty field, `""`, is a record).
public enum CSVReader {
  /// Splits the file into rows of raw string fields, header included.
  public static func rows(from data: Data) throws -> [[String]] {
    var bytes = [UInt8](data)
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    if bytes.count >= bom.count, Array(bytes.prefix(bom.count)) == bom {
      bytes.removeFirst(bom.count)
    }
    // Decoded as it is: Foundation's decoding would drop a second mark too, which is text.
    guard let text = String(validating: bytes, as: UTF8.self) else {
      throw CSVError.invalidEncoding
    }
    return parse(text)
  }

  /// Parses the file into dictionaries keyed by the header row. Every export file has a
  /// fixed column count, so a row of the wrong length is an error rather than something
  /// to pad or truncate silently; a column named twice is an error as well — the file may
  /// be a hand-edited copy, and foreign input must never trap.
  public static func dictionaries(from data: Data) throws -> [[String: String]] {
    let all = try rows(from: data)
    guard let header = all.first else { return [] }
    var seen: Set<String> = []
    for name in header where !seen.insert(name).inserted {
      throw CSVError.duplicateColumn(name: name)
    }
    var result: [[String: String]] = []
    result.reserveCapacity(all.count - 1)
    for (offset, row) in all.dropFirst().enumerated() {
      guard row.count == header.count else {
        throw CSVError.columnCountMismatch(expected: header.count, found: row.count, row: offset)
      }
      result.append(Dictionary(uniqueKeysWithValues: zip(header, row)))
    }
    return result
  }

  /// Parses over Unicode scalars, not `Character`s: Swift's `Character` merges an
  /// adjacent "\r\n" into a single extended grapheme cluster, which would make a
  /// CRLF line ending invisible to a switch over individual "\r" and "\n" cases.
  private static func parse(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = String.UnicodeScalarView()
    var inQuotes = false
    // A field that carried quotes exists even when it ends up empty: `""` at the end of a
    // file without a trailing break is a record, not the absence of one.
    var fieldWasQuoted = false
    var iterator = text.unicodeScalars.makeIterator()
    var pushedBack: Unicode.Scalar?

    func nextScalar() -> Unicode.Scalar? {
      if let scalar = pushedBack {
        pushedBack = nil
        return scalar
      }
      return iterator.next()
    }

    func endField() {
      row.append(String(field))
      field = String.UnicodeScalarView()
      fieldWasQuoted = false
    }

    func endRow() {
      // Nothing at all since the last line break, not even quotes: a blank line.
      if row.isEmpty, field.isEmpty, !fieldWasQuoted { return }
      endField()
      rows.append(row)
      row = []
    }

    while let scalar = nextScalar() {
      if inQuotes {
        if scalar == "\"" {
          if let following = nextScalar() {
            if following == "\"" {
              field.append("\"")
            } else {
              inQuotes = false
              pushedBack = following
            }
          } else {
            inQuotes = false
          }
        } else {
          field.append(scalar)
        }
        continue
      }

      switch scalar {
      case "\"":
        inQuotes = true
        fieldWasQuoted = true
      case ",":
        endField()
      case "\n":
        endRow()
      case "\r":
        // Treat "\r\n" as a single line ending; a lone "\r" also ends the line.
        if let following = nextScalar(), following != "\n" {
          pushedBack = following
        }
        endRow()
      default:
        field.append(scalar)
      }
    }

    if !field.isEmpty || !row.isEmpty || fieldWasQuoted {
      endRow()
    }
    return rows
  }
}
