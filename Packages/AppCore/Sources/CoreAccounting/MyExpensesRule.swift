import CoreKit
import Foundation

/// A part I paid for somebody else and still expect back — one line of the «Owed to me»
/// list. It is not my spending, and it is the input a reimbursement closes.
public struct OwedPart: Identifiable, Hashable, Sendable {
  public var partId: UUID
  public var transactionId: UUID
  public var occurredAt: Date
  public var debtorPersonId: UUID?
  public var categoryId: UUID?
  public var forWhom: ForWhom
  /// Whom the part was bought for, when that is somebody other than the debtor.
  public var forPersonId: UUID?
  /// The event the purchase belongs to. A shortfall left of the part stays in it.
  public var eventId: UUID?
  /// What I paid, in the currency of the operation. Reimbursements are matched against
  /// this figure, so the money coming back must be in the same currency.
  public var amountE4: AmountE4
  /// The same money in rubles, used by the totals.
  public var amountRubE4: AmountE4
  /// The currency `amountE4` is in — the currency of the operation.
  public var currency: CurrencyCode
  /// The operation still converts at a stand-in rate that the pipeline refines later.
  public var rateProvisional: Bool
  public var note: String?
  /// What already came back for the part, in rubles, through live money back that did not
  /// close it: money back may cover only some of a part, which then keeps waiting for the rest.
  public var returnedRubE4: AmountE4
  /// The account the purchase was paid from: what is left of the part and is written off,
  /// or falls short, is spending from that account.
  public var accountId: UUID?

  public var id: UUID { partId }

  /// What is still owed, in rubles: the part less what already came back.
  public var remainingRubE4: AmountE4 { max(.zero, amountRubE4 - returnedRubE4) }

  public init(
    partId: UUID,
    transactionId: UUID,
    occurredAt: Date,
    debtorPersonId: UUID? = nil,
    categoryId: UUID? = nil,
    forWhom: ForWhom = .me,
    forPersonId: UUID? = nil,
    eventId: UUID? = nil,
    amountE4: AmountE4,
    amountRubE4: AmountE4? = nil,
    currency: CurrencyCode = .rub,
    rateProvisional: Bool = false,
    note: String? = nil,
    returnedRubE4: AmountE4 = .zero,
    accountId: UUID? = nil
  ) {
    self.partId = partId
    self.transactionId = transactionId
    self.occurredAt = occurredAt
    self.debtorPersonId = debtorPersonId
    self.categoryId = categoryId
    self.forWhom = forWhom
    self.forPersonId = forPersonId
    self.eventId = eventId
    self.amountE4 = amountE4
    self.amountRubE4 = amountRubE4 ?? amountE4
    self.currency = currency
    self.rateProvisional = rateProvisional
    self.note = note
    self.returnedRubE4 = returnedRubE4
    self.accountId = accountId
  }

  /// `returned` — the rubles already given back for the part through live money back.
  public init(part: TransactionPart, in transaction: Transaction, returned: AmountE4 = .zero) {
    self.init(
      partId: part.id,
      transactionId: transaction.id,
      occurredAt: transaction.occurredAt,
      debtorPersonId: part.debtorPersonId,
      categoryId: part.categoryId,
      forWhom: part.forWhom,
      forPersonId: part.forPersonId,
      eventId: part.eventId,
      amountE4: part.amountE4,
      amountRubE4: part.amountRubE4,
      currency: transaction.currency,
      rateProvisional: transaction.rateProvisional,
      note: part.note ?? transaction.note,
      returnedRubE4: returned,
      accountId: transaction.paymentMethodId)
  }

  /// What is still owed on the part, in rubles — what a reimbursement settled by hand is
  /// matched against: 50 dollars paid for a friend are owed as the rubles they cost that day,
  /// not as «50» of whatever the friend pays back in, and money that already came back for the
  /// part is never owed again, nor counted short a second time.
  public var inRubles: OwedPart {
    var copy = self
    copy.amountE4 = remainingRubE4
    copy.currency = .rub
    return copy
  }
}

/// Spending split by category, with the parts that carry no category kept apart instead
/// of being silently dropped.
public struct CategoryTotals: Hashable, Sendable {
  public var byCategory: [UUID: AmountE4]
  public var uncategorized: AmountE4

  public init(byCategory: [UUID: AmountE4] = [:], uncategorized: AmountE4 = .zero) {
    self.byCategory = byCategory
    self.uncategorized = uncategorized
  }

  public var total: AmountE4 {
    AmountE4.sum(byCategory.values) + uncategorized
  }

  public subscript(categoryId: UUID) -> AmountE4 {
    byCategory[categoryId] ?? .zero
  }

  /// Folds subcategory totals into their parents, for the analytics that report on
  /// top-level categories only.
  public func rolledUp(with tree: CategoryTree) -> CategoryTotals {
    var rolled: [UUID: AmountE4] = [:]
    for (categoryId, amount) in byCategory {
      let key = tree.root(of: categoryId)?.id ?? categoryId
      rolled[key] = (rolled[key] ?? .zero) + amount
    }
    return CategoryTotals(byCategory: rolled, uncategorized: uncategorized)
  }
}

