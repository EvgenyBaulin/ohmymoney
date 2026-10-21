import AppCore
import AppDatabase
import Foundation

extension DebtActions {
  /// «Уже списано до сверки» of a debt's due: the bank took the monthly payment before a count
  /// of the account, so the count holds that money gone. A journal `payment` line of the
  /// monthly payment — never more than what is left — dated the due day, with no operation and
  /// no account (`DebtRules.settledByCount`): the balance drops, the earliest unpaid due closes,
  /// and no money moves on any account. One write, one step of ⌘Z. What is left is read from
  /// the database at the moment of asking — the journal on screen when there is none to read.
  ///
  /// A due paid in part is taken for what is left of it: `owed` is that rest, the monthly payment
  /// when not said.
  @discardableResult
  func settle(debt: Debt, due: DateOnly, owed: AmountE4? = nil) -> Bool {
    let shown = planning.snapshot.map { snapshot in
      DebtRules.balance(of: debt.id, entries: snapshot.dataset.planning.debtEntries)
    }
    guard !debt.closed, let balance = balance(of: debt) ?? shown,
      let line = DebtRules.settledByCount(debt: debt, due: due, balance: balance, owed: owed)
    else {
      AppLog.error(
        "planning.due.notSettled", .db, "a due date was not closed",
        [LogPair("kind", .token("debt")), LogPair("debt", .id(debt.id))])
      return false
    }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    guard planning.apply(PlanningChange(upsert: rows)) else {
      AppLog.error(
        "planning.due.notSettled", .db, "a due date was not closed",
        [LogPair("kind", .token("debt")), LogPair("debt", .id(debt.id))])
      return false
    }
    AppLog.info(
      "planning.due.settled", .db, "a due date was closed as taken before a count",
      [LogPair("kind", .token("debt")), LogPair("debt", .id(debt.id))])
    return true
  }
}
