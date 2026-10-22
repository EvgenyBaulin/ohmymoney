import CoreKit
import Foundation

@testable import CoreAccounting

/// A small synthetic book for the rule tests: a category tree, places, and a way to write
/// operations in a line.
struct RuleBook {
  let groceries = CoreKit.Category(kind: .expense, name: "Продукты", sort: 0)
  let cafe = CoreKit.Category(kind: .expense, name: "Кафе", sort: 1)
  let transport = CoreKit.Category(kind: .expense, name: "Транспорт", sort: 2)
  let salary = CoreKit.Category(kind: .income, name: "Зарплата", sort: 0)
  let goals = CoreKit.Category(kind: .expense, name: "Цели", sort: 9, systemRole: .goals)
  let coffee: CoreKit.Category
  let fiveShop = Place(name: "Пятёрочка", aliases: ["Pyaterochka"])
  let taxi = Place(name: "Яндекс Go")
  let account = UUID()
  let otherAccount = UUID()
  let calendar = CalendarContext.utc
  let base = Date(timeIntervalSince1970: 1_760_000_000)  // 2025-10-09 08:53 UTC, a Thursday

  init() {
    coffee = CoreKit.Category(parentId: cafe.id, kind: .expense, name: "Кофе")
  }

  var tree: CategoryTree {
    CategoryTree([groceries, cafe, transport, salary, goals, coffee])
  }

  var places: [UUID: Place] { [fiveShop.id: fiveShop, taxi.id: taxi] }

  /// An expense of one part.
  func expense(
    _ note: String? = nil, rub: Int64 = 500, place: Place? = nil, category: CoreKit.Category? = nil,
    account: UUID? = nil, day: Int = 0, hourShift: Int = 0, created: Date? = nil,
    updated: Date? = nil, kind: TransactionKind = .expense
  ) -> TransactionEntry {
    let at = base.addingTimeInterval(Double(day) * 86_400 + Double(hourShift) * 3_600)
    let transaction = Transaction(
      kind: kind, occurredAt: at, amountE4: AmountE4(whole: rub), note: note, placeId: place?.id,
      paymentMethodId: account ?? self.account, createdAt: created ?? at,
      updatedAt: updated ?? created ?? at)
    let part = TransactionPart(
      transactionId: transaction.id, categoryId: category?.id, amountE4: AmountE4(whole: rub))
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  /// A split of two parts in two categories.
  func split(
    _ note: String? = nil, _ first: (CoreKit.Category, Int64), _ second: (CoreKit.Category, Int64),
    place: Place? = nil
  ) -> TransactionEntry {
    var entry = expense(note, rub: first.1 + second.1, place: place)
    entry.parts = [
      TransactionPart(
        transactionId: entry.id, categoryId: first.0.id, amountE4: AmountE4(whole: first.1)),
      TransactionPart(
        transactionId: entry.id, categoryId: second.0.id, amountE4: AmountE4(whole: second.1)),
    ]
    return entry
  }

  func rule(
    _ conditions: [RuleCondition], _ actions: [RuleAction], position: Int = 0,
    name: String = "", enabled: Bool = true
  ) -> Rule {
    Rule(
      name: name, position: position, enabled: enabled, conditions: conditions, actions: actions,
      createdAt: Date(timeIntervalSince1970: 1_000 + Double(position)))
  }

  func subject(_ entry: TransactionEntry) -> RuleSubject {
    RuleSubject(entry: entry, places: places, tree: tree, calendar: calendar)
  }
}
