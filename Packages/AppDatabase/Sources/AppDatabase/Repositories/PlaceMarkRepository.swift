import CoreKit
import Foundation
import GRDB

/// The owner's marks on the map. They belong to this device: the table has no triggers of the
/// exchange, is emptied in everything made for another person, and is not in the CSV. A write
/// is a plain save — no journal line, no step of ⌘Z — because a mark is the setting of a
/// device, not an entry of the books.
public struct PlaceMarkRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// On an open database of the app.
  public init(stack: DatabaseStack) {
    self.writer = stack.writer
  }

  /// Every mark, by name; rows that do not read are left out, untouched.
  public func all() throws -> [PlaceMark] {
    try writer.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM place_marks ORDER BY name COLLATE NOCASE, id")
        .compactMap { try? PlaceMark(row: $0) }
    }
  }

  /// Adds the mark or replaces the one with its id.
  public func save(_ mark: PlaceMark) throws {
    try writer.write { db in try mark.save(db) }
  }

  public func delete(id: UUID) throws {
    try writer.write { db in
      try db.execute(sql: "DELETE FROM place_marks WHERE id = ?", arguments: [id.uuidString])
    }
  }

  public func setEnabled(_ enabled: Bool, id: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE place_marks SET enabled = ? WHERE id = ?",
        arguments: [enabled ? 1 : 0, id.uuidString])
    }
  }

  /// Removes the marks of a deleted place or category from the reading of the mark, keeping the
  /// mark itself.
  public func forget(placeId: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE place_marks SET place_id = NULL WHERE place_id = ?",
        arguments: [placeId.uuidString])
    }
  }
}
