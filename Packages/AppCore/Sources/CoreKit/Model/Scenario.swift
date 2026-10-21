import Foundation

/// A saved «what if» scenario (`scenarios`). The database keeps the changes it makes
/// (`specJSON`) and the numbers it was last worked out against (`baselineJSON`) as opaque
/// text; the planning reads and writes them.
public struct Scenario: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// The place the owner dragged it to; 0 everywhere means by name.
  public var sort: Int
  public var specJSON: String
  /// Empty until the scenario is first worked out.
  public var baselineJSON: String
  public var createdAt: Date
  public var updatedAt: Date
  /// Set when the scenario is deleted; the row stays, so ⌘Z brings it back whole.
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(), name: String, sort: Int = 0, specJSON: String, baselineJSON: String = "",
    createdAt: Date = Date(), updatedAt: Date? = nil, deletedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.sort = sort
    self.specJSON = specJSON
    self.baselineJSON = baselineJSON
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.deletedAt = deletedAt
  }

  public var isDeleted: Bool { deletedAt != nil }
}
