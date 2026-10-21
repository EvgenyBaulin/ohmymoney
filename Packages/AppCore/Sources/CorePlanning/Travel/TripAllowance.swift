import CoreKit
import Foundation

/// The budget of a trip and «сегодня потрачено / осталось на день».
public enum TripBudget {
  /// The budget of `event` in `defaultCurrency` at the rates of `day`: kept in the currency it
  /// was made in (`budgetCurrency`, else the default currency of the time), shown in the one the
  /// owner has now chosen, so changing the default currency in the middle of a trip changes the
  /// figures and not the budget. `nil` when the event has no budget or a currency has no rate.
  public static func inDefaultCurrency(
    _ event: Event, defaultCurrency: CurrencyCode, rates: DayRates, on day: DateOnly
  ) -> AmountE4? {
    guard let budget = event.budgetE4 else { return nil }
    let kept = event.budgetCurrency ?? defaultCurrency
    return convert(budget, from: kept, to: defaultCurrency, rates: rates, on: day)
  }

  /// The budget of `event` in rubles at the rates of `day` — what the spending of the ledger
  /// (always in rubles) is compared with.
  public static func inRubles(_ event: Event, rates: DayRates, on day: DateOnly) -> AmountE4? {
    guard let budget = event.budgetE4 else { return nil }
    guard let kept = event.budgetCurrency else { return budget }
    return convert(budget, from: kept, to: .rub, rates: rates, on: day)
  }

  /// `amount` of `from` in `to` through rubles, one rounding.
  public static func convert(
    _ amount: AmountE4, from: CurrencyCode, to: CurrencyCode, rates: DayRates, on day: DateOnly
  ) -> AmountE4? {
    if from == to { return amount }
    guard let source = rates.perUnit(from, on: day), let target = rates.perUnit(to, on: day),
      target > 0
    else { return nil }
    return try? AmountE4(decimal: amount.decimal * source / target)
  }
}

/// «Сегодня потрачено X, осталось на день Y»: what is left of the budget divided over the days
/// that remain, against what today has already cost. All in rubles like the ledger (the screen shows them
/// in the default currency), by the days of the operations' own zones.
public struct TripAllowance: Hashable, Sendable {
  public var budget: AmountE4
  /// Spent on the trip before today (every operation of the event dated earlier, and the ones
  /// with no date of the trip — tickets bought months ago).
  public var spentBeforeToday: AmountE4
  public var spentToday: AmountE4
  /// Days from today to the last day of the trip, today included; at least 1.
  public var daysLeft: Int
  /// What is left of the budget when today begins, divided over the days left; zero when it is
  /// spent.
  public var perDay: AmountE4
  /// `perDay − spentToday`; negative when today is over its share.
  public var leftToday: AmountE4
  /// The whole budget is spent (before or with today).
  public var exhausted: Bool

  /// Nil when the trip has no budget.
  public static func make(
    budget: AmountE4?, spentBeforeToday: AmountE4, spentToday: AmountE4, endDate: DateOnly,
    today: DateOnly
  ) -> TripAllowance? {
    guard let budget else { return nil }
    let daysLeft = max(1, today.days(to: endDate) + 1)
    let remaining = budget - spentBeforeToday
    let perDay: AmountE4
    if remaining.raw <= 0 {
      perDay = .zero
    } else {
      perDay = AmountE4(raw: remaining.raw / Int64(daysLeft))
    }
    return TripAllowance(
      budget: budget, spentBeforeToday: spentBeforeToday, spentToday: spentToday,
      daysLeft: daysLeft, perDay: perDay, leftToday: perDay - spentToday,
      exhausted: (budget - spentBeforeToday - spentToday).raw <= 0)
  }
}
