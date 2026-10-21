import CoreKit
import Foundation
import Testing

@testable import CoreModel

/// What the model may say, when it may say it, and what a correction does to it.
@Suite("What the model may say, when it may say it, and what a correction does to it")
struct CategoryModelTests {
  private let anchor = DateOnly(year: 2026, month: 9, day: 20)
  private let groceries = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private let transport = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
  private let books = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

  private func query(_ text: String, daysAgo: Int = 0, amount: Int64 = 500) -> CategoryQuery {
    CategoryQuery(
      day: CalendarContext.utc.adding(days: -daysAgo, to: anchor), weekday: 1, kind: .expense,
      text: text, amountWhole: amount)
  }

  private func example(_ text: String, _ category: UUID, daysAgo: Int = 0) -> CategoryExample {
    CategoryExample(
      query: query(text, daysAgo: daysAgo), partId: UUID(), categoryId: category)
  }

  private func history(count: Int) -> [CategoryExample] {
    (0..<count).map { index in
      index % 2 == 0
        ? example("продукты в магазине \(index % 5)", groceries, daysAgo: index % 20)
        : example("такси домой \(index % 5)", transport, daysAgo: index % 20)
    }
  }

  // MARK: The threshold

  @Test func theModelSaysNothingBelowFiftyExamples() {
    let model = CategoryModel.train(on: history(count: 49), anchor: anchor)

    #expect(model.readiness == .tooFewExamples(have: 49, needed: 50))
    let prediction = model.predict(query("продукты в магазине 0"), among: [groceries, transport])
    #expect(prediction.suggestions.isEmpty, "below the threshold nothing is offered")
    #expect(!prediction.appliesTop)
  }

  @Test func atFiftyTheModelStartsToAnswer() {
    let model = CategoryModel.train(on: history(count: 50), anchor: anchor)

    #expect(model.readiness.isOn)
    let prediction = model.predict(query("продукты в магазине 0"), among: [groceries, transport])
    #expect(prediction.suggestions.first?.categoryId == groceries)
  }

  /// A category needs five examples. One with four shapes the counts but is never offered:
  /// four sightings are not a habit.
  @Test func aCategoryUnderFiveExamplesIsNeverOffered() {
    var examples = history(count: 60)
    examples += (0..<4).map { _ in example("букинист на канале", books) }
    let model = CategoryModel.train(on: examples, anchor: anchor)

    let prediction = model.predict(
      query("букинист на канале"), among: [groceries, transport, books])
    #expect(
      !prediction.suggestions.contains { $0.categoryId == books },
      "a category with four examples was offered")

