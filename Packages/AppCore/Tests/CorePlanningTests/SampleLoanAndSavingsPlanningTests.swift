import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The education loan and the savings account of the sample, read through the rules of the app:
/// the sample is opened by `make sample`, `make demo` and the learning set, and none of them may
/// ask about a due it says was paid, part a payment otherwise than the app does, or miss the
/// interest it says came.
///
/// Last days spread over a year — the first of a month, its end, February —, both languages.
@Suite("The sample's education loan and savings account, as the app reads them")
struct SampleLoanAndSavingsPlanningTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let lastDay: DateOnly
    let language: String
    var testDescription: String { "\(lastDay.iso) (\(language))" }
  }

  static let cases: [Case] = [
    Case(lastDay: DateOnly(year: 2026, month: 9, day: 18), language: "en"),
    Case(lastDay: DateOnly(year: 2026, month: 10, day: 1), language: "ru"),
    Case(lastDay: DateOnly(year: 2026, month: 10, day: 31), language: "en"),
    Case(lastDay: DateOnly(year: 2027, month: 2, day: 28), language: "ru"),
    Case(lastDay: DateOnly(year: 2027, month: 3, day: 3), language: "en"),
    Case(lastDay: DateOnly(year: 2027, month: 7, day: 6), language: "ru"),
  ]

  static let calendar = CalendarContext.moscow

  static func set(_ testCase: Case) -> SampleDataSet {
    SampleDataGenerator(seed: 20_261_011).generate(
      months: 6, endingOn: testCase.lastDay, calendar: calendar, language: testCase.language
    ).withEveryFeature(
      seed: 20_261_011, calendar: calendar, language: testCase.language)
  }

  static func ledger(_ set: SampleDataSet) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: set.entries, links: set.links, categories: set.categories, people: set.people,
        places: set.places, events: set.events, paymentMethods: set.paymentMethods,
        debts: set.debts, goals: set.goals, planning: set.planningBook,
        settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
        transfers: set.transfers, accountGroups: set.accountGroups,
        accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
        cashbackRules: set.cashbackRules),
      calendar: calendar)
  }

  static func snapshot(_ set: SampleDataSet) -> PlanningSnapshot {
    let now = calendar.startOfDay(set.lastDay).addingTimeInterval(23 * 3_600)
    return PlanningSnapshot.build(
      ledger: ledger(set), today: set.lastDay, now: now,
      rubPerUnit: [.usd: 95, .eur: 103, CurrencyCode("KZT"): Decimal(2) / Decimal(10)])
  }

  /// Every due of the loan up to the last day is paid: none is overdue, none is asked about at
  /// launch, and each asked for exactly what its payment brought.
  @Test(arguments: cases)
  func everyGraceDueIsPaid(_ testCase: Case) throws {
    let set = Self.set(testCase)
    let loan = try #require(set.debts.first { $0.accruesInterest })
    let ledger = Self.ledger(set)
    let states = DebtDues.states(
      debts: [loan], ledger: ledger, journal: set.debtEntries, today: set.lastDay)
    let state = try #require(states[loan.id])
    #expect(state.overdue(today: set.lastDay).isEmpty, "\(testCase)")
    #expect(state.paidCount == 2, "\(testCase)")
    let payments = set.debtEntries.filter { $0.debtId == loan.id && $0.kind == .payment }
      .sorted { ($0.date ?? set.lastDay) < ($1.date ?? set.lastDay) }
    for (index, line) in payments.enumerated() {
      #expect(state.due(index) == line.date, "\(testCase)")
      #expect(state.amount(ofDue: index) == line.amountE4.magnitude, "\(testCase): due \(index)")
    }
    #expect(
      (state.firstUnpaid ?? set.lastDay) > set.lastDay, "\(testCase): the next due is ahead")
    #expect(!Self.snapshot(set).overdue.contains { $0.isDebt }, "\(testCase)")
  }

  /// Each grace payment is all interest, the way the bank parts it, and the interest operation
  /// beside it carries exactly that.
  @Test(arguments: cases)
  func eachInterestOperationIsWhatTheBankParts(_ testCase: Case) throws {
    let set = Self.set(testCase)
    let loan = try #require(set.debts.first { $0.accruesInterest })
    let journal = set.debtEntries.filter { $0.debtId == loan.id }
    let paid = DebtInterest.interestPaid(
      debt: loan, journal: journal, through: set.lastDay, calendar: Self.calendar)
    let payments = journal.filter { $0.kind == .payment }
    #expect(payments.count == 2)
    for line in payments {
      let payment = try #require(set.entries.first { $0.id == line.transactionId })
      let key = "debtinterest:\(payment.id.uuidString.lowercased()):"
      let interest = try #require(
        set.entries.first { $0.transaction.externalId?.hasPrefix(key) == true })
      #expect(paid[line.id] == interest.transaction.amountE4, "\(testCase)")
      #expect(paid[line.id] == line.amountE4.magnitude, "\(testCase): all of it interest")
      let split = DebtInterest.split(
        payment: line.amountE4.magnitude, on: try #require(line.date), debt: loan,
        journal: journal, calendar: Self.calendar, replacing: line.id)
      #expect(split.interestE4 == interest.transaction.amountE4, "\(testCase)")
      #expect(split.principalE4 == .zero, "\(testCase)")
    }
  }

  /// The savings account's first payout came — the income the sample recorded, worth exactly
  /// what the app expects —, and the next one is ahead, not missing.
  @Test(arguments: cases)
  func theSavingsInterestIsReceived(_ testCase: Case) throws {
    let set = Self.set(testCase)
    let savings = try #require(set.paymentMethods.first { $0.interest != nil })
    let income = try #require(
      set.entries.first { entry in
        entry.transaction.paymentMethodId == savings.id && entry.transaction.kind == .income
      })
    let payouts = Self.snapshot(set).deposits.filter { $0.accountId == savings.id }
    let received = try #require(
      payouts.first { $0.state == .received(income.id) }, "\(testCase): \(payouts)")
    #expect(received.expectedE4 == income.transaction.amountE4, "\(testCase)")
    #expect(received.capitalized && received.target.accountId == savings.id)
    #expect(!payouts.contains { $0.state == .missing }, "\(testCase)")
    #expect(payouts.contains { $0.payDate > set.lastDay }, "\(testCase): the next one ahead")
  }
}
