import AppCore
import CoreKit
import Foundation
import GRDB

/// The market valuations of things (`thing_valuations`): one row per observation, so valuations
/// added on two devices never meet, and every row travels with the exchange of changes, the CSV
/// export and the archive like any other table.
public struct ThingValuationRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) { self.writer = writer }

  public func all() throws -> [ThingValuation] {
    try writer.read { db in try Self.all(db) }
  }

  /// A row that does not read (an unknown kind of owner from a newer build) is left out and left
  /// in the database.
  static func all(_ db: Database) throws -> [ThingValuation] {
    try Row.fetchAll(
      db, sql: "SELECT * FROM thing_valuations ORDER BY valued_on, recorded_at, id"
    ).compactMap { try? ThingValuation(row: $0) }
  }

  public func save(_ value: ThingValuation) throws {
    guard value.amountE4.raw >= 0 else { throw ThingValuationWriteError.negativeAmount }
    try writer.write { db in
      let table = value.owner == .asset ? "assets" : "owned_items"
      guard
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)",
          arguments: [value.ownerId.uuidString]) == true
      else { throw ThingValuationWriteError.ownerMissing }
      try value.save(db)
    }
  }

  public func delete(_ id: UUID) throws {
    try writer.write { db in
      _ = try ThingValuation.deleteOne(db, key: id.uuidString)
    }
  }
}

public enum ThingValuationWriteError: Error {
  case negativeAmount
  case ownerMissing
}
