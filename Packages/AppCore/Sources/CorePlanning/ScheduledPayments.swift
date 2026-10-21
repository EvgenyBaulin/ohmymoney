import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

// MARK: - Prices and equivalents

/// A price change of a subscription announced ahead: from `date` on it costs `new` instead
/// of `old`, both in the currency of the payment.
public struct SubscriptionPriceChange: Hashable, Sendable {
  public var date: DateOnly
  public var old: AmountE4
  public var new: AmountE4

  public init(date: DateOnly, old: AmountE4, new: AmountE4) {
    self.date = date
    self.old = old
    self.new = new
  }
}

/// The rows of the price history an edit writes, and the ones it removes.
public struct PriceEdit: Hashable, Sendable {
  public var rows: [SubscriptionPrice]
  public var removed: [UUID]

  public init(rows: [SubscriptionPrice], removed: [UUID]) {
    self.rows = rows
    self.removed = removed
  }
}

/// Prices of a subscription over time, what one charge costs per month and per year, and
/// the conversion to rubles the planning shares. Amounts are exact `Decimal` arithmetic,
/// rounded once, half away from zero.
public enum SubscriptionMath {

  /// What the payment costs on `day`: the latest price row dated on or before it, otherwise
  /// the amount of the payment itself (a payment without a price history).
  public static func price(
    of payment: ScheduledPayment, on day: DateOnly, prices: [SubscriptionPrice]
  ) -> AmountE4 {
    var latest: SubscriptionPrice?
    for row in prices where row.paymentId == payment.id && row.date <= day {
      // On the same date the row listed later wins: it was written later.
      if latest.map({ row.date >= $0.date }) ?? true { latest = row }
    }
    return latest?.amountE4 ?? payment.amountE4
  }

  /// One charge per month: weekly a × 52 ÷ 12 ÷ i, monthly a ÷ i, yearly a ÷ 12 ÷ i.
  public static func monthlyEquivalent(_ amount: AmountE4, rule: RecurrenceRule) -> AmountE4 {
    let value = amount.decimal
    let interval = Decimal(max(1, rule.interval))
    switch rule.freq {
    case .weekly: return rounded(value * 52 / 12 / interval)
    case .monthly: return rounded(value / interval)
    case .yearly: return rounded(value / 12 / interval)
    }
  }

  /// One charge per year: weekly a × 52 ÷ i, monthly a × 12 ÷ i, yearly a ÷ i. Counted from
  /// the charge, not from the rounded monthly figure, so a weekly payment is 52 charges a
  /// year rather than twelve «months» of 4.33 weeks.
  public static func yearlyEquivalent(_ amount: AmountE4, rule: RecurrenceRule) -> AmountE4 {
    let value = amount.decimal
    let interval = Decimal(max(1, rule.interval))
    switch rule.freq {
    case .weekly: return rounded(value * 52 / interval)
    case .monthly: return rounded(value * 12 / interval)
    case .yearly: return rounded(value / interval)
    }
  }

