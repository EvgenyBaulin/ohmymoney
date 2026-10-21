import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

/// «Событие сверх бюджета» counts what the event costs me — a refund inside its purchase, a part
/// paid for a friend not mine even when some money came back — and «Рост цены подписки» reads
/// only the charges written for the subscription: an ordinary operation that pays it by
/// matching is no charge of it until it is tied with «Привязать».
extension AnomalyRefundFoldTests {
  static let trip = UUID(uuidString: "00000000-0000-0000-0000-00000000E001") ?? UUID()

  func ledger(
    _ entries: [TransactionEntry], links: [ReimbursementLink] = [], events: [Event]
  ) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, links: links,
        categories: [
          CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
          CoreKit.Category(id: music, kind: .expense, name: "Music", quality: .neutral),
        ],
        events: events),
      calendar: .utc)
  }

  func onTheTrip(_ entry: TransactionEntry) -> TransactionEntry {
    var entry = entry
    for index in entry.parts.indices { entry.parts[index].eventId = Self.trip }
    return entry
  }

  func overBudget(_ ledger: Ledger) -> [Anomaly] {
    AnomalyRules.build(
      ledger: ledger, events: EventPlanning.build(ledger: ledger, today: today), today: today
    ).all.filter { $0.rule == .eventOverBudget }
  }

  /// A trip of 1–10 September with a budget of 10 000 cost 12 000: over its budget. 3 000 of it
  /// refunded on the 15th — after the trip — and it cost 9 000: within, no anomaly.
  @Test func aRefundTakesAnEventBackUnderItsBudget() {
    let trip = Event(
      id: Self.trip, name: "Trip", startDate: day("2026-09-01"), endDate: day("2026-09-10"),
      budgetE4: money("10000"))
    let hotel = onTheTrip(purchase(1, "2026-09-05", "12000"))
    let over = overBudget(ledger([hotel], events: [trip]))
    #expect(over.map(\.amount) == [money("12000")])
    #expect(over.map(\.reference) == [money("10000")])
    let refund = onTheTrip(refund(2, "2026-09-15", "3000", of: id(10)))
    #expect(overBudget(ledger([hotel, refund], events: [trip])).isEmpty)
  }

  /// On the same trip, 8 000 of mine and 4 000 paid for a friend, who gave 1 500 back: the
  /// trip cost me 8 000 — within its budget — whatever came back of the friend's part.
  @Test func aPartForAFriendIsNotTheEventsSpending() {
    let trip = Event(
      id: Self.trip, name: "Trip", startDate: day("2026-09-01"), endDate: day("2026-09-10"),
      budgetE4: money("10000"))
    let dinner = onTheTrip(purchase(1, "2026-09-05", "8000"))
    let friend = onTheTrip(purchase(3, "2026-09-06", "4000", reimbursable: true))
    let back = moneyBack(4, "2026-09-12", "1500")
    let links = [
      ReimbursementLink(reimbursementTxId: id(4), partId: id(30), amountE4: money("1500"))
    ]
    let ledger = ledger([dinner, friend, back], links: links, events: [trip])
    #expect(EventPlanning.plans(ledger: ledger, today: today).first?.spent == money("8000"))
    #expect(overBudget(ledger).isEmpty)
  }

  /// A subscription charged 1 000 in August by «Провести»; in September 1 300 paid by an
  /// ordinary operation that matches the due date. No rise is said — the rule reads only the
  /// charges written for the payment — until «Привязать» writes the key into the operation.
  @Test func aMatchedChargeIsNoPriceRiseUntilItIsTied() {
    let payment = id(900)
    let august = purchase(
      1, "2026-08-01", "1000", category: music, link: "sched:\(payment.uuidString):2026-08-01")
    let typed = purchase(2, "2026-09-01", "1300", category: music)
    let untied = AnomalyRules.build(ledger: ledger([august, typed]), today: today)
    #expect(!untied.all.contains { $0.rule == .subscriptionPriceRise })
    let tied = purchase(
      2, "2026-09-01", "1300", category: music, link: "sched:\(payment.uuidString):2026-09-01")
    let rises = AnomalyRules.build(ledger: ledger([august, tied]), today: today).all.filter {
      $0.rule == .subscriptionPriceRise
    }
    #expect(rises.map(\.amount) == [money("1300")])
    #expect(rises.map(\.reference) == [money("1000")])
  }
}
