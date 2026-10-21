import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

@Suite("The hint about burnout")
struct BurnoutTests {
  let today = DateOnly(year: 2026, month: 10, day: 11)

  struct Book {
    var categories: [CoreKit.Category] = []
    var entries: [TransactionEntry] = []
    var coffee = UUID()

    init(essentials: Bool = true) {
      let food = CoreKit.Category(
        kind: .expense, name: "Продукты", essential: essentials ? true : nil)
      let coffee = CoreKit.Category(kind: .expense, name: "Кофе")
      self.coffee = coffee.id
      categories = [food, coffee]
    }

    mutating func spend(_ rubles: Int64, on day: DateOnly) {
      let id = UUID()
      let amount = AmountE4(whole: rubles)
      entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id, kind: .expense, occurredAt: CalendarContext.utc.noon(of: day),
            amountE4: amount),
          parts: [TransactionPart(transactionId: id, categoryId: coffee, amountE4: amount)]))
    }

    /// `weeks` weeks before the last one, each with `small` cheap and 6 dear purchases, and the
    /// last week with `last` cheap ones and 2 dear.
    mutating func history(weeks: Int, small: Int, last: Int, today: DateOnly) {
      let weekStart = today.adding(days: -6)
      for week in 1...weeks {
        let start = weekStart.adding(days: -7 * week)
        for index in 0..<small { spend(200, on: start.adding(days: index % 7)) }
        for index in 0..<6 { spend(1000, on: start.adding(days: index % 7)) }
      }
      for index in 0..<last { spend(200, on: weekStart.adding(days: index % 7)) }
      for index in 0..<2 { spend(1000, on: weekStart.adding(days: index)) }
    }

    var ledger: Ledger {
      Ledger(dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
    }
  }

  @Test func fourteenWhenSixIsUsualIsASignal() {
    var book = Book()
    book.history(weeks: 12, small: 6, last: 14, today: today)
    let check = Burnout.check(ledger: book.ledger, tree: book.ledger.tree, today: today)
    #expect(
      check
        == .signal(
          BurnoutSignal(
            lastWeekCount: 14, usualCount: 6, from: today.adding(days: -6), through: today)))
  }

  @Test func nineWhenSixIsUsualIsNot() {
    var book = Book()
    book.history(weeks: 12, small: 6, last: 9, today: today)
    #expect(Burnout.check(ledger: book.ledger, tree: book.ledger.tree, today: today) == .quiet)
  }

  @Test func fiveWeeksOfHistoryAreNotEnough() {
    var book = Book()
    book.history(weeks: 5, small: 6, last: 14, today: today)
    #expect(
      Burnout.check(ledger: book.ledger, tree: book.ledger.tree, today: today)
        == .notEnoughHistory)
  }

  @Test func withoutAnEssentialCategoryThereIsNoHint() {
    var book = Book(essentials: false)
    book.history(weeks: 12, small: 6, last: 14, today: today)
    #expect(
      Burnout.check(ledger: book.ledger, tree: book.ledger.tree, today: today)
        == .needsEssentials)
  }

  @Test func onceAWeek() {
    let signal = BurnoutCheck.signal(
      BurnoutSignal(lastWeekCount: 14, usualCount: 6, from: today, through: today))
    #expect(Burnout.shows(signal, enabled: true, lastShownWeek: nil, today: today))
    let week = Burnout.weekKey(today)
    #expect(week == "2026-W41")
    #expect(!Burnout.shows(signal, enabled: true, lastShownWeek: week, today: today))
    #expect(Burnout.shows(signal, enabled: true, lastShownWeek: week, today: today.adding(days: 1)))
    #expect(!Burnout.shows(signal, enabled: false, lastShownWeek: nil, today: today))
    #expect(!Burnout.shows(.quiet, enabled: true, lastShownWeek: nil, today: today))
  }
}