  /// What an edit of a payment's amount or currency does to its price history.
  ///
  /// Any kind: bills are priced by the same history as subscriptions. The new amount holds
  /// from `today` — or from the day after `charged`, the last due charged, when that is today
  /// or later; a row already dated that day is replaced, not doubled. Before its first row
  /// a payment is priced by its own amount — the one the edit replaces — so when no row
  /// covers `since` (the earliest day still priced: the last charge, an overdue due), a row
  /// of the old amount dated then — and never later than yesterday — keeps the past at what
  /// it cost.
  ///
  /// A price has no currency of its own; it is read in the payment's. A change of currency
  /// therefore carries no old number over and removes the history: the payment's own amount
  /// prices every day again.
  public static func priceEdit(
    previous: ScheduledPayment, updated: ScheduledPayment, prices: [SubscriptionPrice],
    today: DateOnly, since: DateOnly?, charged: DateOnly? = nil
  ) -> PriceEdit {
    let own = prices.filter { $0.paymentId == updated.id }
    if previous.currency != updated.currency {
      return PriceEdit(rows: [], removed: own.map(\.id))
    }
    guard previous.amountE4 != updated.amountE4 else { return PriceEdit(rows: [], removed: []) }
    // A due already charged today or ahead keeps the price it was charged at: the new one
    // starts the day after it.
    let from = charged.map { max(today, $0.adding(days: 1)) } ?? today
    let sameDay = own.first { $0.date == from }
    var rows = [
      SubscriptionPrice(
        id: sameDay?.id ?? UUID(), paymentId: updated.id, date: from,
        amountE4: updated.amountE4)
    ]
    // The old price is anchored before today: a row of it dated today or later would sit in
    // the window of the reminders and read as a change back to it (fourth review, 19.09).
    let anchor = since.map { min($0, today.adding(days: -1)) }
    let covered = own.contains { row in anchor.map { row.date <= $0 } ?? true }
    if let anchor, anchor < from, !covered {
      rows.append(
        SubscriptionPrice(paymentId: updated.id, date: anchor, amountE4: previous.amountE4))
    }
    return PriceEdit(rows: rows, removed: [])
  }

  /// The first price row after `today` and no later than `days` days ahead that differs
  /// from what the payment costs today. Rows that repeat today's price announce nothing.
  public static func upcomingPriceChange(
    of payment: ScheduledPayment, prices: [SubscriptionPrice], today: DateOnly,
    within days: Int
  ) -> SubscriptionPriceChange? {
    let current = price(of: payment, on: today, prices: prices)
    let horizon = today.adding(days: max(0, days))
    let change =
      prices
      .filter { $0.paymentId == payment.id && $0.date > today && $0.date <= horizon }
      .sorted { $0.date < $1.date }
      .first { $0.amountE4 != current }
    return change.map { SubscriptionPriceChange(date: $0.date, old: current, new: $0.amountE4) }
  }

  /// The amount in rubles at the rate the caller knows (`rubPerUnit`, rubles for one unit);
  /// rubles are rubles. `nil` without a rate: the planning lists such a payment apart
  /// instead of guessing.
  public static func rubles(
    _ amount: AmountE4, in currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    if currency == .rub { return amount }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return rounded(amount.decimal * rate)
  }

  /// Rounded half away from zero to stored units; sums of real money never leave the range,
  /// anything that does is clamped rather than trapping.
  static func rounded(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }
}

// MARK: - One-off payments

extension ScheduledPayment {
  /// A planned expense of one date — «Разово»: every month and ending on its own next date,
  /// the way the form saves it (and reads it back). It is one charge, not a rhythm: it has no
  /// figure per month or per year and adds nothing to what the subscriptions cost.
  public var isOneOff: Bool {
    guard let next = nextDate else { return false }
    return freq == .monthly && interval == 1 && endDate == next
  }
}

// MARK: - Status of a payment

/// The last operation «Mark as paid» wrote for a payment.
public struct ScheduledCharge: Hashable, Sendable {
  public var transactionId: UUID
  /// The day of the operation.
  public var day: DateOnly
  /// The due date it paid.
  public var due: DateOnly
  /// The whole operation, in its own currency.
  public var amount: AmountE4
  public var currency: CurrencyCode

  public init(
    transactionId: UUID, day: DateOnly, due: DateOnly, amount: AmountE4, currency: CurrencyCode
  ) {
    self.transactionId = transactionId
    self.day = day
    self.due = due
    self.amount = amount
    self.currency = currency
  }
}

/// What one payment costs me and what the person it is for gives back, in rubles.
public struct ScheduledShare: Hashable, Sendable {
  public var amountRub: AmountE4
  /// Zero unless the payment is reimbursable.
  public var expectedReturnRub: AmountE4
  /// max(0, amount − expected return).
  public var myShareRub: AmountE4

  public init(amountRub: AmountE4, expectedReturnRub: AmountE4, myShareRub: AmountE4) {
    self.amountRub = amountRub
    self.expectedReturnRub = expectedReturnRub
    self.myShareRub = myShareRub
  }
}

