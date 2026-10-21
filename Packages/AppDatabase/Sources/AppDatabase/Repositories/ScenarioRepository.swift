import AppCore
import CoreKit
import Foundation
import GRDB

/// The saved «what if» scenarios and the order of the goals. Every write is a `PlanningChange`
/// — one record, one step of ⌘Z —, so the app writes it through the same store as every other
/// change of the planning, and ⌘Z gives back the rows as they were. A scenario deleted is a row
/// with `deletedAt` set, written over like any other (no list of ids to delete).
public struct ScenarioRepository: Sendable {
  public let planning: PlanningRepository
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter, liveCounts: LiveCountsContext = .standard) {
    self.writer = writer
    self.planning = PlanningRepository(writer: writer, liveCounts: liveCounts)
  }

  // MARK: - Reading

  /// The live scenarios in the owner's order, then by name.
  public func scenarios() throws -> [Scenario] {
    try writer.read { db in try Self.live(db) }
  }

  /// One scenario, a deleted one included.
  public func scenario(id: UUID) throws -> Scenario? {
    try writer.read { db in try Scenario.fetchOne(db, key: id.uuidString) }
  }

  /// The scenarios in the bin, the latest deleted first.
  public func deleted() throws -> [Scenario] {
    try writer.read { db in
      try Scenario.filter(Column("deleted_at") != nil)
        .order(Column("deleted_at").desc, Column.rowID).fetchAll(db)
    }
  }

  static func live(_ db: Database) throws -> [Scenario] {
    try Scenario.filter(Column("deleted_at") == nil)
      .order(Column("sort"), Column("name"), Column.rowID).fetchAll(db)
  }

  // MARK: - The changes

  /// A scenario saved, new or written over: stamped as updated at `at`. A new one goes last.
  public func saving(_ scenario: Scenario, at instant: Date = Date()) throws -> PlanningChange {
    try writer.read { db in
      var row = scenario
      row.updatedAt = instant
      if try Scenario.fetchOne(db, key: row.id.uuidString) == nil {
        let last = try Int.fetchOne(
          db, sql: "SELECT MAX(sort) FROM scenarios WHERE deleted_at IS NULL")
        if row.sort == 0, let last { row.sort = last + 1 }
      }
      return PlanningChange(upsert: PlanningRows(scenarios: [row]), at: instant)
    }
  }

  /// The scenario under another name.
  public func renaming(
    _ id: UUID, to name: String, at instant: Date = Date()
  ) throws -> PlanningChange {
    try writer.read { db in
      guard var row = try Scenario.fetchOne(db, key: id.uuidString) else {
        throw ReferenceWriteError.notFound
      }
      row.name = name
      row.updatedAt = instant
      return PlanningChange(upsert: PlanningRows(scenarios: [row]), at: instant)
    }
  }

  /// The live scenarios in this order; ones left out keep their order after them. Only rows
  /// whose place changes are written.
  public func reordering(_ ids: [UUID], at instant: Date = Date()) throws -> PlanningChange {
    try writer.read { db in
      let existing = try Self.live(db)
      let named = ids.compactMap { id in existing.first { $0.id == id } }
      let rest = existing.filter { row in !named.contains { $0.id == row.id } }
      var rows: [Scenario] = []
      for (index, var row) in (named + rest).enumerated() where row.sort != index {
        row.sort = index
        row.updatedAt = instant
        rows.append(row)
      }
      return PlanningChange(upsert: PlanningRows(scenarios: rows), at: instant)
    }
  }

  /// The scenario deleted softly: the row stays with `deletedAt` set.
  public func deleting(_ id: UUID, at instant: Date = Date()) throws -> PlanningChange {
    try writer.read { db in
      guard var row = try Scenario.fetchOne(db, key: id.uuidString) else {
        throw ReferenceWriteError.notFound
      }
      row.deletedAt = instant
      row.updatedAt = instant
      return PlanningChange(upsert: PlanningRows(scenarios: [row]), at: instant)
    }
  }

  /// A deleted scenario brought back.
  public func restoring(_ id: UUID, at instant: Date = Date()) throws -> PlanningChange {
    try writer.read { db in
      guard var row = try Scenario.fetchOne(db, key: id.uuidString) else {
        throw ReferenceWriteError.notFound
      }
      row.deletedAt = nil
      row.updatedAt = instant
      return PlanningChange(upsert: PlanningRows(scenarios: [row]), at: instant)
    }
  }

  /// The goals in this order, from 1 (`sort` 0 is «not placed»); ones left out keep their order
  /// after them. Archived goals are in the order too.
  public func reorderingGoals(_ ids: [UUID], at instant: Date = Date()) throws -> PlanningChange {
    try writer.read { db in
      let existing = try Goal.order(Column("sort"), Column("name")).fetchAll(db)
      let named = ids.compactMap { id in existing.first { $0.id == id } }
      let rest = existing.filter { row in !named.contains { $0.id == row.id } }
      var rows: [Goal] = []
      for (index, var row) in (named + rest).enumerated() where row.sort != index + 1 {
        row.sort = index + 1
        rows.append(row)
      }
      return PlanningChange(upsert: PlanningRows(goals: rows), at: instant)
    }
  }
}
