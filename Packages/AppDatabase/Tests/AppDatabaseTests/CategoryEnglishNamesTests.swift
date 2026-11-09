import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// A stand-in for the system's model and translator: a fixed dictionary, `nil` for a word it
/// does not know, and a switch for a device that has nothing to translate with.
final class StubTranslator: CategoryNameTranslating, @unchecked Sendable {
  private let lock = NSLock()
  private var dictionary: [String: String]
  private var available: Bool
  private var asked: [String] = []
  /// Run before an answer: a test renames a category «while the translator thinks».
  var beforeAnswer: (@Sendable (String) -> Void)?

  init(_ dictionary: [String: String] = [:], available: Bool = true) {
    self.dictionary = dictionary
    self.available = available
  }

  var questions: [String] {
    lock.lock()
    defer { lock.unlock() }
    return asked
  }

  func set(available: Bool) {
    lock.lock()
    self.available = available
    lock.unlock()
  }

  func isAvailable() async -> Bool {
    lock.withLock { available }
  }

  func english(for name: String) async -> String? {
    beforeAnswer?(name)
    return lock.withLock {
      asked.append(name)
      return dictionary[name]
    }
  }
}

/// The English names of the categories are made in the background for every category without
/// one, again after a rename, never over the owner's name, and nothing breaks when the device
/// cannot translate.
@Suite("English names of the categories")
struct CategoryEnglishNamesTests {
  private func stack(_ names: [String]) throws -> (DatabaseStack, [CoreKit.Category]) {
    let stack = try TestSupport.makeStack()
    let categories = names.enumerated().map {
      CoreKit.Category(kind: .expense, name: $0.element, sort: $0.offset)
    }
    try stack.writer.write { db in for category in categories { try category.insert(db) } }
    return (stack, categories)
  }

  private func read(_ stack: DatabaseStack) throws -> [String: CoreKit.Category] {
    let all = try ReferenceRepository(writer: stack.writer).categories(includeArchived: true)
    return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
  }

  @Test func everyCategoryGetsItsEnglishNameAndTheOwnersNameStays() async throws {
    let (stack, _) = try stack(["Продукты", "Кафе", "Такси"])
    let translator = StubTranslator([
      "Продукты": "Groceries", "Кафе": "\"Cafes\".", "Такси": "Taxi",
    ])
    let pass = await CategoryEnglishNames(writer: stack.writer, translator: translator).run()
    #expect(pass == CategoryEnglishNames.Pass(due: 3, made: 3, left: 0))
    let read = try read(stack)
    #expect(read["Продукты"]?.englishName == "Groceries")
    #expect(read["Кафе"]?.englishName == "Cafes", "only the name is kept of the answer")
    #expect(read["Такси"]?.englishName == "Taxi")
    #expect(Set(read.keys) == ["Продукты", "Кафе", "Такси"], "the owner's names are not touched")
    // A second pass has nothing to do and asks nothing.
    let again = await CategoryEnglishNames(writer: stack.writer, translator: translator).run()
    #expect(again == CategoryEnglishNames.Pass())
    #expect(translator.questions.count == 3)
  }

  @Test func aNameWithATypoIsTranslatedLikeAnyOther() async throws {
    let (stack, _) = try stack(["Продуты"])
    let translator = StubTranslator(["Продуты": "Groceries"])
    _ = await CategoryEnglishNames(writer: stack.writer, translator: translator).run()
    #expect(try read(stack)["Продуты"]?.englishName == "Groceries")
  }

  @Test func aRenameMakesTheEnglishNameAgain() async throws {
    let (stack, categories) = try stack(["Кафе"])
    let translator = StubTranslator(["Кафе": "Cafes", "Кафе и бары": "Cafes and bars"])
    let names = CategoryEnglishNames(writer: stack.writer, translator: translator)
    _ = await names.run()
    var renamed = try #require(try read(stack)["Кафе"])
    renamed.name = "Кафе и бары"
    try ReferenceRepository(writer: stack.writer).save(renamed)
    #expect(try names.due().map(\.id) == [categories[0].id.uuidString])
    #expect(try read(stack)["Кафе и бары"]?.englishName == nil, "the old one is not used")
    _ = await names.run()
    #expect(try read(stack)["Кафе и бары"]?.englishName == "Cafes and bars")
  }