/// One line of the list of scheduled payments and subscriptions.
public struct ScheduledStatus: Hashable, Sendable, Identifiable {
  public var payment: ScheduledPayment
  /// Due dates from `next_date` through the end of this month, the overdue ones included,
  /// at most 12 — the latest ones, so this month's are always in it however long the
  /// payment has been overdue. Empty when the next one falls in a later month.
  public var dueDates: [DateOnly]
  public var nextDue: DateOnly
  /// A due date from the next one on is before today and still unpaid — neither by «Mark as
  /// paid» nor by an ordinary operation that matches it.
  public var isOverdue: Bool
  /// The price on the next unpaid due date (`nextUnpaid`, else `next_date`), in the currency
  /// of the payment.
  public var amountNext: AmountE4
  /// `amountNext` per month and per year (`SubscriptionMath`); zero for a one-off payment,
  /// which is one charge and no rhythm (`isOneOff`).
  public var monthly: AmountE4
  public var yearly: AmountE4
  /// A planned expense of one date, «Разово» (`ScheduledPayment.isOneOff`): the list shows no
  /// figure per month or per year for it.
  public var isOneOff: Bool
  /// My part of that charge in rubles; `nil` when a rate is missing.
  public var myShareRubNext: AmountE4?
  /// What the person gives back for the next charge, in rubles; `nil` without a rate.
  public var expectedReturnRubNext: AmountE4?
  public var lastCharge: ScheduledCharge?
  /// The last charge differed from the price on its due date — in amount or in currency.
  public var chargedDifferently: Bool
  /// Due dates from the next one on that an ordinary operation pays by matching them
  /// (`ScheduledMatching`), with that operation: «оплачено операцией», to tie with
  /// «Привязать» or to dismiss with «Это другое».
  public var matchedDues: [DateOnly: UUID]
  /// The first due date from `next_date` on that nothing paid — neither a key nor a matching
  /// operation: the date the list shows as the next one. `next_date` stays behind it while
  /// ordinary operations pay the payment, since nothing moves it then. When every due date
  /// through the end of the payment is paid, the last of them (its operation is in
  /// `matchedDues`). Given no value, `nextDue`.
  public var nextUnpaid: DateOnly
  /// The payment names an account that is archived: it is paid from — and comes off — the main
  /// account, and the list says «счёт в архиве — перенесите платёж на другой».
  public var accountArchived: Bool

  public init(
    payment: ScheduledPayment, dueDates: [DateOnly], nextDue: DateOnly, isOverdue: Bool,
    amountNext: AmountE4, monthly: AmountE4, yearly: AmountE4, myShareRubNext: AmountE4?,
    expectedReturnRubNext: AmountE4?, lastCharge: ScheduledCharge?, chargedDifferently: Bool,
    matchedDues: [DateOnly: UUID] = [:], nextUnpaid: DateOnly? = nil, isOneOff: Bool = false,
    accountArchived: Bool = false
  ) {
    self.payment = payment
    self.dueDates = dueDates
    self.nextDue = nextDue
    self.isOverdue = isOverdue
    self.amountNext = amountNext
    self.monthly = monthly
    self.yearly = yearly
    self.myShareRubNext = myShareRubNext
    self.expectedReturnRubNext = expectedReturnRubNext
    self.lastCharge = lastCharge
    self.chargedDifferently = chargedDifferently
    self.matchedDues = matchedDues
    self.nextUnpaid = nextUnpaid ?? nextDue
    self.isOneOff = isOneOff
    self.accountArchived = accountArchived
  }

  /// How many due dates `dueDates` keeps at most.
  public static let dueDatesKept = 12

  public var id: UUID { payment.id }
  /// The payment or its reimbursement is in a currency without a known rate.
  public var isWithoutRate: Bool { myShareRubNext == nil }
}

// MARK: - Mark as paid

