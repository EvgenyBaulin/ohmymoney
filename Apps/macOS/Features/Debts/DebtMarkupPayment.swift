import AppCore
import AppDatabase
import Foundation

/// The markup of an instalment plan (`Debt.markupE4`), spent part by part. The purchase was spent
/// at its price; what the plan costs above it is spending too, and each payment carries the share
/// of the dues it closes (`DebtMarkup.split`). Beside the payment the app writes that share as an
/// expense in the debt's subcategory of «Кредиты» (else «Кредиты»), on the debt the way a purchase
/// on credit is (`creditDebtId`): spending once, no money of its own — the payment moved it.
///
/// The markup operation points back at its payment by `external_id`
/// `debtmarkup:<payment>:<itself>`: it goes with its payment when the payment is deleted, and
/// follows it when the payment's money, day, account or card is edited — in the same write and the
/// same step of ⌘Z, exactly as the interest of a loan does (`DebtInterestPayment`).
enum DebtMarkupPayment {
  /// Whether a payment of `debt` carries markup: an open instalment plan I owe with a markup.
  static func applies(to debt: Debt) -> Bool {
    debt.direction == .iOwe && debt.isInstalmentPlan && (debt.markupE4?.raw ?? 0) > 0
  }

  /// The markup operation of `payment`: an expense of `markup` in `categoryId` on the payment's
  /// moment, account and card, in its currency at its rate, its rubles the share of the
  /// payment's — on `debt`, so it moves no money.
  static func markupOperation(
    of payment: TransactionEntry, debt: Debt, markup: AmountE4, categoryId: UUID?, note: String?,
    id: UUID = UUID(), now: Date = Date()
  ) throws -> TransactionEntry {
    var entry = try DebtInterestPayment.interestOperation(
      of: payment, debt: debt, interest: markup, categoryId: categoryId, note: note, id: id,
      now: now)
    entry.transaction.externalId = DebtMarkup.key(ofPayment: payment.id, markup: id)
    return entry
  }

  /// The state of the dues of `debt` before the payment `paymentId`: the data without it.
  static func dues(
    of debt: Debt, without paymentId: UUID?, dataset: Dataset, calendar: CalendarContext,
    today: DateOnly
  ) -> DebtDueState {
    let base = paymentId.map { dataset.removing([$0]) } ?? dataset
    let journal = base.planning.debtEntries.filter { line in
      line.debtId == debt.id && (paymentId == nil || line.transactionId != paymentId)
    }
    let ledger = Ledger(dataset: base, calendar: calendar)
    return DebtDues.states(debts: [debt], ledger: ledger, journal: journal, today: today)[debt.id]
      ?? .none(of: debt.id)
  }

  /// The state of the dues of `debt` from its `journal` alone — each payment of a plan is a line
  /// of it — and the sums typed from the bank's app.
  static func dues(
    of debt: Debt, journal: [DebtEntry], typed: [DebtInstalmentStep], calendar: CalendarContext,
    today: DateOnly
  ) -> DebtDueState {
    let ledger = Ledger(
      dataset: Dataset(debts: [debt], debtInstalments: typed), calendar: calendar)
    return DebtDues.states(
      debts: [debt], ledger: ledger, journal: journal.filter { $0.debtId == debt.id },
      today: today)[debt.id] ?? .none(of: debt.id)
  }

  /// `change` with the markup operation of the payment it writes on `debt`: the payment line of
  /// `debt` with an operation of `change`, parted against `dues` — the dues before it.
  static func parting(
    _ change: PlanningChange, paying debt: Debt?, journal: [DebtEntry], dues: DebtDueState?,
    categoryId: UUID?, note: String?, now: Date = Date()
  ) -> PlanningChange {
    guard let debt, applies(to: debt), let dues,
      let line = change.upsert.debtEntries.first(where: { line in
        line.debtId == debt.id && line.kind == .payment && line.amountE4.isNegative
          && line.transactionId != nil
      }),
      let payment = change.created.first(where: { $0.id == line.transactionId })
    else { return change }
    let split = DebtMarkup.split(
      payment: line.amountE4.magnitude, debt: debt,
      journal: journal.filter { $0.debtId == debt.id && $0.id != line.id }, dues: dues)
    guard split.interestE4.raw > 0,
      let markup = try? markupOperation(
        of: payment, debt: debt, markup: split.interestE4, categoryId: categoryId, note: note,
        now: now)
    else { return change }
    var parted = change
    parted.created.append(markup)
    return parted
  }

