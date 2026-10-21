import AppCore
import AppDatabase
import Foundation

/// The interest a payment of a loan pays first, on a loan that accrues interest
/// (`Debt.accruesInterest`) and whose payments are not expenses — an education loan, whose
/// tranches were the expense. The bank parts every payment the way `DebtInterest.split` does:
/// the interest accrued so far first, the rest off the principal. The principal was spent when the
/// tranche was; the interest is spending of its own, in «Кредиты».
///
/// The payment stays one operation with all of its money: it lowers the debt by all of it in the
/// journal (the core gives the interest back as a line of its own when it reads the journal) and
/// moves all of it off the account. Beside it the app writes the interest it paid as an expense in
/// «Кредиты» on the debt the way a purchase on credit is (`creditDebtId`): spending exactly once,
/// and no money of its own, since the payment moved it. A payment that is all interest — the
/// payments of a grace period are — needs no operation of nought for its principal.
///
/// The interest operation points back at its payment by `external_id`
/// `debtinterest:<payment>:<itself>`: it goes with its payment when the payment is deleted, and
/// follows it when the payment's money, day or account is edited — in the same write and the same
/// step of ⌘Z.
enum DebtInterestPayment {
  static let keyPrefix = "debtinterest:"

  /// The key of the interest operation `interest` of the payment `payment`.
  static func key(ofPayment payment: UUID, interest: UUID) -> String {
    keyPrefix + payment.uuidString.lowercased() + ":" + interest.uuidString.lowercased()
  }

  /// The payment an interest operation's key names; `nil` for any other key.
  static func payment(ofKey key: String?) -> UUID? {
    guard let key, key.hasPrefix(keyPrefix) else { return nil }
    let fields = key.dropFirst(keyPrefix.count).split(separator: ":")
    guard fields.count == 2 else { return nil }
    return UUID(uuidString: String(fields[0]))
  }

  /// Whether a payment of `debt` has an interest part of its own: a debt I owe, which accrues
  /// interest and whose payments are not expenses. A payment that is an expense is all of it
  /// spending in «Кредиты» already.
  static func applies(to debt: Debt) -> Bool {
    debt.direction == .iOwe && debt.accruesInterest && !DebtRules.paymentIsExpense(on: debt)
  }

