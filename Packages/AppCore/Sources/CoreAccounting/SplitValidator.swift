import CoreKit
import Foundation

/// What stops a split operation from being saved. The cases carry ids, never amounts or
/// notes: errors end up in logs, and logs must stay free of personal data.
///
/// The unallocated remainder is not part of the error — it lives in
/// `SplitValidation.unallocated`, because the UI has to show it while it is still wrong.
public enum SplitProblem: Error, Hashable, Sendable, CustomStringConvertible {
  case noParts
  /// The parts do not add up to the total. `CoreError.unbalancedSplit` is the same
  /// refusal one layer down, where the entry is written.
  case unbalanced
  case emptyPart(partId: UUID)
  case categoryMissing(partId: UUID)
  /// A part paid for somebody else has to name the person who owes me.
  case debtorMissing(partId: UUID)
  /// A part filed under Goals has to name the goal it contributes to.
  case goalMissing(partId: UUID)
  /// A part naming a goal has to be filed under the subcategory of that goal.
  case goalCategoryMismatch(partId: UUID)

  public var description: String {
    switch self {
    case .noParts:
      return "An operation needs at least one part."
    case .unbalanced:
      return "The parts have to add up to the total of the operation."
    case .emptyPart:
      return "Every part needs an amount above zero."
    case .categoryMissing:
      return "Every part needs a category."
    case .debtorMissing:
      return "A part paid for somebody else needs the person who owes it back."
    case .goalMissing:
      return "A contribution to a goal needs the goal."
    case .goalCategoryMismatch:
      return "A contribution to a goal belongs in the subcategory of that goal."
    }
  }
}

/// The state of a split as the ↓ panel shows it: the remainder stays visible, and saving
/// is only allowed once nothing is left and no part is incomplete.
public struct SplitValidation: Hashable, Sendable {
  /// Amount not distributed between the parts yet. Positive means money is missing from
  /// the parts, negative means the parts claim more than the operation.
  public var unallocated: AmountE4
  public var problems: [SplitProblem]

  public init(unallocated: AmountE4, problems: [SplitProblem]) {
    self.unallocated = unallocated
    self.problems = problems
  }

  public var isBalanced: Bool { unallocated.isZero }
  public var canSave: Bool { problems.isEmpty }
}

/// Splitting one operation into parts.
///
/// The parts have to add up to the total: the remainder is shown while it is not zero,
/// and only a zero remainder can be saved. `TransactionDraft` already knows how to
/// measure itself (`unallocated`, `isBalanced`); this type adds the rules that the draft
/// itself cannot check, and hands out equal shares without losing a unit.
public enum SplitValidator {

  // MARK: - Validating

  /// Checks a draft. `categories` is optional: without it the Goals rules are skipped,
  /// because nothing says which category is the system Goals one.
  public static func validate(
    _ draft: TransactionDraft, categories: CategoryTree = CategoryTree()
  ) -> SplitValidation {
    var problems: [SplitProblem] = []
    if draft.parts.isEmpty {
      problems.append(.noParts)
    } else if !draft.unallocated.isZero {
      problems.append(.unbalanced)
    }

    for part in draft.parts {
      if part.amount.raw <= 0 {
        problems.append(.emptyPart(partId: part.id))
      }
      if part.categoryId == nil && part.goalId == nil {
        problems.append(.categoryMissing(partId: part.id))
      }
      if part.reimbursable && part.debtorPersonId == nil {
        problems.append(.debtorMissing(partId: part.id))
      }
      problems.append(contentsOf: goalProblems(for: part, categories: categories))
    }

    return SplitValidation(unallocated: draft.unallocated, problems: problems)
  }

  /// Throws the first problem, for the call sites that only want to save or fail.
  public static func check(
    _ draft: TransactionDraft, categories: CategoryTree = CategoryTree()
  ) throws {
    if let problem = validate(draft, categories: categories).problems.first {
      throw problem
    }
  }

  private static func goalProblems(
    for part: PartDraft, categories: CategoryTree
  ) -> [SplitProblem] {
    guard !categories.isEmpty else { return [] }
    let isGoalCategory = categories.isGoalCategory(part.categoryId)
    if isGoalCategory && part.goalId == nil {
      return [.goalMissing(partId: part.id)]
    }
    if part.goalId != nil && part.categoryId != nil && !isGoalCategory {
      return [.goalCategoryMismatch(partId: part.id)]
    }
    return []
  }

  // MARK: - Equal shares

  /// Splits an amount into equal shares that add up exactly to the original: the
  /// remaining units go to the first shares, so no kopeck disappears.
  public static func equalShares(of amount: AmountE4, into count: Int) -> [AmountE4] {
    amount.split(into: count)
  }

  /// Rewrites the parts of a draft as equal shares of its total. Existing parts keep
  /// everything but their amount; missing ones are added.
  public static func splitEqually(_ draft: TransactionDraft, into count: Int) -> TransactionDraft {
    guard count > 0 else { return draft }
    var result = draft
    let shares = equalShares(of: draft.amount, into: count)
    var parts: [PartDraft] = []
    parts.reserveCapacity(count)
    for index in 0..<count {
      var part = index < draft.parts.count ? draft.parts[index] : PartDraft()
      part.amount = shares[index]
      part.amountExpression = nil
      parts.append(part)
    }
    result.parts = parts
    return result
  }

  /// The remainder the ↓ panel shows next to the parts.
  public static func unallocated(_ draft: TransactionDraft) -> AmountE4 {
    draft.unallocated
  }
}
