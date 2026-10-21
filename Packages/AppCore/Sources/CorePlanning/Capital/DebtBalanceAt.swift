import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The balance of a debt at the end of a day, in the debt's currency: its journal lines dated
/// on or before the day (a line without a day or a moment always counts), plus the interest a loan that
/// accrues it has charged through the day (`DebtInterest`). Through today it is the balance
/// the Debts screen shows.
public enum DebtBalanceAt {
  /// What a debt owes at the end of a day: `balance` as above, and the interest accrued since
  /// the last payment and not paid yet (`accruedE4`, zero for a debt that does not accrue it),
  /// which the bank asks for on top of the balance.
  public struct Owed: Hashable, Sendable {
    public var balance: AmountE4
    public var accruedE4: AmountE4

    public init(balance: AmountE4, accruedE4: AmountE4) {
      self.balance = balance
      self.accruedE4 = accruedE4
    }
  }

  public static func balance(
    of debt: Debt, journal: [DebtEntry], through day: DateOnly, calendar: CalendarContext
  ) -> AmountE4 {
    owed(of: debt, journal: journal, through: day, calendar: calendar).balance
  }

  /// The balance and the unpaid interest of the debt at the end of `day`, read once.
  public static func owed(
    of debt: Debt, journal: [DebtEntry], through day: DateOnly, calendar: CalendarContext
  ) -> Owed {
    // A line written with a moment and no day is dated by that moment, as the dues read it.
    let dated = journal.filter { line in
      guard line.debtId == debt.id else { return false }
      guard let lineDay = line.date ?? line.occurredAt.map(calendar.day(of:)) else { return true }
      return lineDay <= day
    }
    var balance = DebtRules.balance(entries: dated)
    var accrued = AmountE4.zero
    if let interest = DebtInterest.read(
      debt: debt, journal: dated, through: day, calendar: calendar)
    {
      balance += DebtRules.balance(entries: interest.lines)
      accrued = interest.accruedE4
    }
    return Owed(balance: balance, accruedE4: accrued)
  }
}
