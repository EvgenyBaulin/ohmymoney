import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What a loan really costs: the payments and every other cost against the money received, and
/// the yearly rate that makes the two equal — the way the Bank of Russia works out the full cost
/// of credit.
public struct DebtCostReport: Hashable, Sendable {
  public var principalE4: AmountE4
  public var paymentsE4: AmountE4
  public var interestE4: AmountE4
  public var costsOnceE4: AmountE4
  public var costsPeriodicE4: AmountE4
  /// All payments + all costs − the money received.
  public var overpayE4: AmountE4
  /// % a year, three digits; `nil` — no rate makes the flows equal.
  public var effectiveRate: Decimal?
  /// The full cost of credit from the contract.
  public var contractPsk: Decimal?
  /// The worked-out rate minus the contract's, in percentage points.
  public var pskGap: Decimal?

  public init(
    principalE4: AmountE4 = .zero, paymentsE4: AmountE4 = .zero, interestE4: AmountE4 = .zero,
    costsOnceE4: AmountE4 = .zero, costsPeriodicE4: AmountE4 = .zero,
    overpayE4: AmountE4 = .zero, effectiveRate: Decimal? = nil, contractPsk: Decimal? = nil,
    pskGap: Decimal? = nil
  ) {
    self.principalE4 = principalE4
    self.paymentsE4 = paymentsE4
    self.interestE4 = interestE4
    self.costsOnceE4 = costsOnceE4
    self.costsPeriodicE4 = costsPeriodicE4
    self.overpayE4 = overpayE4
    self.effectiveRate = effectiveRate
    self.contractPsk = contractPsk
    self.pskGap = pskGap
  }

  /// What `debt` costs, over `schedule` — every due of the loan from its first, as
  /// `DebtAmortization.schedule` gives it — and `costs`.
  ///
  /// * The payments are the dues of the schedule (with what was paid early in them); the
  ///   interest is what they pay above the money borrowed (`borrowedE4`).
  /// * A cost paid once counts once; a monthly cost counts in each month of the schedule from
  ///   the month of its day, a yearly one every twelve months from it.
  /// * The overpay is all payments and all costs less the money received — `borrowedE4`, which
  ///   holds a cost paid out of the loan (`inLoan`) too, so that cost is not counted twice.
  /// * The worked-out rate (`effectiveRate`) is the yearly rate of the flow: received less the
  ///   costs paid once at the start, the payments and the periodic costs in their months. Against
  ///   the contract's full cost of credit (`Debt.psk`) it gives `pskGap`.
  ///
  /// `paidE4` and `firstDay` say where the loan stands: the months of the flow are counted from
  /// the month of `firstDay`.
  public static func report(
    debt: Debt, borrowedE4: AmountE4, costs: [DebtCost], schedule: [AmortizationRow],
    paidE4: AmountE4, firstDay: DateOnly
  ) -> DebtCostReport {
    let own = costs.filter { $0.debtId == debt.id }
    var payments = AmountE4.zero
    var flows: [Int: Decimal] = [:]
    var lastMonth = 0
    for row in schedule {
      let paid = row.paymentE4 + row.prepaidE4
      payments += paid
      let month = max(1, firstDay.monthKey.months(to: row.due.monthKey))
      flows[month, default: 0] += paid.decimal
      lastMonth = max(lastMonth, month)
    }
    var once = AmountE4.zero
    var periodic = AmountE4.zero
    var atStart = Decimal(0)
    for cost in own {
      let start = max(0, firstDay.monthKey.months(to: cost.day.monthKey))
      switch cost.every {
      case .once:
        once += cost.amountE4
        if start == 0 {
          atStart += cost.amountE4.decimal
        } else {
          flows[start, default: 0] += cost.amountE4.decimal
        }
      case .monthly, .yearly:
        let step = cost.every == .monthly ? 1 : 12
        var month = max(start, cost.every == .monthly ? 1 : start)
        while month <= lastMonth {
          periodic += cost.amountE4
          if month == 0 {
            atStart += cost.amountE4.decimal
          } else {
            flows[month, default: 0] += cost.amountE4.decimal
          }
          month += step
        }
      }
    }
    let interest = max(payments - borrowedE4, .zero)
    let overpay = payments + once + periodic - borrowedE4
    let received = borrowedE4.decimal - atStart
    let monthly = lastMonth >= 1 ? (1...lastMonth).map { flows[$0] ?? 0 } : []
    let rate = effectiveRate(
      received: DebtRubles.round(received),
      payments: monthly.map { DebtRubles.round($0) })
    let gap = rate.flatMap { rate in debt.psk.map { rate - $0 } }
    return DebtCostReport(
      principalE4: borrowedE4, paymentsE4: payments, interestE4: interest, costsOnceE4: once,
      costsPeriodicE4: periodic, overpayE4: overpay, effectiveRate: rate, contractPsk: debt.psk,
      pskGap: gap)
  }

  /// The gap past which the worked-out rate and the contract's full cost of credit disagree:
  /// half a percentage point.
  public static let pskTolerance = Decimal(string: "0.5")!

  /// Whether the worked-out rate disagrees with the contract by more than `pskTolerance`.
  public var disagreesWithContract: Bool {
    guard let pskGap else { return false }
    return (pskGap < 0 ? -pskGap : pskGap) > Self.pskTolerance
  }

  /// The monthly internal rate of the flow — `received` at the start, then `payments[k]` in
  /// month k + 1 — × 12 × 100, three digits: the yearly rate the Bank of Russia counts the full
  /// cost of credit by, its base period a month. Found by bisection in `Decimal` (200 steps)
  /// between 0 and 100 % a month; `nil` when no rate in that span makes the flows equal.
  private static let negligible = Decimal(string: "1e-60")!

  public static func effectiveRate(received: AmountE4, payments: [AmountE4]) -> Decimal? {
    guard received.raw > 0, !payments.isEmpty else { return nil }
    let flows = payments.map(\.decimal)
    let start = received.decimal
    // What the payments are worth at the start at a monthly rate: falls as the rate grows.
    func present(_ rate: Decimal) -> Decimal {
      let discount = 1 / (1 + rate)
      var factor = Decimal(1)
      var total = Decimal(0)
      for flow in flows {
        factor *= discount
        // A payment so far away that its share is below 1e-48 of the start counts for nothing;
        // going on would run the factor under the smallest `Decimal`, which traps on Linux.
        if factor < Self.negligible { break }
        total += flow * factor
      }
      return total
    }
    var low = Decimal(0)
    var high = Decimal(1)
    guard present(low) >= start, present(high) <= start else { return nil }
    for _ in 0..<200 {
      let middle = (low + high) / 2
      if present(middle) > start { low = middle } else { high = middle }
      if high - low < Decimal(string: "0.0000000000001")! { break }
    }
    let yearly = (low + high) / 2 * 1200
    return DecimalMath.round(yearly, scale: 3)
  }
}
