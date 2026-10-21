import AppCore
import XCTest

@testable import OhMyMoney

/// The category model learning from the owner's own choices: when it may speak at all (fifty
/// examples, five of a class), what it fills in and what it only offers, the exact dictionary of
/// texts and places, a correction that is exactly a retraining, recency, the order of examples
/// that never matters, what counts as the owner's choice, and the words it reads in both
/// languages with «ё», digits and punctuation folded.
final class InsightsScenarioModelTests: XCTestCase {
  private let food = UUID()
  private let transport = UUID()
  private let fun = UUID()
  private let today = DateOnly.d(9, 14)

  private func query(
    _ text: String, day: DateOnly? = nil, place: UUID? = nil, amount: Int64 = 250
  ) -> CategoryQuery {
    let day = day ?? today
    return CategoryQuery(
      day: day, weekday: day.weekday, kind: .expense, text: text, placeId: place,
      amountWhole: amount)
  }

  private func examples(
    _ text: String, _ category: UUID, count: Int, day: DateOnly? = nil, place: UUID? = nil
  ) -> [CategoryExample] {
    (0..<count).map { index in
      CategoryExample(
        query: query(text, day: (day ?? today).adding(days: -index), place: place),
        partId: UUID(), categoryId: category)
    }
  }

  /// Thirty coffees in «Food», twenty-five taxis in «Transport».
  private var everyday: [CategoryExample] {
    examples("coffee", food, count: 30) + examples("taxi home", transport, count: 25)
  }

  private func model(_ examples: [CategoryExample]) -> CategoryModel {
    CategoryModel.train(on: examples, anchor: today)
  }

  // MARK: - When it speaks

  /// Forty-nine examples are too few; the fiftieth turns it on.
  func testFiftyExamplesTurnTheModelOn() {
    let few = model(examples("coffee", food, count: 49))
    XCTAssertEqual(few.readiness, .tooFewExamples(have: 49, needed: 50))
    XCTAssertTrue(few.predict(query("coffee"), among: [food]).suggestions.isEmpty)
    XCTAssertEqual(model(examples("coffee", food, count: 50)).readiness, .on(classes: 1))
  }

  /// Fifty examples spread so thin that no class has five: nothing is offered.
  func testNoClassWithFiveExamplesOffersNothing() {
    let thin = (0..<13).flatMap { _ in examples("thing", UUID(), count: 4) }
    let model = model(thin)
    XCTAssertEqual(model.readiness, .noClassReady(needed: 5))
  }

  /// A habit is filled in: «coffee» goes to «Food» without a question.
  func testAHabitIsFilledIn() throws {
    let prediction = model(everyday).predict(query("coffee"), among: [food, transport])
    XCTAssertEqual(prediction.suggestions.first?.categoryId, food)
    XCTAssertTrue(prediction.appliesTop)
    XCTAssertLessThanOrEqual(prediction.suggestions.count, 3)
  }

  /// A word it never saw is not filled in, whatever the history leans to.
  func testAnUnknownWordIsNeverFilledIn() {
    let prediction = model(everyday).predict(query("абв"), among: [food, transport])
    XCTAssertFalse(prediction.appliesTop)
  }

  /// Only the categories asked about can be the answer.
  func testOnlyTheCandidatesAreAnswers() {
    let prediction = model(everyday).predict(query("coffee"), among: [transport, fun])
    XCTAssertFalse(prediction.suggestions.contains { $0.categoryId == food })
    XCTAssertFalse(prediction.suggestions.contains { $0.categoryId == fun })
  }

  /// A class with four examples shapes the counts but is never offered, not even for its own
  /// text.
  func testAClassOfFourIsNeverOffered() {
    let model = model(everyday + examples("cinema", fun, count: 4))
    let prediction = model.predict(query("cinema"), among: [food, transport, fun])
    XCTAssertFalse(prediction.suggestions.contains { $0.categoryId == fun })
  }

  /// Every suggestion clears the floor; never more than three.
  func testSuggestionsClearTheFloorAndAreAtMostThree() {
    var many = everyday
    for _ in 0..<5 { many += examples("misc", UUID(), count: 6) }
    let model = model(many)
    let prediction = model.predict(query("misc"), among: many.map(\.categoryId))
    XCTAssertLessThanOrEqual(prediction.suggestions.count, 3)
    XCTAssertTrue(prediction.suggestions.allSatisfy { $0.confidenceBp >= 1_500 })
  }

