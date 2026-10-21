import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The answer «Платёж…» offers first for an early repayment is the one given last on the debt.
/// The journal comes in the order it was written, so of two answers of one day the later line
/// wins; a later day wins whatever the order of the lines.
@Suite("Early repayment: the answer offered first")
struct DebtPrepayDefaultChoiceTests {
  private let debt = UUID()
  private let day = DateOnly(year: 2026, month: 10, day: 14)

  private func payment(_ choice: PrepayChoice?, on day: DateOnly) -> DebtEntry {
    DebtEntry(
      debtId: debt, date: day, amountE4: AmountE4(whole: -1_000), kind: .payment,
      prepay: choice)
  }

  @Test func noAnswerYetOffersAShorterTerm() {
    #expect(DebtPrepay.defaultChoice(debtId: debt, journal: [payment(nil, on: day)]) == .term)
  }

  @Test func ofTwoAnswersOfOneDayTheLaterLineWins() {
    let journal = [payment(.term, on: day), payment(.payment, on: day)]
    #expect(DebtPrepay.defaultChoice(debtId: debt, journal: journal) == .payment)
    #expect(DebtPrepay.defaultChoice(debtId: debt, journal: journal.reversed()) == .term)
  }

  @Test func aLaterDayWinsWhateverTheOrder() {
    let journal = [payment(.forward, on: day.adding(days: 1)), payment(.payment, on: day)]
    #expect(DebtPrepay.defaultChoice(debtId: debt, journal: journal) == .forward)
  }

  @Test func anotherDebtsAnswerIsNotOffered() {
    var other = payment(.payment, on: day)
    other.debtId = UUID()
    #expect(DebtPrepay.defaultChoice(debtId: debt, journal: [other]) == .term)
  }
}
