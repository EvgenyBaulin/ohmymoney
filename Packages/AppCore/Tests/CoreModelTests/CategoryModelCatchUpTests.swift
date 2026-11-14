import CoreKit
import Foundation
import Testing

@testable import CoreModel

/// «A model brought up to date by what changed is the model a training on everything gives»:
/// the counts add and take back exactly, so after any few writes the two are equal to the last
/// count.
@Suite("The model catching up with a few writes")
struct CategoryModelCatchUpTests {
  private let anchor = DateOnly(year: 2026, month: 9, day: 20)
  private let categories = (1...6).map {
    UUID(uuidString: "0000000\($0)-0000-4000-8000-000000000000")!
  }
  private let words = ["milk", "bread", "taxi", "metro", "book", "coffee", "gym", "cinema"]

  private func example(_ number: Int, category: Int? = nil, word: Int? = nil) -> CategoryExample {
    CategoryExample(
      query: CategoryQuery(
        day: CalendarContext.utc.adding(days: -(number % 400), to: anchor),
        weekday: 1 + number % 7, kind: .expense,
        text: "\(words[word ?? number % words.count]) \(number % 17)",
        placeId: number % 5 == 0
          ? UUID(uuidString: "00000000-0000-4000-8000-00000000000\(number % 5)") : nil,
        amountWhole: Int64(50 + number % 900)),
      partId: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", number))!,
      categoryId: categories[category ?? number % categories.count])
  }

  private func byPart(_ examples: [CategoryExample]) -> [UUID: CategoryExample] {
    Dictionary(uniqueKeysWithValues: examples.map { ($0.partId, $0) })
  }

  @Test func aCorrectionAnAdditionAndARemovalGiveTheModelOfAFullTraining() {
    let before = (0..<600).map { example($0) }
    var model = CategoryModel.train(on: before, anchor: anchor)

    var after = before
    after[10] = example(10, category: 3, word: 2)  // refiled and reworded
    after[250] = example(250, category: 0)  // refiled
    after.remove(at: 77)  // deleted
    after.append(example(1000))  // written
    after.append(example(1001, category: 4))

    let applied = model.catchUp(from: byPart(before), to: byPart(after), limit: 16)
    #expect(applied)
    #expect(model == CategoryModel.train(on: after, anchor: anchor))
  }

  @Test func successiveWritesDoNotDrift() {
    var examples = (0..<300).map { example($0) }
    var model = CategoryModel.train(on: examples, anchor: anchor)
    var next = 300
    for step in 0..<60 {
      var changed = examples
      switch step % 3 {
      case 0:
        changed.append(example(next))
        next += 1
      case 1:
        // Refiled and reworded: the same part, another category and other words.
        let index = step * 3 % changed.count
        changed[index].categoryId = categories[step % categories.count]
        changed[index].query.text = "\(words[step % words.count]) \(step)"
      default:
        changed.remove(at: step * 7 % changed.count)
      }
      let applied = model.catchUp(from: byPart(examples), to: byPart(changed), limit: 8)
      #expect(applied)
      examples = changed
    }
    #expect(model == CategoryModel.train(on: examples, anchor: anchor))
  }

  @Test func nothingChangedLeavesTheModelAlone() {
    let examples = (0..<100).map { example($0) }
    var model = CategoryModel.train(on: examples, anchor: anchor)
    let before = model
    let applied = model.catchUp(from: byPart(examples), to: byPart(examples), limit: 0)
    #expect(applied)
    #expect(model == before)
  }

  @Test func moreChangesThanTheLimitLeaveTheModelUntouched() {
    let before = (0..<100).map { example($0) }
    var model = CategoryModel.train(on: before, anchor: anchor)
    let untouched = model
    let after = before + (200..<230).map { example($0) }
    let applied = model.catchUp(from: byPart(before), to: byPart(after), limit: 10)
    #expect(!applied)
    #expect(model == untouched)
  }
}