/// Everything «Mark as paid» asks the storage layer to write, decided here and applied by
/// the repository: the operation, the key that ties it to the due date, the payment moved
/// on to its next due date and, when the owner chose to, the new price.
public struct MarkAsPaidPlan: Hashable, Sendable {
  public var draft: TransactionDraft
  /// `OperationLink.scheduled(paymentId:due:)` — goes to `transactions.external_id`; the
  /// unique index on it makes one due date impossible to pay twice.
  public var externalId: String
  /// The payment with `next_date` moved past the paid due date.
  public var payment: ScheduledPayment
  /// A price row dated the due date, when the price was updated and differs.
  public var newPrice: SubscriptionPrice?

  public init(
    draft: TransactionDraft, externalId: String, payment: ScheduledPayment,
    newPrice: SubscriptionPrice?
  ) {
    self.draft = draft
    self.externalId = externalId
    self.payment = payment
    self.newPrice = newPrice
  }
}

/// Why a payment cannot be saved as it is. `key` is what the app localizes.
public enum ScheduledIssue: String, Error, Hashable, Sendable, CaseIterable {
  case emptyName
  case nonPositiveAmount
  case badInterval
  case badDay
  case badMonth
  case negativeReimbursement
  case incomeCategory
  case systemCategory

  public var key: String { "planning.scheduled.issue.\(rawValue)" }
}

// MARK: - Rules

/// Scheduled payments and subscriptions: their status, «Mark as paid», «Skip» and the checks
/// before saving.
public enum ScheduledRules {

