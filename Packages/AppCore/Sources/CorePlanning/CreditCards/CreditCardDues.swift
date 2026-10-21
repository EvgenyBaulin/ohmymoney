import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What the credit cards out of the summary ask to be paid by a day: the free sum keeps it
/// back, while the minus of a card in the summary is in the money already.
public enum CreditCardDues {
  /// The sums «without interest» of the statements due by `until` of the credit cards out of
  /// the summary, in rubles: of each card only its latest statement counts — a later statement
  /// holds what an earlier one left unpaid —, by what is left of it to pay. A card in the
  /// summary adds nothing: its minus is already in the money now. A card in another currency
  /// is converted at the rate its balance is shown in rubles today; without one it adds
  /// nothing.
  public static func outOfSummary(
    accounts: AccountsSnapshot, statements: [UUID: [CreditStatement]], today: DateOnly,
    until: DateOnly
  ) -> AmountE4 {
    var total = AmountE4.zero
    for (accountId, list) in statements {
      guard let line = accounts.line(of: accountId), line.account.isCreditCard,
        !line.account.archived, !accounts.isInSummary(accountId),
        let last = list.max(by: { $0.closesOn < $1.closesOn }), last.due <= until
      else { continue }
      let left = last.remainingE4
      guard left.raw > 0 else { continue }
      let currency = line.account.mainCurrency
      if currency == .rub {
        total += left
        continue
      }
      guard let key = line.keys.first(where: { $0.key.currency == currency }),
        let balance = key.balance, let rub = key.rub, !balance.isZero
      else { continue }
      total += InterestMath.cents(left.decimal * rub.decimal / balance.decimal)
    }
    return total
  }
}
