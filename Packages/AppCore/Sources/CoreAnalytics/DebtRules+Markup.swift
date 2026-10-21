import CoreAccounting
import CoreKit
import Foundation

/// The markup of an instalment plan, spent part by part: each payment carries the share of the
/// markup of the dues it closes (`InstalmentPlan.markupShares`), the rest of it lowers the price.
/// A payment that closes no due carries none yet.
public enum DebtMarkup {
  /// The prefix of the key of the markup operation of a payment: `debtmarkup:<payment>:<itself>`.
  public static let keyPrefix = "debtmarkup:"

  /// `payment` parted into the markup of the dues it closes (`interestE4`) and the price
  /// (`principalE4`). `dues` is the state of the plan before the payment; `journal` its lines.
  /// A debt without a markup, or that is no instalment plan, is all principal.
  public static func split(
    payment: AmountE4, debt: Debt, journal: [DebtEntry], dues: DebtDueState
  ) -> DebtPaymentSplit {
    let money = payment.magnitude
    guard debt.isInstalmentPlan, let markup = debt.markupE4, markup.raw > 0,
      let count = debt.parts, count >= 1
    else { return DebtPaymentSplit(interestE4: .zero, principalE4: money) }
    let shares = InstalmentPlan.markupShares(markup: markup, count: count)
    let instalments =
      dues.instalments.isEmpty
      ? InstalmentPlan.instalments(
        debt: debt, price: InstalmentPlan.price(of: debt, journal: journal))
      : dues.instalments
    var kept = dues.partialE4 + money
    var index = dues.paidCount
    var carried = AmountE4.zero
    while index < count {
      let amount = instalments.amount(at: index)
      guard amount.raw > 0, kept + DebtDues.tolerance(of: amount) >= amount else { break }
      kept = max(kept - amount, .zero)
      carried += shares[index]
      index += 1
    }
    let interest = min(carried, money)
    return DebtPaymentSplit(interestE4: interest, principalE4: money - interest)
  }

  /// The key of the markup operation `markup` of the payment `payment`.
  public static func key(ofPayment payment: UUID, markup: UUID) -> String {
    keyPrefix + payment.uuidString.lowercased() + ":" + markup.uuidString.lowercased()
  }

  /// The payment a markup operation's key names; `nil` for any other key.
  public static func payment(ofKey key: String?) -> UUID? {
    guard let key, key.hasPrefix(keyPrefix) else { return nil }
    let fields = key.dropFirst(keyPrefix.count).split(separator: ":")
    guard fields.count == 2 else { return nil }
    return UUID(uuidString: String(fields[0]))
  }
}