  /// The interest operation of `payment`: an expense of `interest` in `categoryId` on the
  /// payment's day, account and card, in its currency at its rate, its rubles the share of the
  /// payment's — on `debt` as a purchase on credit is, so it moves no money.
  static func interestOperation(
    of payment: TransactionEntry, debt: Debt, interest: AmountE4, categoryId: UUID?,
    note: String?, id: UUID = UUID(), now: Date = Date()
  ) throws -> TransactionEntry {
    let paid = payment.transaction
    var draft = TransactionDraft(
      kind: .expense, occurredAt: paid.occurredAt, currency: paid.currency, amount: interest,
      rate: paid.rate, rateDate: paid.rateDate, rateSource: paid.rateSource,
      rateProvisional: paid.rateProvisional, note: note, paymentMethodId: paid.paymentMethodId,
      creditDebtId: debt.id, cardId: paid.cardId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    if categoryId != nil { draft.parts[0].categorySource = .system }
    let rubles = share(of: paid.amountRubE4, part: interest, outOf: paid.amountE4)
    var entry = try draft.materialize(id: id, now: now, rublesConverter: { _ in rubles })
    entry.transaction.externalId = key(ofPayment: payment.id, interest: id)
    return entry
  }

  /// `part` of `whole`, in the rubles `rubles` of the whole, to the unit.
  static func share(of rubles: AmountE4, part: AmountE4, outOf whole: AmountE4) -> AmountE4 {
    guard !whole.isZero, part != whole else { return rubles }
    return rubles.allocated(proportionallyTo: [part, whole - part], outOf: whole)[0]
  }

  /// The category of the interest: the debt's own subcategory of «Кредиты», else «Кредиты».
  static func categoryId(of debt: Debt, tree: CategoryTree?) -> UUID? {
    debt.loansSubcategoryId ?? tree?.systemCategory(.loans)?.id
  }

  /// `change` with the interest operation of the payment it writes on `debt`: the line of the
  /// journal that pays `debt` with an operation of `change`, parted against `journal` — the lines
  /// of the debt before the change. The same change for a debt the rule does not apply to, a
  /// payment that pays no interest, and a change that pays nothing.
  static func parting(
    _ change: PlanningChange, paying debt: Debt?, journal: [DebtEntry],
    calendar: CalendarContext, categoryId: UUID?, note: String?, now: Date = Date()
  ) -> PlanningChange {
    guard let debt, applies(to: debt),
      let line = change.upsert.debtEntries.first(where: { line in
        line.debtId == debt.id && line.kind == .payment && line.amountE4.isNegative
          && line.transactionId != nil
      }),
      let payment = change.created.first(where: { $0.id == line.transactionId })
    else { return change }
    let day = line.date ?? calendar.day(of: payment.transaction.occurredAt)
    let split = DebtInterest.split(
      payment: line.amountE4.magnitude, on: day, debt: debt,
      journal: journal.filter { $0.debtId == debt.id && $0.id != line.id }, calendar: calendar)
    guard split.interestE4.raw > 0,
      let interest = try? interestOperation(
        of: payment, debt: debt, interest: split.interestE4, categoryId: categoryId, note: note,
        now: now)
    else { return change }
    var parted = change
    parted.created.append(interest)
    return parted
  }

  /// The live interest operations of the payments `ids`, among `entries` — and the markup
  /// operations of payments of instalment plans (`DebtMarkupPayment`), which go the same way.
  static func companions(
    ofPayments ids: some Collection<UUID>, among entries: [TransactionEntry]
  ) -> [UUID] {
    let payments = Set(ids)
    guard !payments.isEmpty else { return [] }
    return entries.compactMap { entry in
      guard !entry.transaction.isDeleted,
        let paid = payment(ofKey: entry.transaction.externalId)
          ?? DebtMarkup.payment(ofKey: entry.transaction.externalId),
        payments.contains(paid)
      else { return nil }
      return entry.id
    }
  }

  /// Of `going` — what a deletion takes —, the interest operations among `entries` whose
  /// payments go with it, added: the rules keep an operation on a debt as a purchase on credit,
  /// and the interest of a payment is not one to keep once its payment is gone.
  static func goingWithTheirPayments(
    _ going: [UUID], among entries: [TransactionEntry]
  ) -> [UUID] {
    let taken = Set(going)
    let interest = companions(ofPayments: taken, among: entries).filter { !taken.contains($0) }
    return going + interest
  }

  /// The edit of a payment that has, or now pays, interest of its own, as one change: the payment
  /// as edited, its journal line with the money and day of the edit, and its interest operation
  /// parted anew — rewritten, written, or deleted when the payment pays none any more. `nil` when
  /// the edit is not one: the operation pays no such debt, the edit moves it to another debt,
  /// kind or currency, or changes neither its money, day, account nor card — the edit is written
  /// the usual way then.
  ///
  /// `before` is the operation as it is before the edit, `entries` the operations around it,
  /// `journal` the lines of its debt.
  static func editChange(
    _ edited: TransactionEntry, before: TransactionEntry, debts: [Debt],
    entries: [TransactionEntry], journal: [DebtEntry], calendar: CalendarContext,
    categoryId: UUID?, note: String?, now: Date = Date()
  ) -> PlanningChange? {
    let old = before.transaction
    let new = edited.transaction
    guard let debtId = old.debtId, new.debtId == debtId,
      let debt = debts.first(where: { $0.id == debtId }), applies(to: debt),
      old.kind == .expense, new.kind == .expense, old.currency == new.currency,
      let line = journal.first(where: {
        $0.debtId == debtId && $0.transactionId == old.id && $0.kind == .payment
      })
    else { return nil }
    let moved =
      old.amountE4 != new.amountE4 || old.occurredAt != new.occurredAt
      || old.paymentMethodId != new.paymentMethodId || old.cardId != new.cardId
    guard moved else { return nil }

    let day = calendar.day(of: new.occurredAt)
    var written = line
    written.amountE4 = -new.amountE4.magnitude
    written.date = day
    written.fullAmountE4 = nil
    written.share = nil
    let split = DebtInterest.split(
      payment: new.amountE4.magnitude, on: day, debt: debt,
      journal: journal.filter { $0.debtId == debtId }, calendar: calendar, replacing: line.id)

    var rewrittenPayment = edited
    rewrittenPayment.transaction.updatedAt = now
    var change = PlanningChange(
      upsert: PlanningRows(debtEntries: [written]), rewritten: [rewrittenPayment], at: now)
    let current = entries.first { entry in
      !entry.transaction.isDeleted
        && DebtInterestPayment.payment(ofKey: entry.transaction.externalId) == old.id
    }
    if split.interestE4.raw > 0 {
      guard
        var interest = try? interestOperation(
          of: rewrittenPayment, debt: debt, interest: split.interestE4,
          categoryId: categoryId, note: note, id: current?.id ?? UUID(), now: now)
      else { return nil }
      if let current {
        // What the owner wrote in it stays: its note, category and rating.
        interest.transaction.note = current.transaction.note
        interest.transaction.externalId = current.transaction.externalId
        interest.transaction.createdAt = current.transaction.createdAt
        if let kept = current.parts.first, interest.parts.count == 1 {
          interest.parts[0].id = kept.id
          interest.parts[0].categoryId = kept.categoryId
          interest.parts[0].categorySource = kept.categorySource
          interest.parts[0].quality = kept.quality
          interest.parts[0].qualitySource = kept.qualitySource
        }
        change.rewritten.append(interest)
      } else {
        change.created.append(interest)
      }
    } else if let current {
      change.softDeleted = [current.id]
    }
    return change
  }
}

@MainActor
extension DebtInterestPayment {
  /// The words an interest operation is noted with: «Проценты по «Учёба»».
  static func note(of debt: Debt, language: AppLanguage) -> String {
    language.format("interest.note", table: "Debts", debt.name)
  }

