import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One payment of an instalment plan or a purchase on credit coming up.
public struct UpcomingInstalment: Hashable, Sendable {
  public var debtId: UUID
  public var due: DateOnly
  public var currency: CurrencyCode
  public var amountE4: AmountE4

  public init(debtId: UUID, due: DateOnly, currency: CurrencyCode, amountE4: AmountE4) {
    self.debtId = debtId
    self.due = due
    self.currency = currency
    self.amountE4 = amountE4
  }
}

/// «Сколько висит в рассрочках»: what the open instalment plans and purchases on credit still
/// ask, in rubles at today's rate, and the payments coming up first.
public struct InstalmentsSummary: Hashable, Sendable {
  public var totalRub: AmountE4
  public var count: Int
  /// The soonest payments, at most five.
  public var next: [UpcomingInstalment]
  /// Plans in a currency without a known rate: left out, never guessed.
  public var withoutRate: [UUID]

  public init(
    totalRub: AmountE4 = .zero, count: Int = 0, next: [UpcomingInstalment] = [],
    withoutRate: [UUID] = []
  ) {
    self.totalRub = totalRub
    self.count = count
    self.next = next
    self.withoutRate = withoutRate
  }

  public static let empty = InstalmentsSummary()

  /// What the open instalment plans and purchases on credit still ask (their balances), in
  /// rubles at today's rate rounded once, and their next dues, the soonest first.
  ///
  /// A plan counts while it is open, not deleted and something is left on it; its balance is
  /// `journalBalances` — the balance the Debts section shows —, else what its dues know. A plan
  /// in a currency without a rate is listed in `withoutRate` and left out of the total, never
  /// guessed; its dues still show in its own currency. The next dues are the first unpaid due of
  /// each plan and those after it, on or after the earliest unpaid one, at most five in all.
  public static func build(
    debts: [Debt], states: [UUID: DebtDueState], journalBalances: [UUID: AmountE4],
    rubPerUnit: [CurrencyCode: Decimal], today: DateOnly
  ) -> InstalmentsSummary {
    var total = Decimal(0)
    var count = 0
    var withoutRate: [UUID] = []
    var upcoming: [UpcomingInstalment] = []
    for debt in debts
    where !debt.closed && !debt.isDeleted && debt.direction == .iOwe && debt.origin == .purchase {
      let state = states[debt.id]?.knowing(debt)
      guard let balance = journalBalances[debt.id] ?? state?.balanceE4, balance.raw > 0 else {
        continue
      }
      count += 1
      if debt.currency == .rub {
        total += balance.decimal
      } else if let rate = rubPerUnit[debt.currency] {
        total += balance.decimal * rate
      } else {
        withoutRate.append(debt.id)
      }
      guard let state, let first = state.firstUnpaidIndex else { continue }
      // A few dues of each plan are enough to find the soonest five of all.
      let horizon = state.due(first).adding(days: 400)
      for day in state.unpaid(through: horizon).prefix(5) {
        let amount = state.owed(day)
        guard amount.raw > 0 else { continue }
        upcoming.append(
          UpcomingInstalment(debtId: debt.id, due: day, currency: debt.currency, amountE4: amount))
      }
    }
    upcoming.sort { left, right in
      left.due != right.due
        ? left.due < right.due : left.debtId.uuidString < right.debtId.uuidString
    }
    return InstalmentsSummary(
      totalRub: DebtRubles.round(total), count: count, next: Array(upcoming.prefix(5)),
      withoutRate: withoutRate.sorted { $0.uuidString < $1.uuidString })
  }
}
