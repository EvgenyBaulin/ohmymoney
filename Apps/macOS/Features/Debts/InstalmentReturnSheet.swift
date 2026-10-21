import AppCore
import AppDatabase
import SwiftUI

/// A thing bought in instalments, returned: the bank lowers the debt, or gives the money back to
/// the card (`RefundRules.instalmentReturn`, lowering the debt by default). Lowering it, the
/// return is two refunds of the purchase part in one write and one step of ⌘Z: what was already
/// paid off the price back to the account, an ordinary refund; the rest off the debt — a refund
/// that moves no money (`instreturn:<return>:debt`) and the `offset` line of the journal naming
/// it. A plan brought to zero offers to close, as a payment that pays a debt off does.
enum InstalmentReturn {
  /// The open instalment plan the refund `entry` returns a thing of: a part of it refunds a part
  /// of a purchase made on the plan (`creditDebtId`). `nil` for any other refund.
  static func plan(of entry: TransactionEntry, dataset: Dataset) -> Debt? {
    guard entry.transaction.kind == .refund else { return nil }
    let purchased = Set(entry.parts.compactMap(\.refundOfPartId))
    guard !purchased.isEmpty,
      let purchase = dataset.entries.first(where: { candidate in
        candidate.parts.contains { purchased.contains($0.id) }
      }),
      let debtId = purchase.transaction.creditDebtId,
      let debt = dataset.debts.first(where: { $0.id == debtId }),
      debt.isInstalmentPlan, !debt.closed, !debt.isDeleted
    else { return nil }
    return debt
  }

  /// What was paid off the price of `debt` so far: the money paid on it less the markup of the
  /// dues it closed.
  static func paidPrincipal(
    of debt: Debt, journal: [DebtEntry], balance: AmountE4, dues: DebtDueState?
  ) -> AmountE4 {
    let borrowed = AmountE4.sum(
      journal.filter { $0.debtId == debt.id && $0.kind != .payment && $0.amountE4.raw > 0 }
        .map(\.amountE4))
    let paid = max(borrowed - balance, .zero)
    guard let markup = debt.markupE4, let count = debt.parts, let dues else { return paid }
    let shares = InstalmentPlan.markupShares(markup: markup, count: count)
    let markupPaid = AmountE4.sum(Array(shares.prefix(min(dues.paidCount, count))))
    return max(paid - markupPaid, .zero)
  }

  /// The markup of the dues not paid yet: what cancelling the overpayment of the remaining
  /// parts lowers the debt by (600 in 4 parts, one paid: 450). Zero for a plan without markup.
  static func unpaidMarkup(of debt: Debt, dues: DebtDueState?) -> AmountE4 {
    guard let markup = debt.markupE4, markup.raw > 0, let count = debt.parts, count >= 1 else {
      return .zero
    }
    let paid = min(dues?.paidCount ?? 0, count)
    return AmountE4.sum(
      Array(InstalmentPlan.markupShares(markup: markup, count: count).dropFirst(paid)))
  }

  /// The change a return writes: `refund` as the owner made it, split as `split` says. The part
  /// off the debt keeps the refund's moment, account and rate, its parts in proportion; with
  /// `closing` the debt closes in the same write. `cancelledMarkup` is the overpayment of the
  /// parts still to pay, taken off the debt by one `adjustment` line of the journal in the same
  /// write; it never takes the debt below zero, and the amounts of the parts are not rewritten.
  static func change(
    refund: TransactionEntry, debt: Debt, split: InstalmentReturnSplit, day: DateOnly,
    closing: Bool, cancelledMarkup: AmountE4 = .zero, balance: AmountE4 = .zero,
    markupNote: String? = nil, now: Date = Date()
  ) -> PlanningChange {
    let total = refund.transaction.amountE4
    let cancelled = min(cancelledMarkup, max(balance - split.toDebtE4, .zero))
    var cancelLines: [DebtEntry] = []
    if cancelled.raw > 0 {
      var line = DebtRules.makeEntry(
        debtId: debt.id, kind: .adjustment, amountE4: -cancelled, date: day)
      line.description = markupNote
      cancelLines = [line]
    }
    guard split.toDebtE4.raw > 0, total.raw > 0 else {
      return PlanningChange(
        created: [refund], upsert: PlanningRows(debtEntries: cancelLines), at: now)
    }
    let debtPart: TransactionEntry
    var created: [TransactionEntry] = []
    if split.toDebtE4 >= total {
      debtPart = keyed(refund)
    } else {
      let shares = [split.toDebtE4, total - split.toDebtE4]
      let part = scaled(refund, to: split.toDebtE4, of: total, id: UUID())
      debtPart = keyed(part)
      created.append(scaled(refund, to: shares[1], of: total, id: refund.id))
    }
    created.insert(debtPart, at: 0)
    var line = DebtRules.makeEntry(
      debtId: debt.id, kind: .offset, amountE4: debtPart.transaction.amountE4, date: day,
      transactionId: debtPart.id)
    line.description = refund.transaction.note
    var rows = PlanningRows(debtEntries: [line] + cancelLines)
    if closing {
      var closed = debt
      closed.closed = true
      rows.debts = [closed]
    }
    return PlanningChange(created: created, upsert: rows, at: now)
  }

  /// `entry` as the part of the return that lowers the debt: its key names it.
  private static func keyed(_ entry: TransactionEntry) -> TransactionEntry {
    var keyed = entry
    keyed.transaction.externalId = RefundRules.instalmentReturnKey(of: entry.id)
    return keyed
  }

