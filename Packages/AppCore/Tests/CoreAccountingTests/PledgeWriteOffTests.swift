import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A pledge that did not come back: closed with what is left, an expense of the loss.
@Suite("Pledge written off")
struct PledgeWriteOffTests {
  @Test func aPledgeWrittenOffClosesAndSpendsWhatIsLeft() {
    var pledge = Debt(id: id(1), direction: .owedToMe, type: .personal, name: "Flat")
    pledge.pledge = true
    pledge.returnBy = day("2026-11-01")
    let (closed, line, expense) = DebtRules.writeOff(
      debt: pledge, balance: money("30000"), categoryId: id(2), day: day("2026-11-10"),
      calendar: .utc)
    #expect(closed.closed)
    #expect(line.amountE4 == money("-30000"))
    #expect(line.date == day("2026-11-10"))
    #expect(expense.transaction.kind == .expense)
    #expect(expense.transaction.creditDebtId == id(1))
    #expect(expense.transaction.externalId == DebtRules.pledgeLossKey(of: id(1)))
    #expect(expense.transaction.amountE4 == money("30000"))
    #expect(expense.parts.first?.categoryId == id(2))
    #expect(CalendarContext.utc.day(of: expense.transaction.occurredAt) == day("2026-11-10"))
  }
}
