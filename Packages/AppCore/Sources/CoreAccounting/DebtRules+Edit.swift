import CoreKit
import Foundation

/// What an edit of an operation does to the journal lines that point at it
/// (`debt_entries.transaction_id`).
public struct DebtJournalEdit: Hashable, Sendable {
  /// Lines to write over the line with the same id, or to add: the lines the edit changed,
  /// and a new one when the edit made the operation pay a debt it did not pay before.
  public var upsert: [DebtEntry]
  /// Lines that go: the operation no longer points at their debt.
  public var delete: [UUID]

  public init(upsert: [DebtEntry] = [], delete: [UUID] = []) {
    self.upsert = upsert
    self.delete = delete
  }

  public var isEmpty: Bool { upsert.isEmpty && delete.isEmpty }
}

/// An operation that moves a debt keeps its journal line in step with it when it is edited:
/// a payment lowers the debt at the same time. The entry line and the Debts section write
/// the operation and its line together; the editor changes the operation, and
/// the line has to follow, or the balance of the debt — a sum of its lines — would tell
/// another story than the operation does.
extension DebtRules {

  /// Whether money of this kind on this debt makes it grow rather than pays it: money I gave
  /// on a debt owed to me — I lent more — or money I got on a debt I owe — I borrowed more,
  /// or a payment came back as a refund, which undoes it. Only money that flows the paying way
  /// pays a debt: out of my pocket on a debt I owe, into it on a debt owed to me. Everything
  /// but an expense brings money in (`TransactionKind.reducesSpending`). The entry line
  /// decides by it (`EntryCommit`), and so does an edit.
  public static func operationGrows(_ kind: TransactionKind, _ debt: Debt) -> Bool {
    switch debt.direction {
    case .owedToMe: kind == .expense
    case .iOwe: kind != .expense
    }
  }

  /// The journal lines of an operation after it was edited from `before` into `after`.
  ///
  /// Two lines can hang on an operation, and each follows its own field:
  ///
  /// * a purchase on credit — the `borrowed` line that opened its debt, by `credit_debt_id`;
  /// * a payment of a debt — or money lent or borrowed on it — by `debt_id`: a `payment` (or
  ///   the `offset` of «Paid for the creditor»), or `borrowed` when the money grows the debt
  ///   (`operationGrows`).
  ///
  /// Only what the edit changed reaches a line: a new amount, signed by the line's kind; a new
  /// day; a new debt, which moves the line onto it. A field set to none takes its line away. A
  /// debt chosen in the edit gets the line the entry line would have written, and an operation
  /// that always pointed at its debt without a line — older than the journal — is not given
  /// one. Everything else of a line — its id, group, description and note — stays.
  ///
  /// Throws `EditRefusal.debtCurrency` when a line would count the operation's money on a
  /// debt kept in another currency.
  public static func journal(
    of lines: [DebtEntry], afterEditing before: Transaction, into after: Transaction,
    debts: [UUID: Debt], calendar: CalendarContext
  ) throws -> DebtJournalEdit {
    let edit = OperationEdit(before: before, after: after, calendar: calendar)
    guard edit.movesDebts else { return DebtJournalEdit() }
    var journal = DebtJournalEdit()
    var remaining = lines

    let opening = before.creditDebtId.flatMap { debtId in
      take(from: &remaining) { $0.debtId == debtId && $0.kind == .borrowed }
    }
    try follow(
      opening, from: before.creditDebtId, to: after.creditDebtId, edit: edit, debts: debts,
      into: &journal
    ) { _, _ in .borrowed }

    let payment = before.debtId.flatMap { debtId in
      take(from: &remaining) { $0.debtId == debtId }
    }
    try follow(
      payment, from: before.debtId, to: after.debtId, edit: edit, debts: debts, into: &journal
    ) { debt, line in
      if operationGrows(after.kind, debt) { return .borrowed }
      // A payment stays a payment and an offset an offset; money that stopped growing the
      // debt pays it.
      if let line, effect(of: line.kind) == .decreases { return line.kind }
      return .payment
    }
    return journal
  }

  /// One line and the field it follows.
  private static func follow(
    _ line: DebtEntry?, from oldDebtId: UUID?, to newDebtId: UUID?, edit: OperationEdit,
    debts: [UUID: Debt], into journal: inout DebtJournalEdit,
    kind: (Debt, DebtEntry?) -> DebtEntryKind
  ) throws {
    guard let newDebtId else {
      if let line { journal.delete.append(line.id) }
      return
    }
    let moved = newDebtId != oldDebtId
    guard line != nil || moved, let debt = debts[newDebtId] else { return }
    guard debt.currency == edit.after.currency else { throw EditRefusal.debtCurrency }

    guard let line else {
      let kind = kind(debt, nil)
      journal.upsert.append(
        makeEntry(
          debtId: debt.id, kind: kind, amountE4: edit.after.amountE4, date: edit.afterDay,
          description: edit.after.note, transactionId: edit.after.id))
      return
    }
    var written = line
    written.debtId = debt.id
    let newKind = moved || edit.kindChanged ? kind(debt, line) : line.kind
    if newKind != line.kind || edit.amountChanged {
      written.kind = newKind
      written.amountE4 = signedAmount(edit.after.amountE4, for: newKind)
      // The amount no longer comes from a share of a full amount.
      written.fullAmountE4 = nil
      written.share = nil
    }
    // «В этом месяце больше платежей не будет» is said of a payment only.
    if written.kind != .payment { written.closesTerm = false }
    if edit.dayChanged { written.date = edit.afterDay }
    if written != line { journal.upsert.append(written) }
  }

  private static func take(
    from lines: inout [DebtEntry], where matches: (DebtEntry) -> Bool
  ) -> DebtEntry? {
    guard let index = lines.firstIndex(where: matches) else { return nil }
    return lines.remove(at: index)
  }
}

/// What of an operation an edit changed, as far as its debts care.
private struct OperationEdit {
  let after: Transaction
  let afterDay: DateOnly
  let amountChanged: Bool
  let kindChanged: Bool
  let dayChanged: Bool
  let movesDebts: Bool

  init(before: Transaction, after: Transaction, calendar: CalendarContext) {
    self.after = after
    afterDay = calendar.day(of: after.occurredAt)
    amountChanged = before.amountE4 != after.amountE4
    kindChanged = before.kind != after.kind
    dayChanged = calendar.day(of: before.occurredAt) != afterDay
    movesDebts =
      amountChanged || kindChanged || dayChanged || before.currency != after.currency
      || before.debtId != after.debtId || before.creditDebtId != after.creditDebtId
  }
}
