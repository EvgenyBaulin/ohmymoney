import CoreKit
import Foundation

/// The answers the synthetic history is known to have, month by month.
///
/// The generator keeps them itself while it writes each operation: it knows what it meant
/// by it — my purchase, a refund, a part for a friend that will be written off, a payment
/// on something bought in instalments — and adds the money to the right figure there and
/// then. Nothing here reads the operations back through `MyExpensesRule`, the `Ledger` or
/// any other rule of the app, so the analytics can be checked against it rather than
/// against themselves. Deleted operations add nothing.
///
/// Spending figures belong to the month of the date; income to the month it is for
/// (`period_month`, otherwise the month of the date); the money paid for others to the
/// month of the purchase, whenever it came back.
public struct SampleExpectations: Hashable, Sendable {
  /// Parts of purchases paid for somebody else, by what became of them.
  public struct ForOthers: Hashable, Sendable {
    public var paid: AmountE4 = .zero
    /// What reimbursements brought back for these parts, in rubles.
    public var returned: AmountE4 = .zero
    public var writtenOff: AmountE4 = .zero
    public var waiting: AmountE4 = .zero
    /// How much less than a part came back before it was closed.
    public var shortfall: AmountE4 = .zero

    public init() {}
  }

  public struct Month: Hashable, Sendable {
    /// My expenses of the operations dated in the month.
    public var myExpenses: AmountE4 = .zero
    /// The same money by top-level category; the `nil` key holds the parts without one.
    public var byRootCategory: [UUID?: AmountE4] = [:]
    /// The same money by quality: the stored one, or the one the rules give a part that
    /// has none.
    public var byQuality: [Quality: AmountE4] = [:]
    public var forOthers = ForOthers()
    /// Income that belongs to the month.
    public var income: AmountE4 = .zero
    /// The surplus of reimbursements — income in Surcharges — that belongs to the month.
    public var surplus: AmountE4 = .zero
    /// Cashback that belongs to the month, by the payment method it came to.
    public var cashbackByMethod: [UUID: AmountE4] = [:]

    public init() {}
  }

  public private(set) var months: [MonthKey: Month] = [:]

  public init() {}

  public subscript(month: MonthKey) -> Month { months[month] ?? Month() }

  /// Every month something was recorded for, oldest first.
  public var monthKeys: [MonthKey] { months.keys.sorted() }

  // MARK: - Recording, as the generator writes

  /// My spending (a refund comes with a minus).
  mutating func spend(_ amount: AmountE4, in month: MonthKey, root: UUID?, quality: Quality) {
    months[month, default: Month()].myExpenses += amount
    months[month, default: Month()].byRootCategory[root, default: .zero] += amount
    months[month, default: Month()].byQuality[quality, default: .zero] += amount
  }

  /// A part bought for somebody else. A written-off part is my spending too, and the
  /// caller adds it through `spend`; a returned one is settled by `settle`.
  mutating func payForOthers(
    _ amount: AmountE4, in month: MonthKey, status: ReimbursementStatus
  ) {
    months[month, default: Month()].forOthers.paid += amount
    switch status {
    case .expected: months[month, default: Month()].forOthers.waiting += amount
    case .writtenOff: months[month, default: Month()].forOthers.writtenOff += amount
    case .returned: break
    }
  }

  /// A reimbursement closed a part bought in `month`: what its link carries came back, the
  /// rest of the part is the shortfall.
  mutating func settle(returned: AmountE4, shortfall: AmountE4, purchasedIn month: MonthKey) {
    months[month, default: Month()].forOthers.returned += returned
    months[month, default: Month()].forOthers.shortfall += shortfall
  }

  /// Money back covered only some of a part bought in `month`: what came back is returned,
  /// and the part waits for the rest of it — no shortfall, since it is still owed.
  mutating func settlePartly(returned: AmountE4, purchasedIn month: MonthKey) {
    months[month, default: Month()].forOthers.returned += returned
    let waiting = months[month, default: Month()].forOthers.waiting
    months[month, default: Month()].forOthers.waiting = waiting - returned
  }

  mutating func receive(
    _ amount: AmountE4, for month: MonthKey, cashbackTo method: UUID? = nil,
    isSurplus: Bool = false
  ) {
    months[month, default: Month()].income += amount
    if let method {
      months[month, default: Month()].cashbackByMethod[method, default: .zero] += amount
    }
    if isSurplus { months[month, default: Month()].surplus += amount }
  }
}
