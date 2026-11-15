import AppCore
import CoreKit
import Foundation
import GRDB

/// Sums of stored amounts. SQLite's own `SUM` raises «integer overflow» when a column adds up
/// beyond `Int64`, and a stored row may hold any `Int64` (an archive, a CSV, a row of an older
/// build): the amounts are added the way the ledger adds them (`AmountE4.sum`) instead, so a
/// huge book is read as a huge book and never as an error.
enum StoredSum {
  /// The amounts a query selects (one column), added up; a total beyond the range stops at its
  /// edge.
  static func total(
    _ db: Database, sql: String, arguments: StatementArguments = StatementArguments()
  ) throws -> AmountE4 {
    AmountE4.sum(try Int64.fetchAll(db, sql: sql, arguments: arguments).map { AmountE4(raw: $0) })
  }

  /// The amounts a query selects as rows of `(key, amount)`, added up per key.
  static func totals(
    _ db: Database, sql: String, arguments: StatementArguments = StatementArguments()
  ) throws -> [String: AmountE4] {
    var grouped: [String: [AmountE4]] = [:]
    for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
      guard let key: String = row["key"] else { continue }
      grouped[key, default: []].append(AmountE4(raw: row["amount"] ?? 0))
    }
    return grouped.mapValues { AmountE4.sum($0) }
  }
}
