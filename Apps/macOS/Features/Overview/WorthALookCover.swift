import AppCore
import Foundation

/// «Стоит посмотреть» while the hidden accounts are covered: a line about one operation of a
/// hidden account, about a hidden account or a card of one, says nothing of it. Lines about a
/// category, a month, a tax or a figure stay — they are figures, and figures keep all the money.
///
/// Read from the snapshot the card draws (`DataSnapshot.hiding`); the whole snapshot hides
/// nothing.
enum WorthALookCover {
  /// The anomalies without those about one operation of a hidden account.
  static func covering(
    _ report: AnomalyReport, hidden: HiddenOperations, ledger: Ledger
  ) -> AnomalyReport {
    guard !hidden.isEmpty else { return report }
    var copy = report
    copy.all = report.all.filter { !hidden.hides(operation: $0.transactionId, in: ledger) }
    return copy
  }

  /// The lines of 1.9 and later without those about a hidden account or its operations.
  static func covering(
    _ notes: [WorthALookNote], hidden: HiddenOperations, ledger: Ledger
  ) -> [WorthALookNote] {
    guard !hidden.isEmpty else { return notes }
    return notes.filter { !hides($0, hidden: hidden, ledger: ledger) }
  }

  /// A bank all of whose live accounts are hidden: naming it, or its money, gives them away.
  static func hidesBank(
    _ bank: UUID, accounts: [PaymentMethod], hiding: HiddenAccounts
  ) -> Bool {
    guard !hiding.isEmpty else { return false }
    let live = accounts.filter { $0.bankId == bank && !$0.archived }
    return !live.isEmpty && live.allSatisfy { hiding.isHidden($0.id) }
  }

  /// Whether a line is about a hidden account, a card of one, or an operation of one. Every kind
  /// of line is named here, so a new one has to say whether it speaks of an account.
  static func hides(_ note: WorthALookNote, hidden: HiddenOperations, ledger: Ledger) -> Bool {
    let account = { (id: UUID) in hidden.accounts.isHidden(id) }
    let operation = { (id: UUID) in hidden.hides(operation: id, in: ledger) }
    switch note {
    case .debt(let reminder):
      switch reminder {
      case .cardPayBy(let id, _, _, _), .cardGraceMissed(let id, _, _), .cardOverLimit(let id, _):
        return account(id)
      case .prepayNotice, .pledgeDue, .insuranceCooling, .creditHistory:
        return false
      }
    case .bank(let bankNote):
      switch bankNote {
      case .limitNear(let id, _, _, _), .limitExceeded(let id, _, _, _),
        .minBalanceBelow(let id, _, _, _):
        return account(id)
      case .cardExpiry(let id, let card, _, _, _):
        return account(id) || hidden.cards.contains(card)
      case .insuranceOver(let bank, _, _, _):
        return hidesBank(bank, accounts: ledger.dataset.paymentMethods, hiding: hidden.accounts)
      case .forgotten:
        return false
      }
    case .allocate(let incomeId, _, _):
      return operation(incomeId)
    case .depositEnds(let advice):
      return account(advice.accountId)
    case .warranty(let reminder):
      return operation(reminder.transactionId)
    case .purchase(let purchase):
      switch purchase {
      case .refundWaiting(let id, _, _, _, _, _): return operation(id)
      case .regret(let question): return operation(question.transactionId)
      case .wishReady, .birthday: return false
      }
    case .cashback(let cashback):
      switch cashback {
      case .choose(let due): return account(due.accountId)
      case .payHere(let hint):
        return account(hint.best.accountId) || hint.usual.map { account($0.accountId) } == true
      case .trap: return false
      }
    case .npdDue, .salaryLate, .monthRest, .npdLimit, .burnout, .lowCopySpace,
      .databaseProblems:
      return false
    // The lines of the habits name no account: the wizard asks only about the accounts shown.
    case .habit:
      return false
    }
  }
}
