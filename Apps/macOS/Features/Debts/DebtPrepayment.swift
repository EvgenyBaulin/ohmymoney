import AppCore
import AppDatabase
import Foundation

/// An early repayment of a loan, as the forms write it: a payment above what the dues ask by its
/// day asks «Уменьшить срок / Уменьшить платёж / Это платёж вперёд», the answer offered first is
/// the last one given on the debt (`DebtPrepay.defaultChoice`), and the answer is kept on the
/// payment's line (`DebtEntry.prepay`) — «платёж вперёд» too, so it is offered first next time,
/// though its money pays the next dues as any payment does. An early repayment the owner planned
/// (`Debt.plannedPrepay`) is put away by the one written, in the same write; a payment ahead is
/// none and leaves the plan. «Платёж…», the ↓ panel and the entry line all write
/// through `marking`.
enum DebtPrepayment {
  /// What to ask about a payment of `amount` on `day` toward `debt`: the money above the dues and
  /// the answer offered first; `nil` when there is nothing to ask (`DebtPrepay.asks`).
  static func question(
    debt: Debt, amount: AmountE4, day: DateOnly, dues: DebtDueState?, journal: [DebtEntry]
  ) -> (excess: AmountE4, choice: PrepayChoice)? {
    guard let dues = dues?.knowing(debt),
      DebtPrepay.asks(debt: debt, dues: dues, payment: amount, day: day)
    else { return nil }
    return (
      DebtPrepay.excess(payment: amount, dues: dues, on: day),
      DebtPrepay.defaultChoice(debtId: debt.id, journal: journal)
    )
  }

  /// `change` with the answer `choice` on the payment line it writes on `debt`, and the planned
  /// early repayment of the debt put away. The same change without an answer.
  static func marking(
    _ change: PlanningChange, debt: Debt, choice: PrepayChoice?
  ) -> PlanningChange {
    guard let choice,
      let index = change.upsert.debtEntries.firstIndex(where: { line in
        line.debtId == debt.id && line.kind == .payment && line.amountE4.isNegative
      })
    else { return change }
    var marked = change
    marked.upsert.debtEntries[index].prepay = choice
    if choice.isEarlyRepayment, debt.plannedPrepay != nil {
      if let written = marked.upsert.debts.firstIndex(where: { $0.id == debt.id }) {
        marked.upsert.debts[written].plannedPrepay = nil
      } else {
        var unplanned = debt
        unplanned.plannedPrepay = nil
        marked.upsert.debts.append(unplanned)
      }
    }
    AppLog.info(
      "debts.prepay.recorded", .db, "an early repayment was answered",
      [LogPair("debt", .id(debt.id)), LogPair("choice", .token(choice.rawValue))])
    return marked
  }
}
