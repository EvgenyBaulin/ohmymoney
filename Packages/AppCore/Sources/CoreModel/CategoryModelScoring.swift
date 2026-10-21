import CoreKit
import Foundation

extension CategoryModel {
  /// Everything taken together: a multinomial naive Bayes over the features of the operation.
  ///
  /// This is the one place in the model where a fraction appears. Money never becomes one
  /// and nothing here is money: these are log-probabilities and a share, and they
  /// stop at the edge of this file — what leaves is a category and basis points. `make
  /// check-core-purity` holds that line: nothing `public` in this target may carry a
  /// `Double`.
  func weighed(_ query: CategoryQuery, among classes: [UUID]) -> [CategorySuggestion] {
    let keys = query.featureKeys
    let vocabulary = max(featureWeight.count, 1)
    let alpha = Double(options.featureSmoothingMilli)  // stats-only
    let pi = Double(options.priorSmoothingMilli)  // stats-only
    let totalWeight = Double(classWeight.values.reduce(0, +))  // stats-only
    let classCount = Double(classes.count)  // stats-only

    // The order the classes are walked in is fixed, so a tie is broken the same way twice.
    var scored: [(id: UUID, score: Double)] = []  // stats-only
    for id in classes.sorted(by: { $0.uuidString < $1.uuidString }) {
      let prior = (Double(classWeight[id] ?? 0) + pi) / (totalWeight + pi * classCount)  // stats-only
      var score = Foundation.log(prior)  // stats-only
      let seen = Double(featureTotal[id] ?? 0)  // stats-only
      let denominator = seen + alpha * Double(vocabulary)  // stats-only
      for key in keys {
        let weight = Double(featureWeight[key]?[id] ?? 0)  // stats-only
        score += Foundation.log((weight + alpha) / denominator)  // stats-only
      }
      scored.append((id, score))
    }
    guard let best = scored.map(\.score).max() else { return [] }

    // A softmax over what is close enough to matter. Anything thirty nats behind contributes
    // less than a thousandth of a basis point and is left out of the sum rather than
    // underflowing it.
    var mass = 0.0  // stats-only
    var weights: [(id: UUID, weight: Double)] = []  // stats-only
    for entry in scored where best - entry.score < 30 {
      let weight = Foundation.exp(entry.score - best)  // stats-only
      weights.append((entry.id, weight))
      mass += weight
    }
    guard mass > 0 else { return [] }

    return
      weights
      .map { entry in
        CategorySuggestion(
          categoryId: entry.id, confidenceBp: Int((entry.weight / mass * 10_000).rounded()),
          reason: .weighed)
      }
      .sorted { left, right in
        left.confidenceBp != right.confidenceBp
          ? left.confidenceBp > right.confidenceBp
          : (documents(of: left.categoryId) != documents(of: right.categoryId)
            ? documents(of: left.categoryId) > documents(of: right.categoryId)
            : left.categoryId.uuidString < right.categoryId.uuidString)
      }
  }

  func documents(of category: UUID) -> Int { classDocuments[category] ?? 0 }

  /// What the model is made of, for «Качество модели» and for the row in `ml_models`. Counts
  /// only: nothing here says what anything was about.
  public var summary: Summary {
    Summary(
      examples: documents, classes: classDocuments.count,
      classesReady: classDocuments.values.filter { $0 >= options.minimumPerClass }.count,
      features: featureWeight.count, exactKeys: exact.count, anchorDay: anchorDay)
  }

  public struct Summary: Hashable, Sendable, Codable {
    public var examples: Int
    public var classes: Int
    public var classesReady: Int
    public var features: Int
    public var exactKeys: Int
    public var anchorDay: DateOnly
  }
}
