import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// How much one account needs in one currency this month for the scheduled payments, as in
/// «card X: 10 000 ₸, 50 €, 75 $». A card is topped up in its own money, so a due in a currency
/// the account does not hold is shown in what the account is charged in.
public struct FundingLine: Hashable, Sendable {
  /// The account; `nil` only while there is no main account to stand for a payment that names
  /// none.
  public var paymentMethodId: UUID?
  public var currency: CurrencyCode
  /// Every due date of the month: the ones still ahead at their price, the paid ones at what
  /// their operations took from this account in this currency.
  public var due: AmountE4
  /// What the operations that paid due dates of the month took from this account in this
  /// currency — «Mark as paid» ones and ordinary ones that match a due date.
  public var paid: AmountE4
  /// max(0, due − paid): what still has to be there.
  public var remaining: AmountE4
  /// Some due dates of the line could not be converted into what the account holds for want
  /// of a rate today: they stay in the payment's own currency, which the account does not
  /// hold, and the line says so.
  public var withoutRate: Bool

  public init(
    paymentMethodId: UUID?, currency: CurrencyCode, due: AmountE4, paid: AmountE4,
    remaining: AmountE4, withoutRate: Bool = false
  ) {
    self.paymentMethodId = paymentMethodId
    self.currency = currency
    self.due = due
    self.paid = paid
    self.remaining = remaining
    self.withoutRate = withoutRate
  }
}

public enum Funding {

