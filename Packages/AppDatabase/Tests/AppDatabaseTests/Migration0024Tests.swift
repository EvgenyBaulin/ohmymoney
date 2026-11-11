import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to the mark of a category (`0024_category_icon_color`) only adds: a database of the
/// previous schema keeps every value and every category reads as having no mark, and the two new
/// fields travel through the records, the CSV, the archive's database and the exchange.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether
/// or not another migration lands after it.
@Suite("Schema 24 comes in without touching a value")
struct Migration0024Tests {
  static let name = "0024_category_icon_color"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0024-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasTheTwoColumnsWithoutACheck() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 24)
    try stack.writer.read { (db: Database) throws in
      let columns = try db.columns(in: "categories")
      for name in ["icon", "color"] {
        let column = try #require(columns.first { $0.name == name }, "\(name)")
        #expect(column.type.uppercased() == "TEXT")
        #expect(!column.isNotNull)
      }
      let sql =
        try String.fetchOne(
          db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'categories'")
        ?? ""
      #expect(!sql.contains("icon TEXT CHECK"), "an added column carries no CHECK")
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndHasNoMark() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO categories (id, kind, name, sort, archived)
            VALUES ('22222222-2222-4222-8222-222222222222', 'expense', 'Кафе', 0, 0);
            INSERT INTO categories (id, parent_id, kind, name, sort, archived)
            VALUES ('33333333-3333-4333-8333-333333333333',
              '22222222-2222-4222-8222-222222222222', 'expense', 'Кофе', 0, 0);
            INSERT INTO transactions
              (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
            VALUES ('11111111-1111-4111-8111-111111111111', 'expense', '2026-10-20 10:00:00.000',
              1500000, 1500000, 'кофе', '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000');
            """)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == TestSupport.migrationNames.filter { $0 >= Self.name })
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      let marks = try Row.fetchAll(db, sql: "SELECT icon, color FROM categories")
      #expect(marks.count == 2)
      for mark in marks {
        #expect((mark["icon"] as DatabaseValue).isNull && (mark["color"] as DatabaseValue).isNull)
      }
      let category = try #require(
        try CoreKit.Category.fetchOne(db, key: "22222222-2222-4222-8222-222222222222"))
      #expect(category.appearance.isEmpty)
    }
  }

  @Test func theMarkRoundTripsThroughTheRecordsAndTheOwnerCanTakeItOff() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    var category = CoreKit.Category(
      kind: .expense, name: "Продукты",
      appearance: CategoryAppearance(icon: "cart", color: "tone1"))
    try references.save(category)
    #expect(try references.categories().first { $0.id == category.id } == category)
    // Saved again with only the symbol: the colour goes — the write is the owner's, empty too.
    category.appearance = CategoryAppearance(icon: "cart", color: nil)
    try references.save(category)
    let read = try #require(try references.categories().first { $0.id == category.id })
    #expect(read.icon == "cart" && read.color == nil)
    category.appearance = .none
    try references.save(category)
    #expect(try references.categories().first { $0.id == category.id }?.appearance.isEmpty == true)
  }

  @Test func aNameThisBuildDoesNotKnowIsKeptAsWrittenAndDrawsAsNone() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let category = CoreKit.Category(
      kind: .expense, name: "Из будущего",
      appearance: CategoryAppearance(icon: "sparkles.rectangle.stack", color: "tone9"))
    try references.save(category)
    let read = try #require(try references.categories().first { $0.id == category.id })
    #expect(read.icon == "sparkles.rectangle.stack" && read.color == "tone9")
    let drawn = CategoryTree([read]).appearance(of: read.id)
    #expect(drawn.icon == nil && drawn.tone == nil)
  }

  @Test func aBlankValueReadsAsNone() throws {
    let stack = try TestSupport.makeStack()
    let category = CoreKit.Category(kind: .expense, name: "Пустая")
    try stack.writer.write { db in
      try category.insert(db)
      try db.execute(
        sql: "UPDATE categories SET icon = '  ', color = '' WHERE id = ?",
        arguments: [category.id.uuidString])
    }
    let read = try #require(
      try ReferenceRepository(writer: stack.writer).categories().first { $0.id == category.id })
    #expect(read.appearance.isEmpty)
  }

  @Test func theMarkGoesLastInTheCSV() throws {
    #expect(Array(ExportTables.categories.columns.suffix(2)) == ["icon", "color"])
    #expect(ExportTables.all.count == 54)
    let marked = CoreKit.Category(
      kind: .expense, name: "Такси", appearance: CategoryAppearance(icon: "car", color: "accent"))
    let row = ExportTables.row(marked)
    #expect(row.count == ExportTables.categories.columns.count)
    #expect(Array(row.suffix(2)) == ["car", "accent"])
    let plain = ExportTables.row(CoreKit.Category(kind: .expense, name: "Такси"))
    #expect(Array(plain.suffix(2)) == ["", ""])
  }

  @Test func theExportOfTheDatabaseWritesTheMark() throws {
    let stack = try TestSupport.makeStack()
    let category = CoreKit.Category(
      kind: .expense, name: "Дом",
      appearance: CategoryAppearance(icon: "house", color: "tone5"))
    try ReferenceRepository(writer: stack.writer).save(category)
    let tables = try ExportRepository(writer: stack.writer).tables()
    let table = try #require(tables.first { $0.fileName == ExportTables.categories.fileName })
    let text = String(decoding: table.data, as: UTF8.self)
    #expect(text.hasPrefix(ExportTables.categories.columns.joined(separator: ",")))
    #expect(text.contains(",house,tone5"))
  }

  @Test func theMarkTravelsWithTheRowToTheOtherDevice() throws {
    let device = try TestDevice("mac")
    try device.sql(
      "INSERT INTO categories (id, kind, name, sort, archived) VALUES ('c1', 'expense', 'Кафе', 0, 0)"
    )
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("UPDATE categories SET icon = 'cup.and.saucer', color = 'tone2' WHERE id = 'c1'")
    let queued = try device.stack.writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT DISTINCT table_name || ':' || row_key FROM sync_outbox ORDER BY 1")
    }
    #expect(queued == ["categories:c1"])

    let mac = try TestDevice("mac2")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(
      """
      INSERT INTO categories (id, kind, name, sort, archived, icon, color)
      VALUES ('c1', 'expense', 'Кафе', 0, 0, 'cup.and.saucer', 'tone2')
      """)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    let row = try phone.stack.writer.read { db in
      try Row.fetchOne(db, sql: "SELECT icon, color FROM categories WHERE id = 'c1'")
    }
    #expect(row?["icon"] == "cup.and.saucer")
    #expect(row?["color"] == "tone2")
  }

  /// A device not yet updated writes its rows without the two columns. What the file does not
  /// have keeps its value here (`SyncRows.write`), so an edit from the older build — here a
  /// rename — does not take the owner's symbol off the category.
  @Test func anEditFromABuildWithoutTheMarkLeavesTheMarkOfThisDevice() throws {
    let newer = try TestDevice("mac")
    let olderStack = try DatabaseStack(inMemory: Self.older)
    #expect(
      try olderStack.writer.read { db in
        try db.columns(in: "categories").map(\.name).contains("icon")
      } == false, "the older build has no such column")
    let older = try SyncExchange(writer: olderStack.writer, deviceId: "old", deviceName: "Old")
    try older.setRecording(true)
    let folder = InMemoryFolder()
    func olderSQL(_ text: String) throws {
      try olderStack.writer.write { db in try db.execute(sql: text) }
    }
    func olderStamp(_ moment: String) throws {
      try olderStack.writer.write { db in
        try db.execute(sql: "UPDATE sync_outbox SET at = ?", arguments: [moment])
      }
    }

    try olderSQL(
      "INSERT INTO categories (id, kind, name, sort, archived) VALUES ('c1', 'expense', 'Кафе', 0, 0)"
    )
    try olderStamp("2026-11-11T10:00:00Z")
    _ = try older.exchange(with: folder)
    _ = try newer.exchange.exchange(with: folder)

    // The owner picks a symbol on the updated device; the other one takes the row without it.
    try newer.sql("UPDATE categories SET icon = 'cup.and.saucer', color = 'tone2' WHERE id = 'c1'")
    try newer.stamp("2026-11-11T10:05:00Z")
    _ = try newer.exchange.exchange(with: folder)
    _ = try older.exchange(with: folder)

    // Then the older build renames the category, as it always could.
    try olderSQL("UPDATE categories SET name = 'Кафе и бары' WHERE id = 'c1'")
    try olderStamp("2026-11-11T10:10:00Z")
    _ = try older.exchange(with: folder)
    let outcome = try newer.exchange.exchange(with: folder)
    #expect(outcome.conflictsOpen == 0)
    let row = try newer.stack.writer.read { db in
      try Row.fetchOne(db, sql: "SELECT name, icon, color FROM categories WHERE id = 'c1'")
    }
    #expect(row?["name"] == "Кафе и бары", "the rename arrived")
    #expect(row?["icon"] == "cup.and.saucer" && row?["color"] == "tone2", "the mark is kept")
  }

  @Test func twoDevicesPickingDifferentMarksIsAConflictTheOwnerSees() {
    #expect(!SyncConflict.isService("icon"))
    #expect(!SyncConflict.isService("color"))
    #expect(SyncConflict.differs("icon", .string("cart"), .string("car")))
    #expect(SyncConflict.differs("color", .string("tone1"), .string("tone2")))
  }

  @Test func theAnonymizedCopyKeepsTheMarkOfACategory() throws {
    let stack = try TestSupport.makeStack()
    let category = CoreKit.Category(
      kind: .expense, name: "Продукты",
      appearance: CategoryAppearance(icon: "cart", color: "tone1"))
    try stack.writer.write { db in try category.insert(db) }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    let row = try stack.writer.read { db in
      try Row.fetchOne(
        db, sql: "SELECT name, icon, color FROM categories WHERE id = ?",
        arguments: [category.id.uuidString])
    }
    #expect(row?["name"] == "Продукты", "the tree is the app's, not a secret")
    #expect(row?["icon"] == "cart" && row?["color"] == "tone1")
  }
}
