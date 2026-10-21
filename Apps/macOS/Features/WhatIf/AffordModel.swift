import AppCore
import Foundation

/// «Хватит ли?» as the app shows it: the numbers `AffordCheck` wants cut from today's planning
/// snapshot, and the sentences its answers are told in. Plain values, no views, so the tests can
/// walk every answer.
enum AffordModel {
  /// An expense of the entry panel above this (in the default currency) offers «Хватит ли?».
  static let entryLinkThresholdE4 = AmountE4(raw: 300_000_000)

  /// Whether the entry panel shows the link: a new expense in the default currency above the
  /// threshold.
  static func offersEntryLink(
    isExpense: Bool, amount: AmountE4, currency: CurrencyCode, defaultCurrency: CurrencyCode
  ) -> Bool {
    isExpense && currency == defaultCurrency && amount > entryLinkThresholdE4
  }

  /// The amount of the panel in rubles, for the sheet: the default currency is the ruble or
  /// goes by the rate the snapshot knows; without one the sheet starts empty.
  static func rubles(
    of amount: AmountE4, currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    if currency == .rub { return amount }
    guard let rate = rubPerUnit[currency] else { return nil }
    return try? AmountE4(decimal: amount.decimal * rate)
  }

  /// What the check is fed with. The goals stand in the owner's order (`GoalOrder`), the ones
  /// already reached left out; a goal's plan counts only in rubles. What is left each month is
  /// the income of the month as the snapshot estimates it less the median monthly spending of
  /// the last three full months (`AffordSpending`) and the plans of the goals; with less
  /// history than that, the obligatory spending stands in (`usesObligatory`). `nil` while no
  /// account is counted (there is no «можно тратить сейчас»).
  static func input(
    amount: AmountE4, snapshot: PlanningSnapshot, spending: AffordSpending
  ) -> AffordCheck.Input? {
    guard let free = snapshot.freeMoney.main else { return nil }
    let ordered = GoalOrder.shown(snapshot.goals).filter {
      $0.remaining.raw > 0 && !$0.goal.archived
    }
    let goals = ordered.map {
      AffordCheck.Goal(
        name: $0.goal.name,
        monthlyPlanE4: $0.goal.currency == .rub ? ($0.goal.monthlyPlanE4 ?? .zero) : .zero)
    }
    let baseline = ScenarioBaseline(snapshot: snapshot)
    return input(
      amount: amount, free: free, goals: goals, incomeMonthly: baseline.incomeMonthlyE4,
      spendingMonthly: spending.medianRub ?? baseline.spendingMonthlyE4,
      cushion: snapshot.cushion.inSummaryRub,
      cushionTarget: snapshot.cushion.goal?.targetRub ?? .zero,
      // The free money counts the cushion unless the owner took it out of the free sum.
      freeCountsCushion: snapshot.freeMoney.cushion.isZero
        && snapshot.cushion.inSummaryRub.raw > 0,
      today: snapshot.today, nextIncomeDay: nextIncomeDay(snapshot))
  }

  /// Whether the sheet leans on the obligatory spending: fewer than three full months of
  /// history, so no median of the spending is there.
  static func usesObligatory(_ spending: AffordSpending) -> Bool { spending.medianRub == nil }

  /// The same from plain numbers: what is left each month is the income less the monthly
  /// spending and the plans of the goals.
  static func input(
    amount: AmountE4, free: AmountE4, goals: [AffordCheck.Goal], incomeMonthly: AmountE4,
    spendingMonthly: AmountE4, cushion: AmountE4, cushionTarget: AmountE4,
    freeCountsCushion: Bool, today: DateOnly, nextIncomeDay: DateOnly?
  ) -> AffordCheck.Input {
    let planned = goals.reduce(AmountE4.zero) { $0 + $1.monthlyPlanE4 }
    return AffordCheck.Input(
      amountE4: amount, freeE4: free,
      monthlySurplusE4: incomeMonthly - spendingMonthly - planned, cushionE4: cushion,
      cushionTargetE4: cushionTarget, freeCountsCushion: freeCountsCushion, goals: goals,
      today: today, nextIncomeDay: nextIncomeDay)
  }

  /// The next day an income is expected from today on: the end of the half of the month when
  /// the income comes twice, otherwise the earliest due date still waiting for money.
  static func nextIncomeDay(_ snapshot: PlanningSnapshot) -> DateOnly? {
    if let half = snapshot.payHalf { return half.nextIncomeDay }
    return snapshot.expected.lazy.flatMap(\.occurrences)
      .filter { $0.due >= snapshot.today && $0.remaining.raw > 0 }
      .map(\.due).min()
  }

  // MARK: The sentences

  /// A sentence: the key of the `WhatIf` table and the already written arguments.
  struct Phrase: Equatable {
    var key: String
    var arguments: [String] = []
  }

  /// How money, months and days are written; the app passes its formatters.
  struct Writer {
    var money: (AmountE4) -> String
    var month: (MonthKey) -> String
    var day: (DateOnly) -> String
  }

  /// The answer in sentences: the headline, then a line for every goal it moves.
  struct Told: Equatable {
    var headline: Phrase
    var lines: [Phrase] = []
  }

  static func told(_ result: AffordCheck.Result, input: AffordCheck.Input, writer: Writer) -> Told {
    switch result.verdict {
    case .yes:
      return Told(headline: Phrase(key: "afford.yes"))
    case .yesGoalsShift:
      return Told(
        headline: Phrase(key: "afford.yesGoalsShift"),
        lines: result.goalShifts.map { Phrase(key: "afford.shift", arguments: [$0.name]) })
    case .yesCushionBelowTarget:
      return Told(
        headline: Phrase(
          key: "afford.yesCushionBelowTarget",
          arguments: [
            writer.money(result.cushionAfterE4 ?? .zero), writer.money(input.cushionTargetE4),
          ]))
    case .notEnough:
      if let until = result.shortUntil {
        return Told(
          headline: Phrase(
            key: "afford.notEnoughUntil",
            arguments: [writer.day(until), writer.money(result.shortfallE4)]))
      }
      return Told(
        headline: Phrase(key: "afford.notEnough", arguments: [writer.money(result.shortfallE4)]))
    case .yesIfWait:
      return Told(
        headline: Phrase(
          key: "afford.yesIfWait",
          arguments: [
            writer.month(result.waitUntil ?? input.today.monthKey),
            writer.money(result.shortfallE4),
          ]))
    }
  }
}
