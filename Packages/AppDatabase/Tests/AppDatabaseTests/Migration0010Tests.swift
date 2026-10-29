import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to the scenarios (`0010_scenarios`) only adds: a database of 1.10 keeps every
/// value, the table of scenarios starts empty, the goals read as they did — in order of name —
/// until the owner drags one. The scenarios are written, ordered, deleted and brought back by
/// the planning, one step of ⌘Z each.
@Suite("The scenarios come in without touching a value")
struct Migration0010Tests {
  private static let older = FilteredSchemaSource(upTo: "0009_credit_and_allocation")

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0010-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasNoScenariosAndTheGoalsAreNotPlaced() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains("0010_scenarios"))
    #expect(stack.applied.onDisk == 16)
    try stack.writer.read { db in
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scenarios") == 0)
      let columns = try db.columns(in: "scenarios").map(\.name)
      #expect(
        columns == [
          "id", "name", "sort", "spec_json", "baseline_json", "created_at", "updated_at",
          "deleted_at",
        ])
      let goal = try #require(try db.columns(in: "goals").first { $0.name == "sort" })
      #expect(goal.defaultValueSQL == "0")
    }
  }

  @Test func aDatabaseOf19KeepsEveryGoalAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let first = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000))
    let second = Goal(name: "Машина", targetE4: AmountE4(whole: 900_000), currency: .usd)
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      // Written as the build of the time wrote them: the table has no order yet.
      try old.writer.write { db in
        for (goal, currency) in [(first, "RUB"), (second, "USD")] {
          try db.execute(
            sql: """
              INSERT INTO goals (id, name, target_e4, archived, currency)
              VALUES (?, ?, ?, 0, ?)
              """,
            arguments: [goal.id.uuidString, goal.name, goal.targetE4.raw, currency])
        }
      }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0010_scenarios", "0011_travel", "0012_sync", "0013_spending_rules",
          "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0017_attachments",
        ])
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 7)
    #expect(stack.applied.dataSteps.isEmpty)
    let goals = try ReferenceRepository(writer: stack.writer).goals()
    #expect(goals.map(\.name) == ["Машина", "Отпуск"], "alphabetical, as before")
    #expect(goals.allSatisfy { $0.sort == 0 })
    #expect(Set(goals.map(\.id)) == [first.id, second.id])
    #expect(goals.first { $0.id == second.id }?.currency == .usd)
    let scenarios = try stack.writer.read { (db: Database) throws -> Int? in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scenarios")
    }
    #expect(scenarios == 0)
  }

  @Test func scenariosAreSavedRenamedOrderedDeletedAndBroughtBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = ScenarioRepository(writer: stack.writer)
    let planning = repository.planning
    let car = Scenario(name: "Кредит 1,2 млн на 5 лет", specJSON: #"{"changes":[]}"#)
    let twin = Scenario(name: "Кредит 1,2 млн на 5 лет", specJSON: #"{"changes":[1]}"#)
    #expect(try repository.scenarios().isEmpty)

    let saved = try planning.apply(try repository.saving(car))
    _ = try planning.apply(try repository.saving(twin))
    let all = try repository.scenarios()
    #expect(all.count == 2, "the same name twice is allowed, and nothing limits the number")
    #expect(all.map(\.id) == [car.id, twin.id], "a new one goes last")
    #expect(all.map(\.specJSON) == [#"{"changes":[]}"#, #"{"changes":[1]}"#])

    _ = try planning.apply(try repository.renaming(car.id, to: "Копить"))
    #expect(try repository.scenario(id: car.id)?.name == "Копить")

    _ = try planning.apply(try repository.reordering([twin.id, car.id]))
    #expect(try repository.scenarios().map(\.id) == [twin.id, car.id])

    let gone = try planning.apply(try repository.deleting(twin.id))
    #expect(try repository.scenarios().map(\.id) == [car.id])
    #expect(try repository.deleted().map(\.id) == [twin.id])
    _ = try planning.revert(gone)
    #expect(try repository.scenarios().map(\.id) == [twin.id, car.id], "⌘Z brings it back whole")

    _ = try planning.revert(saved)
    #expect(try repository.scenario(id: car.id) == nil, "⌘Z of the first save takes it away")
  }

  @Test func theOrderOfTheGoalsIsTheOwnersAndOneStepOfUndo() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let a = Goal(name: "А", targetE4: AmountE4(whole: 1))
    let b = Goal(name: "Б", targetE4: AmountE4(whole: 1))
    let c = Goal(name: "В", targetE4: AmountE4(whole: 1))
    for goal in [a, b, c] { try references.save(goal) }
    #expect(try references.goals().map(\.id) == [a.id, b.id, c.id])

    let repository = ScenarioRepository(writer: stack.writer)
    let undo = try repository.planning.apply(try repository.reorderingGoals([c.id, a.id]))
    #expect(try references.goals().map(\.id) == [c.id, a.id, b.id], "the ones left out follow")
    #expect(try references.goals().map(\.sort) == [1, 2, 3])
    _ = try repository.planning.revert(undo)
    #expect(try references.goals().map(\.id) == [a.id, b.id, c.id])
    #expect(try references.goals().allSatisfy { $0.sort == 0 })
  }

  @Test func theScenariosAreNotInTheCSVButTravelInTheDatabase() throws {
    #expect(!ExportTables.all.map(\.fileName).contains("scenarios.csv"))
    #expect(ExportTables.all.count == 45)
    #expect(!DatabaseStack.ledgerTables.contains("scenarios"))
    #expect(DatabaseStack.dataTables.contains("scenarios"))
  }
}
