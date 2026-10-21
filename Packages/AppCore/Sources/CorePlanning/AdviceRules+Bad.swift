import CoreAnalytics
import CoreKit
import Foundation

// MARK: - Bad spending: the comparison, the cut scenario, a limit to suggest

extension AdviceRules {
  /// Complete months the average bad spending is taken over.
  static let badAverageMonths = 3
  /// The cuts of the scenario: 10, 25 and 50 %.
  static let badCutsBp = [1_000, 2_500, 5_000]
  /// The suggested limit on bad spending is 90 % of the usual month.
  static let badLimitFactorBp = 9_000

  /// Bad spending against earlier months («сравнение с прошлыми месяцами»): this month
  /// from the 1st through today against the same days of last month and the average of the
  /// same days of the last three complete months — the same span each time, so a month half
  /// gone is never measured against whole months. The average of whole months stands in the
  /// notes. No complete month: «not enough data»; nothing bad at all: no suggestion.
  static func badComparison(_ context: AdviceContext) -> [Advice] {
    let months = context.completeMonths(badAverageMonths)
    guard let last = months.last else {
      return [.notEnoughData(.badComparison, reason: Reason.noCompleteMonth)]
    }
    let ledger = context.ledger
    let today = context.today
    let current = badSpending(ledger, in: DayRange(context.month.firstDay, today))
    func sameSpan(_ month: MonthKey) -> DayRange {
      DayRange(
        month.firstDay,
        DateOnly(year: month.year, month: month.month, day: min(today.day, month.dayCount)))
    }
    let previous = badSpending(ledger, in: sameSpan(last))
    let average = SavingsMath.divide(
      AmountE4.sum(months.map { badSpending(ledger, in: sameSpan($0)) }), by: months.count)
    let wholeAverage = averageBadMonth(ledger, months: months)
    guard !current.isZero || !previous.isZero || !average.isZero || !wholeAverage.isZero else {
      return []
    }
    var notes: [AdviceTerm] = []
    if let change = Change(current: current, previous: previous).basisPoints {
      notes.append(AdviceTerm(key: Key.changeVsLastMonth, value: .basisPoints(change)))
    }
    if let change = Change(current: current, previous: average).basisPoints {
      notes.append(AdviceTerm(key: Key.changeVsAverage, value: .basisPoints(change)))
    }
    notes.append(AdviceTerm(key: Key.badMonthlyAverage, value: .money(wholeAverage)))
    notes.append(AdviceTerm(key: Key.monthsCounted, value: .count(months.count)))
    return [
      Advice(
        id: AdviceBook.id(.badComparison, nil), kind: .badComparison,
        terms: [
          AdviceTerm(key: Key.badThisMonth, op: .plus, value: .money(current)),
          AdviceTerm(key: Key.badSameSpanLastMonth, op: .minus, value: .money(previous)),
        ],
        result: AdviceTerm(key: Key.badVsLastMonth, op: .equals, value: .money(current - previous)),
        notes: [AdviceTerm(key: Key.badSameSpanAverage, value: .money(average))] + notes)
    ]
  }