/// What counts as money I actually spent.
///
/// My spending is every `expense` part that was not paid for somebody else, plus the
/// parts paid for others that I later wrote off, minus refunds of my own purchases.
///
/// Two traps the rules exist to avoid:
///
/// * «Для кого» is an analytics cut only. A present for a friend or a dinner with friends
///   stays my expense; the cut never reduces a total.
/// * A purchase made in instalments is an expense exactly once, at the moment of the
///   purchase. Its later payments only shrink the debt. Payments against a debt that
///   existed before the app work the other way round: they are expenses in Loans.
///
/// Debt balances are not spending at all and never enter these totals — this type only
/// ever looks at operations.
///
/// Every function is pure: the same rules run unchanged in the future Windows port.
public enum MyExpensesRule {

  // MARK: - One part

  /// Does this part add to my expenses?
  ///
  /// `debt` is the debt the *operation* pays off (`transaction.debtId`), `creditDebt` the
  /// debt a purchase was made on (`transaction.creditDebtId`). When an operation points at
  /// a debt it pays off that the caller did not supply, the part is left out: the schema
  /// cannot tell us whether counting it would be double counting, and a purchase must never
  /// count twice.
  public static func isMySpending(
    part: TransactionPart, in transaction: Transaction, debt: Debt? = nil,
    creditDebt: Debt? = nil
  ) -> Bool {
    guard !transaction.isDeleted, transaction.kind == .expense else { return false }
    guard debtAllowsCounting(transaction, debt: debt, creditDebt: creditDebt) else {
      return false
    }
    guard part.reimbursable else { return true }
    // Paid for somebody else: mine only once I gave up on getting it back.
    return part.reimbursementStatus == .writtenOff
  }

  /// The signed contribution of one part to my expenses, in rubles: the amount for
  /// spending, minus the amount for a refund of a purchase, zero for everything else.
  /// Income and reimbursements never contribute — a reimbursement is not income. A refund
  /// part marked as paid for somebody else never contributes either: that money was never
  /// mine.
  public static func contribution(
    part: TransactionPart, in transaction: Transaction, debt: Debt? = nil,
    creditDebt: Debt? = nil
  ) -> AmountE4 {
    if isMySpending(part: part, in: transaction, debt: debt, creditDebt: creditDebt) {
      return part.amountRubE4
    }
    // A refund goes through the same debt gate as the expense it takes back. Without it a
    // refund of a payment that was never an expense — a payment on something bought in
    // instalments, or on a debt the caller did not supply — pushed my spending below zero.
    guard !transaction.isDeleted, transaction.kind == .refund,
      debtAllowsCounting(transaction, debt: debt, creditDebt: creditDebt)
    else { return .zero }
    // A refund of something bought for somebody else takes back money that was never mine.
    // Its status does not matter: only expense parts are ever returned or written off.
    if part.reimbursable { return .zero }
    return -part.amountRubE4
  }

  /// The gate a debt puts on an operation, the same one for an expense and for the refund
  /// that takes it back: money that was never counted as spending cannot be taken off it.
  private static func debtAllowsCounting(
    _ transaction: Transaction, debt: Debt?, creditDebt: Debt?
  ) -> Bool {
    if transaction.debtId != nil {
      // A payment counts only on a debt whose payments are expenses. An unknown debt is
      // left out: the operation alone cannot say whether counting it would count the same
      // purchase twice.
      guard let debt, DebtRules.paymentIsExpense(on: debt) else { return false }
    }
    if transaction.creditDebtId != nil, let creditDebt,
      !DebtRules.purchaseIsExpense(on: creditDebt)
    {
      // That debt records its payments as expenses, so this purchase is counted there.
      // An unknown debt keeps the purchase instead: its payments are left out anyway, so
      // the money is still shown exactly once.
      return false
    }
    return true
  }

  // MARK: - Totals

  public static func total(entries: [TransactionEntry], debts: [UUID: Debt] = [:]) -> AmountE4 {
    var total = AmountE4.zero
    forEachContribution(entries: entries, debts: debts) { _, _, amount in
      total += amount
    }
    return total
  }

  /// Spending by «для кого». The cut splits the same total — it never changes it.
  public static func byForWhom(
    entries: [TransactionEntry], debts: [UUID: Debt] = [:]
  ) -> [ForWhom: AmountE4] {
    var totals: [ForWhom: AmountE4] = [:]
    forEachContribution(entries: entries, debts: debts) { part, _, amount in
      totals[part.forWhom] = (totals[part.forWhom] ?? .zero) + amount
    }
    return totals
  }

