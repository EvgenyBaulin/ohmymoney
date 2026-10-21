import CoreAnalytics
import CoreKit
import Foundation

// MARK: - Can save, the savings rate, the goals

extension AdviceRules {
  typealias Key = AdviceBook.Key
  typealias Reason = AdviceBook.Reason

  /// «Can save this month»: the lines of `CanSave` as the formula, P50 as
  /// the result, and around it the range, what is saved already and what can go on top.
  static func canSave(_ canSave: CanSave) -> Advice {
    guard case .ready = canSave.status, let p50 = canSave.p50 else {
      if case .notEnoughData(let reason) = canSave.status {
        return .notEnoughData(.canSave, reason: reason)
      }
      return .notEnoughData(.canSave, reason: Reason.noIncome)
    }
    var notes: [AdviceTerm] = []
    if let low = canSave.low, let high = canSave.high {
      notes.append(AdviceTerm(key: Key.canSaveRange, value: .range(low, high)))
    }
    notes.append(AdviceTerm(key: Key.alreadySaved, value: .money(canSave.alreadySaved)))
    if let more = canSave.canSaveMore {
      notes.append(AdviceTerm(key: Key.canSaveMore, value: .money(more)))
    }
    return Advice(
      id: AdviceBook.id(.canSave, nil), kind: .canSave,
      terms: canSave.lines.map { line in
        AdviceTerm(
          key: line.key, op: line.sign == .plus ? .plus : .minus, value: .money(line.amount))
      },
      result: AdviceTerm(key: Key.canSave, op: .equals, value: .money(p50)), notes: notes)
  }

  /// The savings rate («взносы на цели / доход месяца, сравнение с целевой долей»): net
  /// goal contributions ÷ income of this month against the target. Before this month has any
  /// income the last month stands in, named as such; with neither there is no rate.
  static func savingsRate(thisMonth: SavingsRate, lastMonth: SavingsRate) -> Advice {
    let current: SavingsRate
    let keys: (goals: String, income: String, rate: String)
    var notes: [AdviceTerm] = []
    if thisMonth.rateBp != nil {
      current = thisMonth
      keys = (Key.goalsNetThisMonth, Key.incomeThisMonth, Key.savingsRate)
      if let last = lastMonth.rateBp {
        notes.append(AdviceTerm(key: Key.savingsRateLastMonth, value: .basisPoints(last)))
      }
    } else if lastMonth.rateBp != nil {
      current = lastMonth
      keys = (Key.goalsNetLastMonth, Key.incomeLastMonth, Key.savingsRateLastMonth)
    } else {
      return .notEnoughData(.savingsRate, reason: Reason.noIncomeForRate)
    }
    let rate = current.rateBp ?? 0
    notes.insert(AdviceTerm(key: Key.savingsTarget, value: .basisPoints(current.targetBp)), at: 0)
    notes.insert(
      rate < current.targetBp
        ? AdviceTerm(key: Key.shortOfTarget, value: .basisPoints(current.targetBp - rate))
        : AdviceTerm(key: Key.aboveTarget, value: .basisPoints(rate - current.targetBp)),
      at: 1)
    return Advice(
      id: AdviceBook.id(.savingsRate, nil), kind: .savingsRate,
      terms: [
        AdviceTerm(key: keys.goals, value: .money(current.goalsNet)),
        AdviceTerm(key: keys.income, value: .money(current.income)),
      ],
      result: AdviceTerm(key: keys.rate, op: .equals, value: .basisPoints(rate)), notes: notes)
  }

  /// One suggestion per goal not reached yet («нужный взнос, хватает ли „можно отложить“,
  /// реалистичный срок или сумма»), from its `GoalStatus`.
  ///
  /// * The result is the contribution the goal needs a month (with a target date), else the
  ///   month it is reached in at its pace.
  /// * Whether «can save» covers the goals is asked of all of them together: Σ needed a month
  ///   of every open goal with a date against P50 — two goals that each fit can still not fit
  ///   together. «Can save» is rubles, so each goal's need is added in rubles at today's rate;
  ///   a goal whose currency has no rate today leaves the question unanswered, not guessed.
  /// * A goal's own amounts are in its currency.
  /// * A goal without a date and without a pace has nothing to go by: «not enough data».
  static func goals(_ statuses: [GoalStatus], canSaveP50: AmountE4?) -> [Advice] {
    let open = statuses.filter { $0.remaining.raw > 0 }
    let needs = open.compactMap { status in status.neededMonthly.map { status.rubles($0) } }
    let anyNeed = !needs.isEmpty
    let allNeed: AmountE4? =
      needs.contains(nil) ? nil : AmountE4.sum(needs.compactMap { $0 })
    return open.map { status in
      let goal = status.goal
      let subject = AdviceSubject.goal(goal.name)
      let idSuffix = goal.id.uuidString.lowercased()
      guard status.neededMonthly != nil || status.pace != nil else {
        return .notEnoughData(
          .goal, reason: Reason.goalNoDateNoPace, subject: subject, idSuffix: idSuffix)
      }
      func money(_ amount: AmountE4) -> AdviceValue {
        AdviceMath.money(amount, in: status.currency)
      }
      var terms = [AdviceTerm(key: Key.goalRemaining, value: money(status.remaining))]
      if let date = goal.targetDate {
        terms.append(AdviceTerm(key: Key.goalTargetDate, value: .date(date)))
      }
      if let months = status.monthsLeft {
        terms.append(AdviceTerm(key: Key.goalMonthsLeft, value: .months(months)))
      }
      if let pace = status.pace {
        terms.append(AdviceTerm(key: Key.goalPace, value: money(pace)))
      }

      var result: AdviceTerm?
      var notes: [AdviceTerm] = []
      if let needed = status.neededMonthly {
        result = AdviceTerm(key: Key.goalNeededMonthly, op: .equals, value: money(needed))
        if let projected = status.projectedCompletion {
          notes.append(AdviceTerm(key: Key.goalProjected, value: .month(projected)))
        }
      } else if let projected = status.projectedCompletion {
        result = AdviceTerm(key: Key.goalProjected, op: .equals, value: .month(projected))
      }
      if let byDate = status.amountByTargetDate {
        notes.append(AdviceTerm(key: Key.goalByTargetDate, value: money(byDate)))
      }
      if anyNeed, let allNeed, let p50 = canSaveP50 {
        notes.append(AdviceTerm(key: Key.allGoalsNeed, value: .money(allNeed)))
        notes.append(
          allNeed <= p50
            ? AdviceTerm(key: Key.canSaveCovers, value: .money(p50 - allNeed))
            : AdviceTerm(key: Key.canSaveShort, value: .money(allNeed - p50)))
      }
      return Advice(
        id: AdviceBook.id(.goal, idSuffix), kind: .goal, subject: subject, terms: terms,
        result: result, notes: notes)
    }
  }
}