  /// «Cut bad spending by 10, 25 or 50 % and every goal comes sooner», one suggestion
  /// per goal.
  ///
  /// s = p × the average monthly bad spending of the last three complete months. For a goal
  /// with R still to save and a positive monthly pace r (its plan, else its average net
  /// contribution — `GoalStatus.pace`): months sooner = ⌈R ÷ r⌉ − ⌈R ÷ (r + s)⌉. R and r are in
  /// the goal's currency, so the rubles s frees are turned into it at today's rate; a goal
  /// whose currency has no rate today is left out. No open goal: nothing to suggest, whatever
  /// the history; no complete month: «not enough data»; open goals, but none with a pace:
  /// «not enough data»; no bad spending: nothing to suggest.
  static func badCutScenarios(_ context: AdviceContext, goals: [GoalStatus]) -> [Advice] {
    // The scenario is about goals: without one to bring forward there is nothing to say, not
    // too little to say it with.
    let open = goals.filter { $0.remaining.raw > 0 }
    guard !open.isEmpty else { return [] }
    let months = context.completeMonths(badAverageMonths)
    guard !months.isEmpty else {
      return [.notEnoughData(.badCutScenario, reason: Reason.noCompleteMonth)]
    }
    let average = averageBadMonth(context.ledger, months: months)
    guard average.raw > 0 else { return [] }
    let paced = open.filter { ($0.pace?.raw ?? 0) > 0 }
    guard !paced.isEmpty else {
      return [.notEnoughData(.badCutScenario, reason: Reason.goalNoPace)]
    }
    return paced.compactMap { status in
      guard let rate = status.rubPerUnit, rate > 0 else { return nil }
      let currency = status.currency
      let remaining = status.remaining
      let pace = status.pace ?? .zero
      let base = SavingsMath.ceilingQuotient(remaining, pace)
      var terms = [
        AdviceTerm(key: Key.badMonthlyAverage, value: .money(average)),
        AdviceTerm(key: Key.goalRemaining, value: AdviceMath.money(remaining, in: currency)),
        AdviceTerm(key: Key.goalPace, value: AdviceMath.money(pace, in: currency)),
        AdviceTerm(key: Key.monthsAtPace, value: .months(base)),
      ]
      var notes: [AdviceTerm] = []
      for cut in badCutsBp {
        let freed = AdviceMath.share(average, basisPoints: cut)
        let freedInGoal = currency == .rub ? freed : SavingsMath.rounded(freed.decimal / rate)
        let sooner = base - SavingsMath.ceilingQuotient(remaining, pace + freedInGoal)
        terms.append(AdviceTerm(key: Key.sooner(cutBp: cut), value: .months(sooner)))
        notes.append(AdviceTerm(key: Key.cut(cutBp: cut), value: .money(freed)))
      }
      return Advice(
        id: AdviceBook.id(.badCutScenario, status.goal.id), kind: .badCutScenario,
        subject: .goal(status.goal.name), terms: terms, notes: notes)
    }
  }

  /// A limit on bad spending, when there is none («предложение общего лимита»): 90 % of
  /// the median monthly bad spending of the last three to six complete months, rounded to
  /// 100 ₽. Fewer than three complete months: «not enough data»; a usual month without bad
  /// spending: nothing to limit.
  static func badLimitSuggestion(_ context: AdviceContext, budgets: [Budget]) -> [Advice] {
    guard !budgets.contains(where: { $0.scope == .badTotal }) else { return [] }
    let months = context.completeMonths(categoryMonths)
    guard months.count >= minimumMonths else {
      return [.notEnoughData(.badLimitSuggestion, reason: Reason.fewerThanThreeMonths)]
    }
    let values = months.map { badSpending(context.ledger, in: Period.month($0).range) }
    guard let median = IncomeEstimate.median(values), median.raw > 0 else { return [] }
    let suggested = AdviceMath.roundedToHundred(
      median.decimal * Decimal(badLimitFactorBp) / Decimal(Shares.whole))
    guard suggested.raw > 0 else { return [] }
    return [
      Advice(
        id: AdviceBook.id(.badLimitSuggestion, nil), kind: .badLimitSuggestion,
        terms: [
          AdviceTerm(key: Key.monthsCounted, value: .count(months.count)),
          AdviceTerm(key: Key.monthlyMedian, value: .money(median)),
          AdviceTerm(key: Key.limitFactor, value: .basisPoints(badLimitFactorBp)),
        ],
        result: AdviceTerm(key: Key.suggestedLimit, op: .equals, value: .money(suggested)))
    ]
  }

  // MARK: Figures

  /// The probe a limit on bad spending counts rows with.
  private static let badProbe = Budget(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000bad0") ?? UUID(), scope: .badTotal,
    amountE4: .zero)

  /// My bad spending over the days: what a limit on bad spending counts
  /// (`LimitRules.counts`), refunds taken off.
  static func badSpending(_ ledger: Ledger, in range: DayRange) -> AmountE4 {
    AmountE4.sum(
      ledger.rows(in: range).lazy.filter { LimitRules.counts($0, for: badProbe) }.map(
        \.contribution))
  }

  /// The average of whole months of bad spending.
  static func averageBadMonth(_ ledger: Ledger, months: [MonthKey]) -> AmountE4 {
    guard !months.isEmpty else { return .zero }
    return SavingsMath.divide(
      AmountE4.sum(months.map { badSpending(ledger, in: Period.month($0).range) }),
      by: months.count)
  }
}