    // A fifth makes it offerable, and then it wins its own words outright.
    var richer = examples
    richer.append(example("букинист на канале", books))
    let after = CategoryModel.train(on: richer, anchor: anchor)
    #expect(
      after.predict(query("букинист на канале"), among: [groceries, transport, books])
        .suggestions.first?.categoryId == books)
  }

  @Test func withNoCategoryReadyTheModelStaysQuiet() {
    let examples = (0..<60).map { index in
      example("операция \(index)", UUID())
    }
    let model = CategoryModel.train(on: examples, anchor: anchor)

    #expect(model.readiness == .noClassReady(needed: 5))
  }

  // MARK: Corrections

  /// The promise that makes learning from a correction honest: taking one example back and
  /// putting another in leaves exactly the model that a full retraining would have built.
  /// Not nearly — exactly, to the last count.
  @Test func aCorrectionLeavesTheSameModelAsAFullRetraining() {
    let base = history(count: 60)
    let wrong = example("книга по архитектуре", transport)
    let right = CategoryExample(query: wrong.query, partId: wrong.partId, categoryId: books)

    var corrected = CategoryModel.train(on: base + [wrong], anchor: anchor)
    corrected.unlearn(wrong)
    corrected.learn(right)

    let retrained = CategoryModel.train(on: base + [right], anchor: anchor)
    #expect(corrected == retrained)
  }

  /// The same promise when the example taken back was the latest sighting of its text: an
  /// older one of the same words stays, and the model — and its file, byte for byte — is the
  /// one a retraining on what is left builds.
  @Test func takingBackTheLatestSightingLeavesTheSameModelAsAFullRetraining() throws {
    let base = history(count: 60)
    let older = example("книга по архитектуре", books, daysAgo: 10)
    let newer = example("книга по архитектуре", transport, daysAgo: 5)

    var corrected = CategoryModel.train(on: base + [older, newer], anchor: anchor)
    corrected.unlearn(newer)

    let retrained = CategoryModel.train(on: base + [older], anchor: anchor)
    #expect(corrected == retrained)
    let moment = Date(timeIntervalSince1970: 1_790_000_000)
    #expect(
      try CategoryModelFile.data(of: corrected, trainedAt: moment)
        == CategoryModelFile.data(of: retrained, trainedAt: moment))
  }

  /// And a correction is felt at once, without waiting for a retraining.
  @Test func aCorrectionChangesTheNextAnswer() {
    var model = CategoryModel.train(on: history(count: 60), anchor: anchor)
    let examples = (0..<5).map { _ in example("букинист на канале", transport) }
    for example in examples { model.learn(example) }
    #expect(
      model.predict(query("букинист на канале"), among: [groceries, transport, books])
        .suggestions.first?.categoryId == transport)

    for example in examples {
      model.unlearn(example)
      model.learn(CategoryExample(query: example.query, partId: example.partId, categoryId: books))
    }

    #expect(
      model.predict(query("букинист на канале"), among: [groceries, transport, books])
        .suggestions.first?.categoryId == books)
  }

  /// Unlearning everything leaves nothing behind — no empty classes, no stray keys.
  @Test func unlearningEverythingEmptiesTheModel() {
    let examples = history(count: 20)
    var model = CategoryModel.train(on: examples, anchor: anchor)
    for example in examples { model.unlearn(example) }

    #expect(model == CategoryModel(anchorDay: anchor))
  }

  // MARK: What it answers

  /// A category the model is allowed to offer at all: five examples of its own, as the
  /// the rule is.
  private func booksWorthOffering() -> [CategoryExample] {
    (0..<5).map { example("книга номер \($0)", books) }
  }

  /// The same words, filed the same way twice, are worth more than everything else together.
  @Test func theSameWordsTwiceBeatTheRest() {
    var examples = history(count: 60) + booksWorthOffering()
    examples += [example("кофейня на углу", books), example("кофейня на углу", books)]
    let model = CategoryModel.train(on: examples, anchor: anchor)

    let prediction = model.predict(query("кофейня на углу"), among: [groceries, transport, books])
    #expect(prediction.suggestions.first?.categoryId == books)
    #expect(prediction.suggestions.first?.reason == .exactText)
  }

  /// Two sightings are two, whenever they were. The pipeline trains with today as the anchor,
  /// so every sighting lies in the past and weighs less than a whole one: counted by weight,
  /// yesterday's and three days ago's made 1.956 «observations», one, and the exact answer
  /// stayed silent until a third or a fourth.
  @Test func theSameWordsTwiceBeatTheRestEvenWhenTheyWereNotToday() {
    for (first, second) in [(1, 3), (30, 60), (170, 190)] {
      var examples = history(count: 60) + booksWorthOffering()
      examples += [
        example("кофейня на углу", books, daysAgo: first),
        example("кофейня на углу", books, daysAgo: second),
      ]
      let model = CategoryModel.train(on: examples, anchor: anchor)

      let prediction = model.predict(
        query("кофейня на углу"), among: [groceries, transport, books])
      #expect(prediction.suggestions.first?.categoryId == books, "\(first), \(second)")
      #expect(prediction.suggestions.first?.reason == .exactText, "\(first), \(second)")
    }
  }

  /// The first sighting is a coincidence and each one after it is evidence, so the exact
  /// answer is sure by (sightings − 1) / sightings of the weight filed there:
  /// two give 0.50 — offered first, not filled in — and three 0.66, over the
  /// threshold, whenever they were. The words here are the groceries' own, so the weighing
  /// alone would never say books.
  @Test func twoSightingsAreOfferedAndThreeAreFilledIn() {
    let text = "продукты в магазине"
    func prediction(_ days: [Int], elsewhere: Int = 0) -> CategoryPrediction {
      var examples = history(count: 60) + booksWorthOffering()
      examples += days.map { example(text, books, daysAgo: $0) }
      examples += (0..<elsewhere).map { _ in example(text, transport) }
      return CategoryModel.train(on: examples, anchor: anchor)
        .predict(query(text), among: [groceries, transport, books])
    }

    for days in [[0, 0], [2, 9], [40, 200]] {
      let two = prediction(days)
      #expect(two.suggestions.first?.categoryId == books, "\(days)")
      #expect(two.suggestions.first?.reason == .exactText, "\(days)")
      #expect(two.suggestions.first?.confidenceBp == 5_000, "\(days)")
      #expect(!two.appliesTop, "two sightings are offered, not filled in: \(days)")
    }
    let three = prediction([0, 3, 30])
    #expect(three.suggestions.first?.categoryId == books)
    #expect(three.suggestions.first?.confidenceBp == 6_666)
    #expect(three.appliesTop)

    // Five for books and one for transport, all today: 5/6 of the weight, 5/6 of the evidence.
    let mixed = prediction([0, 0, 0, 0, 0], elsewhere: 1)
    #expect(mixed.suggestions.first?.categoryId == books)
    #expect(mixed.suggestions.first?.confidenceBp == 8_333 * 5 / 6)
  }

  /// The exact answer puts a category first; it never makes the model less sure of that
  /// category than the weighing already was. Two sightings of words only books ever had
  /// weigh near certainty, and saying 0.50 instead would stop filling in what one sighting
  /// filled in.
  @Test func theExactAnswerNeverLowersWhatTheWeighingSaid() {
    var examples = history(count: 60) + booksWorthOffering()
    examples += [
      example("кофейня на углу", books, daysAgo: 2), example("кофейня на углу", books, daysAgo: 9),
    ]
    var weighingOnly = CategoryModelOptions.standard
    weighingOnly.exactMinimumObservations = 1_000
    let weighed = CategoryModel.train(on: examples, anchor: anchor, options: weighingOnly)
      .predict(query("кофейня на углу"), among: [groceries, transport, books])
    let both = CategoryModel.train(on: examples, anchor: anchor)
      .predict(query("кофейня на углу"), among: [groceries, transport, books])

    #expect(weighed.suggestions.first?.categoryId == books)
    #expect((weighed.suggestions.first?.confidenceBp ?? 0) > 5_000)
    #expect(both.suggestions.first?.reason == .exactText)
    #expect(both.suggestions.first?.confidenceBp == weighed.suggestions.first?.confidenceBp)
    #expect(both.appliesTop == weighed.appliesTop)
  }

  /// Words the model has never seen fill nothing in, however lopsided the history is: the
  /// prior, the weekday and the amount alone would put «абв 250» and «кофе 300» into the
  /// biggest category without a question.
  @Test func wordsTheModelNeverSawFillNothingIn() {
    var examples = (0..<90).map { index in
      example("продукты в магазине \(index % 5)", groceries, daysAgo: index % 20)
    }
    examples += (0..<10).map { index in example("такси домой", transport, daysAgo: index) }
    let model = CategoryModel.train(on: examples, anchor: anchor)

    let unknown = model.predict(query("абв"), among: [groceries, transport])
    #expect(!unknown.appliesTop, "an unknown word is not evidence")
    let empty = model.predict(query(""), among: [groceries, transport])
    #expect(!empty.appliesTop, "no words, no place — nothing to go on")
    let known = model.predict(query("продукты"), among: [groceries, transport])
    #expect(known.appliesTop && known.suggestions.first?.categoryId == groceries)
  }

  /// One sighting is a coincidence: the exact dictionary stays silent and the weighing answers.
  @Test func oneSightingIsNotEnoughToFillAnythingIn() {
    var examples = history(count: 60) + booksWorthOffering()
    examples.append(example("кофейня на углу", books))
    let model = CategoryModel.train(on: examples, anchor: anchor)

    let prediction = model.predict(query("кофейня на углу"), among: [groceries, transport, books])
    #expect(prediction.suggestions.first?.reason != .exactText)
  }

  @Test func noMoreThanThreeSuggestionsEver() {
    var examples = history(count: 60) + booksWorthOffering()
    for _ in 0..<6 { examples.append(example("разное", books)) }
    let model = CategoryModel.train(on: examples, anchor: anchor)

    #expect(
      model.predict(query("что-то ещё"), among: [groceries, transport, books]).suggestions.count
        <= 3)
  }

  /// The order the examples arrive in changes nothing: counts add up the same way.
  @Test func theOrderOfLearningDoesNotMatter() {
    let examples = history(count: 60)
    let forwards = CategoryModel.train(on: examples, anchor: anchor)
    let backwards = CategoryModel.train(on: examples.reversed(), anchor: anchor)

    #expect(forwards == backwards)
  }

  /// A day nearer to the anchor counts for more, and the arithmetic is integer, so the same
  /// example always weighs the same thing.
  @Test func anOlderExampleWeighsLess() {
    #expect(Recency.weight(daysFromAnchor: 0, halfLife: 180) == 1000)
    #expect(Recency.weight(daysFromAnchor: -180, halfLife: 180) == 500)
    #expect(Recency.weight(daysFromAnchor: -360, halfLife: 180) == 250)
    #expect(
      Recency.weight(daysFromAnchor: -10, halfLife: 180)
        > Recency.weight(daysFromAnchor: -100, halfLife: 180))
  }

  @Test func daysAreCountedOnAPlainGregorianCalendar() {
    #expect(
      Recency.days(
        from: DateOnly(year: 2026, month: 2, day: 28), to: DateOnly(year: 2026, month: 3, day: 1))
        == 1, "2026 is not a leap year")
    #expect(
      Recency.days(
        from: DateOnly(year: 2024, month: 2, day: 28), to: DateOnly(year: 2024, month: 3, day: 1))
        == 2, "2024 is")
    #expect(
      Recency.days(
        from: DateOnly(year: 2026, month: 1, day: 1), to: DateOnly(year: 2027, month: 1, day: 1))
        == 365)
  }
}
