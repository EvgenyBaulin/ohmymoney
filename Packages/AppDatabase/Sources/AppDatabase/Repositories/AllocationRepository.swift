import AppCore
import Foundation
import GRDB

/// The writes of the allocation of an income, each one record and one step of ⌘Z: what the
/// sheet chose (contributions to goals and transfers, `alloc:<income>:<uuid>`), the rules of
/// allocation, and the deletion of an income with everything its allocation wrote. Each is a
/// `PlanningChange`, so the app writes it through the same store as every other change of the
/// planning and ⌘Z takes it back whole.
public struct AllocationRepository: Sendable {
  public let planning: PlanningRepository
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter, liveCounts: LiveCountsContext = .standard) {
    self.writer = writer
    self.planning = PlanningRepository(writer: writer, liveCounts: liveCounts)
  }

  // MARK: - The changes

  /// What the sheet writes: the contributions, the transfers, the goals whose «transfer on
  /// contribution» changed, and — in the same record — the categories a contribution needs
  /// (the subcategory of a goal that had none) and the settings the sheet remembers (the
  /// account of the cushion, the rest of the month done).
  public static func change(
    for write: AllocationWrite, categories: [CoreKit.Category] = [],
    settings: [String: String?] = [:], at: Date = Date()
  ) -> PlanningChange {
    var rows = PlanningRows.empty
    rows.categories = categories
    rows.goals = write.goals
    rows.transfers = write.transfers
    return PlanningChange(created: write.contributions, upsert: rows, settings: settings, at: at)
  }

  /// The deletion of an income: the income alone, or — `withAllocation` — the income with the
  /// contributions and transfers its allocation wrote (`Allocation.linked`).
  public static func deletion(
    incomeIds: [UUID], contributions: [UUID] = [], transfers: [UUID] = [], at: Date = Date()
  ) -> PlanningChange {
    var ids = PlanningRowIDs.empty
    ids.transfers = transfers
    return PlanningChange(delete: ids, softDeleted: incomeIds + contributions, at: at)
  }

  /// The rules as the list of rules has them now: `saving` written, `deleting` gone.
  public static func rules(saving: [AllocationRule], deleting: [UUID] = []) -> PlanningChange {
    var rows = PlanningRows.empty
    rows.allocationRules = saving
    var ids = PlanningRowIDs.empty
    ids.allocationRules = deleting
    return PlanningChange(upsert: rows, delete: ids)
  }

  // MARK: - Writing

  @discardableResult
  public func write(
    _ write: AllocationWrite, categories: [CoreKit.Category] = [],
    settings: [String: String?] = [:], at: Date = Date()
  ) throws -> PlanningUndo {
    try planning.apply(
      Self.change(for: write, categories: categories, settings: settings, at: at))
  }

  /// The contributions and transfers the allocation of `incomeId` wrote, read from the
  /// database: what «Удалить и распределение» takes along.
  public func linked(incomeId: UUID) throws -> (contributions: [UUID], transfers: [UUID]) {
    let prefix = "alloc:\(incomeId.uuidString):"
    return try writer.read { db in
      let contributions = try String.fetchAll(
        db,
        sql: """
          SELECT id FROM transactions
          WHERE deleted_at IS NULL AND upper(external_id) LIKE upper(?) || '%'
          ORDER BY id
          """, arguments: [prefix])
      let transfers = try String.fetchAll(
        db,
        sql: """
          SELECT id FROM transfers WHERE upper(external_id) LIKE upper(?) || '%' ORDER BY id
          """, arguments: [prefix])
      return (
        contributions.compactMap(UUID.init(uuidString:)),
        transfers.compactMap(UUID.init(uuidString:))
      )
    }
  }
}
