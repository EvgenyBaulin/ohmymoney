import CoreKit
import Foundation

/// A goal for a holiday saved beforehand: when the money is gathered, the trip is ready to be
/// switched on with that budget. The goal itself is a goal as any other; this only reads it.
public enum TripGoal {
  /// The budget a trip made from the goal starts with: what the goal gathered, once it has
  /// gathered its target; `nil` while it has not, and for a goal with no target.
  public static func readyBudget(target: AmountE4, saved: AmountE4) -> AmountE4? {
    guard target.raw > 0, saved >= target else { return nil }
    return saved
  }

  /// The trip made from a gathered goal: an event of kind «Поездка» named like the goal, with
  /// the goal's date as the first day, `days` long, in the currency of the goal for the budget.
  public static func event(
    goalName: String, budget: AmountE4, budgetCurrency: CurrencyCode, startDate: DateOnly,
    days: Int, tripCurrency: CurrencyCode?
  ) -> Event {
    Event(
      name: goalName, kind: .trip, startDate: startDate,
      endDate: startDate.adding(days: max(1, days) - 1), budgetE4: budget,
      tripCurrency: tripCurrency, budgetCurrency: budgetCurrency)
  }

  /// «Сделать поездкой» on a gathered goal: the trip the goal starts, for the owner to look over
  /// before it is made. It is named like the goal, starts on the goal's date (today when that is
  /// past or missing) and lasts `days`, with what the goal gathered as the budget in the goal's
  /// own currency. `nil` while the goal has not gathered its target.
  public static func draft(
    goalName: String, target: AmountE4, saved: AmountE4, currency: CurrencyCode,
    targetDate: DateOnly?, today: DateOnly, days: Int = 14
  ) -> TripStart.Draft? {
    guard let budget = readyBudget(target: target, saved: saved) else { return nil }
    let start = max(targetDate ?? today, today)
    return TripStart.Draft(
      name: goalName, startDate: start, endDate: start.adding(days: max(1, days) - 1),
      tripCurrency: nil, budget: budget, budgetCurrency: currency)
  }
}
