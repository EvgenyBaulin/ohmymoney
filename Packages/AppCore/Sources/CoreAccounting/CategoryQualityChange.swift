import CoreKit
import Foundation

/// The new quality of a category, carried over to the operations already filed under it.
///
/// Changing the quality of a category in Settings changes it for the operations to come at
/// once, and asks whether the past should follow. This answers what «yes» rewrites: the
/// question counts the operations from the pipeline's ledger, and the write applies the
/// rule again to each row as it is in the database at that moment, so a part rated by hand
/// since the question was asked stays as it is.
///
/// A part follows only when it took its quality from that category — directly, or through
/// a subcategory with no quality of its own (`QualityResolver.updatesForCategoryQualityChange`).
/// My own ratings, the ratings my history gave and goal contributions stay; so do deleted
/// operations and the kinds that are never rated — income and money given back.
public struct CategoryQualityChange: Hashable, Sendable {
  public var categoryId: UUID

  public init(categoryId: UUID) {
    self.categoryId = categoryId
  }

  /// What the category rates its parts as now (rule 3): its own quality, its parent's when
  /// it has none, neutral when neither has one. «—» on a subcategory hands its parts back to
  /// the parent's quality, and «—» on a category makes them neutral — the way a new
  /// operation is rated.
  public func quality(in tree: CategoryTree) -> Quality {
    tree.effectiveQuality(of: categoryId) ?? .neutral
  }

  /// The operation with every part that follows the category rated anew, or `nil` when
  /// none of its parts changes.
  public func applied(to entry: TransactionEntry, tree: CategoryTree) -> TransactionEntry? {
    guard !entry.transaction.isDeleted, entry.transaction.kind.hasQuality else { return nil }
    let updates = QualityResolver.updatesForCategoryQualityChange(
      parts: entry.parts, categoryId: categoryId, newQuality: quality(in: tree),
      categories: tree)
    guard !updates.isEmpty else { return nil }
    let byPart = Dictionary(
      updates.map { ($0.partId, $0) }, uniquingKeysWith: { first, _ in first })
    var changed = entry
    for index in changed.parts.indices {
      guard let update = byPart[changed.parts[index].id] else { continue }
      changed.parts[index].quality = update.quality
      changed.parts[index].qualitySource = update.source
    }
    return changed
  }

  /// The operations the change would rewrite, in the order given: what the question counts
  /// and what the write is asked to go over.
  public func affected(_ entries: some Sequence<TransactionEntry>, tree: CategoryTree) -> [UUID] {
    entries.compactMap { applied(to: $0, tree: tree)?.id }
  }
}
