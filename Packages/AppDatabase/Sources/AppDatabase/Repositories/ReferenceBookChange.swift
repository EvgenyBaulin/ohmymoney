import CoreKit
import Foundation
import GRDB

/// A confirmed action of the reference books, written and undone with the planning journal.
public enum ReferenceBookChange: Sendable, Hashable {
  case merge(book: ReferenceBook, source: UUID, target: UUID)
  case delete(book: ReferenceBook, ids: [UUID])
}

/// Only the rows and links a reference-book action changed, kept for one step of undo.
public struct ReferenceBookUndo: Sendable, Hashable {
  public var deletion = ReferenceDeletion()
  public var transactionIds: [UUID] = []
  var people: [Person] = []
  var places: [Place] = []
  var events: [Event] = []
  var links: [Link] = []

  struct Link: Sendable, Hashable {
    var table: String
    var column: String
    var id: String
    var source: UUID
    var target: UUID
  }

  public var hasChanges: Bool { !people.isEmpty || !places.isEmpty || !events.isEmpty }
}

extension ReferenceRepository {
  static func apply(_ change: ReferenceBookChange, db: Database) throws -> ReferenceBookUndo {
    var undo = ReferenceBookUndo()
    switch change {
    case .delete(let book, let ids):
      for id in Set(ids).sorted(by: { $0.uuidString < $1.uuidString }) {
        let usage = try usage(in: book, only: id, db: db)[id] ?? ReferenceUsage()
        guard !usage.isUsed else {
          undo.deletion.kept[id] = usage
          continue
        }
        guard try undo.keep(id, in: book, db: db) else { continue }
        try db.execute(
          sql: "DELETE FROM \(book.rawValue) WHERE id = ?", arguments: [id.uuidString])
        undo.deletion.deleted.append(id)
      }
    case .merge(let book, let source, let target):
      guard source != target else { return undo }
      guard try undo.keep(source, in: book, db: db),
        try undo.keep(target, in: book, db: db)
      else { throw ReferenceWriteError.notFound }
      var transactions = Set<UUID>()
      for (table, column) in mergedColumns[book.rawValue] ?? [] {
        let rows = try Row.fetchAll(
          db, sql: "SELECT * FROM \(table) WHERE \(column) = ?", arguments: [source.uuidString])
        for row in rows {
          let id: String = row["id"]
          undo.links.append(
            .init(table: table, column: column, id: id, source: source, target: target))
          let transaction: String? =
            table == "transactions"
            ? id : (table == "transaction_parts" ? row["transaction_id"] : nil)
          if let transaction, let id = UUID(uuidString: transaction) { transactions.insert(id) }
        }
      }
      undo.transactionIds = transactions.sorted { $0.uuidString < $1.uuidString }
      try repoint(book.rawValue, from: source, to: target, db: db)
      switch book {
      case .people: try mergeAliases(Person.self, source: source, into: target, db: db)
      case .places: try mergeAliases(Place.self, source: source, into: target, db: db)
      case .events: break
      }
      try db.execute(
        sql: "UPDATE \(book.rawValue) SET archived = 1 WHERE id = ?",
        arguments: [source.uuidString])
    }
    return undo
  }

  static func revert(_ undo: ReferenceBookUndo, db: Database) throws {
    for row in undo.people { try row.save(db) }
    for row in undo.places { try row.save(db) }
    for row in undo.events { try row.save(db) }
    for link in undo.links {
      // A later edit stays in place; only links still pointing at the merge target move back.
      try db.execute(
        sql: "UPDATE \(link.table) SET \(link.column) = ? WHERE id = ? AND \(link.column) = ?",
        arguments: [link.source.uuidString, link.id, link.target.uuidString])
    }
  }
}

extension ReferenceBookUndo {
  /// Captures the complete row before it is changed; a missing row is never recreated.
  fileprivate mutating func keep(_ id: UUID, in book: ReferenceBook, db: Database) throws -> Bool {
    switch book {
    case .people:
      guard let row = try Person.fetchOne(db, key: id.uuidString) else { return false }
      people.append(row)
    case .places:
      guard let row = try Place.fetchOne(db, key: id.uuidString) else { return false }
      places.append(row)
    case .events:
      guard let row = try Event.fetchOne(db, key: id.uuidString) else { return false }
      events.append(row)
    }
    return true
  }
}
