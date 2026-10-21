import Foundation

/// A bank (`banks`): the top of «bank → account → card». It owns nothing that moves: the money,
/// the balances, the operations and the counts stay on its accounts, as the cards stay on theirs.
/// A bank is what the owner names first, and what a list of choices shows when the bank has one
/// account and one card (`AccountLabels`).
///
/// A bank's name is its own, among the live banks; an account keeps the name it has, which stays
/// unique among accounts, so nothing the entry line reads changes.
public struct Bank: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// The place in the lists, ahead of the name; 0 everywhere means alphabetical.
  public var sort: Int
  public var archived: Bool

  public init(id: UUID = UUID(), name: String, sort: Int = 0, archived: Bool = false) {
    self.id = id
    self.name = name
    self.sort = sort
    self.archived = archived
  }
}
