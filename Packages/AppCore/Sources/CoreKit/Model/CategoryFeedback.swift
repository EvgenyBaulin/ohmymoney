import Foundation

/// The owner's choice of a category for a part the model had an answer for, as
/// `category_feedback` keeps it.
///
/// A choice that differs from what the model offered first is a correction. The part itself
/// carries the chosen category and is what the model learns from; this row keeps what the
/// part does not: what the model offered and how sure it was when it offered it.
public struct CategoryFeedback: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  /// The words the model was asked about — the same text it is taught with.
  public var text: String
  /// What the model offered first. `nil` once that category has been deleted.
  public var predictedCategoryId: UUID?
  /// What the owner filed the part under. `nil` once that category has been deleted.
  public var chosenCategoryId: UUID?
  /// The part the choice was made for: its operation holds everything else the model was
  /// asked, so nothing of it is copied here.
  public var partId: UUID?
  /// How sure the model was of what it offered first, in basis points.
  public var confidenceBp: Int?
  public var at: Date

  public init(
    id: UUID = UUID(), text: String, predictedCategoryId: UUID?, chosenCategoryId: UUID?,
    partId: UUID?, confidenceBp: Int?, at: Date
  ) {
    self.id = id
    self.text = text
    self.predictedCategoryId = predictedCategoryId
    self.chosenCategoryId = chosenCategoryId
    self.partId = partId
    self.confidenceBp = confidenceBp
    self.at = at
  }

  /// The owner filed the part somewhere else than the model offered first.
  public var overrulesTheModel: Bool { chosenCategoryId != predictedCategoryId }
}
