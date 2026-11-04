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
    /// A reference to another record (a category, a bank…) whose name is not known here: the
    /// row says "other" and the difference is the point.
    case other
    /// A yes-or-no column, read as «да» / «нет».
    case flag(Bool)
    /// The colour of an account (`payment_methods.accent`), shown by its swatch and its name.
    case color(String)
  }

  struct Row: Equatable, Identifiable {
    /// The column, which is also the key of the label.
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

  /// Columns the owner never reads beyond the bookkeeping the exchange sets aside itself
  /// (`SyncConflict.isService`): identifiers from outside and how a rate was found.
  static let hidden: Set<String> = [
    "external_id", "rate_provisional", "rate_source", "rate_date",
  ]
  /// The columns shown first, in this order, whether they differ or not (a row that matches is
  /// shown quietly, so the owner sees what the two versions agree on).
  static let leading = [
    "note", "name", "amount_e4", "amount_rub_e4", "currency", "occurred_at", "date",
  ]
  /// Columns whose labels live in the table `Sync`; every other column is labelled from the
  /// table `OwnerFixesConflicts` (see `ConflictText.label`).
  static let labelled: Set<String> = Set(leading).union(["kind", "category_id"])
  /// Columns that hold a yes-or-no, whatever integer SQLite keeps for it.
  static let flags: Set<String> = [
    "hidden", "archived", "is_default", "cushion", "credit_cash_no_grace", "credit_grace",
    "recurring_yearly", "reimbursable", "one_off", "is_system", "in_summary", "closed",
  ]

  /// - Parameter names: the names of the rows a reference points to, by id, so a bank or a
  ///   group reads by its name; an id missing here reads "other".
  static func make(_ conflict: SyncConflict, names: [String: String] = [:]) -> ConflictComparison {
    let mine = conflict.mine
    let theirs = conflict.theirs
    let columns = Set(mine.fields.keys).union(theirs.fields.keys)
      .filter { !hidden.contains($0) && !SyncConflict.isService($0) }
    var rows: [Row] = []
    for column in leading where columns.contains(column) {
      rows.append(row(column, mine, theirs, names))
    }
    // Every other column that differs is a row of its own, under its own label: never one
    // «другие данные» row that hides what changed.
    for column in columns.subtracting(leading).sorted() {
      let candidate = row(column, mine, theirs, names)
      if candidate.differs { rows.append(candidate) }
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

  /// The ids the differing references of a conflict point to: what `names` has to know.
  static func referencedIds(_ conflict: SyncConflict) -> Set<String> {
    var ids: Set<String> = []
    for column in conflict.meaningfulDifferences where column.hasSuffix("_id") {
      for side in [conflict.mine, conflict.theirs] {
        if case .string(let id)? = side.fields[column], !id.isEmpty { ids.insert(id) }
      }
    }
    return ids
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
    _ column: String, _ mine: SyncConflict.Side, _ theirs: SyncConflict.Side,
    _ names: [String: String]
  ) -> Row {
    let a = mine.fields[column]
    let b = theirs.fields[column]
    let differs = SyncConflict.differs(column, a, b)
    var left = cell(column, a, differs: differs, names)
    var right = cell(column, b, differs: differs, names)
    // Two sums that differ below a kopeck would read the same rounded: show them exactly.
    if differs, left == right, column.hasSuffix("_e4") {
      if case .int(let raw)? = a { left = .value(exact(raw)) }
      if case .int(let raw)? = b { right = .value(exact(raw)) }
    }
    return Row(id: column, mine: left, theirs: right, differs: differs)
  }

  private static func cell(
    _ column: String, _ value: SyncValue?, differs: Bool, _ names: [String: String]
  ) -> Cell {
    if flags.contains(column) || column.hasPrefix("is_") {
      return .flag(SyncConflict.normalized(value) != nil)
    }
    guard let value = SyncConflict.normalized(value) else { return .empty }
    if column.hasSuffix("_id") {
      guard differs else { return .empty }
      if case .string(let id) = value, let name = names[id], !name.isEmpty { return .value(name) }
      return .other
    }
    if case .bool(let flag) = value { return .flag(flag) }
    if column == "accent", case .string(let key) = value { return .color(key) }
    if column.hasSuffix("_e4"), case .int(let raw) = value { return .value(money(raw)) }
    if isDay(column), case .string(let day) = value { return .value(String(day.prefix(10))) }
    guard let shown = text(value), !shown.isEmpty else { return .empty }
    return .value(shown)
  }

  /// Columns that hold a day or a moment: only the day is shown.
  private static func isDay(_ column: String) -> Bool {
    column == "occurred_at" || column == "date" || column.hasSuffix("_on")
      || column.hasSuffix("_at") || column.hasSuffix("_date")
  }

  private static func text(_ value: SyncValue) -> String? {
    switch value {
    case .null: nil
    case .bool(let flag): flag ? "1" : "0"
    case .int(let number): String(number)
    case .string(let text): text
    }
  }

  /// `1/10 000` units to all four places, the trailing zeros dropped: «0.0015».
  static func exact(_ e4: Int64) -> String {
    let magnitude = e4.magnitude
    var fraction = String(magnitude % 10_000)
    fraction = String(repeating: "0", count: 4 - fraction.count) + fraction
    while fraction.hasSuffix("0") { fraction.removeLast() }
    let whole = String(magnitude / 10_000)
    return (e4 < 0 ? "\u{2212}" : "") + whole + (fraction.isEmpty ? "" : "." + fraction)
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
