import Foundation
import GRDB

extension TransactionRepository {
  /// Every part that names the goal — of live operations and of those in the bin alike — with
  /// its category, read fresh: what deleting an archived goal lets go of, and what decides
  /// whether it may (a part filed outside «Цели» may not let go of it). Ordered by the part's
  /// id, so the answer never depends on the order of the rows on disk.
  public func goalParts(of goalId: UUID) throws -> [(partId: UUID, categoryId: UUID?)] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT id, category_id FROM transaction_parts WHERE goal_id = ? ORDER BY id",
        arguments: [goalId.uuidString]
      ).compactMap { row -> (partId: UUID, categoryId: UUID?)? in
        guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)) else {
          return nil
        }
        let category = (row["category_id"] as String?).flatMap(UUID.init(uuidString:))
        return (partId: id, categoryId: category)
      }
    }
  }
}
