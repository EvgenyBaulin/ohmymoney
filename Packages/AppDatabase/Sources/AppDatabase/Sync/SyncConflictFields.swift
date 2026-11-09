import AppCore
import Foundation
import GRDB

/// Which differences between two versions of a row mean something to the owner.
///
/// Two devices that save the same row apart write different bookkeeping into it — the moment of
/// the save, the place in a sorted list — and a newer build fills a column an older one left
/// empty (`hidden`, the cashback cap, the day the cashback categories are chosen). None of that
/// is a choice the owner can make, so it is neither compared nor shown: a conflict that differs
/// only in such columns is no conflict at all.
extension SyncConflict {
  /// Columns that are bookkeeping, never a choice: the row's own id, the moments the app keeps,
  /// versions, the exchange's own columns, the order in a list, and the English name of a
  /// category — each device makes its own of the same name in the background, and two devices
  /// wording it apart is nothing the owner chose.
  public static func isService(_ column: String) -> Bool {
    if serviceColumns.contains(column) { return true }
    return column.hasPrefix("sync_") || column.hasSuffix("_version")
  }

  static let serviceColumns: Set<String> = [
    "id", "created_at", "updated_at", "deleted_at", "version", "sort", "sort_order", "position",
    "import_batch_id", "name_en", "name_en_source",
  ]

  /// The value as compared: an empty text, zero, `false` and no value are all "nothing", so a
  /// column one build writes empty and another writes with its default does not differ; a flag
  /// and the integer SQLite keeps for it are the same.
  public static func normalized(_ value: SyncValue?) -> SyncValue? {
    switch value {
    case nil, .null?: nil
    case .bool(let flag)?: flag ? .int(1) : nil
    case .int(0)?: nil
    case .string(let text)? where text.isEmpty: nil
    case let other?: other
    }
  }

  /// Whether the two versions of one column differ once bookkeeping and empty values are set
  /// aside.
  public static func differs(_ column: String, _ a: SyncValue?, _ b: SyncValue?) -> Bool {
    !isService(column) && normalized(a) != normalized(b)
  }

  /// The columns on which the two versions differ for the owner, sorted. A delete on one side
  /// only is a difference of its own (`deleted`).
  public var meaningfulDifferences: [String] {
    var out = Set(mine.fields.keys).union(theirs.fields.keys)
      .filter { Self.differs($0, mine.fields[$0], theirs.fields[$0]) }
    if mine.isDeleted != theirs.isDeleted { out.insert("deleted") }
    return out.sorted()
  }

  /// Nothing the owner could choose between: the conflict settles itself.
  public var isOnlyBookkeeping: Bool { meaningfulDifferences.isEmpty }
}

extension SyncExchange {
  /// The tables whose rows a conflict can point to by name (a bank, a group, a category…).
  static let namedTables = [
    "banks", "account_groups", "payment_methods", "cards", "categories", "places", "people",
    "goals", "debts", "events", "tags",
  ]

  /// The names of the rows the given ids point to, for the comparison of a conflict: the owner
  /// reads «Т-Банк | Сбер», not two ids. An id found in no named table is left out.
  public func names(of ids: Set<String>) -> [String: String] {
    guard !ids.isEmpty else { return [:] }
    let list = Array(ids)
    let marks = Array(repeating: "?", count: list.count).joined(separator: ",")
    let found = try? writer.read { db -> [String: String] in
      var out: [String: String] = [:]
      for table in Self.namedTables {
        // A table an older database does not have is simply skipped.
        guard
          let rows = try? Row.fetchAll(
            db, sql: "SELECT id, name FROM \(table) WHERE id IN (\(marks))",
            arguments: StatementArguments(list))
        else { continue }
        for row in rows {
          if let id: String = row["id"], let name: String = row["name"], out[id] == nil {
            out[id] = name
          }
        }
      }
      return out
    }
    return found ?? [:]
  }
}
