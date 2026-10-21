import CoreKit
import Foundation

/// What a set of operations comes to: one day of the list, the operations selected in it,
/// the text of the dialog that deletes them. One function for all three, so the
/// header of a day, the bar under that day selected whole and the confirmation that deletes
/// it can never disagree.
///
/// Four sums, all in rubles, deleted operations left out:
///
/// * `myExpenses` — `MyExpensesRule.contribution` of every part: a refund goes in with a
///   minus, a part paid for somebody else stays out until it is written off, a payment on
///   something bought in instalments stays out altogether. A refund taken back from a purchase
///   counts in the purchase instead (`RefundIndex`): the purchase comes in cheaper, and the
///   refund itself adds nothing — so a day, a selection and the Overview agree;
/// * `income` — operations of kind `income`, a surplus in Surcharges among them;
/// * `forOthers` — parts of purchases paid for somebody else that were not written off:
///   money I laid out that is not my spending;
/// * `moneyReturned` — reimbursements, the money people gave back. It is neither income nor
///   spending, so it is kept apart and never added to either.
public struct RowTotals: Hashable, Sendable {
  public enum Group: String, CaseIterable, Hashable, Sendable {
    case myExpenses
    case income
    case forOthers
    case moneyReturned
  }

  public var myExpenses: AmountE4
  public var income: AmountE4
  public var forOthers: AmountE4
  public var moneyReturned: AmountE4

  public static let zero = RowTotals()

  public init(
    myExpenses: AmountE4 = .zero,
    income: AmountE4 = .zero,
    forOthers: AmountE4 = .zero,
    moneyReturned: AmountE4 = .zero
  ) {
    self.myExpenses = myExpenses
    self.income = income
    self.forOthers = forOthers
    self.moneyReturned = moneyReturned
  }

  /// `debts` decides whether a payment on a debt is spending (`MyExpensesRule`); closed
  /// debts belong in it too, or closing a loan would change the days it was paid on.
  /// `refunds` are the refunds of the whole ledger, not only of `entries`: a purchase shows
  /// what its refunds took back whether or not they are among the operations summed.
  public init(
    entries: some Sequence<TransactionEntry>, debts: [UUID: Debt] = [:],
    refunds: RefundIndex = .empty
  ) {
    self.init()
    for entry in entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted else { continue }
      switch transaction.kind {
      case .income:
        income += transaction.amountRubE4
      case .reimbursement:
        moneyReturned += transaction.amountRubE4
      case .expense, .refund:
        let debt = transaction.debtId.flatMap { debts[$0] }
        let creditDebt = transaction.creditDebtId.flatMap { debts[$0] }
        for part in entry.parts {
          if refunds.isLinked(refundPart: part.id) { continue }
          myExpenses +=
            MyExpensesRule.contribution(
              part: part, in: transaction, debt: debt, creditDebt: creditDebt)
            + refunds.movedContribution(part: part.id)
          if transaction.kind == .expense, part.reimbursable,
            part.reimbursementStatus != .writtenOff
          {
            forOthers += part.amountRubE4
          }
        }
      }
    }
  }

  public subscript(group: Group) -> AmountE4 {
    switch group {
    case .myExpenses: myExpenses
    case .income: income
    case .forOthers: forOthers
    case .moneyReturned: moneyReturned
    }
  }

  /// The groups worth showing, in a fixed order: an empty one says nothing.
  public var nonEmptyGroups: [Group] {
    Group.allCases.filter { !self[$0].isZero }
  }

  public var isEmpty: Bool { nonEmptyGroups.isEmpty }

  /// The totals of two lists of rows taken together: group by group.
  public static func + (lhs: RowTotals, rhs: RowTotals) -> RowTotals {
    RowTotals(
      myExpenses: lhs.myExpenses + rhs.myExpenses, income: lhs.income + rhs.income,
      forOthers: lhs.forOthers + rhs.forOthers,
      moneyReturned: lhs.moneyReturned + rhs.moneyReturned)
  }
}