  /// `entry` with `amount` of its `total`, its rubles and parts in proportion, under `id`.
  private static func scaled(
    _ entry: TransactionEntry, to amount: AmountE4, of total: AmountE4, id: UUID
  ) -> TransactionEntry {
    var scaled = entry
    scaled.transaction.id = id
    scaled.transaction.amountE4 = amount
    scaled.transaction.amountRubE4 =
      entry.transaction.amountRubE4.allocated(
        proportionallyTo: [amount, total - amount], outOf: total)[0]
    if let charged = entry.transaction.accountAmountE4 {
      scaled.transaction.accountAmountE4 =
        charged.allocated(proportionallyTo: [amount, total - amount], outOf: total)[0]
    }
    let amounts = amount.allocated(
      proportionallyTo: entry.parts.map(\.amountE4), outOf: total)
    let rubles = scaled.transaction.amountRubE4.allocated(
      proportionallyTo: entry.parts.map(\.amountE4), outOf: total)
    scaled.parts = entry.parts.enumerated().map { index, part in
      var copy = part
      copy.transactionId = id
      if id != entry.id { copy.id = UUID() }
      copy.amountE4 = amounts[index]
      copy.amountRubE4 = rubles[index]
      return copy
    }
    return scaled
  }
}

/// «Вернули вещь из рассрочки»: the question of a refund of a thing bought in instalments — the
/// bank lowers the debt, or gives the money back to the card —, the split it makes, and «Закрыть
/// рассрочку» when the debt comes to zero. The entry line hands the refund it would write; the
/// sheet writes it, one step of ⌘Z, and says whether it landed (`onDone`).
struct InstalmentReturnSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let refund: TransactionEntry
  let debt: Debt
  var onDone: (Bool) -> Void = { _ in }

  @State private var choice: InstalmentReturnChoice = .reducesDebt
  @State private var closing = true
  /// «Переплата за оставшиеся части»: left as a debt unless the owner cancels it.
  @State private var cancelsMarkup = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("instalmentReturn.title", table: "Debts", debt.name))
        .appFont(.headline)
      Form {
        Picker(t("instalmentReturn.question"), selection: $choice) {
          Text(verbatim: t("instalmentReturn.reducesDebt")).tag(InstalmentReturnChoice.reducesDebt)
          Text(verbatim: t("instalmentReturn.toCard")).tag(InstalmentReturnChoice.toCard)
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier("debts.instalmentReturn.choice")
        if markupToCancel.raw > 0 {
          Picker(t("instalmentReturn.markup.question"), selection: $cancelsMarkup) {
            Text(verbatim: t("instalmentReturn.markup.keep")).tag(false)
            Text(verbatim: t("instalmentReturn.markup.cancel")).tag(true)
          }
          .pickerStyle(.radioGroup)
          .accessibilityIdentifier("debts.instalmentReturn.markup")
          if cancelsMarkup {
            Text(verbatim: markupText).appFont(.callout)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Text(verbatim: splitText).appFont(.callout).fixedSize(horizontal: false, vertical: true)
        if closesDebt {
          Toggle(t("instalmentReturn.close"), isOn: $closing)
        }
      }
      .formStyle(.grouped)
      if failed {
        Text(verbatim: environment.language("form.notSaved", table: "Planning"))
          .appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) {
          onDone(false)
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(t("form.save")) { save() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(dependencies == nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
  }

  private var line: DebtLine? {
    compute.snapshot?.planning.debts.iOwe.first { $0.debt.id == debt.id }
  }

  private var split: InstalmentReturnSplit {
    let balance = line?.balance ?? .zero
    let journal = compute.snapshot?.dataset.planning.debtEntries ?? []
    return RefundRules.instalmentReturn(
      refund: refund.transaction.amountE4, debt: debt, balance: balance,
      paidPrincipal: InstalmentReturn.paidPrincipal(
        of: debt, journal: journal, balance: balance, dues: line?.dues),
      choice: choice)
  }

  private var markupToCancel: AmountE4 {
    InstalmentReturn.unpaidMarkup(of: debt, dues: line?.dues)
  }

  private var markupText: String {
    environment.format(
      "instalmentReturn.markup.cancelled", table: "Debts",
      environment.money.exact(
        min(markupToCancel, max((line?.balance ?? .zero) - split.toDebtE4, .zero)),
        currency: refund.transaction.currency))
  }

  private var closesDebt: Bool {
    guard let balance = line?.balance else { return false }
    let left = balance - split.toDebtE4 - (cancelsMarkup ? markupToCancel : .zero)
    return choice == .reducesDebt && split.toDebtE4.raw > 0 && left.raw <= 0
  }

  private var splitText: String {
    let money = environment.money
    let currency = refund.transaction.currency
    return environment.format(
      "instalmentReturn.split", table: "Debts", money.exact(split.toAccountE4, currency: currency),
      money.exact(split.toDebtE4, currency: currency))
  }

  private func save() {
    guard let dependencies else { return }
    let change = InstalmentReturn.change(
      refund: refund, debt: debt, split: split,
      day: environment.calendar.day(of: refund.transaction.occurredAt),
      closing: closesDebt && closing, cancelledMarkup: cancelsMarkup ? markupToCancel : .zero,
      balance: line?.balance ?? .zero, markupNote: t("instalmentReturn.markup.note"))
    if PlanningActions(dependencies).apply(change) {
      AppLog.info(
        "debts.instalmentReturned", .db, "a thing bought in instalments was returned",
        [LogPair("debt", .id(debt.id)), LogPair("choice", .token(choice.rawValue))])
      onDone(true)
      dismiss()
    } else {
      failed = true
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
