import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The bank loan of the sample was taken 300 days before the history begins, so it was paid
/// for months before it too. Its journal says so, month after month from the first due on, and
/// the demo asks about nothing the sample did not mean it to ask about — a loan whose early
/// months stayed unpaid opened «Просроченные платежи» at every launch with ten rows of the same
/// loan.
@Suite("The sample's bank loan was paid before the history, too")
struct SampleLoanHistoryTests {
  static let calendar = CalendarContext.moscow
  static let endings = [
    DateOnly(year: 2026, month: 9, day: 18), DateOnly(year: 2026, month: 3, day: 31),
    DateOnly(year: 2026, month: 2, day: 28), DateOnly(year: 2026, month: 1, day: 1),
    DateOnly(year: 2026, month: 9, day: 25), DateOnly(year: 2025, month: 12, day: 26),
  ]

  static func set(
    endingOn: DateOnly = endings[0], seed: UInt64 = 20_260_920, months: Int = 6,
    language: String = "en"
  ) -> SampleDataSet {
    SampleDataGenerator(seed: seed).generate(
      months: months, endingOn: endingOn, calendar: calendar, language: language)
  }

  struct Loan {
    var debt: Debt
    var journal: [DebtEntry]
    var opening: DebtEntry
    var began: DateOnly
  }

  static func loan(of set: SampleDataSet) throws -> Loan {
    let debt = try #require(set.debts.first { $0.type == .loan })
    let journal = set.debtEntries.filter { $0.debtId == debt.id }
    let opening = try #require(journal.first { $0.kind == .borrowed })
    return Loan(
      debt: debt, journal: journal, opening: opening, began: try #require(opening.date))
  }

  /// One payment for every month from the first one the loan owes through the last of the
  /// history — before the history as a line of the journal alone, in it as the operation and its
  /// line.
  @Test(arguments: endings)
  func everyMonthSinceTheLoanBeganHasItsPayment(_ ending: DateOnly) throws {
    let set = Self.set(endingOn: ending)
    let loan = try Self.loan(of: set)
    let payday = try #require(loan.debt.paymentDay)
    let dates = loan.journal.filter { $0.kind == .payment }.compactMap(\.date).sorted()
    let last = try #require(dates.last)
    var first = loan.began.monthKey
    if DateOnly(year: first.year, month: first.month, day: payday) < loan.began {
      first = first.next
    }
    var months: [MonthKey] = []
    for month in sequence(first: first, next: { $0.next }) {
      guard month <= last.monthKey else { break }
      months.append(month)
    }
    #expect(dates.map(\.monthKey) == months)
    #expect(dates.allSatisfy { $0.day == payday })
    #expect(dates.first.map { $0 >= loan.began } == true, "nothing is paid before the loan began")
    #expect(last <= set.lastDay)
  }

  /// What comes before the history is the journal alone: no operation, no account, the monthly
  /// payment each, and money that was never in the history does not move on any account.
  @Test func theEarlyPaymentsAreLinesOfTheJournalAlone() throws {
    let set = Self.set()
    let loan = try Self.loan(of: set)
    let early = loan.journal.filter {
      $0.kind == .payment && ($0.date ?? set.firstDay) < set.firstDay
    }
    #expect(early.count >= 9, "ten months between the loan and the history")
    for line in early {
      #expect(line.transactionId == nil)
      #expect(line.paymentMethodId == nil)
      #expect(line.accountCurrency == nil)
      #expect(line.amountE4 == -AmountE4(whole: 15_000))
      #expect(line.closesTerm == false)
    }
    #expect(Set(early.map(\.id)).count == early.count, "every line has an id of its own")
    // The payments of the history are the operations' own, as ever.
    let inHistory = loan.journal.filter {
      $0.kind == .payment && ($0.date ?? set.lastDay) >= set.firstDay
    }
    #expect(inHistory.count >= 5)
    #expect(inHistory.allSatisfy { $0.transactionId != nil })
    // What is owed at the end is the loan less everything paid, and stays above zero.
    let balance = AmountE4.sum(loan.journal.map(\.amountE4))
    #expect(balance.raw > 0)
    let paid = Int64(early.count + inHistory.count)
    #expect(balance == AmountE4(whole: 500_000) - AmountE4(whole: 15_000 * paid))
  }

  /// The lines are not drawn: the same seed gives the same ids, and a different language the
  /// same ones, since the ids come from the loan's own and the month — nothing asks the random
  /// source for one more value, so no operation of the history moves.
  @Test func theIdsAreMadeNotDrawn() throws {
    let one = try Self.loan(of: Self.set())
    let again = try Self.loan(of: Self.set())
    #expect(one.journal == again.journal)
    let russian = try Self.loan(of: Self.set(language: "ru"))
    let early = { (loan: Loan) in
      loan.journal.filter { $0.kind == .payment && $0.transactionId == nil }.map(\.id)
    }
    #expect(early(one) == early(russian))
    let another = try Self.loan(of: Self.set(seed: 7))
    #expect(Set(early(one)).isDisjoint(with: early(another)))
  }
}
