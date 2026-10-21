import CoreKit
import Foundation
import GRDB

/// Explicit row mapping helpers.
///
/// Everything is mapped by hand on purpose: identifiers must land in TEXT columns (GRDB
/// would store `UUID` as a blob), amounts in INTEGER `*_e4` columns, rates as decimal
/// strings and calendar days as `YYYY-MM-DD`. The SQL schema in `Schema/` is the contract
/// shared with the future Windows port, so the storage format may not drift.
enum RowMapping {
  /// An id the row cannot do without. One that is not a UUID fails the whole read with
  /// `UnreadableValue` rather than being skipped: a row left out would take its money out of
  /// every figure without a word.
  static func uuid(_ row: Row, _ column: String) throws -> UUID {
    guard let text: String = row[column], let value = UUID(uuidString: text) else {
      throw UnreadableValue(column: column)
    }
    return value
  }

  static func optionalUUID(_ row: Row, _ column: String) -> UUID? {
    guard let text: String = row[column] else { return nil }
    return UUID(uuidString: text)
  }

  /// An instant, in any form GRDB reads — its own `YYYY-MM-DD HH:MM:SS.SSS`, with a `T`, a
  /// timestamp —, or `nil` for NULL; a text reads as exactly the millisecond it names
  /// (`StoredInstant`). A value that is no instant fails the read with `UnreadableValue`, as an
  /// id that is no UUID does: GRDB's own subscript stops the program on it, and the whole
  /// history is read at every start.
  static func optionalInstant(_ row: Row, _ column: String) throws -> Date? {
    guard row.hasColumn(column) else { return nil }
    let value: DatabaseValue = row[column]
    guard !value.isNull else { return nil }
    guard let instant = StoredInstant.date(from: value) else {
      throw UnreadableValue(column: column)
    }
    return instant
  }

  /// An instant the row cannot do without; NULL reads as the start of 1970, as it always has.
  static func instant(_ row: Row, _ column: String) throws -> Date {
    try optionalInstant(row, column) ?? Date(timeIntervalSince1970: 0)
  }

  /// An instant where one that cannot be read is no reason to stop reading: it reads as none.
  static func readableInstant(_ row: Row, _ column: String) -> Date? {
    (try? optionalInstant(row, column)) ?? nil
  }

  /// An amount in 1/10000; NULL reads as zero, as it always has.
  static func amount(_ row: Row, _ column: String) throws -> AmountE4 {
    try optionalAmount(row, column) ?? .zero
  }

  /// An amount in 1/10000, or `nil` for NULL (`number`).
  static func optionalAmount(_ row: Row, _ column: String) throws -> AmountE4? {
    try number(row, column).map { AmountE4(raw: $0) }
  }

  /// A count, a day of the month, an order, or `nil` for NULL (`number`).
  static func optionalInteger(_ row: Row, _ column: String) throws -> Int? {
    guard let value = try number(row, column) else { return nil }
    guard let integer = Int(exactly: value) else { throw UnreadableValue(column: column) }
    return integer
  }

  /// A flag: `fallback` for NULL, false for zero and true for any other number, as SQLite reads
  /// a number in a condition (`number`).
  static func flag(_ row: Row, _ column: String, fallback: Bool) throws -> Bool {
    guard let value = try number(row, column) else { return fallback }
    return value != 0
  }

  /// The integer of an INTEGER column, or `nil` for NULL and for a column the row does not have.
  ///
  /// SQLite keeps a value that is no number as it was given, even where an integer belongs — a
  /// hand edit, another program with the checks of the schema off —, and GRDB reads such a text
  /// as 0 without a word, or stops the program on it, depending on how the row was fetched. An
  /// amount read as 0 is money gone from every figure, so it fails the read with
  /// `UnreadableValue`, as an id that is no UUID does. A real number reads as SQLite's own
  /// `CAST` reads it, toward zero; one past the range of an integer is unreadable too.
  private static func number(_ row: Row, _ column: String) throws -> Int64? {
    guard row.hasColumn(column) else { return nil }
    let value: DatabaseValue = row[column]
    guard !value.isNull else { return nil }
    guard let number = Int64.fromDatabaseValue(value) else {
      throw UnreadableValue(column: column)
    }
    return number
  }

  static func decimal(_ row: Row, _ column: String) -> Decimal? {
    guard let text: String = row[column] else { return nil }
    return Decimal(string: text, locale: posix)
  }

  /// Rates are written with a dot whatever the machine's language. Built once rather than
  /// for every row that carries a rate: making a `Locale` costs far more than reading the
  /// number, and the whole history is read on every load.
  private static let posix = Locale(identifier: "en_US_POSIX")

  static func day(_ row: Row, _ column: String) -> DateOnly? {
    guard let text: String = row[column] else { return nil }
    return DateOnly(iso: text)
  }

  /// A currency code, or `nil` for NULL and for text that is empty or only spaces.
  static func currency(_ row: Row, _ column: String) -> CurrencyCode? {
    guard let text: String = row[column] else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : CurrencyCode(trimmed)
  }

  /// Currency codes joined by commas, in their order; empty entries are dropped.
  static func currencies(_ row: Row, _ column: String) -> [CurrencyCode] {
    let text: String = row[column] ?? ""
    return text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(CurrencyCode.init)
  }

  static func month(_ row: Row, _ column: String) -> MonthKey? {
    guard let text: String = row[column] else { return nil }
    return MonthKey(iso: text)
  }

  /// The column keeps one alias per line, so any newline separates aliases. `\r\n` counts
  /// as one separator, because the Windows port writes the same column.
  static func aliases(_ row: Row, _ column: String) -> [String] {
    let text: String = row[column] ?? ""
    return split(text)
  }

  static func split(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
  }

  /// A newline inside a single alias would silently turn it into two aliases — and the
  /// parser would then match either half on its own. It becomes a space instead; spaces
  /// around an alias are the owner's and are kept.
  static func join(_ aliases: [String]) -> String {
    aliases.map(singleLine).filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func singleLine(_ alias: String) -> String {
    guard alias.contains(where: \.isNewline) else { return alias }
    var result = ""
    result.reserveCapacity(alias.count)
    for character in alias {
      result.append(character.isNewline ? " " : character)
    }
    return result
  }

  /// Decimal written back as a plain string, so the value survives a round trip untouched.
  static func string(_ value: Decimal?) -> String? {
    guard let value else { return nil }
    return "\(value)"
  }
}

/// A value the app cannot read where it needs one: an id that is not a UUID, an instant that is
/// no instant, a text where an amount, a flag or a count belongs. Only a writer other than the
/// app makes such a row — a hand edit, another program. The error names the
/// column, never the value, and its type is what the journal of a failed read records, so
/// the report says «a damaged row», not «not found».
public struct UnreadableValue: Error, Equatable, Sendable {
  public let column: String

  public init(column: String) {
    self.column = column
  }
}
