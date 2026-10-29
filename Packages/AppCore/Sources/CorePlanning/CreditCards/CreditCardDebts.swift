import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// A credit card that became a debt, as «Долги» and the tab of its bank show it: one line per
/// card. A view only — the money is the card's balance on its account and is counted there
/// once; the line is in no total of the debts, the capital or the free sum.
public struct CreditCardDebtLine: Hashable, Sendable, Identifiable {
  public var accountId: UUID
  public var name: String
  public var bankId: UUID?
  public var currency: CurrencyCode
  /// All the card owes, in its currency.
  public var debtE4: AmountE4
  /// The same in rubles, when the rate is known.
  public var debtRub: AmountE4?
  /// The due day of the statement that was missed.
  public var missedDue: DateOnly?
  /// The interest the card likely charges: an estimate («≈»), never money.
  public var estimateE4: AmountE4?
  public var overLimitE4: AmountE4

  public var id: UUID { accountId }

  public init(
    accountId: UUID, name: String, bankId: UUID? = nil, currency: CurrencyCode, debtE4: AmountE4,
    debtRub: AmountE4? = nil, missedDue: DateOnly? = nil, estimateE4: AmountE4? = nil,
    overLimitE4: AmountE4 = .zero
  ) {
    self.accountId = accountId
    self.name = name
    self.bankId = bankId
    self.currency = currency
    self.debtE4 = debtE4
    self.debtRub = debtRub
    self.missedDue = missedDue
    self.estimateE4 = estimateE4
    self.overLimitE4 = overLimitE4
  }
}

public enum CreditCardDebts {
  /// The cards in debt, the largest debt in rubles first, then by name. An archived card, one
  /// without a line in the accounts, a card within its grace period, and one that a live debt
  /// of the kind credit card I owe already stands for under the same name are left out.
  public static func lines(
    states: [UUID: CreditCardState], accounts: AccountsSnapshot, debts: [Debt] = []
  ) -> [CreditCardDebtLine] {
    let named = Set(
      debts.filter {
        $0.type == .creditCard && $0.direction == .iOwe && !$0.isDeleted && !$0.closed
      }
      .map { NameKey.fold($0.name) })
    var result: [CreditCardDebtLine] = []
    for (accountId, state) in states where state.isDebt {
      guard let line = accounts.line(of: accountId), line.account.isCreditCard,
        !line.account.archived, !named.contains(NameKey.fold(line.account.name))
      else { continue }
      let currency = line.account.mainCurrency
      result.append(
        CreditCardDebtLine(
          accountId: accountId, name: line.account.name, bankId: line.account.bankId,
          currency: currency, debtE4: state.debtE4,
          debtRub: rubles(state.debtE4, currency: currency, line: line),
          missedDue: state.missedDue,
          estimateE4: state.estimate.map(\.shownE4).flatMap { $0.raw > 0 ? $0 : nil },
          overLimitE4: state.overLimitE4))
    }
    return result.sorted {
      let (left, right) = ($0.debtRub ?? .zero, $1.debtRub ?? .zero)
      return left != right ? left > right : $0.name < $1.name
    }
  }

  /// `amount` in rubles at the rate the balance of the account is shown at; `nil` without one.
  static func rubles(
    _ amount: AmountE4, currency: CurrencyCode, line: AccountsSnapshot.AccountLine
  ) -> AmountE4? {
    if currency == .rub { return amount }
    guard let key = line.keys.first(where: { $0.key.currency == currency }),
      let balance = key.balance, let rub = key.rub, !balance.isZero
    else { return nil }
    return InterestMath.cents(amount.decimal * rub.decimal / balance.decimal)
  }
}