  /// `change` with the interest operation of the payment it writes on `debt`, against the journal
  /// of the debt as the database has it now (the data on screen without one). The entry line
  /// writes a payment of a debt through here.
  static func parting(
    _ change: PlanningChange, paying debt: Debt?, environment: AppEnvironment,
    snapshot: DataSnapshot? = nil
  ) -> PlanningChange {
    guard let debt, applies(to: debt) || DebtMarkupPayment.applies(to: debt) else {
      return change
    }
    let journal =
      (try? environment.references?.debtEntries(debtId: debt.id))
      ?? snapshot?.dataset.planning.debtEntries.filter { $0.debtId == debt.id } ?? []
    let category = categoryId(of: debt, environment: environment, snapshot: snapshot)
    if DebtMarkupPayment.applies(to: debt) {
      // The dues before the payment, from the journal as the database has it: every payment of
      // a plan is a line of it.
      let dues = DebtMarkupPayment.dues(
        of: debt, journal: journal,
        typed: snapshot?.dataset.debtInstalments.filter { $0.debtId == debt.id } ?? [],
        calendar: environment.calendar, today: environment.today)
      return DebtMarkupPayment.parting(
        change, paying: debt, journal: journal, dues: dues, categoryId: category,
        note: DebtMarkupPayment.note(of: debt, language: environment.language))
    }
    return parting(
      change, paying: debt, journal: journal, calendar: environment.calendar,
      categoryId: category, note: note(of: debt, language: environment.language))
  }

  /// The category of the interest of `debt` (`categoryId(of:tree:)`), «Кредиты» read from the
  /// database when the data on screen has none.
  static func categoryId(
    of debt: Debt, environment: AppEnvironment, snapshot: DataSnapshot?
  ) -> UUID? {
    categoryId(of: debt, tree: snapshot?.ledger.tree)
      ?? (try? environment.references?.category(systemRole: .loans, kind: .expense))?.id
  }
}

extension DebtInterestPayment {
  /// The note of an interest operation in the language of the interface as it is chosen right
  /// now, read where the choice is stored — for a write that has no environment at hand.
  nonisolated static func storedNote(
    of debt: Debt, _ defaults: UserDefaults = .standard
  )
    -> String
  {
    storedWords("interest.note", of: debt, defaults)
  }

  /// A text of the table «Debts» with the debt's name, in the language stored right now.
  nonisolated static func storedWords(
    _ key: String, of debt: Debt, _ defaults: UserDefaults = .standard
  ) -> String {
    let words = (key: key, table: "Debts")
    let code = AppLanguage.storedCode(in: defaults)
    let bundle =
      Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    var format = bundle.localizedString(forKey: words.key, value: nil, table: words.table)
    if format == words.key {
      format = Bundle.main.localizedString(forKey: words.key, value: "%@", table: words.table)
    }
    return String(format: format, debt.name)
  }
}

extension TransactionsStore {
  /// The edit of a payment of a loan whose interest is an operation of its own
  /// (`DebtInterestPayment.editChange`), from the rows the lists show; `nil` for any other edit,
  /// which is written the usual way.
  func interestEdit(of edited: TransactionEntry, calendar: CalendarContext) -> PlanningChange? {
    guard let listing, let before = listing.entry(edited.id),
      let debtId = before.transaction.debtId,
      let debt = listing.dataset.debts.first(where: { $0.id == debtId })
    else { return nil }
    let dataset = listing.dataset
    if DebtMarkupPayment.applies(to: debt) {
      return DebtMarkupPayment.editChange(
        edited, before: before, debt: debt, dataset: dataset, calendar: calendar,
        today: calendar.day(of: Date()),
        categoryId: DebtInterestPayment.categoryId(of: debt, tree: listing.tree),
        note: DebtMarkupPayment.storedNote(of: debt), now: edited.transaction.updatedAt)
    }
    return DebtInterestPayment.editChange(
      edited, before: before, debts: dataset.debts, entries: dataset.entries,
      journal: dataset.planning.debtEntries.filter { $0.debtId == debtId }, calendar: calendar,
      categoryId: DebtInterestPayment.categoryId(of: debt, tree: listing.tree),
      note: DebtInterestPayment.storedNote(of: debt), now: edited.transaction.updatedAt)
  }
}
