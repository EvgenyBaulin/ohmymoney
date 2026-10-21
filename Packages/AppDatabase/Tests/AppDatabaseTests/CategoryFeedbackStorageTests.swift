import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// A category chosen against the model is written to `category_feedback`: what is stored of
/// a choice, and that the snapshot the calculations read carries it.
@Suite("Storage of the owner's category choices")
struct CategoryFeedbackStorageTests {
  private func category(_ name: String, in references: ReferenceRepository) throws -> UUID {
    let category = CoreKit.Category(kind: .expense, name: name, quality: .neutral)
    try references.save(category)
    return category.id
  }

  @Test("A choice keeps every field it was written with")
  func aChoiceKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let models = ModelRepository(writer: stack.writer)
    let coffee = try category("Coffee", in: references)
    let taxi = try category("Taxi", in: references)
    let entry = try TestSupport.makeEntry()
    try transactions.save(entry)
    let choice = CategoryFeedback(
      text: "coffee", predictedCategoryId: coffee, chosenCategoryId: taxi,
      partId: entry.parts[0].id, confidenceBp: 7_250,
      at: Date(timeIntervalSince1970: 1_789_000_000))

    try models.record(choice)

    #expect(try models.feedback() == [choice])
    #expect(choice.overrulesTheModel)
  }

  /// A deleted category leaves the choice standing with a blank where it was, and an
  /// operation erased for good takes its choices with it.
  @Test("A choice outlives its categories but not its part")
  func aChoiceFollowsItsPart() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let models = ModelRepository(writer: stack.writer)
    let coffee = try category("Coffee", in: references)
    let entry = try TestSupport.makeEntry()
    try transactions.save(entry)
    try models.record(
      CategoryFeedback(
        text: "coffee", predictedCategoryId: coffee, chosenCategoryId: coffee,
        partId: entry.parts[0].id, confidenceBp: 9_000, at: Date()))

    try stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM categories WHERE id = ?", arguments: [coffee.uuidString])
    }
    let kept = try #require(try models.feedback().first)
    #expect(kept.predictedCategoryId == nil && kept.chosenCategoryId == nil)

    try stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM transactions WHERE id = ?", arguments: [entry.id.uuidString])
    }
    #expect(try models.feedback().isEmpty)
  }

  @Test("The snapshot of the calculations carries the choices")
  func theSnapshotCarriesTheChoices() async throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let models = ModelRepository(writer: stack.writer)
    let coffee = try category("Coffee", in: references)
    let entry = try TestSupport.makeEntry()
    try transactions.save(entry)
    let choice = CategoryFeedback(
      text: "coffee", predictedCategoryId: nil, chosenCategoryId: coffee,
      partId: entry.parts[0].id, confidenceBp: nil,
      at: Date(timeIntervalSince1970: 1_789_000_000))
    try models.record(choice)

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)

    #expect(dataset.feedback == [choice])
  }
}
