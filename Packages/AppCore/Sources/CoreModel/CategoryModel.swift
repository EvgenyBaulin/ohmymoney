import CoreKit
import Foundation

/// The category model: an exact dictionary over a multinomial naive Bayes, both of them
/// nothing but counts.
///
/// Counting is what makes it fit what this application needs. It learns from one correction
/// without being retrained; it gives the same answer twice; and it can say why — the features
/// that moved it are the words of the operation. A gradient would have given none of the
/// three.
///
/// Everything stored is an integer, so the file means exactly the same thing on macOS, on
/// Linux and later on Windows. Floating point appears only while a prediction is being
/// weighed and never leaves: what comes out is a category and a number of basis points.
public struct CategoryModel: Sendable, Equatable, Codable {
  /// 2: an exact entry keeps its count of sightings (24.09.2026).
  /// 3: an exact entry no longer keeps the day of its latest sighting (24.09.2026).
  public static let formatVersion = 3

  public private(set) var options: CategoryModelOptions
  /// The day the weights were worked out from. Reset by a full training.
  public private(set) var anchorDay: DateOnly
  public internal(set) var documents: Int
  var classDocuments: [UUID: Int]
  var classWeight: [UUID: Int64]
  var featureWeight: [String: [UUID: Int64]]
  var featureTotal: [UUID: Int64]
  var exact: [String: Exact]

  /// Nothing but counts, so taking an example back undoes it exactly. The day of the latest
  /// sighting was kept once: a maximum, which a correction cannot take back, and which
  /// nothing read.
  struct Exact: Hashable, Sendable, Codable {
    var byClass: [UUID: Int64]
    /// How many times this very text or place was filed, whenever it was: a count of
    /// sightings, not of weight. The pipeline trains with today as the anchor, so every
    /// sighting weighs less than a whole one, and two of them by weight would be one.
    var documents: Int

    var total: Int64 { byClass.values.reduce(0, +) }
  }

  public init(options: CategoryModelOptions = .standard, anchorDay: DateOnly) {
    self.options = options
    self.anchorDay = anchorDay
    self.documents = 0
    self.classDocuments = [:]
    self.classWeight = [:]
    self.featureWeight = [:]
    self.featureTotal = [:]
    self.exact = [:]
  }

  // MARK: Learning

  /// A model from nothing, which is what the pipeline does when the data has changed.
  public static func train(
    on examples: [CategoryExample], anchor: DateOnly, options: CategoryModelOptions = .standard
  ) -> CategoryModel {
    var model = CategoryModel(options: options, anchorDay: anchor)
    for example in examples { model.learn(example) }
    return model
  }

  /// One more example. A correction is `unlearn` of what was there and `learn` of what the
  /// owner chose — the same model as a full retraining, to the last count, which is what
  /// makes learning from a correction honest rather than approximate.
  public mutating func learn(_ example: CategoryExample) {
    apply(example, sign: 1)
  }

  public mutating func unlearn(_ example: CategoryExample) {
    apply(example, sign: -1)
  }

  private mutating func apply(_ example: CategoryExample, sign: Int64) {
    let weight =
      sign
      * Recency.weight(
        daysFromAnchor: Recency.days(from: anchorDay, to: example.query.day),
        halfLife: options.halfLifeDays)
    let category = example.categoryId

    documents += Int(sign)
    classDocuments[category, default: 0] += Int(sign)
    classWeight[category, default: 0] += weight
    if classDocuments[category] == 0 {
      classDocuments[category] = nil
      classWeight[category] = nil
    }

    for key in example.query.featureKeys {
      featureWeight[key, default: [:]][category, default: 0] += weight
      if featureWeight[key]?[category] == 0 { featureWeight[key]?[category] = nil }
      if featureWeight[key]?.isEmpty == true { featureWeight[key] = nil }
      featureTotal[category, default: 0] += weight
    }
    if featureTotal[category] == 0 { featureTotal[category] = nil }

    if let key = example.query.exactKey {
      var entry = exact[key] ?? Exact(byClass: [:], documents: 0)
      entry.byClass[category, default: 0] += weight
      if entry.byClass[category] == 0 { entry.byClass[category] = nil }
      entry.documents += Int(sign)
      exact[key] = entry.byClass.isEmpty || entry.documents <= 0 ? nil : entry
    }
  }

