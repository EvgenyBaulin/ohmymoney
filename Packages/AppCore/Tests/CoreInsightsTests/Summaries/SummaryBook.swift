import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

@testable import CoreInsights

/// A synthetic book for the summaries tests: every operation is built in UTC so nothing depends
/// on the time zone of the Mac.
struct SummaryBook {
  struct Spec {
    var amount: Int64 = 1000
    var hour = 18
    var place: UUID?
    var category: UUID?
    var note: String?
    var quality: Quality?
    var kind: TransactionKind = .expense
    var externalId: String?
    var periodMonth: MonthKey?
  }

  var entries: [TransactionEntry] = []
  var categories: [CoreKit.Category] = []
  var places: [Place] = []
  var debts: [Debt] = []
  var debtEntries: [DebtEntry] = []
  var settings = AnalyticsSettings()

  let food = CoreKit.Category(kind: .expense, name: "Продукты")
  let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
  let transport = CoreKit.Category(kind: .expense, name: "Транспорт")
  let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  let cashback = CoreKit.Category(kind: .income, name: "Кэшбэк")
  let recount = CoreKit.Category(kind: .expense, name: "Сверка")
  let shopA = Place(name: "Магазин А")
  let shopB = Place(name: "Магазин Б")

  init() {
    categories = [food, cafe, transport, salary, cashback, recount]
    places = [shopA, shopB]
  }

  static let calendar = CalendarContext.utc

  mutating func add(_ spec: Spec, on day: DateOnly) {
    let id = UUID()
    let amount = AmountE4(whole: spec.amount)
    let moment = Self.calendar.startOfDay(day).addingTimeInterval(Double(spec.hour) * 3600 + 1800)
    let transaction = Transaction(
      id: id, kind: spec.kind, occurredAt: moment, amountE4: amount, note: spec.note,
      placeId: spec.place, periodMonth: spec.periodMonth, externalId: spec.externalId)
    entries.append(
      TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: id, categoryId: spec.category ?? food.id, quality: spec.quality,
            amountE4: amount)
        ]))
  }

  mutating func spend(_ amount: Int64, on day: DateOnly, category: UUID? = nil) {
    add(Spec(amount: amount, category: category), on: day)
  }

  mutating func earn(_ amount: Int64, on day: DateOnly, category: UUID? = nil) {
    add(Spec(amount: amount, category: category ?? salary.id, kind: .income), on: day)
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: categories, places: places, debts: debts,
        planning: PlanningBook(debtEntries: debtEntries), settings: settings),
      calendar: Self.calendar)
  }

  // MARK: - The habits book

  /// Sunday 25 October 2026, the last day of week 43.
  static let end = DateOnly(year: 2026, month: 10, day: 25)
  /// The first day of the flat book: 86 days up to `end`.
  static let start = DateOnly(year: 2026, month: 8, day: 1)

  /// One purchase of 1,000 ₽ every day from `start` to `end`, bought in the evening in shop A
  /// with an unrepeated note — a book in which no check has anything to say. `shape` may
  /// change or add purchases of a day.
  static func flat(
    shape: (_ index: Int, _ day: DateOnly, _ book: inout SummaryBook) -> Bool = { _, _, _ in false }
  ) -> SummaryBook {
    var book = SummaryBook()
    for (index, day) in DayRange(start, end).days.enumerated() {
      if shape(index, day, &book) { continue }
      book.add(Spec(place: book.shopA.id, note: "n\(index)"), on: day)
    }
    return book
  }

  /// The days of the last 28 and of the 28 before them, counted from `end`.
  static func isRecent(_ day: DateOnly) -> Bool { day > end.adding(days: -28) }
  static func isPrior(_ day: DateOnly) -> Bool {
    day <= end.adding(days: -28) && day > end.adding(days: -56)
  }
}
