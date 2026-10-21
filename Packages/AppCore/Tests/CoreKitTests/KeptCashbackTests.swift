import Foundation
import Testing

@testable import CoreKit

/// The cashback the owner typed for one operation is kept only where it means something: on an
/// expense, in the currency that moved on the account. A write that changes what moved drops
/// it, since a figure in money the account no longer moved says nothing.
@Suite("The owner's cashback of one operation is kept as the write keeps it")
struct KeptCashbackTests {
  private let at = Date(timeIntervalSince1970: 1_790_000_000)

  private func operation(
    _ kind: TransactionKind = .expense, currency: CurrencyCode = .rub,
    accountCurrency: CurrencyCode? = nil, accountAmount: AmountE4? = nil, cashback: Money?
  ) -> Transaction {
    Transaction(
      kind: kind, occurredAt: at, currency: currency, amountE4: AmountE4(whole: 1_000),
      accountCurrency: accountCurrency, accountAmountE4: accountAmount, cashback: cashback)
  }

  private func money(_ whole: Int64, _ currency: CurrencyCode = .rub) -> Money {
    Money(amount: AmountE4(whole: whole), currency: currency)
  }

  @Test func anExpenseInTheMovedCurrencyKeepsIt() {
    #expect(operation(cashback: money(45)).keptCashback == money(45))
    #expect(operation(cashback: money(0)).keptCashback == money(0))
  }

  @Test func anotherCurrencyDropsIt() {
    #expect(operation(cashback: money(45, .usd)).keptCashback == nil)
  }

  /// With a leg, what moved is the leg: rubles on a ruble account paying dollars.
  @Test func theLegIsWhatMoved() {
    let paid = operation(
      currency: .usd, accountCurrency: .rub, accountAmount: AmountE4(whole: 92_000),
      cashback: money(920))
    #expect(paid.movedMoney.currency == .rub)
    #expect(paid.keptCashback == money(920))
    let inDollars = operation(
      currency: .usd, accountCurrency: .rub, accountAmount: AmountE4(whole: 92_000),
      cashback: money(10, .usd))
    #expect(inDollars.keptCashback == nil)
  }

  @Test func anotherKindDropsIt() {
    for kind in [TransactionKind.income, .refund, .reimbursement] {
      #expect(operation(kind, cashback: money(45)).keptCashback == nil, "\(kind)")
    }
  }

  @Test func noCashbackIsNone() {
    #expect(operation(cashback: nil).keptCashback == nil)
  }

  /// The database takes no cashback below zero, so none is ever kept.
  @Test func belowZeroIsDropped() {
    #expect(
      operation(cashback: Money(amount: AmountE4(raw: -1), currency: .rub)).keptCashback == nil)
  }
}