  @Test func aRenameWhileTheTranslatorThinksIsNotOverwritten() async throws {
    let (stack, categories) = try stack(["Кафе"])
    let translator = StubTranslator(["Кафе": "Cafes"])
    let writer = stack.writer
    let id = categories[0].id.uuidString
    translator.beforeAnswer = { _ in
      try? writer.write { db in
        try db.execute(sql: "UPDATE categories SET name = 'Бары' WHERE id = ?", arguments: [id])
      }
    }
    let pass = await CategoryEnglishNames(writer: stack.writer, translator: translator).run()
    #expect(pass.made == 0 && pass.left == 1)
    let read = try read(stack)
    #expect(read["Бары"]?.translation == nil, "an English name of the old name is not written")
  }

  @Test func withoutAModelOrATranslatorNothingIsAskedAndNothingBreaks() async throws {
    let (stack, _) = try stack(["Продукты", "Кафе"])
    let translator = StubTranslator(["Продукты": "Groceries"], available: false)
    let names = CategoryEnglishNames(writer: stack.writer, translator: translator)
    let pass = await names.run()
    #expect(pass == CategoryEnglishNames.Pass(due: 2, made: 0, left: 2, unavailable: true))
    #expect(translator.questions.isEmpty)
    #expect(try read(stack).values.allSatisfy { $0.translation == nil })
    // Later the language is there: the same pass makes what it can, the rest waits.
    translator.set(available: true)
    let later = await names.run()
    #expect(later == CategoryEnglishNames.Pass(due: 2, made: 1, left: 1))
    #expect(try names.due().count == 1)
  }

  @Test func theWritesStayOutOfTheJournalAndTheRecordingIsPutBack() async throws {
    let device = try TestDevice("mac")
    try device.sql(
      "INSERT INTO categories (id, kind, name, sort, archived) VALUES ('c1', 'expense', 'Кафе', 0, 0)"
    )
    try device.sql("DELETE FROM sync_outbox")
    let historyBefore = try device.count("sync_history")
    let translator = StubTranslator(["Кафе": "Cafes"])
    let names = CategoryEnglishNames(writer: device.stack.writer, translator: translator)
    _ = await names.run()
    #expect(try device.outboxCount() == 0, "a background write is no change for the others")
    #expect(try device.count("sync_history") == historyBefore, "nor a line of the history")
    #expect(device.exchange.isRecording, "the journal is on again")
    try names.write("Cafés", of: "c1", madeOf: "Кафе")
    #expect(try device.outboxCount() == 0)
    #expect(device.exchange.isRecording)
    // The owner's own edit is recorded as ever.
    try device.sql("UPDATE categories SET essential = 1 WHERE id = 'c1'")
    #expect(try device.outboxCount() == 1)
  }

  @Test func onADeviceThatRecordsNothingTheSwitchStaysOff() async throws {
    let device = try TestDevice("mac", recording: false)
    try device.sql(
      "INSERT INTO categories (id, kind, name, sort, archived) VALUES ('c1', 'expense', 'Кафе', 0, 0)"
    )
    _ = await CategoryEnglishNames(
      writer: device.stack.writer, translator: StubTranslator(["Кафе": "Cafes"])
    ).run()
    #expect(!device.exchange.isRecording)
    #expect(try device.outboxCount() == 0)
  }

  @Test func theEnglishNameIsNeverWhatTheBooksSearch() async throws {
    let (stack, _) = try stack(["Продукты"])
    _ = await CategoryEnglishNames(
      writer: stack.writer, translator: StubTranslator(["Продукты": "Groceries"])
    ).run()
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    let category = try #require(dataset.categories.first)
    #expect(category.name == "Продукты")
    #expect(category.englishName == "Groceries")
    // The entry line reads the owner's words only.
    let vocabulary = try ReferenceRepository(writer: stack.writer)
      .vocabulary(enabledCurrencies: [.rub])
    #expect(!String(describing: vocabulary).contains("Groceries"))
  }
}
