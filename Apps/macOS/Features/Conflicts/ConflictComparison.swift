import AppCore
import AppDatabase
import Foundation

/// One conflict laid out for the screen: the fields of the two versions side by side, the ones
/// that differ marked. Pure — no language, no view — so a test can read it.
struct ConflictComparison: Equatable {
  /// What one side shows in one row.
  enum Cell: Equatable {
    case value(String)
    /// No value on this side (the field is empty or the version does not have it).
    case empty
    /// A reference to another record (a category, a card…) that differs; its name is not
    /// known here, so the row says "other" and the difference is the point.
    case other
  }

  struct Row: Equatable, Identifiable {
    /// The column, which is also the key of the label (`sync.field.<column>`).
    var id: String
    var mine: Cell
    var theirs: Cell
    var differs: Bool
  }

  var tableKey: String
  var title: String?
  var rows: [Row]
  var mineDeleted: Bool
  var theirsDeleted: Bool

  /// Columns the owner never reads: identifiers of the row itself and the moments the app keeps.
  static let hidden: Set<String> = [
    "id", "created_at", "updated_at", "deleted_at", "external_id", "import_batch_id",
    "rate_provisional", "rate_source", "rate_date",
  ]
  /// The columns shown first, in this order, whether they differ or not (a row that matches is
  /// shown quietly, so the owner sees what the two versions agree on).
  static let leading = [
    "note", "name", "amount_e4", "amount_rub_e4", "currency", "occurred_at", "date",
  ]
  /// Columns whose labels exist in the catalog; any other differing column is one row,
  /// «Другие данные», however many there are.
  static let labelled: Set<String> = Set(leading).union(["kind", "category_id"])

  static func make(_ conflict: SyncConflict) -> ConflictComparison {
    let mine = conflict.mine
    let theirs = conflict.theirs
    let names = Set(mine.fields.keys).union(theirs.fields.keys).subtracting(hidden)
    var rows: [Row] = []
    var otherDiffers = false
    for column in leading where names.contains(column) {
      rows.append(row(column, mine, theirs))
    }
    for column in names.subtracting(leading).sorted() {
      let candidate = row(column, mine, theirs)
      guard candidate.differs else { continue }
      if labelled.contains(column) {
        rows.append(candidate)
      } else {
        otherDiffers = true
      }
    }
    if otherDiffers {
      rows.append(Row(id: "other", mine: .other, theirs: .other, differs: true))
    }
    let title = [mine, theirs].lazy
      .compactMap { side in
        ["note", "name"].lazy.compactMap { side.fields[$0].flatMap(text) }.first
      }
      .first { !$0.isEmpty }
    return ConflictComparison(
      tableKey: tableKey(conflict.key.table), title: title, rows: rows,
      mineDeleted: mine.isDeleted, theirsDeleted: theirs.isDeleted)
  }

  /// `sync.table.<table>` for the tables a person knows by name, `sync.table.other` for the rest.
  static func tableKey(_ table: String) -> String {
    known.contains(table) ? "sync.table.\(table)" : "sync.table.other"
  }

  static let known: Set<String> = [
    "transactions", "transaction_parts", "people", "places", "categories", "goals", "debts",
    "events", "payment_methods", "cards", "transfers", "templates",
  ]

  private static func row(
    _ column: String, _ mine: SyncConflict.Side, _ theirs: SyncConflict.Side
  )
    -> Row
  {
    let a = mine.fields[column]
    let b = theirs.fields[column]
    let differs = a != b
    return Row(
      id: column, mine: cell(column, a, differs: differs),
      theirs: cell(column, b, differs: differs),
      differs: differs)
  }

  private static func cell(_ column: String, _ value: SyncValue?, differs: Bool) -> Cell {
    guard let value, value != .null else { return .empty }
    if column.hasSuffix("_id") { return differs ? .other : .empty }
    if column.hasSuffix("_e4"), case .int(let raw) = value { return .value(money(raw)) }
    if column == "occurred_at" || column == "date", case .string(let day) = value {
      return .value(String(day.prefix(10)))
    }
    guard let shown = text(value), !shown.isEmpty else { return .empty }
    return .value(shown)
  }

  private static func text(_ value: SyncValue) -> String? {
    switch value {
    case .null: nil
    case .bool(let flag): flag ? "1" : "0"
    case .int(let number): String(number)
    case .string(let text): text
    }
  }

  /// `1/10 000` units as «1,234.56» with the minus «−» (0206): whole units grouped by comma, the
  /// fraction only when there is one, to two places.
  static func money(_ e4: Int64) -> String {
    let negative = e4 < 0
    let magnitude = e4.magnitude
    let whole = magnitude / 10_000
    let cents = (magnitude % 10_000 + 50) / 100  // half up, to two places
    let (carriedWhole, shownCents) = cents == 100 ? (whole + 1, 0) : (whole, Int(cents))
    var digits = String(carriedWhole)
    var grouped = ""
    while digits.count > 3 {
      grouped = "," + digits.suffix(3) + grouped
      digits.removeLast(3)
    }
    grouped = digits + grouped
    let fraction = shownCents == 0 ? "" : "." + (shownCents < 10 ? "0" : "") + String(shownCents)
    return (negative ? "\u{2212}" : "") + grouped + fraction
  }
}
