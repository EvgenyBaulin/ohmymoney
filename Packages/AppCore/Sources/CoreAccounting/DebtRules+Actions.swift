import CoreKit
import Foundation

/// Why an action of the debt card could not be turned into a journal line.
public enum DebtActionError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The balance typed into «Adjust» is the balance the debt already has: the line would
  /// be a zero, which the journal has no use for.
  case nothingToAdjust
  /// The difference between the two balances does not fit into stored units.
  case amountOutOfRange

  public var description: String {
    switch self {
    case .nothingToAdjust: return "The new balance is the balance the debt already has."
    case .amountOutOfRange: return "The difference between the balances is out of range."
    }
  }
}

/// The actions of the debt card («Pay», «Adjust», «Close», a share typed
/// as «1/2»). They only build what is to be written — drafts and journal lines — and reuse
/// the signs and the payment rules of `DebtRules`, so the card and the entry line can never
/// disagree on what a payment is.
extension DebtRules {

  // MARK: - Pay

  /// The kind of operation «Pay» writes.
  ///
  /// On a debt I owe the money leaves me, so it is an expense. Whether it is also *my
  /// spending* is not decided here: `MyExpensesRule` looks at the debt the operation pays
  /// (`paymentIsExpense`), so a payment on something bought in instalments stays out of the
  /// totals while a payment on a loan I already had counts in Loans.
  ///
  /// On a debt owed to me the money comes back to me. That is a reimbursement — the same kind
  /// a friend's money for a dinner I paid is — and a reimbursement is neither income nor
  /// spending: lending money was never an expense, so getting it back is not income.
  public static func paymentKind(for debt: Debt) -> TransactionKind {
    debt.direction == .iOwe ? .expense : .reimbursement
  }

  /// The operation «Pay» offers in the panel, in the currency of the debt.
  ///
  /// * A debt I owe: an expense in the Loans subcategory of the debt, or in the Loans root
  ///   (`loansCategoryId`) while the debt has no subcategory of its own yet. The category is
  ///   the system's choice, not the owner's. The quality is left to the usual rules
  ///   (`QualityResolver`), which give the neutral of Loans unless the owner decided
  ///   otherwise.
  /// * A debt owed to me: a reimbursement without a category — money given back has none —
  ///   naming the person, like the reimbursement sheet does.
  ///
  /// Either way the operation points at the debt (`debtId`), which is how the payment rules
  /// and «paid this month» find it. The amount is taken without its sign.
  public static func paymentDraft(
    debt: Debt, amount: AmountE4, occurredAt: Date, paymentMethodId: UUID?,
    loansCategoryId: UUID?
  ) -> TransactionDraft {
    let kind = paymentKind(for: debt)
    let money = amount.magnitude
    var part = PartDraft(amount: money)
    switch kind {
    case .expense:
      part.categoryId = debt.loansSubcategoryId ?? loansCategoryId
      if part.categoryId != nil { part.categorySource = .system }
    default:
      part.forPersonId = debt.personId
    }
    return TransactionDraft(
      kind: kind, occurredAt: occurredAt, currency: debt.currency, amount: money,
      paymentMethodId: paymentMethodId, debtId: debt.id, parts: [part])
  }

  // MARK: - Adjust and close

  /// «Adjust»: the owner types what the balance really is, and the journal gains the
  /// difference, new − old, as one signed `adjustment` line. The journal stays the only
  /// truth of the balance: nothing overwrites it, and the correction can be seen and undone.
  public static func adjustment(
    on debt: Debt, from balance: AmountE4, to newBalance: AmountE4, date: DateOnly? = nil,
    note: String? = nil, entryId: UUID = UUID()
  ) throws -> DebtEntry {
    let (raw, overflow) = newBalance.raw.subtractingReportingOverflow(balance.raw)
    guard !overflow else { throw DebtActionError.amountOutOfRange }
    guard raw != 0 else { throw DebtActionError.nothingToAdjust }
    return makeEntry(
      id: entryId, debtId: debt.id, kind: .adjustment, amountE4: AmountE4(raw: raw), date: date,
      note: note)
  }

  /// «Close»: the debt moves to the closed list. What is left on it stays in the journal
  /// unless the owner asks to write it off — then one `adjustment` of −balance brings it to
  /// zero, so a closed debt never shows money that nobody is going to pay. Closing never
  /// touches operations: the payments of a closed loan stay in their months.
  public static func closing(
    _ debt: Debt, balance: AmountE4, writeOffRemainder: Bool, date: DateOnly? = nil,
    entryId: UUID = UUID()
  ) -> (debt: Debt, entry: DebtEntry?) {
    var closed = debt
    closed.closed = true
    guard writeOffRemainder, !balance.isZero else { return (closed, nil) }
    let entry = makeEntry(
      id: entryId, debtId: debt.id, kind: .adjustment, amountE4: -balance, date: date)
    return (closed, entry)
  }

  // MARK: - A share typed by hand

  /// The share of «full amount 1 000 000, share 1/2», as the owner types it: a fraction
  /// («1/2», « 1 / 3 »), a decimal with either separator («0.5», «0,5») or a percentage
  /// («50%», «33,3 %»). `nil` for anything else and for a share outside (0, 1] — the range
  /// `share(of:share:)` accepts. A fraction is divided exactly in `Decimal`, so «1/3» of 100
  /// is 33.3333, the same as `Decimal(1) / Decimal(3)`.
  public static func parseShare(_ text: String) -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let value: Decimal?
    if trimmed.hasSuffix("%") {
      value = DecimalMath.parse(String(trimmed.dropLast())).map { $0 / 100 }
    } else if let slash = trimmed.firstIndex(of: "/") {
      // `DecimalMath.parse` refuses a second slash, so «1/2/3» is not a share.
      guard let numerator = DecimalMath.parse(String(trimmed[..<slash])),
        let denominator = DecimalMath.parse(String(trimmed[trimmed.index(after: slash)...])),
        denominator != 0
      else { return nil }
      value = numerator / denominator
    } else {
      value = DecimalMath.parse(trimmed)
    }
    guard let value, value > 0, value <= 1 else { return nil }
    return value
  }
}
