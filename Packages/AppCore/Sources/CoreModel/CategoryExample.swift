import CoreKit
import Foundation

/// One operation as the model sees it — asked about, or learned from.
public struct CategoryQuery: Hashable, Sendable {
  /// The day it happened, which decides how much an example still counts for.
  public var day: DateOnly
  /// 1 for Monday … 7 for Sunday.
  public var weekday: Int
  /// Expense or income: only categories of the same kind can ever be the answer.
  public var kind: CategoryKind
  /// The note, the place's name if there is none — whatever names the operation.
  public var text: String
  public var placeId: UUID?
  public var paymentMethodId: UUID?
  public var forWhom: String
  public var forPersonId: UUID?
  /// Whole units. The model only ever sees which bucket this falls in.
  public var amountWhole: Int64

  public init(
    day: DateOnly, weekday: Int, kind: CategoryKind, text: String, placeId: UUID? = nil,
    paymentMethodId: UUID? = nil, forWhom: String = "me", forPersonId: UUID? = nil,
    amountWhole: Int64
  ) {
    self.day = day
    self.weekday = weekday
    self.kind = kind
    self.text = text
    self.placeId = placeId
    self.paymentMethodId = paymentMethodId
    self.forWhom = forWhom
    self.forPersonId = forPersonId
    self.amountWhole = amountWhole
  }

  var featureKeys: [String] {
    CategoryFeatures.keys(
      text: text, place: placeId, paymentMethod: paymentMethodId, forWhom: forWhom,
      person: forPersonId, weekday: weekday, amountWhole: amountWhole)
  }

  /// What an exact repetition is keyed by: the same words, or — when there are none — the
  /// same place. Most everyday operations carry no note at all, and «the same shop again» is
  /// the strongest signal there is.
  var exactKey: String? {
    let normalized = CategoryFeatures.normalize(text)
    if !normalized.isEmpty { return "t:\(normalized)" }
    if let placeId { return "p:\(placeId.uuidString)" }
    return nil
  }
}

/// A query whose answer is known: what the model learns from.
public struct CategoryExample: Hashable, Sendable {
  public var query: CategoryQuery
  /// The part this came from, so a correction can take the old one back.
  public var partId: UUID
  /// The most specific category the owner filed it under.
  public var categoryId: UUID

  public init(query: CategoryQuery, partId: UUID, categoryId: UUID) {
    self.query = query
    self.partId = partId
    self.categoryId = categoryId
  }
}

/// What the model offers, and how sure it is.
public struct CategorySuggestion: Hashable, Sendable {
  public enum Reason: String, Hashable, Sendable, Codable {
    /// The very same words, filed the same way before.
    case exactText
    /// The same place, with nothing written.
    case exactPlace
    /// Everything else weighed together.
    case weighed
  }

  public var categoryId: UUID
  /// Basis points, 0…10000. Money is never a fraction here and neither is this.
  public var confidenceBp: Int
  public var reason: Reason

  public init(categoryId: UUID, confidenceBp: Int, reason: Reason) {
    self.categoryId = categoryId
    self.confidenceBp = confidenceBp
    self.reason = reason
  }
}

/// Whether the model may say anything at all.
public enum CategoryModelReadiness: Hashable, Sendable {
  case on(classes: Int)
  /// Fewer than `needed` labelled operations — the spec's fifty.
  case tooFewExamples(have: Int, needed: Int)
  /// Enough operations, but no category has the five of its own it needs.
  case noClassReady(needed: Int)

  public var isOn: Bool { if case .on = self { true } else { false } }
}

/// The answer to one question.
public struct CategoryPrediction: Hashable, Sendable {
  /// At most three, already past the floor below which nothing is worth showing.
  public var suggestions: [CategorySuggestion]
  /// The first one is sure enough to be filled in rather than merely offered.
  public var appliesTop: Bool
  public var readiness: CategoryModelReadiness

  public init(
    suggestions: [CategorySuggestion] = [], appliesTop: Bool = false,
    readiness: CategoryModelReadiness
  ) {
    self.suggestions = suggestions
    self.appliesTop = appliesTop
    self.readiness = readiness
  }
}
