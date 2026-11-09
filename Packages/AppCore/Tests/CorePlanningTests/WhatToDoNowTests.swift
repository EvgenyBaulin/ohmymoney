import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("What to do now")
struct WhatToDoNowTests {
  private let today = DateOnly(year: 2026, month: 11, day: 5)

  private func payment(_ name: String, due: DateOnly?, active: Bool = true) -> ScheduledPayment {
    var payment = ScheduledPayment(name: name, amountE4: AmountE4(whole: 100))
    payment.nextDate = due
    payment.active = active
    return payment
  }

  @Test func nothingToDoIsAnEmptyList() {
    let list = WhatToDoNow.list(
      payments: [
        payment("later", due: today.adding(days: 1)), payment("off", due: today, active: false),
      ],
      reviews: [DoNowSource(id: "a", count: 0)], today: today)
    #expect(list.isEmpty)
    #expect(list.more == 0)
  }

  @Test func overdueAndTodayComeFirstOldestFirst() {
    let today1 = payment("today", due: today)
    let old = payment("old", due: today.adding(days: -5))
    let older = payment("older", due: today.adding(days: -9))
    let list = WhatToDoNow.list(
      payments: [today1, old, older], reviews: [DoNowSource(id: "r", count: 4)], today: today)
    #expect(list.items.map(\.paymentId) == [older.id, old.id, today1.id])
    #expect(list.items.map { $0.isOverdue(today: today) } == [true, true, false])
    #expect(list.more == 1)
  }

  @Test func reviewComesBeforeStatementsAndAfterPayments() {
    let list = WhatToDoNow.list(
      payments: [payment("p", due: today)],
      reviews: [DoNowSource(id: "inbox", count: 3)],
      statements: [DoNowSource(id: "bank", count: 1)], today: today)
    #expect(list.items.map(\.action) == [.post, .review, .load])
    #expect(list.items[1].count == 3)
    #expect(list.more == 0)
  }

  @Test func atMostThreeAndTheRestIsCounted() {
    let payments = (1...5).map { payment("p\($0)", due: today.adding(days: -$0)) }
    let list = WhatToDoNow.list(
      payments: payments, statements: [DoNowSource(id: "s", count: 2)], today: today)
    #expect(list.items.count == WhatToDoNow.limit)
    #expect(list.items.allSatisfy { $0.action == .post })
    #expect(list.more == 3)
  }

  @Test func theOrderDoesNotDependOnTheInputOrder() {
    let payments = [payment("b", due: today), payment("a", due: today)]
    let first = WhatToDoNow.list(payments: payments, today: today)
    let second = WhatToDoNow.list(payments: payments.reversed(), today: today)
    #expect(first == second)
  }
}
