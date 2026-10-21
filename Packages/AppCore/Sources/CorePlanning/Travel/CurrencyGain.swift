import CoreAccounting
import CoreKit
import Foundation

/// «Курсовая разница»: what the money held in currencies other than the ruble gained or lost in
/// rubles over a period just because the rate moved, with every pair (account, currency) counted
/// and not only the foreign-currency accounts of a trip. A row of the capital screen, never an
/// income or an expense.
///
/// For a pair, the gain is `balance at the end × rate of the last day − balance at the start ×
/// rate of the day before the period − Σ every movement × rate of its own day`: the money that
/// came in or went out in the middle of the period is valued at its own day, so only the move of
/// the rate is left. A pair that was not counted by the start or by the end is listed, not
/// guessed, and so is a pair whose currency has no rate at all.
public struct CurrencyGain: Hashable, Sendable {
  public struct Flow: Hashable, Sendable {
    public var day: DateOnly
    /// Signed, in the currency of the pair: plus came in.
    public var amount: AmountE4

    public init(day: DateOnly, amount: AmountE4) {
      self.day = day
      self.amount = amount
    }
  }

  /// What the books say of one pair, ready to be valued.
  public struct Input: Hashable, Sendable {
    public var key: BalanceKey
    /// The balance when the period starts and when it ends; `nil` — not counted by then.
    public var balanceAtStart: AmountE4?
    public var balanceAtEnd: AmountE4?
    public var flows: [Flow]

    public init(
      key: BalanceKey, balanceAtStart: AmountE4?, balanceAtEnd: AmountE4?, flows: [Flow]
    ) {
      self.key = key
      self.balanceAtStart = balanceAtStart
      self.balanceAtEnd = balanceAtEnd
      self.flows = flows
    }
  }

  public struct Pair: Hashable, Sendable {
    public var key: BalanceKey
    /// In rubles; negative — the rate fell.
    public var gain: AmountE4
  }

  public var from: DateOnly
  public var to: DateOnly
  public var pairs: [Pair]
  /// Σ of the pairs, in rubles.
  public var total: AmountE4
  /// Pairs left out because they were not counted at the start or at the end of the period.
  public var uncounted: [BalanceKey]
  /// Pairs left out because their currency has no rate.
  public var unpriced: [BalanceKey]

  /// The gain of the period from `from` to `to`, both days included.
  public init(inputs: [Input], rates: DayRates, from: DateOnly, to: DateOnly) {
    self.from = from
    self.to = to
    var pairs: [Pair] = []
    var uncounted: [BalanceKey] = []
    var unpriced: [BalanceKey] = []
    let dayBefore = from.adding(days: -1)
    for input in inputs where input.key.currency != .rub {
      guard let start = input.balanceAtStart, let end = input.balanceAtEnd else {
        uncounted.append(input.key)
        continue
      }
      let currency = input.key.currency
      guard let startRate = rates.perUnit(currency, on: dayBefore),
        let endRate = rates.perUnit(currency, on: to)
      else {
        unpriced.append(input.key)
        continue
      }
      var flowsValue = Decimal.zero
      for flow in input.flows {
        guard let rate = rates.perUnit(currency, on: flow.day) else { continue }
        flowsValue += flow.amount.decimal * rate
      }
      let value = end.decimal * endRate - start.decimal * startRate - flowsValue
      guard let gain = try? AmountE4(decimal: value) else { continue }
      pairs.append(Pair(key: input.key, gain: gain))
    }
    self.pairs = pairs.sorted { $0.key < $1.key }
    self.total = AmountE4.sum(pairs.map(\.gain))
    self.uncounted = uncounted.sorted()
    self.unpriced = unpriced.sorted()
  }

  /// The gain of the books: every pair not in rubles (archived and out of the summary too),
  /// counted by the balances at the start and at the end of the period in `calendar`.
  public init(
    balances: AccountBalances, calendar: CalendarContext, rates: DayRates, from: DateOnly,
    to: DateOnly
  ) {
    let before = calendar.startOfDay(from).addingTimeInterval(-0.001)
    let endInstant = calendar.endOfDay(to)
    let inputs = balances.keys.filter { $0.currency != .rub }.map { key in
      Input(
        key: key,
        balanceAtStart: balances.balance(key, at: before),
        balanceAtEnd: balances.balance(key, at: endInstant),
        flows: balances.movements(key, after: before, through: endInstant)
          .map { Flow(day: calendar.day(of: $0.at), amount: $0.amountE4) })
    }
    self.init(inputs: inputs, rates: rates, from: from, to: to)
  }
}