  // MARK: - The exact dictionary

  /// A place seen again and again, with no words, is filed where it always was.
  func testTheSamePlaceIsAnExactAnswer() throws {
    let shop = UUID()
    let model = model(everyday + examples("", fun, count: 6, place: shop))
    let top = try XCTUnwrap(
      model.predict(query("", place: shop), among: [food, transport, fun]).suggestions.first)
    XCTAssertEqual(top.categoryId, fun)
    XCTAssertEqual(top.reason, .exactPlace)
  }

  /// The same text filed half here, half there is no exact answer.
  func testADividedTextIsNoExactAnswer() {
    let model = model(
      everyday + examples("gift", fun, count: 5) + examples("gift", food, count: 5))
    let prediction = model.predict(query("gift"), among: [food, transport, fun])
    XCTAssertFalse(prediction.suggestions.contains { $0.reason == .exactText })
  }

  /// «Ёлка», «елка» and «ЁЛКА!» are one text; «order 12345» and «order 7» one order.
  func testFoldedSpellingsAreOneText() throws {
    let model = model(everyday + examples("Ёлка", fun, count: 6))
    let top = try XCTUnwrap(
      model.predict(query("ЕЛКА!"), among: [food, transport, fun]).suggestions.first)
    XCTAssertEqual(top.categoryId, fun)
    XCTAssertEqual(top.reason, .exactText)
    XCTAssertEqual(
      CategoryFeatures.normalize("order 12345"), CategoryFeatures.normalize("Order #7"))
  }

  // MARK: - Learning and unlearning

  /// Learning an example and taking it back leaves the model as it was.
  func testLearningAndUnlearningIsNothing() {
    let before = model(everyday)
    var after = before
    let extra = examples("cinema", fun, count: 1)[0]
    after.learn(extra)
    XCTAssertNotEqual(after, before)
    after.unlearn(extra)
    XCTAssertEqual(after, before)
  }

  /// A correction — the old category taken back, the owner's learned — is the very model a
  /// full retraining on the corrected examples gives.
  func testACorrectionIsARetraining() {
    var all = everyday
    var corrected = model(all)
    let wrong = all[3]
    var right = wrong
    right.categoryId = transport
    corrected.unlearn(wrong)
    corrected.learn(right)
    all[3] = right
    XCTAssertEqual(corrected, model(all))
  }

  /// The order of the examples never matters.
  func testTheOrderOfExamplesNeverMatters() {
    let all = everyday + examples("cinema", fun, count: 7)
    XCTAssertEqual(model(all), model(all.reversed()))
    XCTAssertEqual(model(all), model(all.shuffled()))
  }

  /// The same question twice is the same answer.
  func testTheSameQuestionIsTheSameAnswer() {
    let model = model(everyday + examples("cinema", fun, count: 7))
    let question = query("taxi to the cinema")
    XCTAssertEqual(
      model.predict(question, among: [food, transport, fun]),
      model.predict(question, among: [food, transport, fun]))
  }

  /// Recent choices outweigh old ones: «lunch» filed in «Food» two years ago, in «Fun» lately.
  func testRecentChoicesOutweighOldOnes() throws {
    let old = examples("lunch", food, count: 25, day: .d(9, 14, 2024))
    let recent = examples("lunch", fun, count: 25)
    let model = model(everyday + old + recent)
    let top = try XCTUnwrap(
      model.predict(query("lunch"), among: [food, transport, fun]).suggestions.first)
    XCTAssertEqual(top.categoryId, fun)
  }

  /// The model survives the file it is kept in.
  func testTheModelSurvivesItsFile() throws {
    let model = model(everyday)
    let data = try JSONEncoder().encode(model)
    XCTAssertEqual(try JSONDecoder().decode(CategoryModel.self, from: data), model)
  }

  // MARK: - What counts as the owner's choice

  private func row(
    source: CategorySource = .manual, role: SystemRole? = nil, external: String? = nil,
    deleted: Bool = false, category: UUID? = UUID()
  ) -> CategoryTraining.Row {
    CategoryTraining.Row(
      partId: UUID(), categoryId: category, systemRole: role, categorySource: source,
      externalId: external, isDeleted: deleted, query: query("coffee"))
  }

