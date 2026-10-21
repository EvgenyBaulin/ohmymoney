import CoreKit
import Foundation

/// What deleting a debt writes and what it leaves, worked out before anything is written.
///
/// A debt is deleted softly: it is stamped with the moment (`deleted_at`) and leaves every list,
/// reminder, due date, the free sum and the pickers, while every operation that points at it
/// keeps pointing at it. That is what keeps the figures right: a payment on a purchase made on
/// credit is not spending only while it names its debt, a purchase on credit moves no money on
/// the account only while it does, and the money the journal alone lent or borrowed stays in the
/// balances of the accounts.
public struct DebtDeletion: Hashable, Sendable {
  /// What the operations that paid the debt were, and stay.
  public enum PaymentMeaning: Hashable, Sendable {
    /// A debt I owe whose payments are spending in «Кредиты».
    case loansExpense
    /// A debt I owe whose payments only lowered it: the purchase was the spending.
    case notSpending
    /// A debt owed to me: money lent and given back, never income or spending.
    case moneyBack
  }

  /// The debt with its moment of deletion.
  public var debt: Debt
  /// Its live subcategory of «Кредиты», archived; `nil` when there is none live.
  public var archivedSubcategory: CoreKit.Category?
  /// The lines of its journal.
  public var journalLines: Int
  /// The lines that moved money on an account by themselves.
  public var movesMoneyLines: Int
  /// The live operations that name it as the debt they paid or grew.
  public var operations: Int
  public var meaning: PaymentMeaning
  /// The live purchases made on it on credit.
  public var creditPurchases: [TransactionEntry]
  /// What was left on it, in its currency.
  public var balance: AmountE4

  /// A debt owed to me with money still owed on it: if the person pays it back after all, the
  /// money is income — there is no debt left for it to repay. The confirmation says so.
  public var warnsOfIncomeLater: Bool { meaning == .moneyBack && balance.raw > 0 }

  public init(
    debt: Debt, archivedSubcategory: CoreKit.Category?, journalLines: Int, movesMoneyLines: Int,
    operations: Int, meaning: PaymentMeaning, creditPurchases: [TransactionEntry],
    balance: AmountE4
  ) {
    self.debt = debt
    self.archivedSubcategory = archivedSubcategory
    self.journalLines = journalLines
    self.movesMoneyLines = movesMoneyLines
    self.operations = operations
    self.meaning = meaning
    self.creditPurchases = creditPurchases
    self.balance = balance
  }
}

extension DebtRules {
  /// Deleting `debt`: nothing is written but the debt stamped with `instant` and its live
  /// subcategory of «Кредиты» sent to the archive — operations filed under it keep it, and the
  /// pickers stop offering the name of a debt that is gone. The rest says what stays, for the
  /// confirmation.
  public static func deletion(
    of debt: Debt, journal: [DebtEntry], entries: [TransactionEntry], tree: CategoryTree,
    mainAccountId: UUID?, calendar: CalendarContext, at instant: Date
  ) -> DebtDeletion {
    var deleted = debt
    deleted.deletedAt = instant
    let lines = journal.filter { $0.debtId == debt.id }
    var openings = AccountBalances.creditOpenings(entries, calendar: calendar)
    let movesMoney = lines.filter {
      AccountBalances.journalMovement(
        of: $0, debt: debt, mainId: mainAccountId, openings: &openings, calendar: calendar)
        != nil
    }.count
    let live = entries.filter { !$0.transaction.isDeleted }
    let meaning: DebtDeletion.PaymentMeaning =
      debt.direction == .owedToMe
      ? .moneyBack : paymentIsExpense(on: debt) ? .loansExpense : .notSpending
    var subcategory = tree.category(debt.loansSubcategoryId)
    if subcategory?.archived == true { subcategory = nil }
    subcategory?.archived = true
    return DebtDeletion(
      debt: deleted, archivedSubcategory: subcategory, journalLines: lines.count,
      movesMoneyLines: movesMoney,
      operations: live.filter { $0.transaction.debtId == debt.id }.count, meaning: meaning,
      creditPurchases: live.filter { $0.transaction.creditDebtId == debt.id },
      balance: balance(entries: lines))
  }

  /// The debts something ever paid: a live operation naming the debt that is not money lent or
  /// borrowed more nor an offset (`notPayments`), or a `payment` line of its journal. A purchase
  /// on credit of such a debt stays when the debt is deleted: its payments were never spending,
  /// so without the purchase the money that left the account would be in no figure at all.
  public static func paidDebts(entries: [TransactionEntry], journal: [DebtEntry]) -> Set<UUID> {
    let notPaying = notPayments(journal)
    var paid = Set(journal.filter { $0.kind == .payment }.map(\.debtId))
    for entry in entries where !entry.transaction.isDeleted {
      guard let debtId = entry.transaction.debtId, !notPaying.contains(entry.id) else { continue }
      paid.insert(debtId)
    }
    return paid
  }

  /// The debts a deletion of `operations` leaves closed with something owed again: a closed debt
  /// whose journal was at zero or below, and has money owed once the lines of those operations
  /// — the payments that closed it — leave the journal. Deleting the payment does not open the
  /// debt; the deletion asks whether to (`TransactionsStore.delete(ids:reopening:)`). A deleted
  /// debt, an open one and a debt closed with money still owed on it are not among them. In the
  /// order of `debts`.
  public static func closedByDeleting(
    _ operations: Set<UUID>, debts: [Debt], journal: [DebtEntry]
  ) -> [Debt] {
    guard !operations.isEmpty else { return [] }
    var lines: [UUID: [DebtEntry]] = [:]
    for line in journal { lines[line.debtId, default: []].append(line) }
    return debts.filter { debt in
      guard debt.closed, debt.deletedAt == nil, let own = lines[debt.id] else { return false }
      let kept = own.filter { line in
        guard let operation = line.transactionId else { return true }
        return !operations.contains(operation)
      }
      guard kept.count < own.count else { return false }
      return balance(entries: own).raw <= 0 && balance(entries: kept).raw > 0
    }
  }
}
