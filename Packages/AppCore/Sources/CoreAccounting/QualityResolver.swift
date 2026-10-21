import CoreKit
import Foundation

/// The quality of a part together with the rule that produced it.
public struct QualityDecision: Hashable, Sendable {
  public var quality: Quality
  public var source: QualitySource
  /// Goal contributions are fixed at `good`: the UI must not offer another value.
  public var isLocked: Bool

  public init(quality: Quality, source: QualitySource, isLocked: Bool = false) {
    self.quality = quality
    self.source = source
    self.isLocked = isLocked
  }
}

/// One part that a category quality change would rewrite.
public struct QualityUpdate: Hashable, Sendable {
  public var partId: UUID
  public var previous: Quality?
  public var quality: Quality
  public var source: QualitySource

  public init(
    partId: UUID, previous: Quality?, quality: Quality, source: QualitySource = .category
  ) {
    self.partId = partId
    self.previous = previous
    self.quality = quality
    self.source = source
  }
}

/// The qualities I set by hand, keyed by the description of the operation.
///
/// The second rule of how a part gets its quality: once I have rated an operation with a
/// given description myself, the same description keeps that rating. Descriptions are
/// compared after trimming, folding inner runs of whitespace and lowercasing, so
/// «Taxi  home» and «taxi home» are the same thing.
public struct ManualQualityHistory: Hashable, Sendable {
  public static let empty = ManualQualityHistory()

  private var latest: [String: Quality]

  public init(latest: [String: Quality] = [:]) {
    var normalized: [String: Quality] = [:]
    for (description, quality) in latest {
      guard let key = Self.normalized(description) else { continue }
      normalized[key] = quality
    }
    self.latest = normalized
  }

  /// Rebuilds the history from stored operations: the rating made last wins — «моя последняя
  /// оценка». A part keeps no time of its own rating, so the operation's last write
  /// (`updatedAt`) stands for it: an operation entered today with last month's date carries
  /// the newest rating. Its date decides only between operations written at the same moment,
  /// as an import writes a whole batch.
  public init(entries: [TransactionEntry]) {
    var latest: [String: Quality] = [:]
    let ordered = entries.sorted { left, right in
      if left.transaction.updatedAt != right.transaction.updatedAt {
        return left.transaction.updatedAt < right.transaction.updatedAt
      }
      if left.transaction.occurredAt != right.transaction.occurredAt {
        return left.transaction.occurredAt < right.transaction.occurredAt
      }
      if left.transaction.createdAt != right.transaction.createdAt {
        return left.transaction.createdAt < right.transaction.createdAt
      }
      // An import gives a whole batch the same timestamps, and `sorted` is not stable, so
      // without a last tiebreaker «the newest rating wins» depended on the order the rows
      // happened to come out of the database.
      return left.transaction.id.uuidString < right.transaction.id.uuidString
    }
    for entry in ordered where !entry.transaction.isDeleted {
      for part in entry.parts {
        guard part.qualitySource == .manual, let quality = part.quality else { continue }
        guard let key = Self.normalized(Self.description(of: part, in: entry.transaction))
        else { continue }
        latest[key] = quality
      }
    }
    self.latest = latest
  }

  public var isEmpty: Bool { latest.isEmpty }

  public func quality(for description: String?) -> Quality? {
    guard let key = Self.normalized(description) else { return nil }
    return latest[key]
  }

  public mutating func record(_ quality: Quality, for description: String?) {
    guard let key = Self.normalized(description) else { return }
    latest[key] = quality
  }

  /// What counts as «the description of the operation»: the note of the part when it has
  /// one, otherwise the note of the operation.
  public static func description(of part: TransactionPart, in transaction: Transaction) -> String? {
    part.note ?? transaction.note
  }

  public static func normalized(_ description: String?) -> String? {
    guard let description else { return nil }
    var result = ""
    var pendingSpace = false
    for character in description {
      if character.isWhitespace {
        pendingSpace = !result.isEmpty
        continue
      }
      if pendingSpace {
        result.append(" ")
        pendingSpace = false
      }
      result.append(contentsOf: String(character).lowercased())
    }
    return result.isEmpty ? nil : result
  }
}

public enum QualityError: Error, Equatable, Sendable, CustomStringConvertible {
  /// A contribution to a goal is always good and cannot be marked otherwise.
  case goalContributionIsAlwaysGood

  public var description: String {
    switch self {
    case .goalContributionIsAlwaysGood:
      return "A goal contribution is always good and cannot be rated by hand."
    }
  }
}

/// How a part gets its quality.
///
/// The rules are tried in this order, and the first one that fits wins:
///
/// 1. a contribution to a goal is always `good`, source `system`, and cannot be changed;
/// 2. a description I have already rated by hand keeps my last rating, source `history`;
/// 3. otherwise the quality of the subcategory, or of its parent when the subcategory has
///    none, source `category`.
///
/// A rating I set by hand has source `manual` and is never overwritten: neither by the
/// rules above, nor by changing the quality of a category.
public enum QualityResolver {

  // MARK: - Resolving

  public static func resolve(
    goalId: UUID? = nil,
    categoryId: UUID? = nil,
    description: String? = nil,
    categories: CategoryTree = CategoryTree(),
    history: ManualQualityHistory = .empty
  ) -> QualityDecision {
    if isGoalContribution(goalId: goalId, categoryId: categoryId, categories: categories) {
      return QualityDecision(quality: .good, source: .system, isLocked: true)
    }
    if let remembered = history.quality(for: description) {
      return QualityDecision(quality: remembered, source: .history)
    }
    let inherited = categories.effectiveQuality(of: categoryId) ?? .neutral
    return QualityDecision(quality: inherited, source: .category)
  }

