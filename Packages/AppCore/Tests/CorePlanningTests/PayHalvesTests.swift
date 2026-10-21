import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The halves of a month paid twice")
struct PayHalvesTests {
  typealias B = B3Book

  /// The salary on the 10th and the 25th: two terms of one expectation.
  struct Setup {
    var book = B3Book()
    var salary = UUID()
    var advance: ExpectedIncome
    var rest: ExpectedIncome

    init() {
      salary = book.category("Зарплата", kind: .income)
      advance = ExpectedIncome(
        name: "Зарплата", categoryId: salary, kind: .recurring, totalE4: B.rub("50000"),
        dueDate: B.day(9, 10), freq: .monthly, day: 10)
      rest = ExpectedIncome(
        name: "Зарплата", categoryId: salary, kind: .recurring, totalE4: B.rub("50000"),
        dueDate: B.day(9, 25), freq: .monthly, day: 25)
      book.expected = [advance, rest]
    }

    mutating func received(_ term: ExpectedIncome, on day: DateOnly) {
      let id = book.operation(.income, "50000", on: day, category: salary)
      book.links.append(ExpectedIncomeLink(expectedIncomeId: term.id, transactionId: id))
    }

    func half(_ today: DateOnly) -> PayHalf? {
      PayHalves.current(
        today: today, expected: book.expected, links: book.links, ledger: book.ledger)
    }
  }

  @Test func fromTheAdvanceToTheRest() {
    var setup = Setup()
    setup.received(setup.advance, on: B.day(10, 10))
    let half = setup.half(B.day(10, 12))
    #expect(half?.start == B.day(10, 10))
    #expect(half?.nextIncomeDay == B.day(10, 25))
    #expect(half?.nextIncomeId == setup.rest.id)
    #expect(half?.late == false)
  }

  @Test func theRestComingEarlyStartsTheNextHalf() {
    var setup = Setup()
    setup.received(setup.advance, on: B.day(10, 10))
    setup.received(setup.rest, on: B.day(10, 23))
    let half = setup.half(B.day(10, 23))
    #expect(half?.start == B.day(10, 23))
    #expect(half?.nextIncomeDay == B.day(11, 10))
  }

  @Test func theRestNotComingMakesTheHalfLate() {
    var setup = Setup()
    setup.received(setup.advance, on: B.day(10, 10))
    let half = setup.half(B.day(10, 27))
    #expect(half?.nextIncomeDay == B.day(10, 25))
    #expect(half?.late == true)
  }

  @Test func oneTermAMonthHasNoHalves() {
    var setup = Setup()
    setup.book.expected = [setup.rest]
    #expect(setup.half(B.day(10, 12)) == nil)
  }

  @Test func aPaymentOnTheDayOfTheIncomeIsPaidFromTheHalfThatEnds() {
    var setup = Setup()
    setup.received(setup.advance, on: B.day(10, 10))
    setup.book.accounts = [PaymentMethod(name: "Основной", isDefault: true)]
    setup.book.scheduled = [
      ScheduledPayment(
        name: "Интернет", amountE4: B.rub("700"), freq: .monthly, day: 25,
        nextDate: B.day(10, 25))
    ]
    let today = B.day(10, 12)
    var planning = setup.book.planning(today: today)
    planning.payHalf = setup.half(today)
    let free = planning.halfFreeMoney(ledger: setup.book.ledger)
    #expect(free?.until == B.day(10, 25))
    #expect(free?.plan.scheduled == B.rub("700"))
  }
}
