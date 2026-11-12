import CoreKit
import Foundation

/// Money put aside: net goal contributions and transfers across the boundary of saving accounts.
/// Transfers between saving accounts do not save the same money twice. Foreign transfers stay
/// out until a ruble valuation is available.
public struct SavingsTotals: Hashable, Sendable {
  public var goals: AmountE4
  public var accounts: AmountE4
  public var income: AmountE4
  public var leftOutForeign: Int

  public var saved: AmountE4 { goals + accounts }
  /// Basis points, rounded half away from zero; absent without positive income.
  public var basisPoints: Int? { Shares.ratio(saved, of: income) }

  /// The whole month, including income attributed to it even when received in another month.
  public static func month(ledger: Ledger, month: MonthKey) -> SavingsTotals {
    SavingsTotals(
      ledger: ledger, in: Period.month(month).range, income: ledger.income(attributedTo: [month]))
  }

  public init(ledger: Ledger, in span: DayRange, income: AmountE4) {
    self.income = income
    goals = Self.netGoalContributions(ledger: ledger, in: span)
    let savers = Set(
      ledger.dataset.paymentMethods.filter { $0.cushion || $0.interest != nil }.map(\.id))
    var net = AmountE4.zero
    var foreign = 0
    for transfer in ledger.dataset.transfers
    where span.contains(ledger.calendar.day(of: transfer.occurredAt)) {
      let into = savers.contains(transfer.toAccountId)
      let out = savers.contains(transfer.fromAccountId)
      guard into != out else { continue }
      if into {
        if transfer.toCurrency == .rub { net += transfer.toAmountE4 } else { foreign += 1 }
      } else {
        if transfer.fromCurrency == .rub { net = net - transfer.fromAmountE4 } else { foreign += 1 }
      }
    }
    accounts = net
    leftOutForeign = foreign
  }

  /// Goal withdrawals count on their own date, even when linked to an earlier contribution.
  /// Expense contributions have already had linked refunds deducted, so use the gross amounts.
  public static func netGoalContributions(ledger: Ledger, in span: DayRange) -> AmountE4 {
    var total = AmountE4.zero
    for row in ledger.rows(in: span) where row.isGoalContribution {
      switch row.kind {
      case .expense: total += row.amountRubE4
      case .refund: total += -row.amountRubE4
      case .income, .reimbursement: continue
      }
    }
    return total
  }
}
