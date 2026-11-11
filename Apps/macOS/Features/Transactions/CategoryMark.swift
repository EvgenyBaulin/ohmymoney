import AppCore
import SwiftUI

/// What the round mark in front of an operation draws when its category has a mark of its own:
/// the category's symbol on the tint of its tone. The name of the category is always written
/// next to the row (the description line, the category column or the second line of a card), so
/// the mark helps the eye and the colour never carries the meaning alone.
struct CategoryMark: Hashable, Sendable {
  /// A `CategoryIcon` name.
  let icon: String
  let tone: CategoryTone

  /// The mark of one category, or `nil` when it has no symbol to draw — a category without one,
  /// one with a symbol this build does not know, or one that is not in the tree — and the row
  /// keeps the mark of its kind. A symbol without a colour takes the accent.
  init?(of categoryId: UUID?, tree: CategoryTree) {
    let found = tree.appearance(of: categoryId)
    guard let icon = found.icon else { return nil }
    self.icon = icon
    self.tone = found.tone ?? .accent
  }

  /// The mark of a whole operation: the mark of its category when every part is filed under
  /// that one category, none for a split over several categories, a part without a category
  /// and a transfer — those keep the mark of their kind.
  static func of(_ categoryIds: [UUID?], tree: CategoryTree) -> CategoryMark? {
    guard let first = categoryIds.first, categoryIds.allSatisfy({ $0 == first }) else { return nil }
    return CategoryMark(of: first, tree: tree)
  }
}
