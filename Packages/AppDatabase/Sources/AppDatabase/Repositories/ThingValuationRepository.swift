import AppCore
import CoreKit
import Foundation
import GRDB

/// Valuations stored independently in settings until they have their own table. The normal
/// settings CSV, archive and change journal preserve the whole record, including its currency. Settings do not participate in device exchange.
public struct ThingValuationRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) { self.writer = writer }

  public func all() throws -> [ThingValuation] {
    try writer.read { db in try Self.all(db) }
  }

  static func all(_ db: Database) throws -> [ThingValuation] {
    try Row.fetchAll(
      db, sql: "SELECT key, value FROM settings WHERE key GLOB ? ORDER BY key",
      arguments: [ThingValuation.storagePrefix + "*"]
    )
    .compactMap { row in
      guard let value = try? ThingValuation.decode(row["value"]),
        value.storageKey == (row["key"] as String), value.amountE4.raw >= 0
      else { return nil }
      return value
    }
  }

  public func save(_ value: ThingValuation) throws {
    guard value.amountE4.raw >= 0 else { throw ThingValuationWriteError.negativeAmount }
    let encoded = try value.storedValue
    try writer.write { db in
      let table = value.owner == .asset ? "assets" : "owned_items"
      guard
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)",
          arguments: [value.ownerId.uuidString]) == true
      else { throw ThingValuationWriteError.ownerMissing }
      try SettingsRepository.set(value.storageKey, to: encoded, in: db)
    }
  }

  public func delete(_ id: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: "DELETE FROM settings WHERE key = ?",
        arguments: [ThingValuation.storagePrefix + id.uuidString])
    }
  }

  static func delete(owner: ThingValuation.Owner, id: UUID, db: Database) throws {
    for value in try all(db) where value.owner == owner && value.ownerId == id {
      try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [value.storageKey])
    }
  }
}

public enum ThingValuationWriteError: Error {
  case negativeAmount
  case ownerMissing
}
