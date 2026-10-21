import AppCore
import AppDatabase
import Foundation

/// «Сверх частей 2,000 ₽ — в счёт долга «Аня»»: money back from a person who owes on a debt
/// owed to me as well as for parts. What the parts take closes them; the money over them can
/// repay the debt instead of becoming income, and the owner decides in the sheet — the switch is
/// on by default.
///
/// It is written as two operations of money back: the one for the parts, with the money they
/// took and their links, and one that repays the debt by the rule of repayments
/// (`DebtRules.repayment`) — the journal takes what is left of the debt, the debt closes once it
/// is covered, and what the debt cannot take is income in «Доплаты» of that repayment. Each stays
/// consistent when a part's rubles change later (`MoneyBackSettlement` balances links and
/// surplus of the money back for the parts alone), and deleting either takes only its own along.
extension ReimbursementRecording {
  /// This recording with its surplus given to `debt`, owed to me by the person the money came
  /// from, and the rows of the debt that go in the same write; `nil` when it cannot be: the
  /// recording has no surplus or its money is not all there is to split (it reached an account in
  /// another currency than it came in), or the debt is not an open one in the money's currency
  /// with something left on it.
  ///
  /// `balance` is what is left on the debt now, `day` the day of the line of its journal.
  func repayingDebt(
    _ debt: Debt, balance: AmountE4, on day: DateOnly, now: Date, setting: Setting
  ) throws -> (recording: ReimbursementRecording, settling: DebtSettling)? {
    guard let surplus = outcome.surplus, surplus.amountE4.raw > 0,
      debt.direction == .owedToMe, !debt.closed, balance.raw > 0,
      surplus.currency == debt.currency,
      reimbursement.transaction.accountAmountE4 == nil,
      reimbursement.transaction.accountCurrency == nil,
      reimbursement.parts.count == 1
    else { return nil }
    let transaction = reimbursement.transaction
    let partsAmount = transaction.amountE4 - surplus.amountE4
    let partsRub = transaction.amountRubE4 - surplus.amountRubE4
    guard partsAmount.raw > 0, partsRub.raw > 0 else { return nil }

    // The money back for the parts keeps what the parts took.
    var back = reimbursement
    back.transaction.amountE4 = partsAmount
    back.transaction.amountRubE4 = partsRub
    back.transaction.amountExpr = nil
    back.parts[0].amountE4 = partsAmount
    back.parts[0].amountRubE4 = partsRub
    var shorter = outcome
    shorter.surplus = nil

    // The money over them is a money back of its own that names the debt.
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: transaction.occurredAt, currency: surplus.currency,
      amount: surplus.amountE4, rate: transaction.rate, rateDate: transaction.rateDate,
      rateSource: transaction.rateSource, note: transaction.note,
      paymentMethodId: transaction.paymentMethodId, debtId: debt.id)
    draft.rateProvisional = transaction.rateProvisional
    draft.normalizeSinglePart()
    draft.parts[0].forPersonId = reimbursement.parts.first?.forPersonId
    let repaying = try draft.materialize(
      now: now, rublesConverter: { _ in surplus.amountRubE4 })

    let repayment = try DebtRules.repayment(
      on: debt, by: repaying.transaction, balance: balance, date: day,
      description: transaction.note)
    // The old surplus goes: what the debt cannot take is the income of the repayment.
    let surplusKey = ReimbursementCompanions.surplusKey(of: reimbursement.id)
    var extra = self.extra.filter { $0.transaction.externalId != surplusKey }
    extra.append(repaying)
    if let over = repayment.surplus {
      extra.append(
        try Self.surplusEntry(
          over, of: repaying.id, on: transaction.occurredAt, now: now,
          rate: transaction.rate, rateDate: transaction.rateDate, setting: setting))
    }
    var closed: [Debt] = []
    if repayment.closes {
      var debt = debt
      debt.closed = true
      closed = [debt]
    }
    return (
      ReimbursementRecording(outcome: shorter, reimbursement: back, extra: extra),
      DebtSettling(lines: repayment.line.map { [$0] } ?? [], debts: closed)
    )
  }

  /// The debt owed to me by `person` that a surplus in `currency` may repay: open, kept in that
  /// currency, with something left on it (`balances`); when there are several, the first by name.
  /// `nil` when there is none — then the surplus is income, as ever.
  static func debtForSurplus(
    of person: UUID, in currency: CurrencyCode, among debts: [Debt],
    balances: [UUID: AmountE4]
  ) -> (debt: Debt, balance: AmountE4)? {
    let candidates = debts.filter { debt in
      !debt.closed && debt.direction == .owedToMe && debt.personId == person
        && debt.currency == currency && (balances[debt.id]?.raw ?? 0) > 0
    }
    guard
      let debt = candidates.min(by: { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }),
      let balance = balances[debt.id]
    else { return nil }
    return (debt, balance)
  }
}
