import CoreKit
import Foundation

/// Name records of the dictionaries (goals, events, people, places, categories, accounts, cards,
/// banks). The history of a record is only what the operations actually say about it.
extension Namesakes {
  private static func months(
    of entries: [TransactionEntry], calendar: CalendarContext,
    keys: (TransactionEntry) -> [UUID]
  ) -> [UUID: [MonthKey]] {
    var history: [UUID: [MonthKey]] = [:]
    for entry in entries where !entry.transaction.isDeleted {
      let month = calendar.day(of: entry.transaction.occurredAt).monthKey
      for key in Set(keys(entry)) { history[key, default: []].append(month) }
    }
    return history
  }

  /// A goal's history is its contributions: parts filed in its own subcategory.
  public static func goals(
    _ goals: [Goal], entries: [TransactionEntry], calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let history = months(of: entries, calendar: calendar) { $0.parts.compactMap(\.categoryId) }
    return goals.map {
      NamesakeRecord(
        kind: .goal, id: $0.id, name: $0.name, archived: $0.archived,
        history: $0.subcategoryId.flatMap { history[$0] } ?? [])
    }
  }

  /// An event's history is the months its days cover.
  public static func events(_ events: [Event]) -> [NamesakeRecord] {
    events.map { event in
      var months: [MonthKey] = []
      if event.startDate <= event.endDate {
        months = [event.startDate.monthKey, event.endDate.monthKey]
      }
      return NamesakeRecord(
        kind: .event, id: event.id, name: event.name, archived: event.archived, history: months)
    }
  }

  public static func people(
    _ people: [Person], entries: [TransactionEntry], calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let history = months(of: entries, calendar: calendar) {
      $0.parts.flatMap { [$0.forPersonId, $0.debtorPersonId].compactMap { $0 } }
    }
    return people.map {
      NamesakeRecord(
        kind: .person, id: $0.id, name: $0.name, archived: $0.archived,
        history: history[$0.id] ?? [])
    }
  }

  public static func places(
    _ places: [Place], entries: [TransactionEntry], calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let history = months(of: entries, calendar: calendar) {
      [$0.transaction.placeId].compactMap { $0 }
    }
    return places.map {
      NamesakeRecord(
        kind: .place, id: $0.id, name: $0.name, archived: $0.archived,
        history: history[$0.id] ?? [])
    }
  }

  public static func categories(
    _ categories: [CoreKit.Category], entries: [TransactionEntry], calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let history = months(of: entries, calendar: calendar) { $0.parts.compactMap(\.categoryId) }
    return categories.map {
      NamesakeRecord(
        kind: .category, id: $0.id, name: $0.name, archived: $0.archived,
        history: history[$0.id] ?? [])
    }
  }

  public static func accounts(
    _ accounts: [PaymentMethod], entries: [TransactionEntry], calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let history = months(of: entries, calendar: calendar) {
      [$0.transaction.paymentMethodId].compactMap { $0 }
    }
    return accounts.map {
      NamesakeRecord(
        kind: .account, id: $0.id, name: $0.name, archived: $0.archived,
        history: history[$0.id] ?? [])
    }
  }

  public static func cards(
    _ cards: [PaymentCard], entries: [TransactionEntry], calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let history = months(of: entries, calendar: calendar) {
      [$0.transaction.cardId].compactMap { $0 }
    }
    return cards.map {
      NamesakeRecord(
        kind: .card, id: $0.id, name: $0.name, archived: $0.archived,
        history: history[$0.id] ?? [])
    }
  }

  /// A bank's history is its accounts' history.
  public static func banks(
    _ banks: [Bank], accounts: [PaymentMethod], entries: [TransactionEntry],
    calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let history = months(of: entries, calendar: calendar) {
      [$0.transaction.paymentMethodId].compactMap { $0 }
    }
    return banks.map { bank in
      let own = accounts.filter { $0.bankId == bank.id }.flatMap { history[$0.id] ?? [] }
      return NamesakeRecord(
        kind: .bank, id: bank.id, name: bank.name, archived: bank.archived, history: own)
    }
  }
}
