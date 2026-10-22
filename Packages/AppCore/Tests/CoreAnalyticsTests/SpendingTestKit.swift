import CoreKit
import Foundation

@testable import CoreAnalytics

/// Small hand-made books for the tests of «Разбор трат». Everything is synthetic; the ledger
/// reads days in Moscow, as the application does.
enum SpendKit {
  static let moscow = CalendarContext.moscow
  static let singapore = TimeZone(identifier: "Asia/Singapore")!
  static let bangkok = TimeZone(identifier: "Asia/Bangkok")!

  static let food = CoreKit.Category(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!, kind: .expense, name: "Food")
  static let dairy = CoreKit.Category(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!, parentId: food.id,
    kind: .expense, name: "Dairy")
  static let taxi = CoreKit.Category(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!, kind: .expense, name: "Taxi")
  static let fun = CoreKit.Category(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F4")!, kind: .expense, name: "Fun")
  static let salary = CoreKit.Category(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F5")!, kind: .income, name: "Salary")
  static let gifts = CoreKit.Category(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F6")!, kind: .income, name: "Gifts")
  static let all = [food, dairy, taxi, fun, salary, gifts]

  static func day(_ year: Int, _ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  /// The instant of `hour`:`minute` of `day` on the clock of `zone`.
  static func moment(
    _ day: DateOnly, _ hour: Int, _ minute: Int = 0, in zone: TimeZone = moscow.timeZone
  ) -> Date {
    CalendarContext(timeZone: zone).moment(day, hour: hour, minute: minute)
  }

  /// What the entry line gives an operation typed without a time.
  static func noon(_ day: DateOnly) -> Date { moscow.noon(of: day) }

  /// One operation of one part. `zone` is the zone it is recorded in (`nil` — none, as before
  /// 1.13).
  static func entry(
    _ whole: Int64, at instant: Date, kind: TransactionKind = .expense,
    category: CoreKit.Category = food, place: UUID? = nil, person: UUID? = nil,
    zone: String? = nil, reimbursable: Bool = false, status: ReimbursementStatus? = nil,
    refundOf: UUID? = nil, id: UUID = UUID(), partId: UUID = UUID()
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: instant, amount: AmountE4(whole: whole), placeId: place)
    var part = PartDraft(id: partId, categoryId: category.id, amount: AmountE4(whole: whole))
    if let person {
      part.forWhom = .other
      part.forPersonId = person
    }
    if reimbursable {
      part.reimbursable = true
      part.debtorPersonId = person ?? UUID()
      part.reimbursementStatus = status ?? .expected
    }
    part.refundOfPartId = refundOf
    draft.parts = [part]
    var entry = try draft.materialize(id: id)
    entry.transaction.timeZoneId = zone
    return entry
  }

  /// A purchase on `day` at 12:30, a time of its own (not the noon of an untimed one).
  static func purchase(
    _ whole: Int64, on day: DateOnly, category: CoreKit.Category = food, place: UUID? = nil,
    person: UUID? = nil, id: UUID = UUID()
  ) throws -> TransactionEntry {
    try entry(
      whole, at: moment(day, 12, 30), category: category, place: place, person: person, id: id)
  }

  static func ledger(
    _ entries: [TransactionEntry], places: [Place] = [], people: [Person] = [],
    events: [Event] = [], version: Int = 0
  ) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: all, people: people, places: places, events: events,
        version: version),
      calendar: moscow)
  }
}