  /// The funding of `month`, by account and currency.
  ///
  /// * Due — every due date of the month. The dates still ahead come from the schedule of
  ///   each active payment, from its `next_date`, at the price on that date. Each goes to the
  ///   payment's account — the main one (`mainId`) when it names none or names an archived
  ///   account, which the payment is paid from instead — in the payment's currency when the
  ///   account holds it; otherwise in the account's main currency, converted through rubles
  ///   at today's rates (`rubPerUnit`, rubles for one unit), or, without a rate, left in its
  ///   own currency on a line marked `withoutRate`. The dates already paid are settled where
  ///   their money came from: the operation's account and what moved on it
  ///   (`Transaction.movedMoney`), at its amount. A skipped date is in neither and needs no
  ///   money.
  /// * Paid — the operations that paid due dates of the month: those «Mark as paid» wrote
  ///   (`sched:<payment>:<due>`) and ordinary ones that match a due date (`matches`). A
  ///   subscription paid from another card draws on that card, and the payment's own card is
  ///   not asked for it again. A paid date never leaves anything remaining.
  ///
  /// An operation counts in the month of the due date it paid, not of its own date: paying
  /// the 1 October charge on 30 September settles October. `today` does not change the
  /// figures — an overdue date of the month still needs its money. An account the list does
  /// not know is taken to hold every currency.
  ///
  /// Sorted the way every list of accounts is: the main account first, then the others in the
  /// order of the menus (`AccountRules.ordered`, archived ones included), then accounts the
  /// list does not know by id, none last; within an account its currencies in its own order,
  /// then any other by code.
  public static func month(
    _ month: MonthKey, book: PlanningBook, ledger: Ledger, today: DateOnly,
    accounts: [PaymentMethod] = [], mainId: UUID? = nil,
    rubPerUnit: [CurrencyCode: Decimal] = [:], matches: ScheduledMatches = .empty,
    locale: Locale = Locale(identifier: "en")
  ) -> [FundingLine] {
    struct Key: Hashable {
      let method: UUID?
      let currency: CurrencyCode
    }
    var due: [Key: AmountE4] = [:]
    var paid: [Key: AmountE4] = [:]
    var unconverted: Set<Key> = []
    let payments = Dictionary(
      book.scheduled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let accountsById = Dictionary(
      accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    func settle(_ transactionId: UUID) {
      guard let entry = ledger.entry(transactionId) else { return }
      let transaction = entry.transaction
      let moved = transaction.movedMoney
      let key = Key(method: transaction.paymentMethodId ?? mainId, currency: moved.currency)
      due[key, default: .zero] += moved.amount
      paid[key, default: .zero] += moved.amount
    }

    var paidDues: [UUID: Set<DateOnly>] = [:]
    for row in ledger.rows where row.isFirstPart {
      guard case .scheduled(let paymentId, let dueDate) = row.link, dueDate.monthKey == month,
        payments[paymentId] != nil
      else { continue }
      settle(row.transactionId)
      paidDues[paymentId, default: []].insert(dueDate)
    }

    for payment in book.scheduled where payment.active {
      guard let next = payment.nextDate else { continue }
      let dates = Recurrence.occurrences(
        from: next, through: month.lastDay, rule: RecurrenceRule(payment: payment),
        end: payment.endDate, limit: 10_000)
      for date in dates where date >= month.firstDay {
        guard paidDues[payment.id]?.contains(date) != true else { continue }
        if let operation = matches.operation(for: payment.id, date) {
          settle(operation)
          paidDues[payment.id, default: []].insert(date)
          continue
        }
        let price = SubscriptionMath.price(of: payment, on: date, prices: book.prices)
        // A payment on an archived account is paid from the main one.
        let own = payment.paymentMethodId.flatMap { accountsById[$0] }
        let method = own?.archived == true ? mainId : (payment.paymentMethodId ?? mainId)
        guard let account = method.flatMap({ accountsById[$0] }), !account.holds(payment.currency)
        else {
          due[Key(method: method, currency: payment.currency), default: .zero] += price
          continue
        }
        let target = account.mainCurrency
        if let from = perUnit(payment.currency, rubPerUnit), let to = perUnit(target, rubPerUnit),
          let converted = AccountRules.crossConvert(price, fromPerUnit: from, toPerUnit: to)
        {
          due[Key(method: method, currency: target), default: .zero] += converted
        } else {
          let key = Key(method: method, currency: payment.currency)
          due[key, default: .zero] += price
          unconverted.insert(key)
        }
      }
    }

    let keys = Set(due.keys).union(paid.keys)
    var place: [UUID: Int] = [:]
    for (index, account) in AccountRules.ordered(accounts, locale: locale, includeArchived: true)
      .enumerated()
    {
      place[account.id] = index + 1
    }
    if let mainId { place[mainId] = 0 }
    func accountPrecedes(_ left: UUID?, _ right: UUID?) -> Bool {
      guard let left else { return false }
      guard let right else { return true }
      switch (place[left], place[right]) {
      case (let first?, let second?): return first < second
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): return left.uuidString < right.uuidString
      }
    }
    func currencyPrecedes(_ left: CurrencyCode, _ right: CurrencyCode, on account: UUID?) -> Bool {
      let held = account.flatMap { accountsById[$0] }?.currencies ?? []
      switch (held.firstIndex(of: left), held.firstIndex(of: right)) {
      case (let first?, let second?): return first < second
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): return left.code < right.code
      }
    }
    return
      keys
      .map { key in
        let owed = due[key] ?? .zero
        let spent = paid[key] ?? .zero
        return FundingLine(
          paymentMethodId: key.method, currency: key.currency, due: owed, paid: spent,
          remaining: max(.zero, owed - spent), withoutRate: unconverted.contains(key))
      }
      .sorted { left, right in
        if left.paymentMethodId != right.paymentMethodId {
          return accountPrecedes(left.paymentMethodId, right.paymentMethodId)
        }
        return currencyPrecedes(left.currency, right.currency, on: left.paymentMethodId)
      }
  }

  /// Rubles for one unit: 1 for the ruble, the caller's rate otherwise.
  private static func perUnit(
    _ currency: CurrencyCode, _ rubPerUnit: [CurrencyCode: Decimal]
  ) -> Decimal? {
    if currency == .rub { return 1 }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return rate
  }
}