  /// The owner's choices teach; what the model or the app filled in, deleted operations, the
  /// app's own categories and lines, and parts without a category do not.
  func testOnlyTheOwnersChoicesTeach() {
    for source in [CategorySource.manual, .history, .template, .imported] {
      XCTAssertTrue(CategoryTraining.isLabelled(row(source: source)), "\(source)")
    }
    XCTAssertFalse(CategoryTraining.isLabelled(row(source: .model)))
    XCTAssertFalse(CategoryTraining.isLabelled(row(source: .system)))
    XCTAssertFalse(CategoryTraining.isLabelled(row(role: .goals)))
    XCTAssertFalse(CategoryTraining.isLabelled(row(external: "sched:x")))
    XCTAssertFalse(CategoryTraining.isLabelled(row(deleted: true)))
    XCTAssertFalse(CategoryTraining.isLabelled(row(category: nil)))
    XCTAssertEqual(
      CategoryTraining.examples(from: [row(), row(source: .model), row(deleted: true)]).count, 1)
  }

  /// The fingerprint changes only when what the model reads changes: not the order of the
  /// examples, not an amount within its bucket; the note and the bucket do.
  func testTheFingerprintFollowsWhatTheModelReads() {
    let part = UUID()
    func example(_ text: String, _ amount: Int64) -> CategoryExample {
      CategoryExample(query: query(text, amount: amount), partId: part, categoryId: food)
    }
    let others = examples("taxi", transport, count: 3)
    let base = CategoryTraining.fingerprint(of: [example("coffee", 250)] + others)
    XCTAssertEqual(
      CategoryTraining.fingerprint(of: others.reversed() + [example("coffee", 250)]), base)
    XCTAssertEqual(CategoryTraining.fingerprint(of: [example("coffee", 300)] + others), base)
    XCTAssertNotEqual(CategoryTraining.fingerprint(of: [example("coffee", 600)] + others), base)
    XCTAssertNotEqual(CategoryTraining.fingerprint(of: [example("tea", 250)] + others), base)
    XCTAssertTrue(base.hasPrefix("4:"))
  }

  // MARK: - Words

  /// Words: folded, each once; grams inside words with the edges marked.
  func testWordsAndGrams() {
    XCTAssertEqual(
      CategoryFeatures.words(in: "Кофе кофе КОФЕ с молоком"), ["кофе", "с", "молоком"])
    XCTAssertEqual(CategoryFeatures.grams(in: "ab"), ["_ab", "ab_"])
    XCTAssertEqual(CategoryFeatures.grams(in: "a"), ["_a_"])
    XCTAssertEqual(CategoryFeatures.normalize("Coffee☕️, 2x!"), "coffee #x")
    XCTAssertEqual(CategoryFeatures.normalize("  ...  "), "")
    XCTAssertEqual(CategoryFeatures.words(in: String(repeating: "w ", count: 1)), ["w"])
  }

  /// No more than forty words of a long note.
  func testALongNoteIsCutAtFortyWords() {
    let note = (1...60).map { "word\(String(repeating: "x", count: $0))" }.joined(separator: " ")
    XCTAssertEqual(CategoryFeatures.words(in: note).count, CategoryFeatures.wordLimit)
    XCTAssertLessThanOrEqual(CategoryFeatures.grams(in: note).count, CategoryFeatures.gramLimit)
  }

  /// The buckets of an amount at their edges.
  func testTheBucketsOfAnAmount() {
    XCTAssertEqual(CategoryFeatures.amountBucket(whole: 0), 0)
    XCTAssertEqual(CategoryFeatures.amountBucket(whole: 49), 0)
    XCTAssertEqual(CategoryFeatures.amountBucket(whole: 50), 1)
    XCTAssertEqual(CategoryFeatures.amountBucket(whole: 499), 3)
    XCTAssertEqual(CategoryFeatures.amountBucket(whole: 500), 4)
    XCTAssertEqual(CategoryFeatures.amountBucket(whole: 1_000_000), 13)
    XCTAssertEqual(CategoryFeatures.amountBucket(whole: -100), 0)
  }
}