  // MARK: What it may say

  public var readiness: CategoryModelReadiness {
    guard documents >= options.minimumExamples else {
      return .tooFewExamples(have: documents, needed: options.minimumExamples)
    }
    let ready = classDocuments.values.filter { $0 >= options.minimumPerClass }.count
    guard ready > 0 else { return .noClassReady(needed: options.minimumPerClass) }
    return .on(classes: ready)
  }

  /// Classes with fewer than five examples of their own stay in the counts — they shape the
  /// denominators and the prior — but are never offered. Five is what is asked
  /// for, and one sighting is not a habit.
  private func offered(among candidates: [UUID]) -> [UUID] {
    candidates.filter { (classDocuments[$0] ?? 0) >= options.minimumPerClass }
  }

  /// Up to three categories, most likely first.
  ///
  /// The exact dictionary goes first when it has seen this very text — or this very place,
  /// for the everyday operations that carry no words at all — often enough and firmly
  /// enough. Everything else is weighed. The two are a cascade and not a blend, which is what
  /// keeps the answer explainable: a suggestion is either «you always file this here» or
  /// «everything taken together says here». The exact answer puts its category first but
  /// never makes the model less sure of it than the weighing was: two sightings are only
  /// 0.50 of their own, and words nobody else ever used may weigh far more.
  public func predict(_ query: CategoryQuery, among candidates: [UUID]) -> CategoryPrediction {
    let readiness = readiness
    guard readiness.isOn else { return CategoryPrediction(readiness: readiness) }
    let classes = offered(among: candidates)
    guard !classes.isEmpty else { return CategoryPrediction(readiness: readiness) }

    var ranked = weighed(query, among: classes)
    let exactAnswer = exactSuggestion(query, among: classes)
    if var exact = exactAnswer {
      if let same = ranked.first(where: { $0.categoryId == exact.categoryId }) {
        exact.confidenceBp = max(exact.confidenceBp, same.confidenceBp)
      }
      ranked.removeAll { $0.categoryId == exact.categoryId }
      ranked.insert(exact, at: 0)
    }

    let shown =
      ranked
      .filter { $0.confidenceBp >= options.suggestionFloorBp }
      .prefix(options.topK)
      .map { $0 }
    return CategoryPrediction(
      suggestions: shown,
      appliesTop: (shown.first?.confidenceBp ?? 0) >= options.confidenceThresholdBp
        && (exactAnswer != nil || hasSeenAnythingOf(query)),
      readiness: readiness)
  }

  /// Whether the operation carries a word or a place the model was taught. Without one the
  /// weighing rests on the prior, the weekday and the amount — what any operation has — and a
  /// lopsided history would fill its biggest category into «абв 250» without a question. It
  /// may still offer it; it does not fill it in.
  private func hasSeenAnythingOf(_ query: CategoryQuery) -> Bool {
    query.featureKeys.contains { key in
      (key.hasPrefix("w:") || (key.hasPrefix("p:") && key != "p:none"))
        && featureWeight[key] != nil
    }
  }

  private func exactSuggestion(_ query: CategoryQuery, among classes: [UUID]) -> CategorySuggestion?
  {
    guard let key = query.exactKey, let entry = exact[key] else { return nil }
    let total = entry.total
    let seen = entry.documents
    guard total > 0, seen >= options.exactMinimumObservations else { return nil }
    let best = entry.byClass
      .filter { classes.contains($0.key) }
      .max { left, right in
        left.value != right.value
          ? left.value < right.value : left.key.uuidString > right.key.uuidString
      }
    guard let best, best.value * 3 >= total * 2 else { return nil }
    // The share of the weight filed here, times (sightings − 1) / sightings: the first sighting
    // is a coincidence and only the ones after it are evidence, so two unanimous sightings are
    // 0.50 of their own — under the threshold of filling in — three 0.66, and it never reaches
    // 1.00.
    let unanimity = best.value * 10_000 / total
    let share = Int(unanimity) * (seen - 1) / seen
    return CategorySuggestion(
      categoryId: best.key, confidenceBp: min(share, 10_000),
      reason: key.hasPrefix("t:") ? .exactText : .exactPlace)
  }
}
