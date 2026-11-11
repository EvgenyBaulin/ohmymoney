import CoreAccounting
import CoreKit
import Foundation

extension Namesakes {
  /// Only explicitly linked, live income operations make up an expectation's history.
  /// A scheduled date says when money was expected, not when its history happened.
  public static func expected(
    _ incomes: [ExpectedIncome], links: [ExpectedIncomeLink], entries: [TransactionEntry],
    calendar: CalendarContext
  ) -> [NamesakeRecord] {
    let days = Dictionary(
      entries.filter { !$0.transaction.isDeleted && $0.transaction.kind == .income }
        .map { ($0.id, calendar.day(of: $0.transaction.occurredAt).monthKey) },
      uniquingKeysWith: { first, _ in first })
    var history: [UUID: [MonthKey]] = [:]
    for link in links {
      if let month = days[link.transactionId] {
        history[link.expectedIncomeId, default: []].append(month)
      }
    }
    return incomes.map {
      NamesakeRecord(
        kind: .expectedIncome, id: $0.id, name: $0.name, archived: $0.closed,
        history: history[$0.id] ?? [])
    }
  }

  /// Inactive payments already form the subscription archive. Explicit charges remain history
  /// after deactivation; matched charges can be supplied by the existing matching calculation.
  public static func scheduled(
    _ payments: [ScheduledPayment], entries: [TransactionEntry], calendar: CalendarContext,
    matchedOperations: [UUID: Set<UUID>] = [:]
  ) -> [NamesakeRecord] {
    var history: [UUID: [MonthKey]] = [:]
    for entry in entries where !entry.transaction.isDeleted {
      if case .scheduled(let id, _) = OperationLink(externalId: entry.transaction.externalId) {
        history[id, default: []].append(calendar.day(of: entry.transaction.occurredAt).monthKey)
      }
    }
    let months = Dictionary(
      entries.filter { !$0.transaction.isDeleted }.map {
        ($0.id, calendar.day(of: $0.transaction.occurredAt).monthKey)
      }, uniquingKeysWith: { first, _ in first })
    return payments.map {
      let matched = (matchedOperations[$0.id] ?? []).compactMap { months[$0] }
      return NamesakeRecord(
        kind: .scheduledPayment, id: $0.id, name: $0.name, archived: !$0.active,
        history: (history[$0.id] ?? []) + matched)
    }
  }
}
