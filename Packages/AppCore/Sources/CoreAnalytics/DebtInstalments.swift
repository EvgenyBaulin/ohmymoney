import CoreKit
import Foundation

/// What each due of a debt asks for, by the index of the due (0 the first): a list of steps, each
/// holding from its index on until the next one; the last step runs on. A loan with one monthly
/// payment is one step (`flat`); a loan with a grace period is a step per due of the grace and
/// one for the main schedule (`DebtSchedulePlan.instalments`). A due of zero is no due.
public struct DebtInstalments: Hashable, Sendable {
  public struct Step: Hashable, Sendable {
    /// The index of the first due the step holds for.
    public var fromIndex: Int
    public var amountE4: AmountE4

    public init(fromIndex: Int, amountE4: AmountE4) {
      self.fromIndex = max(0, fromIndex)
      self.amountE4 = max(AmountE4.zero, amountE4)
    }
  }

  /// In order of `fromIndex`, each index once.
  public private(set) var steps: [Step]

  /// Steps in any order; of two from the same index the later in the list holds.
  public init(steps: [Step]) {
    var byIndex: [Int: Step] = [:]
    for step in steps { byIndex[step.fromIndex] = step }
    self.steps = byIndex.values.sorted { $0.fromIndex < $1.fromIndex }
  }

  /// The same sum for every due; none for no sum or a sum not above zero.
  public static func flat(_ monthly: AmountE4?) -> DebtInstalments {
    guard let monthly, monthly.raw > 0 else { return .none }
    return DebtInstalments(steps: [Step(fromIndex: 0, amountE4: monthly)])
  }

  /// No dues to pay: every due asks for nothing.
  public static let none = DebtInstalments(steps: [])

  /// The steps worked out and the steps typed from the bank's app together, by index: on one
  /// index the typed step holds, and a step holds until the next step of either kind — a sum
  /// worked out again after a later early repayment holds over a sum typed before it.
  public static func merged(
    computed: DebtInstalments, typed: [DebtInstalmentStep]
  ) -> DebtInstalments {
    guard !typed.isEmpty else { return computed }
    return DebtInstalments(
      steps: computed.steps
        + typed.map { Step(fromIndex: $0.fromIndex, amountE4: $0.amountE4) })
  }

  /// Whether the instalments ask for anything at all.
  public var isEmpty: Bool { steps.allSatisfy { $0.amountE4.isZero } }

  /// The one sum every due asks for, when there is one: a flat schedule.
  public var flatAmount: AmountE4? {
    guard steps.count == 1, steps[0].fromIndex == 0, steps[0].amountE4.raw > 0 else {
      return nil
    }
    return steps[0].amountE4
  }

  /// What the due of index `index` asks for: the step at or before it; zero before the first.
  public func amount(at index: Int) -> AmountE4 {
    var result = AmountE4.zero
    for step in steps {
      guard step.fromIndex <= index else { break }
      result = step.amountE4
    }
    return result
  }

  /// What the dues of indexes `from ..< to` ask for together; zero for none.
  public func total(from: Int, to: Int) -> AmountE4 {
    guard to > from else { return .zero }
    var total = AmountE4.zero
    for (position, step) in steps.enumerated() {
      let start = max(step.fromIndex, from)
      let end = min(position + 1 < steps.count ? steps[position + 1].fromIndex : Int.max, to)
      guard end > start else { continue }
      total += AmountE4.rounded(step.amountE4.decimal * Decimal(end - start))
    }
    return total
  }
}