  /// The edit of a payment of an instalment plan with markup, as one change: the payment as
  /// edited, its journal line with the money and day of the edit, and its markup operation parted
  /// anew — rewritten, written, or deleted when it carries none any more. `nil` when the edit is
  /// not one (`DebtInterestPayment.editChange` says when).
  static func editChange(
    _ edited: TransactionEntry, before: TransactionEntry, debt: Debt, dataset: Dataset,
    calendar: CalendarContext, today: DateOnly, categoryId: UUID?, note: String?,
    now: Date = Date()
  ) -> PlanningChange? {
    let old = before.transaction
    let new = edited.transaction
    guard applies(to: debt), old.debtId == debt.id, new.debtId == debt.id,
      old.currency == new.currency, old.kind == new.kind,
      let line = dataset.planning.debtEntries.first(where: {
        $0.debtId == debt.id && $0.transactionId == old.id && $0.kind == .payment
      })
    else { return nil }
    let moved =
      old.amountE4 != new.amountE4 || old.occurredAt != new.occurredAt
      || old.paymentMethodId != new.paymentMethodId || old.cardId != new.cardId
    guard moved else { return nil }
    var written = line
    written.amountE4 = -new.amountE4.magnitude
    written.date = calendar.day(of: new.occurredAt)
    written.fullAmountE4 = nil
    written.share = nil
    let before = dues(
      of: debt, without: old.id, dataset: dataset, calendar: calendar, today: today)
    let split = DebtMarkup.split(
      payment: new.amountE4.magnitude, debt: debt,
      journal: dataset.planning.debtEntries.filter { $0.debtId == debt.id && $0.id != line.id },
      dues: before)
    var rewrittenPayment = edited
    rewrittenPayment.transaction.updatedAt = now
    var change = PlanningChange(
      upsert: PlanningRows(debtEntries: [written]), rewritten: [rewrittenPayment], at: now)
    let current = dataset.entries.first { entry in
      !entry.transaction.isDeleted
        && DebtMarkup.payment(ofKey: entry.transaction.externalId) == old.id
    }
    if split.interestE4.raw > 0 {
      guard
        var markup = try? markupOperation(
          of: rewrittenPayment, debt: debt, markup: split.interestE4, categoryId: categoryId,
          note: note, id: current?.id ?? UUID(), now: now)
      else { return nil }
      if let current {
        // What the owner wrote in it stays: its note, category and rating.
        markup.transaction.note = current.transaction.note
        markup.transaction.externalId = current.transaction.externalId
        markup.transaction.createdAt = current.transaction.createdAt
        if let kept = current.parts.first, markup.parts.count == 1 {
          markup.parts[0].id = kept.id
          markup.parts[0].categoryId = kept.categoryId
          markup.parts[0].categorySource = kept.categorySource
          markup.parts[0].quality = kept.quality
          markup.parts[0].qualitySource = kept.qualitySource
        }
        change.rewritten.append(markup)
      } else {
        change.created.append(markup)
      }
    } else if let current {
      change.softDeleted = [current.id]
    }
    return change
  }
}

@MainActor
extension DebtMarkupPayment {
  /// The words a markup operation is noted with: «Переплата по «Пылесос»».
  static func note(of debt: Debt, language: AppLanguage) -> String {
    language.format("markup.note", table: "Debts", debt.name)
  }
}

extension DebtMarkupPayment {
  /// The note of a markup operation in the language stored right now — for a write that has no
  /// environment at hand.
  nonisolated static func storedNote(of debt: Debt, _ defaults: UserDefaults = .standard) -> String
  {
    DebtInterestPayment.storedWords("markup.note", of: debt, defaults)
  }
}
