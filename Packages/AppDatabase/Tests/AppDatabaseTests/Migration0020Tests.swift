import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to schema 20 (`0020_habits`) only adds: a database of the previous release keeps
/// every value, the note of a goal starts empty, the two new tables start empty, no setting is
/// written; a badge once written stays whatever the history says later.
@Suite("The habits come in without touching a value")
struct Migration0020Tests {
  private static let older = FilteredSchemaSource(upTo: "0019_privacy")

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0020-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private static let goalId = "33333333-3333-4333-8333-333333333333"

  @Test func aNewDatabaseHasTheColumnAndTheTablesEmpty() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == TestSupport.lastMigration)
    try stack.writer.read { (db: Database) throws in
      #expect(try db.columns(in: "goals").map(\.name).contains("why_note"))
      for table in ["habit_badges", "no_spend_days"] {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
      let keys = try String.fetchAll(db, sql: "SELECT key FROM settings WHERE key LIKE 'habits.%'")
      #expect(keys.isEmpty, "every key reads its default")
    }
  }

  @Test func aDatabaseOfThePreviousReleaseKeepsEveryValueAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO goals (id, name, target_e4, monthly_plan_e4, archived, currency, sort)
            VALUES ('\(Self.goalId)', 'Море', 1500000000, 100000000, 0, 'RUB', 2)
            """)
        try db.execute(
          sql: """
            INSERT INTO transactions (id, kind, occurred_at, amount_e4, amount_rub_e4, note,
                                      created_at, updated_at)
            VALUES ('11111111-1111-4111-8111-111111111111', 'expense', '2026-10-20 10:00:00.000',
                    1000000, 1000000, 'Кофе', '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000')
            """)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0020_habits", "0021_history_and_cashback_choice", "0022_borrowed_card",
          "0023_receipt_numbers_and_category_english",
        ])
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == TestSupport.migrationCount - 19)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      let filled = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM goals WHERE why_note IS NOT NULL")
      #expect(filled == 0, "goals.why_note starts empty")
      for table in ["habit_badges", "no_spend_days"] {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
    }
    let goal = try #require(try stack.writer.read { db in try Goal.fetchOne(db, key: Self.goalId) })
    #expect(goal.whyNote == nil)
    #expect(goal.name == "Море" && goal.sort == 2)
  }

  @Test func theNoteOfAGoalRoundTripsCleaned() throws {
    let stack = try TestSupport.makeStack()
    let goal = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), whyNote: "  море в июле  ")
    try stack.writer.write { db in try goal.insert(db) }
    let read = try #require(
      try stack.writer.read { db in try Goal.fetchOne(db, key: goal.id.uuidString) })
    #expect(read.whyNote == "море в июле")
    var cleared = read
    cleared.whyNote = "   "
    try stack.writer.write { db in try cleared.update(db) }
    let stored = try stack.writer.read { db in
      try String?.fetchOne(
        db, sql: "SELECT why_note FROM goals WHERE id = ?", arguments: [goal.id.uuidString])
    }
    #expect(stored == .some(nil), "an empty note is stored as none")
  }

  @Test func badgesAreWrittenOnceAndNothingIsWrittenWhenNothingIsNew() throws {
    let stack = try TestSupport.makeStack()
    let habits = HabitRepository(writer: stack.writer)
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let week = HabitBadge(
      kind: .entry7, period: "2026-11-02", earnedOn: DateOnly(year: 2026, month: 11, day: 8),
      earnedAt: at)
    let month = HabitBadge(
      kind: .countMonth, period: "2026-10", earnedOn: DateOnly(year: 2026, month: 10, day: 5),
      earnedAt: at)
    #expect(try habits.award([week, month, week]) == 2)
    var later = week
    later.earnedOn = DateOnly(year: 2026, month: 12, day: 1)
    later.earnedAt = at.addingTimeInterval(86_400)
    let changesBefore = try stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT total_changes()")
    }
    #expect(try habits.award([later, month]) == 0)
    let changesAfter = try stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT total_changes()")
    }
    #expect(changesBefore == changesAfter, "nothing written when nothing is new")
    let data = try habits.data()
    #expect(data.badges.map(\.key).sorted() == ["countMonth:2026-10", "entry7:2026-11-02"])
    #expect(
      data.badges.first { $0.kind == .entry7 }?.earnedOn == DateOnly(year: 2026, month: 11, day: 8),
      "the first day of earning stays")
  }

  /// The history earned a badge; an operation of that streak is deleted, so the history no longer
  /// earns it: the badge stays, and a recount writes nothing.
  @Test func anEditOfThePastNeverTakesABadgeBack() async throws {
    let stack = try TestSupport.makeStack()
    let calendar = CalendarContext.moscow
    let start = DateOnly(year: 2026, month: 11, day: 2)
    let transactions = TransactionRepository(writer: stack.writer)
    var ids: [UUID] = []
    for offset in 0..<7 {
      let day = calendar.adding(days: offset, to: start)
      var entry = try TestSupport.makeEntry()
      entry.transaction.occurredAt = calendar.noon(of: day)
      entry.transaction.createdAt = calendar.noon(of: day)
      entry.transaction.updatedAt = calendar.noon(of: day)
      try transactions.insert([entry])
      ids.append(entry.id)
    }
    let habits = HabitRepository(writer: stack.writer)
    let today = calendar.adding(days: 6, to: start)
    func earned() async throws -> [HabitBadge] {
      let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
      let days = HabitEntryDays.days(
        dataset.entries, noSpend: dataset.habits.markedDays, calendar: calendar)
      return HabitBadges.earned(
        entryDays: days, reconciliations: dataset.planning.reconciliations, today: today,
        at: Date())
    }
    let first = try await earned()
    #expect(first.map(\.kind) == [.entry7])
    #expect(try habits.award(first) == 1)
    for id in ids.dropFirst(2).prefix(3) { _ = try transactions.softDelete(id: id) }
    let after = try await earned()
    #expect(after.isEmpty, "the history no longer earns it")
    #expect(try habits.award(HabitBadges.new(after, stored: try habits.data().badges)) == 0)
    #expect(try habits.data().badges.map(\.kind) == [.entry7], "the badge stays")
  }

  @Test func aDayWithoutSpendingIsMarkedOnceAndCanBeTakenBack() async throws {
    let stack = try TestSupport.makeStack()
    let habits = HabitRepository(writer: stack.writer)
    let day = DateOnly(year: 2026, month: 11, day: 3)
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try habits.markNoSpend(day, at: at))
    #expect(!(try habits.markNoSpend(day, at: at.addingTimeInterval(60))))
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(dataset.habits.markedDays == [day])
    #expect(try habits.unmarkNoSpend(day))
    #expect(!(try habits.unmarkNoSpend(day)))
    #expect(try habits.data().noSpendDays.isEmpty)
  }

  @Test func theSettingReadsItsDefaultAndRoundTrips() throws {
    let stack = try TestSupport.makeStack()
    let habits = HabitRepository(writer: stack.writer)
    #expect(try habits.data().settings == HabitSettings())
    try habits.save(HabitSettings(missedDaysAfter: 5))
    #expect(try habits.data().settings.missedDaysAfter == 5)
  }

  @Test func theTablesGoLastInTheExportAndTheNoteLastInTheGoals() throws {
    let stack = try TestSupport.makeStack()
    let habits = HabitRepository(writer: stack.writer)
    try habits.award([
      HabitBadge(
        kind: .count3, period: "2026-08", earnedOn: DateOnly(year: 2026, month: 10, day: 15),
        earnedAt: Date(timeIntervalSince1970: 1_800_000_000))
    ])
    try habits.markNoSpend(DateOnly(year: 2026, month: 11, day: 3), at: Date())
    try stack.writer.write { db in
      try Goal(name: "Море", targetE4: AmountE4(whole: 1), whyNote: "всей семьёй").insert(db)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    #expect(tables.count == ExportTables.all.count)
    #expect(
      tables.dropLast(2).suffix(2).map(\.fileName) == ["habit_badges.csv", "no_spend_days.csv"])
    let badges = try CSVReader.dictionaries(
      from: try #require(tables.first { $0.name == "habit_badges" }).data)
    #expect(badges.first?["kind"] == "count3" && badges.first?["period"] == "2026-08")
    let days = try CSVReader.dictionaries(
      from: try #require(tables.first { $0.name == "no_spend_days" }).data)
    #expect(days.first?["day"] == "2026-11-03")
    let goals = try CSVReader.dictionaries(
      from: try #require(tables.first { $0.name == "goals" }).data)
    #expect(goals.first?["why_note"] == "всей семьёй")
  }

  @Test func theNewRowsGoToTheOutboxByTheirKeys() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('recording', '1')")
      try db.execute(sql: "DELETE FROM sync_outbox")
    }
    let habits = HabitRepository(writer: stack.writer)
    try habits.award([
      HabitBadge(
        kind: .entry7, period: "2026-11-02", earnedOn: DateOnly(year: 2026, month: 11, day: 8),
        earnedAt: Date())
    ])
    try habits.markNoSpend(DateOnly(year: 2026, month: 11, day: 3), at: Date())
    let queued = try stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT table_name, row_key FROM sync_outbox ORDER BY table_name")
        .map { "\($0["table_name"] as String):\($0["row_key"] as String)" }
    }
    #expect(queued == ["habit_badges:entry7:2026-11-02", "no_spend_days:2026-11-03"])
    #expect(SyncTables.followed["habit_badges"] == "key")
    #expect(SyncTables.followed["no_spend_days"] == "day")
  }

  @Test func theAnonymisedCopyWipesTheNote() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try Goal(name: "Море", targetE4: AmountE4(whole: 1), whyNote: "всей семьёй").insert(db)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    let notes = try stack.writer.read { db in
      try String?.fetchAll(db, sql: "SELECT why_note FROM goals")
    }
    #expect(notes == [nil])
  }
}
