import CoreAccounting
import CoreKit
import Foundation

/// What the owner spent with someone else's card (`BorrowedCardTerms`): the figure its screen
/// shows instead of a balance, and the cut «с чужой карты <имя>» of the spending.
///
/// The spending is the owner's, counted the way «Мои расходы» counts it
/// (`LedgerRow.contribution`): purchases less refunds, parts paid for others and still expected
/// back left out. Only the account it was paid from is new here; the totals of the month,
/// the categories and the limits already hold the same money.
public enum BorrowedCardSpending {
  /// One card and what was spent with it.
  public struct Line: Hashable, Sendable {
    public var account: PaymentMethod
    /// Whose card it is, when said.
    public var personId: UUID?
    /// My expenses paid with the card, in rubles.
    public var spentRub: AmountE4

    public init(account: PaymentMethod, personId: UUID?, spentRub: AmountE4) {
      self.account = account
      self.personId = personId
      self.spentRub = spentRub
    }
  }

  /// My expenses paid with `accountId` on the days of `range`, by date, in rubles.
  public static func spent(ledger: Ledger, accountId: UUID, in range: DayRange) -> AmountE4 {
    AmountE4.sum(
      ledger.rows(in: range).lazy.filter { $0.paymentMethodId == accountId }.map(\.contribution))
  }

  /// «Потрачено за месяц»: my expenses paid with `accountId` in `month`, by date, in rubles.
  public static func spent(ledger: Ledger, accountId: UUID, month: MonthKey) -> AmountE4 {
    spent(ledger: ledger, accountId: accountId, in: DayRange(month.firstDay, month.lastDay))
  }

  /// Every card of someone else's the owner spent with on the days of `range`, the largest
  /// spending first (by name on a tie); a card with nothing spent is left out. Archived cards
  /// count: what was bought with them was still bought.
  public static func lines(
    ledger: Ledger, accounts: [PaymentMethod], in range: DayRange
  ) -> [Line] {
    let borrowed = Dictionary(
      accounts.filter(\.isBorrowed).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard !borrowed.isEmpty else { return [] }
    var spent: [UUID: AmountE4] = [:]
    for row in ledger.rows(in: range) {
      guard let id = row.paymentMethodId, borrowed[id] != nil else { continue }
      spent[id, default: .zero] += row.contribution
    }
    return spent.compactMap { id, amount -> Line? in
      guard let account = borrowed[id], !amount.isZero else { return nil }
      return Line(account: account, personId: account.borrowed?.personId, spentRub: amount)
    }
    .sorted { left, right in
      left.spentRub != right.spentRub
        ? left.spentRub > right.spentRub : left.account.name < right.account.name
    }
  }
}
