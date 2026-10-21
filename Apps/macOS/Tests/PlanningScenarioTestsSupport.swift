import AppCore
import Foundation

@testable import OhMyMoney

/// Builders the planning scenarios share: a day from its ISO text, money in whole rubles or
/// kopecks, and operations of one part dated at noon of their day in UTC — the calendar every
/// scenario reads its ledger with.
enum PlanningScenario {
  static let calendar = CalendarContext.utc

  static func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  static func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  /// Kopecks: `kop(12_345)` is 123.45 ₽.
  static func kop(_ cents: Int64) -> AmountE4 { AmountE4(raw: cents * 100) }

  /// An operation of one part on `day`, in rubles unless `currency` says otherwise; `rubles`
  /// are the rubles it was written at (the amount itself for rubles).
  static func entry(
    _ kind: TransactionKind, _ amount: AmountE4, on day: String, category: UUID?,
    currency: CurrencyCode = .rub, rubles: AmountE4? = nil, account: UUID? = nil,
    externalId: String? = nil, goal: UUID? = nil, event: UUID? = nil, rateDate: DateOnly? = nil,
    periodMonth: MonthKey? = nil, reimbursable: Bool = false, quality: Quality? = nil,
    forWhom: ForWhom = .me
  ) -> TransactionEntry {
    let id = UUID()
    let when = calendar.noon(of: DateOnly(iso: day)!)
    let rub = currency == .rub ? amount : (rubles ?? amount)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: when, currency: currency, amountE4: amount,
        rate: currency == .rub ? nil : rub.decimal / amount.decimal, rateDate: rateDate,
        rateSource: currency == .rub ? nil : .manual, amountRubE4: rub,
        paymentMethodId: account, periodMonth: periodMonth, externalId: externalId,
        createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category, quality: quality, amountE4: amount,
          amountRubE4: rub, forWhom: forWhom,
          reimbursable: reimbursable, reimbursementStatus: reimbursable ? .expected : nil,
          eventId: event, goalId: goal)
      ])
  }

  static func ledger(
    _ entries: [TransactionEntry], categories: [CoreKit.Category] = [],
    accounts: [PaymentMethod] = [], goals: [Goal] = [], events: [Event] = [],
    planning: PlanningBook = .empty
  ) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: categories, events: events, paymentMethods: accounts,
        goals: goals, planning: planning),
      calendar: calendar)
  }
}
