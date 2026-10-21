import CoreArchive
import CoreKit
import Foundation

/// What the model is allowed to learn from.
///
/// Parts of system categories are never learned from. Nor is an operation the application
/// wrote itself — it is not the owner filing anything — and a category the model itself
/// filled in is not evidence either: learning from its own guesses is how one confident
/// mistake becomes a habit within a week.
///
/// This lives beside the model rather than with the ledger on purpose: it takes rows of
/// whatever shape the caller has, so `make eval-model` can use it on a CSV export with no
/// accounting in sight.
public enum CategoryTraining {
  /// One part, as much of it as the rule needs to judge.
  public struct Row: Hashable, Sendable {
    public var partId: UUID
    public var categoryId: UUID?
    /// The role of the category or of its root, if either is one of the app's own.
    public var systemRole: SystemRole?
    /// Where the category came from. What the model itself filled in is not evidence.
    public var categorySource: CategorySource
    /// The operation's `external_id`: the app writes one on everything it creates itself.
    public var externalId: String?
    /// The operation was deleted (kept in the table with a date).
    public var isDeleted: Bool
    public var query: CategoryQuery

    public init(
      partId: UUID, categoryId: UUID?, systemRole: SystemRole?, categorySource: CategorySource,
      externalId: String?, isDeleted: Bool, query: CategoryQuery
    ) {
      self.partId = partId
      self.categoryId = categoryId
      self.systemRole = systemRole
      self.categorySource = categorySource
      self.externalId = externalId
      self.isDeleted = isDeleted
      self.query = query
    }
  }

  /// Whether this part is one the owner filed themselves.
  public static func isLabelled(_ row: Row) -> Bool {
    guard !row.isDeleted, row.categoryId != nil else { return false }
    guard row.systemRole == nil else { return false }
    guard row.categorySource != .model, row.categorySource != .system else { return false }
    // `sched:`, `reimb:`, `reconcile:` — the app's own handwriting.
    guard row.externalId == nil else { return false }
    return true
  }

  public static func examples(from rows: [Row]) -> [CategoryExample] {
    rows.compactMap { row in
      guard isLabelled(row), let categoryId = row.categoryId else { return nil }
      return CategoryExample(query: row.query, partId: row.partId, categoryId: categoryId)
    }
  }

  /// What the model was trained on, in a form that can be compared without keeping the
  /// examples: if this has not changed, nothing needs retraining — the pipeline trains only
  /// when the data changed.
  ///
  /// Each example is taken with everything the model reads from it — the category, the day
  /// its weight comes from, its feature keys and its exact key — so an edit of the note, the
  /// place, the payment method, for whom or the amount's bucket retrains, and an edit the model
  /// cannot see (an amount within the same bucket) does not. What is kept is a digest, never
  /// the words. A model kept from before such an edit would hold words the ledger no longer
  /// has, and a correction would take back counts it never had.
  public static func fingerprint(of examples: [CategoryExample]) -> String {
    let parts =
      examples
      .map { example in
        let learned = ([example.query.exactKey ?? ""] + example.query.featureKeys)
          .joined(separator: "\u{1F}")
        return
          "\(example.partId.uuidString):\(example.categoryId.uuidString):\(example.query.day.iso):"
          + SHA256.hexDigest(learned)
      }
      .sorted()
      .joined(separator: "\n")
    return "\(examples.count):\(CategoryFeatures.version):\(SHA256.hexDigest(parts))"
  }
}
