import AppCore
import Foundation

@testable import OhMyMoney

/// A small book written by hand for the scenarios of Overview, Analytics, Reports, Capital and
/// the calendar: a few categories, and operations of one part (or several) in rubles or another
/// currency, each at noon of its day in UTC, so a day never slips over midnight.
struct InsightsBook {
  let food = CoreKit.Category(kind: .expense, name: "Food")
  let cafe: CoreKit.Category
  let transport = CoreKit.Category(kind: .expense, name: "Transport")
  let fun = CoreKit.Category(kind: .expense, name: "Fun", quality: .bad)
  let health = CoreKit.Category(kind: .expense, name: "Health", quality: .good)
  let salary = CoreKit.Category(kind: .income, name: "Salary")
  let gifts = CoreKit.Category(kind: .income, name: "Gifts")

  /// More categories a scenario needs beside the standard ones.
  var extra: [CoreKit.Category] = []
  var entries: [TransactionEntry] = []
  var links: [ReimbursementLink] = []
  var people: [Person] = []
  var places: [Place] = []
  var events: [Event] = []
  var paymentMethods: [PaymentMethod] = []

  init() {
    cafe = CoreKit.Category(parentId: food.id, kind: .expense, name: "Cafe")
  }

  var categories: [CoreKit.Category] {
    [food, cafe, transport, fun, health, salary, gifts] + extra
  }

  static func whole(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  static func noon(_ day: DateOnly) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  /// One operation of one part. Rubles unless `currency` is given, then `rub` is what it cost.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, _ amount: AmountE4, on day: DateOnly, category: UUID? = nil,
    currency: CurrencyCode = .rub, rub: AmountE4? = nil, forWhom: ForWhom = .me,
    person: UUID? = nil, place: UUID? = nil, event: UUID? = nil, account: UUID? = nil,
    periodMonth: MonthKey? = nil, quality: Quality? = nil, reimbursable: Bool = false,
    debtor: UUID? = nil, status: ReimbursementStatus? = nil, refundOf: UUID? = nil,
    deleted: Bool = false, at seconds: TimeInterval? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let when =
      seconds.map { CalendarContext.utc.startOfDay(day).addingTimeInterval($0) }
      ?? Self.noon(day)
    let rubles = rub ?? amount
    let category = category ?? (kind == .income ? salary.id : food.id)
    let part = TransactionPart(
      transactionId: id, categoryId: category, quality: kind.hasQuality ? quality : nil,
      qualitySource: kind.hasQuality && quality != nil ? .manual : nil, amountE4: amount,
      amountRubE4: rubles, forWhom: forWhom, forPersonId: person, reimbursable: reimbursable,
      debtorPersonId: debtor, reimbursementStatus: status, eventId: event,
      refundOfPartId: refundOf)
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: when, currency: currency, amountE4: amount,
        rate: currency == .rub ? nil : rubles.decimal / amount.decimal,
        amountRubE4: rubles, placeId: place, paymentMethodId: account,
        periodMonth: periodMonth, createdAt: when, updatedAt: when,
        deletedAt: deleted ? when : nil),
      parts: [part])
    entries.append(entry)
    return entry
  }

  /// A split purchase: one operation, a part per amount, each in its category.
  @discardableResult
  mutating func split(_ parts: [(UUID, AmountE4)], on day: DateOnly) -> TransactionEntry {
    let id = UUID()
    let when = Self.noon(day)
    let total = AmountE4.sum(parts.map(\.1))
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: when, amountE4: total, amountRubE4: total,
        createdAt: when, updatedAt: when),
      parts: parts.map {
        TransactionPart(transactionId: id, categoryId: $0.0, amountE4: $0.1, amountRubE4: $0.1)
      })
    entries.append(entry)
    return entry
  }

  var dataset: Dataset {
    Dataset(
      entries: entries, links: links, categories: categories, people: people, places: places,
      events: events, paymentMethods: paymentMethods)
  }

  var ledger: Ledger { Ledger(dataset: dataset, calendar: .utc) }
}

extension DateOnly {
  /// A day of 2026 written short in the scenarios: `.d(9, 15)`.
  static func d(_ month: Int, _ day: Int, _ year: Int = 2026) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }
}
