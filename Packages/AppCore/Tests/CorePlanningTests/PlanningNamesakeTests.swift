import CoreAccounting
import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Namesake periods come from linked history")
struct PlanningNamesakeTests {
  typealias Fx = SchedFx

  @Test func expectationsKeepTheirIdentityArchiveStateAndLinkedHistory() {
    let income = ExpectedIncome(
      id: Fx.id(1), name: "Project", totalE4: Fx.money("100"),
      dueDate: Fx.day("2030-01-01"), closed: true)
    let entries = [
      Fx.operation(2, "2024-11-30", "40", kind: .income),
      Fx.operation(3, "2026-01-01", "60", kind: .income),
      Fx.operation(4, "2023-01-01", "60", kind: .income),
    ]
    let links = entries.prefix(2).map {
      ExpectedIncomeLink(expectedIncomeId: income.id, transactionId: $0.id)
    }
    let records = Namesakes.expected([income], links: links, entries: entries, calendar: .utc)
    #expect(records.map(\.id) == [income.id])
    #expect(records.first?.archived == true)
    #expect(records.first?.period?.first == Fx.day("2024-11-30").monthKey)
    #expect(records.first?.period?.last == Fx.day("2026-01-01").monthKey)
    #expect(
      Namesakes.expected([income], links: [], entries: entries, calendar: .utc)
        .first?.period == nil)
  }

  @Test func paymentHistoryUsesLinkedAndMatchedChargesAndExcludesTheBin() {
    var payment = ScheduledPayment(id: Fx.id(1), name: "Cloud", amountE4: Fx.money("100"))
    payment.active = false
    let first = Fx.operation(
      2, "2024-02-01", "100",
      link: .scheduled(
        paymentId: payment.id, due: Fx.day("2024-02-01")))
    let last = Fx.operation(3, "2026-01-01", "100")
    var deleted = Fx.operation(
      4, "2023-01-01", "100",
      link: .scheduled(
        paymentId: payment.id, due: Fx.day("2023-01-01")))
    deleted.transaction.deletedAt = CalendarContext.utc.startOfDay(Fx.day("2026-01-01"))
    let records = Namesakes.scheduled(
      [payment], entries: [first, last, deleted], calendar: .utc,
      matchedOperations: [payment.id: [last.id]])
    #expect(records.first?.archived == true)
    #expect(records.first?.period?.first == Fx.day("2024-02-01").monthKey)
    #expect(records.first?.period?.last == Fx.day("2026-01-01").monthKey)
  }
}
