import Foundation

/// Builds one RFC 4180 CSV file: comma-separated, `\n` line endings, UTF-8 without a BOM.
/// A field is quoted only when it needs to be — it contains a comma, a quote or a
/// newline, or it is the only field of its row and empty, which would otherwise be a blank
/// line that readers skip — and an embedded quote is doubled. Every row must have as many fields as the
/// header, so the file this produces always opens in `pandas.read_csv` with no parameters.
public struct CSVWriter: Sendable {
  private let columnCount: Int
  private var lines: [String]

  /// Starts a new file with the given header row.
  public init(columns: [String]) {
    self.columnCount = columns.count
    self.lines = [Self.encode(row: columns)]
  }

  /// Appends one data row. The row must have exactly as many fields as the header —
  /// mismatched row shapes are a programming error, not a runtime condition to recover
  /// from, so this traps instead of throwing.
  public mutating func append(_ row: [String]) {
    precondition(
      row.count == columnCount,
      "CSVWriter: expected \(columnCount) columns, got \(row.count)")
    lines.append(Self.encode(row: row))
  }

  /// The finished file, encoded as UTF-8 with no byte-order mark, ending in a single `\n`.
  public func data() -> Data {
    let text = lines.joined(separator: "\n") + "\n"
    return Data(text.utf8)
  }

  private static func encode(row: [String]) -> String {
    if row == [""] { return "\"\"" }
    return row.map(encode(field:)).joined(separator: ",")
  }

  /// Both the test for quoting and the doubling of an embedded quote walk Unicode
  /// scalars, never `Character`s. Swift merges "\r\n" into a single extended grapheme
  /// cluster, and a combining mark glues itself to the character in front of it, so
  /// `contains(",")` and `replacingOccurrences(of: "\"")` both walk straight past a
  /// separator that the bytes of the file still contain. Missing one means an unquoted
  /// comma, quote or line break reaches the file and the row silently breaks apart.
  private static func encode(field: String) -> String {
    guard needsQuoting(field) else { return field }
    var escaped = String.UnicodeScalarView()
    escaped.append("\"")
    for scalar in field.unicodeScalars {
      if scalar == "\"" { escaped.append("\"") }
      escaped.append(scalar)
    }
    escaped.append("\"")
    return String(escaped)
  }

  private static func needsQuoting(_ field: String) -> Bool {
    field.unicodeScalars.contains { scalar in
      scalar == "," || scalar == "\"" || scalar == "\n" || scalar == "\r"
    }
  }
}
