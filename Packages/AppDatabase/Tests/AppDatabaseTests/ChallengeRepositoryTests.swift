import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// The challenges in the database: kept as one setting, read back with the dataset, changed one
/// at a time, and nothing written when nothing changed.
@Suite("The challenges in the database")
struct ChallengeRepositoryTests {
  private func sample(_ title: String = "No delivery") -> Challenge {
    Challenge(
      title: title, kind: .avoid, start: DateOnly(year: 2026, month: 11, day: 2),
      end: DateOnly(year: 2026, month: 11, day: 8), keywords: ["доставка"],
      baseline: AmountE4(whole: 2_500))
  }

  @Test func aNewDatabaseHasNone() throws {
    let stack = try TestSupport.makeStack()
    #expect(try ChallengeRepository(stack: stack).book().items.isEmpty)
  }

  @Test func addUpdateStopRemove() throws {
    let stack = try TestSupport.makeStack()
    let repository = ChallengeRepository(stack: stack)
    var one = sample()
    try repository.add(one)
    try repository.add(sample("Second"))
    #expect(try repository.book().items.map(\.title) == ["No delivery", "Second"])
    one.title = "Renamed"
    try repository.update(one)
    #expect(try repository.book().challenge(one.id)?.title == "Renamed")
    let day = DateOnly(year: 2026, month: 11, day: 4)
    try repository.stop(one.id, on: day)
    try repository.stop(one.id, on: DateOnly(year: 2026, month: 11, day: 6))
    #expect(try repository.book().challenge(one.id)?.stoppedOn == day)
    try repository.remove(one.id)
    #expect(try repository.book().items.map(\.title) == ["Second"])
    // An update of a challenge that is not there adds nothing.
    try repository.update(sample("Ghost"))
    #expect(try repository.book().items.count == 1)
  }

  @Test func theDatasetCarriesThem() async throws {
    let stack = try TestSupport.makeStack()
    let one = sample()
    try ChallengeRepository(stack: stack).add(one)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(dataset.challenges.items == [one])
  }

  @Test func aDamagedTextReadsAsNoneAndSavingFixesIt() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(
        sql: "INSERT INTO settings (key, value) VALUES (?, ?)",
        arguments: [ChallengeBook.storageKey, "{oops"])
    }
    let repository = ChallengeRepository(stack: stack)
    #expect(try repository.book().items.isEmpty)
    try repository.add(sample())
    #expect(try repository.book().items.count == 1)
  }
}
