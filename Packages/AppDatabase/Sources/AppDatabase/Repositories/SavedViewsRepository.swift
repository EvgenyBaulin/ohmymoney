import AppCore
import CoreKit
import Foundation
import GRDB

/// The saved filters and reports (`saved_views`). The book is edited in memory
/// (`SavedViewsBook`) and written as a whole; the repository makes the table hold exactly that and
/// returns the book it replaced, so the write is one step of ⌘Z.
public struct SavedViewsRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func book() throws -> SavedViewsBook {
    try writer.read { db in try Self.book(db) }
  }

  static func book(_ db: Database) throws -> SavedViewsBook {
    let rows = try Row.fetchAll(db, sql: "SELECT * FROM saved_views ORDER BY kind, sort_order, id")
      .compactMap { try? SavedViewRecord(row: $0) }
    return SavedViewsBook(records: rows)
  }

  /// Makes the table hold exactly `book`. A row a newer build wrote that this one can not read is
  /// not in the book and is left alone. Returns the book as it was.
  @discardableResult
  public func replace(with book: SavedViewsBook) throws -> SavedViewsBook {
    try writer.write { db in
      let before = try Self.book(db)
      let wanted = book.records
      let keep = Set(wanted.map(\.id))
      for old in before.records where !keep.contains(old.id) {
        _ = try SavedViewRecord.deleteOne(db, key: old.id.uuidString)
      }
      for record in wanted { try record.save(db) }
      return before
    }
  }
}
