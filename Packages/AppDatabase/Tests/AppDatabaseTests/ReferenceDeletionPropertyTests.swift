import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A person, a place or an event is deleted only while nothing points at it — found here from
/// the schema itself, every column in every table, the bin included — and the deletion takes
/// nothing else with it: no link is emptied, no other row changes. Checked on every row of the
/// three books of a history with accounts, with rows made unused on purpose among them.
@Suite("A reference is deleted only when nothing points at it")
struct ReferenceDeletionPropertyTests {
  /// Whether any column of the schema points at `id` of `table`.
  private static func isPointedAt(_ id: UUID, table: String, db: Database) throws -> Bool {
    let tables = try String.fetchAll(
      db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    for child in tables {
      for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(child))")
      where (key["table"] as String) == table {
        let column: String = key["from"]
        if try Bool.fetchOne(
          db, sql: "SELECT EXISTS (SELECT 1 FROM \(child) WHERE \(column) = ?)",
          arguments: [id.uuidString]) == true
        {
          return true
        }
      }
    }
    return false
  }

  @Test(arguments: ReferenceBook.allCases)
  func onlyWhatNothingPointsAtIsDeletedAndNothingElseMoves(book: ReferenceBook) throws {
    let stack = try PlanningUndoPropertyTests.stack()
    // A few rows nobody uses, among the used ones.
    try stack.writer.write { db in
      for index in 0..<3 {
        switch book {
        case .people:
          try Person(name: "Nobody \(index)").insert(db)
        case .places:
          try Place(name: "Nowhere \(index)").insert(db)
        case .events:
          let day = DateOnly(year: 2027, month: 1, day: index + 1)
          let event = Event(name: "Nothing \(index)", kind: .other, startDate: day, endDate: day)
          try event.insert(db)
          // A payment that belongs to an event uses it: the event stays.
          if index == 2 {
            try ScheduledPayment(
              name: "Venue", amountE4: AmountE4(whole: 1_000), eventId: event.id
            ).insert(db)
          }
        }
      }
    }
    let table = book.rawValue
    let (ids, used, before) = try stack.writer.read { db in
      let ids = try String.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY rowid")
        .compactMap(UUID.init(uuidString:))
      var used: Set<UUID> = []
      for id in ids where try Self.isPointedAt(id, table: table, db: db) { used.insert(id) }
      return (ids, used, try ExactTables.read(db))
    }
    #expect(!used.isEmpty && used.count < ids.count, "\(table): the book has both kinds")

    let result = try ReferenceRepository(writer: stack.writer).delete(ids, from: book)

    #expect(Set(result.deleted) == Set(ids).subtracting(used), "\(table)")
    #expect(Set(result.kept.keys) == used, "\(table)")
    let after = try stack.writer.read { db in try ExactTables.read(db) }
    var expected = before
    if var rows = expected[table], let index = rows.columns.firstIndex(of: "id") {
      let gone = Set(result.deleted.map { "'\($0.uuidString)'" })
      rows.rows.removeAll { gone.contains($0[index + 1]) }
      expected[table] = rows
    }
    #expect(after == expected, "\(table): \(PlanningUndoPropertyTests.difference(expected, after))")
    #expect(
      try stack.writer.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }.isEmpty)
  }

  /// A row pointed at only by an operation in the bin stays: bringing the operation back would
  /// otherwise leave it naming a row that is not there.
  @Test func aRowOnlyADeletedOperationUsesStays() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let place = Place(name: "Only in the bin")
    try ReferenceRepository(writer: stack.writer).save(place)
    var entry = try TestSupport.makeEntry()
    entry.transaction.placeId = place.id
    entry.transaction.paymentMethodId = references.paymentMethod.id
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.save(entry)
    try transactions.softDelete(ids: [entry.id])

    let result = try ReferenceRepository(writer: stack.writer).delete([place.id], from: .places)

    #expect(result.deleted.isEmpty)
    #expect(result.kept[place.id]?.isUsed == true)
    #expect(
      try ReferenceRepository(writer: stack.writer).places(includeArchived: true).contains {
        $0.id == place.id
      })
  }
}