  /// The same rules for a stored part. A part I already rated by hand keeps its rating.
  public static func resolve(
    part: TransactionPart,
    in transaction: Transaction,
    categories: CategoryTree = CategoryTree(),
    history: ManualQualityHistory = .empty
  ) -> QualityDecision {
    if part.qualitySource == .manual, let quality = part.quality,
      !isGoalContribution(goalId: part.goalId, categoryId: part.categoryId, categories: categories)
    {
      return QualityDecision(quality: quality, source: .manual)
    }
    return resolve(
      goalId: part.goalId,
      categoryId: part.categoryId,
      description: ManualQualityHistory.description(of: part, in: transaction),
      categories: categories,
      history: history)
  }

  /// The same rules for a draft, used while the ↓ panel is still open.
  public static func resolve(
    draft: PartDraft,
    description: String? = nil,
    categories: CategoryTree = CategoryTree(),
    history: ManualQualityHistory = .empty
  ) -> QualityDecision {
    if draft.qualitySource == .manual, let quality = draft.quality,
      !isGoalContribution(
        goalId: draft.goalId, categoryId: draft.categoryId, categories: categories)
    {
      return QualityDecision(quality: quality, source: .manual)
    }
    return resolve(
      goalId: draft.goalId,
      categoryId: draft.categoryId,
      description: draft.note ?? description,
      categories: categories,
      history: history)
  }

  // MARK: - Rating by hand

  public static func isGoalContribution(
    goalId: UUID?, categoryId: UUID?, categories: CategoryTree = CategoryTree()
  ) -> Bool {
    goalId != nil || categories.isGoalCategory(categoryId)
  }

  /// Can I choose the quality of this part myself?
  public static func canRateByHand(
    goalId: UUID?, categoryId: UUID?, categories: CategoryTree = CategoryTree()
  ) -> Bool {
    !isGoalContribution(goalId: goalId, categoryId: categoryId, categories: categories)
  }

  /// The decision my own rating produces, or an error when the part is a goal
  /// contribution — those stay `good` whatever the UI sends.
  public static func rateByHand(
    _ quality: Quality,
    goalId: UUID? = nil,
    categoryId: UUID? = nil,
    categories: CategoryTree = CategoryTree()
  ) throws -> QualityDecision {
    guard canRateByHand(goalId: goalId, categoryId: categoryId, categories: categories) else {
      throw QualityError.goalContributionIsAlwaysGood
    }
    return QualityDecision(quality: quality, source: .manual)
  }

  // MARK: - Changing the quality of a category

  /// Which parts change when the quality of a category changes.
  ///
  /// Changing a category asks whether to apply the new quality to past operations; this
  /// function answers what «apply» would touch. A part is in the list only when it took
  /// its quality from that category in the first place: ratings I made by hand, ratings
  /// that came from my history and goal contributions are all left alone, and so is a
  /// part that already carries the new quality.
  ///
  /// Subcategories follow their parent only while they have no quality of their own.
  public static func updatesForCategoryQualityChange(
    parts: [TransactionPart],
    categoryId: UUID,
    newQuality: Quality,
    categories: CategoryTree = CategoryTree()
  ) -> [QualityUpdate] {
    parts.compactMap { part in
      guard let partCategoryId = part.categoryId else { return nil }
      guard part.qualitySource == .category || part.qualitySource == nil else { return nil }
      guard
        !isGoalContribution(
          goalId: part.goalId, categoryId: partCategoryId, categories: categories)
      else { return nil }
      guard follows(partCategoryId, changed: categoryId, in: categories) else { return nil }
      guard part.quality != newQuality else { return nil }
      return QualityUpdate(partId: part.id, previous: part.quality, quality: newQuality)
    }
  }

  /// Does a part filed under `categoryId` take its quality from `changed`?
  private static func follows(
    _ categoryId: UUID, changed: UUID, in categories: CategoryTree
  ) -> Bool {
    if categoryId == changed { return true }
    guard let category = categories[categoryId], category.parentId == changed else { return false }
    return category.quality == nil
  }

  // MARK: - Defaults of the starting categories

  /// The qualities the starting categories are created with. The names are the canonical
  /// English ones; the localized names are only labels.
  public enum Defaults {
    /// Goals is fixed at `good` and cannot be changed at all.
    public static let good: Set<String> = ["goals", "education", "health"]
    /// Subcategories that start as `bad`, keyed by the name of their parent.
    public static let bad: [String: Set<String>] = [
      "car": ["fines"],
      "other": ["fees"],
    ]

    /// The quality a starting category is created with. A top-level category always has
    /// one — `neutral` unless listed; a subcategory has one only when it is listed as bad,
    /// otherwise it is created empty and follows its parent (Pharmacy under Health is good),
    /// exactly as the app's starter list seeds it.
    public static func quality(named name: String, parentNamed parent: String? = nil) -> Quality? {
      let key = name.lowercased()
      guard let parent else { return good.contains(key) ? .good : .neutral }
      return bad[parent.lowercased()]?.contains(key) == true ? .bad : nil
    }
  }
}
