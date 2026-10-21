import CoreKit
import Foundation

/// «Хватит ли?» — can a purchase be paid for now. The answer is read from the free money of the
/// planning (`FreeMoney`: the money on the accounts less what is owed and planned), the cushion
/// and the goals in the owner's order; it never proposes a loan or an instalment.
///
/// The model is plain on purpose: what is free pays the purchase; the part of the free money
/// the goals count on this month is spent last, from the goal lowest in the order up, and
/// moves that goal; the cushion is touched only when the free money counts it.
public enum AffordCheck {
  /// A goal as the check sees it, in the owner's order: the first is the most important.
  public struct Goal: Hashable, Sendable {
    public var name: String
    /// What the goal asks to be put into it each month; zero for one without a plan.
    public var monthlyPlanE4: AmountE4

    public init(name: String, monthlyPlanE4: AmountE4) {
      self.name = name
      self.monthlyPlanE4 = monthlyPlanE4
    }
  }

  public struct Input: Hashable, Sendable {
    public var amountE4: AmountE4
    /// «Можно тратить сейчас».
    public var freeE4: AmountE4
    /// What is left each month after the plan, from the history; zero or less — nothing to wait
    /// with.
    public var monthlySurplusE4: AmountE4
    public var cushionE4: AmountE4
    /// The target of the cushion; zero — none.
    public var cushionTargetE4: AmountE4
    /// The free money counts the cushion (the owner did not take it out of the free sum).
    public var freeCountsCushion: Bool
    public var goals: [Goal]
    public var today: DateOnly
    /// The next income, when it is known: the day it is expected.
    public var nextIncomeDay: DateOnly?

    public init(
      amountE4: AmountE4, freeE4: AmountE4, monthlySurplusE4: AmountE4 = .zero,
      cushionE4: AmountE4 = .zero, cushionTargetE4: AmountE4 = .zero,
      freeCountsCushion: Bool = false, goals: [Goal] = [], today: DateOnly,
      nextIncomeDay: DateOnly? = nil
    ) {
      self.amountE4 = amountE4
      self.freeE4 = freeE4
      self.monthlySurplusE4 = monthlySurplusE4
      self.cushionE4 = cushionE4
      self.cushionTargetE4 = cushionTargetE4
      self.freeCountsCushion = freeCountsCushion
      self.goals = goals
      self.today = today
      self.nextIncomeDay = nextIncomeDay
    }
  }

  /// A goal moved by the purchase: by how many months.
  public struct GoalShift: Hashable, Sendable {
    public var name: String
    public var months: Int
  }

  public enum Verdict: String, Hashable, Sendable {
    /// «Да».
    case yes
    /// «Да, но цель сдвинется на N».
    case yesGoalsShift
    /// «Да, но подушка опустится ниже цели».
    case yesCushionBelowTarget
    /// «Нет — не хватит до 25-го, нужно ещё 34 000».
    case notEnough
    /// «Да, если подождать до …».
    case yesIfWait
  }

  public struct Result: Hashable, Sendable {
    public var verdict: Verdict
    /// What is missing; zero when it is enough.
    public var shortfallE4: AmountE4
    public var goalShifts: [GoalShift]
    /// The cushion after the purchase, when it touches it.
    public var cushionAfterE4: AmountE4?
    /// The month from which it is enough, for «подождать».
    public var waitUntil: MonthKey?
    /// The day the shortfall is told to, «не хватит до …»: the next income, when known.
    public var shortUntil: DateOnly?
  }

  public static func check(_ input: Input) -> Result {
    let amount = max(input.amountE4, .zero)
    let free = max(input.freeE4, .zero)
    let shortfall = max(.zero, amount - free)

    if shortfall.raw > 0 {
      if input.monthlySurplusE4.raw > 0 {
        let months = Int(
          clamping: (shortfall.raw + input.monthlySurplusE4.raw - 1) / input.monthlySurplusE4.raw)
        if months <= ScenarioSpec.maxHorizonMonths {
          return Result(
            verdict: .yesIfWait, shortfallE4: shortfall, goalShifts: [], cushionAfterE4: nil,
            waitUntil: input.today.monthKey.adding(months: months), shortUntil: nil)
        }
      }
      return Result(
        verdict: .notEnough, shortfallE4: shortfall, goalShifts: [], cushionAfterE4: nil,
        waitUntil: nil, shortUntil: input.nextIncomeDay)
    }

    // Enough in all: what it takes from the cushion and from the plans of the goals.
    let planned = input.goals.reduce(AmountE4.zero) { $0 + max($1.monthlyPlanE4, .zero) }
    let cushion = max(input.cushionE4, .zero)
    let spareAfterCushion = input.freeCountsCushion ? max(.zero, free - cushion) : free
    let spare = max(.zero, spareAfterCushion - planned)
    let fromCushion =
      input.freeCountsCushion ? max(.zero, amount - spareAfterCushion) : .zero
    let fromPlans = max(.zero, amount - fromCushion - spare)

    var shifts: [GoalShift] = []
    var left = fromPlans
    for goal in input.goals.reversed() where left.raw > 0 && goal.monthlyPlanE4.raw > 0 {
      left = left - min(left, goal.monthlyPlanE4)
      // A month of the plan, or a part of it, is not put in: the goal comes a month later.
      shifts.append(GoalShift(name: goal.name, months: 1))
    }
    shifts.reverse()

    let cushionAfter = fromCushion.raw > 0 ? cushion - fromCushion : nil
    let below =
      input.cushionTargetE4.raw > 0 && (cushionAfter.map { $0 < input.cushionTargetE4 } ?? false)
    let verdict: Verdict =
      below ? .yesCushionBelowTarget : (shifts.isEmpty ? .yes : .yesGoalsShift)
    return Result(
      verdict: verdict, shortfallE4: .zero, goalShifts: below ? [] : shifts,
      cushionAfterE4: cushionAfter, waitUntil: nil, shortUntil: nil)
  }
}