  /// Spending by category. A refund lands in the category of the part it refunds, so it
  /// reduces exactly the category that was charged.
  public static func byCategory(
    entries: [TransactionEntry], debts: [UUID: Debt] = [:]
  ) -> CategoryTotals {
    var totals = CategoryTotals()
    forEachContribution(entries: entries, debts: debts) { part, _, amount in
      guard let categoryId = part.categoryId else {
        totals.uncategorized += amount
        return
      }
      totals.byCategory[categoryId] = (totals.byCategory[categoryId] ?? .zero) + amount
    }
    return totals
  }

  /// Spending by quality, for the «Good vs Bad» sections. A part stored with no quality is
  /// resolved the way the ledger resolves it (`QualityResolver`: a goal, my last rating of
  /// the same description, then the category or its parent) — `neutral` only when none of
  /// them says anything, as with no `categories` at all.
  public static func byQuality(
    entries: [TransactionEntry], debts: [UUID: Debt] = [:],
    categories: CategoryTree = CategoryTree()
  ) -> [Quality: AmountE4] {
    let unrated = entries.contains { $0.parts.contains { $0.quality == nil } }
    let history = unrated ? ManualQualityHistory(entries: entries) : .empty
    var totals: [Quality: AmountE4] = [:]
    forEachContribution(entries: entries, debts: debts) { part, transaction, amount in
      let quality =
        part.quality
        ?? QualityResolver.resolve(
          part: part, in: transaction, categories: categories, history: history
        ).quality
      totals[quality] = (totals[quality] ?? .zero) + amount
    }
    return totals
  }

  /// Net progress of every goal: contributions minus refunds taken back out of the goal.
  public static func goalProgress(entries: [TransactionEntry]) -> [UUID: AmountE4] {
    var totals: [UUID: AmountE4] = [:]
    for entry in entries where !entry.transaction.isDeleted {
      let sign: Int
      switch entry.transaction.kind {
      case .expense: sign = 1
      case .refund: sign = -1
      case .income, .reimbursement: continue
      }
      for part in entry.parts {
        guard let goalId = part.goalId else { continue }
        let signed = sign > 0 ? part.amountRubE4 : -part.amountRubE4
        totals[goalId] = (totals[goalId] ?? .zero) + signed
      }
    }
    return totals
  }

  // MARK: - Owed to me

  /// The parts I paid for other people and have not been paid back for yet, oldest first.
  /// A part that was already returned or written off has left the list.
  ///
  /// Money back may cover only some of a part: the part keeps waiting, with what came back
  /// in `returnedRubE4` and the rest in `remainingRubE4`, and leaves the list only once nothing
  /// is left. A link counts while its money back is live: one whose money back is among
  /// `entries` and deleted — or is no money back — is passed over, and one whose money back
  /// is not among them is taken as the caller gives it.
  public static func owedToMe(
    entries: [TransactionEntry], links: [ReimbursementLink] = []
  ) -> [OwedPart] {
    var gone: Set<UUID> = []
    for entry in entries
    where entry.transaction.isDeleted || entry.transaction.kind != .reimbursement {
      gone.insert(entry.id)
    }
    var returned: [UUID: AmountE4] = [:]
    for link in links where !gone.contains(link.reimbursementTxId) {
      returned[link.partId, default: .zero] += link.amountE4
    }
    var result: [OwedPart] = []
    for entry in entries where !entry.transaction.isDeleted {
      guard entry.transaction.kind == .expense else { continue }
      for part in entry.parts where part.reimbursable {
        guard (part.reimbursementStatus ?? .expected) == .expected else { continue }
        let owed = OwedPart(part: part, in: entry.transaction, returned: returned[part.id] ?? .zero)
        guard owed.remainingRubE4.raw > 0 else { continue }
        result.append(owed)
      }
    }
    return result.sorted(by: oldestFirst)
  }

  /// What the parts still waiting come to, in rubles: what is left of each.
  public static func totalOwedToMe(
    entries: [TransactionEntry], links: [ReimbursementLink] = []
  ) -> AmountE4 {
    AmountE4.sum(owedToMe(entries: entries, links: links).map(\.remainingRubE4))
  }

  /// Oldest first, with a stable tiebreaker so the order never depends on hashing.
  public static func oldestFirst(_ left: OwedPart, _ right: OwedPart) -> Bool {
    if left.occurredAt != right.occurredAt { return left.occurredAt < right.occurredAt }
    return left.partId.uuidString < right.partId.uuidString
  }

  // MARK: - Shared walk

  private static func forEachContribution(
    entries: [TransactionEntry],
    debts: [UUID: Debt],
    body: (TransactionPart, Transaction, AmountE4) -> Void
  ) {
    for entry in entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted else { continue }
      let debt = transaction.debtId.flatMap { debts[$0] }
      let creditDebt = transaction.creditDebtId.flatMap { debts[$0] }
      for part in entry.parts {
        let amount = contribution(
          part: part, in: transaction, debt: debt, creditDebt: creditDebt)
        guard !amount.isZero else { continue }
        body(part, transaction, amount)
      }
    }
  }
}
