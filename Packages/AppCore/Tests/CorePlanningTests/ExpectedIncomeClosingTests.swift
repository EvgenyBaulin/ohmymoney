import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Expected income: «Закрыть полностью» and names that repeat")
struct ExpectedIncomeClosingTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  func status(
    _ book: SavingsBook, _ income: ExpectedIncome, links: [UUID]
  ) throws -> ExpectedIncomeStatus {
    let planning = PlanningBook(
      expected: [income],
      expectedLinks: links.map {
        ExpectedIncomeLink(expectedIncomeId: income.id, transactionId: $0)
      })
    return try #require(
      ExpectedIncomeRules.statuses(book: planning, ledger: book.ledger, today: today).first)
  }

  func project(_ total: String) -> ExpectedIncome {
    ExpectedIncome(
      id: uid(700), name: "Project", totalE4: rub(total), dueDate: date("2026-09-25"),
      partsExpected: 2)
  }

  /// Exactly what was expected came in: closing is offered.
  @Test func closingIsOfferedWhenTheWholeAmountCame() throws {
    var book = SavingsBook()
    let first = book.income("2026-09-01", "30000", category: book.projects)
    let second = book.income("2026-09-10", "70000", category: book.projects)
    let income = try status(book, project("100000"), links: [first, second])
    #expect(ExpectedIncomeRules.offersClosing(income))
  }

  /// More came than was expected: closing is offered too.
  @Test func closingIsOfferedWhenMoreCame() throws {
    var book = SavingsBook()
    let paid = book.income("2026-09-10", "120000", category: book.projects)
    let income = try status(book, project("100000"), links: [paid])
    #expect(ExpectedIncomeRules.offersClosing(income))
  }

  /// Less came than was expected: nothing is offered — the rest is still awaited.
  @Test func closingIsNotOfferedWhenLessCame() throws {
    var book = SavingsBook()
    let paid = book.income("2026-09-10", "99999.99", category: book.projects)
    let income = try status(book, project("100000"), links: [paid])
    #expect(!ExpectedIncomeRules.offersClosing(income))
    let nothing = try status(book, project("100000"), links: [])
    #expect(!ExpectedIncomeRules.offersClosing(nothing))
  }

  /// A recurring income is never received whole: its next term is coming, so it is not offered
  /// to close even with every term so far paid (the form still closes it by hand).
  @Test func aRecurringIncomeIsNotOfferedToClose() throws {
    var book = SavingsBook()
    let help = ExpectedIncome(
      id: uid(710), name: "Help", categoryId: book.help, kind: .recurring,
      totalE4: rub("20000"), dueDate: date("2026-09-15"), freq: .monthly, day: 15)
    let paid = book.income("2026-09-15", "20000", category: book.help)
    let income = try status(book, help, links: [paid])
    #expect(income.isFulfilled)
    #expect(!ExpectedIncomeRules.offersClosing(income))
  }

  /// An income whose currency has no rate may have received more than is counted: it is not
  /// offered on a guess.
  @Test func anIncomeWithoutARateIsNotOfferedToClose() throws {
    var book = SavingsBook()
    let paid = book.income("2026-09-10", "100000", category: book.projects)
    var dollars = project("1000")
    dollars.currency = .usd
    let income = try status(book, dollars, links: [paid])
    #expect(income.withoutRate)
    #expect(!ExpectedIncomeRules.offersClosing(income))
  }

  /// Names repeat: the incomes whose name another one has too — whatever the case and the spaces
  /// around it — are the ones a menu tells apart by amount and date.
  @Test func namesakesAreTheIncomesWhoseNameRepeats() {
    let salary = ExpectedIncome(id: uid(720), name: "Зарплата", totalE4: rub("50000"))
    let advance = ExpectedIncome(id: uid(721), name: " зарплата ", totalE4: rub("40000"))
    let bonus = ExpectedIncome(id: uid(722), name: "Премия", totalE4: rub("10000"))
    #expect(
      ExpectedIncomeRules.namesakes(among: [salary, advance, bonus]) == [salary.id, advance.id])
    #expect(ExpectedIncomeRules.namesakes(among: [salary, bonus]).isEmpty)
  }
}