  /// The status of every active payment that still has a due date, the soonest unpaid one
  /// first. `matches` are the due dates ordinary operations paid (`ScheduledMatching`): the
  /// price, its equivalents and my part are those of the first due date nothing paid.
  public static func statuses(
    book: PlanningBook, ledger: Ledger, today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal] = [:], matches: ScheduledMatches = .empty
  ) -> [ScheduledStatus] {
    let charges = lastCharges(ledger: ledger)
    let endOfMonth = today.monthKey.lastDay
    let archived = Set(ledger.dataset.paymentMethods.filter(\.archived).map(\.id))
    var result: [ScheduledStatus] = []
    for payment in book.scheduled where payment.active {
      guard let nextDue = payment.nextDate, payment.endDate.map({ nextDue <= $0 }) ?? true
      else { continue }
      let rule = RecurrenceRule(payment: payment)
      let oneOff = payment.isOneOff
      let shown = firstUnpaid(of: payment, from: nextDue, rule: rule, matches: matches)
      let amount = SubscriptionMath.price(of: payment, on: shown.due, prices: book.prices)
      let split = share(of: payment, amount: amount, rubPerUnit: rubPerUnit)
      let charge = charges[payment.id]
      let chargedDifferently =
        charge.map { charge in
          charge.currency != payment.currency
            || charge.amount
              != SubscriptionMath.price(of: payment, on: charge.due, prices: book.prices)
        } ?? false
      result.append(
        ScheduledStatus(
          payment: payment,
          dueDates: Array(
            Recurrence.occurrences(
              from: nextDue, through: endOfMonth, rule: rule, end: payment.endDate,
              limit: 10_000
            ).suffix(ScheduledStatus.dueDatesKept)),
          nextDue: nextDue,
          isOverdue: shown.isUnpaid && shown.due < today,
          amountNext: amount,
          monthly: oneOff ? .zero : SubscriptionMath.monthlyEquivalent(amount, rule: rule),
          yearly: oneOff ? .zero : SubscriptionMath.yearlyEquivalent(amount, rule: rule),
          myShareRubNext: split?.myShareRub,
          expectedReturnRubNext: split?.expectedReturnRub,
          lastCharge: charge,
          chargedDifferently: chargedDifferently,
          matchedDues: matches.matchedDues(of: payment.id), nextUnpaid: shown.due,
          isOneOff: oneOff,
          accountArchived: payment.paymentMethodId.map(archived.contains) ?? false))
    }
    return result.sorted { left, right in
      if left.nextUnpaid != right.nextUnpaid { return left.nextUnpaid < right.nextUnpaid }
      if left.payment.name != right.payment.name { return left.payment.name < right.payment.name }
      return left.payment.id.uuidString < right.payment.id.uuidString
    }
  }

  /// The first due date from `nextDue` on that no key and no matching operation paid, looking
  /// at `ScheduledMatching.duesPerPayment` due dates at most. When the payment ends before
  /// one, its last due date, paid.
  static func firstUnpaid(
    of payment: ScheduledPayment, from nextDue: DateOnly, rule: RecurrenceRule,
    matches: ScheduledMatches
  ) -> (due: DateOnly, isUnpaid: Bool) {
    var due = nextDue
    for _ in 0..<ScheduledMatching.duesPerPayment {
      guard matches.isPaid(payment.id, due) else { return (due, true) }
      let next = Recurrence.next(after: due, rule: rule)
      if let end = payment.endDate, next > end { return (due, false) }
      due = next
    }
    return (due, !matches.isPaid(payment.id, due))
  }

  /// One charge of `amount` (in the payment's currency) split into what the person gives
  /// back and my part, in rubles.
  ///
  /// The return is zero unless the payment is reimbursable; then it is the reimbursement
  /// amount in its own currency (the payment's when none is set), at most the charge, or the
  /// whole charge when no reimbursement amount is set. `nil` when either currency has no
  /// known rate.
  public static func share(
    of payment: ScheduledPayment, amount: AmountE4, rubPerUnit: [CurrencyCode: Decimal]
  ) -> ScheduledShare? {
    guard
      let amountRub = SubscriptionMath.rubles(amount, in: payment.currency, rubPerUnit: rubPerUnit)
    else { return nil }
    var returnRub = AmountE4.zero
    if payment.reimbursable {
      if let reimbursement = payment.reimbursementAmountE4 {
        guard
          let converted = SubscriptionMath.rubles(
            reimbursement, in: payment.reimbursementCurrency ?? payment.currency,
            rubPerUnit: rubPerUnit)
        else { return nil }
        // Never more than the charge, as «Mark as paid» writes it (`expectedReturn`).
        returnRub = min(max(.zero, converted), max(.zero, amountRub))
      } else {
        returnRub = amountRub
      }
    }
    return ScheduledShare(
      amountRub: amountRub, expectedReturnRub: returnRub,
      myShareRub: max(.zero, amountRub - returnRub))
  }

  /// The operation for one due date of a payment, and the payment moved on.
  ///
  /// The operation is an expense of `amount` in the payment's currency, with its category,
  /// payment method, «for whom» and the name of the payment as its description. A payment
  /// for somebody who gives the money back is split in two parts: the part they return —
  /// reimbursable, owed by the debtor (or by the person it is for), expected — and my part
  /// for the rest, if anything is left. The return is the reimbursement amount converted to
  /// the payment's currency through the rubles of both (`rate`, the rate the operation was
  /// paid at, stands for the payment's currency when given); without a rate the whole
  /// amount is reimbursable, and the reimbursement sheet settles the difference later as a
  /// surplus or a shortfall. The parts always add up to `amount`.
  ///
  /// The quality of the parts follows `QualityResolver`, with the payment's name as the
  /// description. A foreign operation carries `rate` as a rate typed by hand; without one
  /// the app applies the bank's rate the way it does for any draft, and it fills the rate
  /// date, which needs the calendar.
  ///
  /// `next_date` moves to the occurrence after `due` — to none past `end_date`. Paying a
  /// due date earlier than `next_date` (one paid or skipped already) leaves it where it is.
  /// With `updatePrice`, an amount other than the price on `due` becomes the price from
  /// `due` on.
  ///
  /// `eventId` — the event the due date belongs to (`event(of:due:events:)`) — goes onto every
  /// part, so the payment counts in the event's «потрачено». The payment's card goes onto the
  /// operation while it is a live card of `cards`; an archived or unknown one is left off.
  public static func markAsPaid(
    _ payment: ScheduledPayment, due: DateOnly, amount: AmountE4, occurredAt: Date,
    paidAt rate: Decimal? = nil, rubPerUnit: [CurrencyCode: Decimal] = [:],
    updatePrice: Bool = false, prices: [SubscriptionPrice] = [],
    categories: CategoryTree = CategoryTree(), history: ManualQualityHistory = .empty,
    eventId: UUID? = nil, cards: [PaymentCard] = []
  ) throws -> MarkAsPaidPlan {
    guard amount.raw > 0 else { throw ScheduledIssue.nonPositiveAmount }
    let rate = rate.flatMap { $0 > 0 ? $0 : nil }
    let decision = QualityResolver.resolve(
      categoryId: payment.categoryId, description: payment.name, categories: categories,
      history: history)

    func part(_ amount: AmountE4, reimbursable: Bool) -> PartDraft {
      PartDraft(
        categoryId: payment.categoryId, categorySource: .manual, quality: decision.quality,
        qualitySource: decision.source, amount: amount, forWhom: payment.forWhom,
        forPersonId: payment.forPersonId, reimbursable: reimbursable,
        debtorPersonId: reimbursable ? (payment.debtorPersonId ?? payment.forPersonId) : nil,
        reimbursementStatus: reimbursable ? .expected : nil, eventId: eventId)
    }

    var parts: [PartDraft] = []
    let returned = expectedReturn(of: payment, amount: amount, paidAt: rate, rubPerUnit: rubPerUnit)
    if returned.raw > 0 {
      parts.append(part(returned, reimbursable: true))
      let mine = amount - returned
      if mine.raw > 0 { parts.append(part(mine, reimbursable: false)) }
    } else {
      parts.append(part(amount, reimbursable: false))
    }

    let foreign = payment.currency != .rub
    var draft = TransactionDraft(
      kind: .expense, occurredAt: occurredAt, currency: payment.currency, amount: amount,
      rate: foreign ? rate : nil, rateSource: foreign && rate != nil ? .manual : nil,
      rateProvisional: false, note: payment.name, paymentMethodId: payment.paymentMethodId,
      parts: parts)
    draft.cardId = cards.first { $0.id == payment.cardId && !$0.archived }?.id

    var newPrice: SubscriptionPrice?
    if updatePrice, amount != SubscriptionMath.price(of: payment, on: due, prices: prices) {
      newPrice = SubscriptionPrice(paymentId: payment.id, date: due, amountE4: amount)
    }
    return MarkAsPaidPlan(
      draft: draft,
      externalId: OperationLink.scheduled(paymentId: payment.id, due: due).externalId,
      payment: advanced(payment, past: due), newPrice: newPrice)
  }

  /// «Skip»: the due date passes without an operation, and `next_date` moves on exactly as
  /// after a payment.
  public static func skip(_ payment: ScheduledPayment, due: DateOnly) -> ScheduledPayment {
    advanced(payment, past: due)
  }

  /// «Уже списано до сверки»: the bank took the money of `due` before a count, so the count
  /// holds it gone and the due date closes without an operation — `next_date` moves past it
  /// exactly as «Skip» moves it.
  public static func settledByCount(
    _ payment: ScheduledPayment, due: DateOnly
  ) -> ScheduledPayment {
    advanced(payment, past: due)
  }

  /// The event a due date of `payment` belongs to: the payment's event while it is among
  /// `events` and `due` is on or before its last day; `nil` otherwise — a due after the
  /// event's end is an ordinary payment.
  public static func event(
    of payment: ScheduledPayment, due: DateOnly, events: [Event]
  ) -> UUID? {
    guard let eventId = payment.eventId,
      let event = events.first(where: { $0.id == eventId }), due <= event.endDate
    else { return nil }
    return event.id
  }

  /// The first thing wrong with a payment, or `nil` when it can be saved. An unknown
  /// category is not an issue here: the tree may be partial, the storage checks the
  /// reference.
  public static func validate(_ payment: ScheduledPayment, tree: CategoryTree) -> ScheduledIssue? {
    if payment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
    if payment.amountE4.raw <= 0 { return .nonPositiveAmount }
    if payment.interval < 1 { return .badInterval }
    if let month = payment.month, !(1...12).contains(month) { return .badMonth }
    if let day = payment.day {
      switch payment.freq {
      case .weekly:
        if !(1...7).contains(day) { return .badDay }
      case .monthly:
        if !(1...31).contains(day) { return .badDay }
      case .yearly:
        // The longest the month can be — 29 in February, which a leap year reaches.
        let longest = payment.month.map { MonthKey(year: 2000, month: $0).dayCount } ?? 31
        if !(1...longest).contains(day) { return .badDay }
      }
    }
    if let reimbursement = payment.reimbursementAmountE4, reimbursement.isNegative {
      return .negativeReimbursement
    }
    if let category = tree.category(payment.categoryId) {
      if category.kind == .income { return .incomeCategory }
      if tree.systemRole(of: category.id) != nil { return .systemCategory }
    }
    return nil
  }

  /// The payment with `due` owed again, for when the operation that paid it (its `sched:`
  /// link) is deleted: `next_date` goes back to `due`. Only the latest paid date goes back —
  /// the one «Mark as paid» moved the payment past, so `next_date` is still the occurrence
  /// right after it (or none, past `end_date`). Once a later date was paid or skipped the
  /// schedule has moved on and is left alone: `nil`, nothing to change.
  public static func reopened(_ payment: ScheduledPayment, due: DateOnly) -> ScheduledPayment? {
    if let current = payment.nextDate, current <= due { return nil }
    var reopened = payment
    reopened.nextDate = due
    guard advanced(reopened, past: due).nextDate == payment.nextDate else { return nil }
    return reopened
  }

  // MARK: Helpers

  /// The payment with `next_date` past `due`: the next occurrence, or none past `end_date`.
  static func advanced(_ payment: ScheduledPayment, past due: DateOnly) -> ScheduledPayment {
    if let current = payment.nextDate, due < current { return payment }
    var copy = payment
    let next = Recurrence.next(after: due, rule: RecurrenceRule(payment: payment))
    copy.nextDate = payment.endDate.map { next > $0 } == true ? nil : next
    return copy
  }

  /// The part of `amount` the person gives back, in the payment's currency, 0…amount.
  static func expectedReturn(
    of payment: ScheduledPayment, amount: AmountE4, paidAt rate: Decimal?,
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4 {
    guard payment.reimbursable else { return .zero }
    guard let reimbursement = payment.reimbursementAmountE4 else { return amount }
    let currency = payment.reimbursementCurrency ?? payment.currency
    let inPaymentCurrency: AmountE4
    if currency == payment.currency {
      inPaymentCurrency = reimbursement
    } else {
      func perUnit(_ code: CurrencyCode) -> Decimal? {
        if code == .rub { return 1 }
        if code == payment.currency, let rate { return rate }
        return rubPerUnit[code].flatMap { $0 > 0 ? $0 : nil }
      }
      guard let from = perUnit(currency), let to = perUnit(payment.currency) else { return amount }
      inPaymentCurrency = SubscriptionMath.rounded(reimbursement.decimal * from / to)
    }
    return min(max(.zero, inPaymentCurrency), amount)
  }

  /// The last live operation «Mark as paid» wrote for each payment: the latest by day and
  /// time, as the ledger orders them.
  static func lastCharges(ledger: Ledger) -> [UUID: ScheduledCharge] {
    var result: [UUID: ScheduledCharge] = [:]
    for row in ledger.rows where row.isFirstPart {
      guard case .scheduled(let paymentId, let due) = row.link,
        let entry = ledger.entry(row.transactionId)
      else { continue }
      result[paymentId] = ScheduledCharge(
        transactionId: row.transactionId, day: row.day, due: due,
        amount: entry.transaction.amountE4, currency: entry.transaction.currency)
    }
    return result
  }
}
