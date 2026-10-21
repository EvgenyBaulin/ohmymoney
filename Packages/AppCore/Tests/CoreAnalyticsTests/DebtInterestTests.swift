import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The interest of a loan that accrues it, read from the journal and never stored: each payment
/// pays the interest accrued since the payment before first, and that interest comes back as a
/// line of its own, so the journal's balance is the principal. At 3.65 % in a year of 365 days,
/// 100 000 earns exactly 10 a day.
@Suite("Debt interest: a payment pays the interest first")
struct DebtInterestTests {
  static let rate = Decimal(string: "3.65") ?? 0
  static let debtId = id(9_900)

  static func loan(accrues: Bool = true, grace: DebtGrace? = nil) -> Debt {
    Debt(
      id: debtId, direction: .iOwe, type: .loan, name: "Loan", interestRate: rate,
      monthlyPaymentE4: grace == nil ? money("1000") : nil, paymentDay: grace == nil ? 1 : 15,
      accruesInterest: accrues, grace: grace, repayMonths: grace == nil ? nil : 12)
  }

  static let borrowed = DebtEntry(
    id: id(9_901), debtId: debtId, date: day("2026-09-01"), amountE4: money("100000"),
    kind: .borrowed)

  func payment(_ iso: String, _ amount: String, _ number: Int) -> DebtEntry {
    DebtEntry(
      id: id(9_910 + number), debtId: Self.debtId, date: day(iso), amountE4: money("-" + amount),
      kind: .payment)
  }

  // MARK: A debt that does not accrue interest

  @Test func aDebtWithoutInterestReadsAsItsJournal() {
    let journal = [Self.borrowed, payment("2026-10-01", "1000", 1)]
    let debt = Self.loan(accrues: false)
    #expect(
      DebtInterest.effectiveJournal(
        debt: debt, journal: journal, through: day("2026-12-31"), calendar: .utc) == journal)
    #expect(
      DebtInterest.accruedE4(
        debt: debt, journal: journal, through: day("2026-12-31"), calendar: .utc
      )
      .isZero)
    #expect(
      DebtInterest.read(debt: debt, journal: journal, through: day("2026-12-31"), calendar: .utc)
        == nil)
    let split = DebtInterest.split(
      payment: money("1000"), on: day("2026-11-01"), debt: debt, journal: journal, calendar: .utc)
    #expect(split == DebtPaymentSplit(interestE4: .zero, principalE4: money("1000")))
  }

  // MARK: Interest first

  /// 30 days of 100 000 to 1 October: the payment of 1 000 pays 300 of interest and 700 of the
  /// principal; the 10 days after it earn on 99 300.
  @Test func aPaymentPaysTheAccruedInterestFirst() throws {
    let journal = [Self.borrowed, payment("2026-10-01", "1000", 1)]
    let reading = try #require(
      DebtInterest.read(
        debt: Self.loan(), journal: journal, through: day("2026-10-11"), calendar: .utc))
    #expect(reading.lines.count == 1)
    let line = try #require(reading.lines.first)
    #expect(line.amountE4 == money("300"))
    #expect(line.kind == .adjustment)
    #expect(line.date == day("2026-10-01"))
    #expect(line.transactionId == nil, "it moves no money and belongs to no operation")
    #expect(line.id == DebtInterest.lineId(forPayment: id(9_911)))
    #expect(line.id != id(9_911))
    #expect(DebtInterest.xor(line.id, with: DebtInterest.lineMask) == id(9_911))
    #expect(reading.interestByPayment == [id(9_911): money("300")])
    #expect(reading.accruedE4 == money("99.3"))
    let effective = DebtInterest.effectiveJournal(
      debt: Self.loan(), journal: journal, through: day("2026-10-11"), calendar: .utc)
    #expect(DebtRules.balance(entries: effective) == money("99300"))
  }

  /// A payment smaller than the interest pays what it can; the rest is carried to the next and
  /// nothing comes off the principal.
  @Test func aPaymentSmallerThanTheInterestCarriesTheRest() {
    let journal = [Self.borrowed, payment("2026-10-01", "100", 1)]
    let effective = DebtInterest.effectiveJournal(
      debt: Self.loan(), journal: journal, through: day("2026-10-11"), calendar: .utc)
    #expect(DebtRules.balance(entries: effective) == money("100000"))
    #expect(
      DebtInterest.accruedE4(
        debt: Self.loan(), journal: journal, through: day("2026-10-11"), calendar: .utc)
        == money("300"), "200 carried and 10 days of 10")
  }

  /// A line of a later day than asked about has not happened yet: no interest line for it.
  @Test func onlyPaymentsThroughTheDayAskedAboutPayInterest() {
    let journal = [Self.borrowed, payment("2026-10-01", "1000", 1)]
    #expect(
      DebtInterest.effectiveJournal(
        debt: Self.loan(), journal: journal, through: day("2026-09-30"), calendar: .utc) == journal)
  }

  /// The parting of a new payment: what is accrued and unpaid through its day, after the
  /// payments already made — 31 days of 99 300 to 1 November.
  @Test func aNewPaymentIsPartedIntoInterestAndPrincipal() {
    let journal = [Self.borrowed, payment("2026-10-01", "1000", 1)]
    let split = DebtInterest.split(
      payment: money("1000"), on: day("2026-11-01"), debt: Self.loan(), journal: journal,
      calendar: .utc)
    #expect(split.interestE4 == money("307.83"))
    #expect(split.principalE4 == money("692.17"))
    // The payment being edited is left out first: it parts as it did.
    let again = DebtInterest.split(
      payment: money("1000"), on: day("2026-10-01"), debt: Self.loan(), journal: journal,
      calendar: .utc, replacing: id(9_911))
    #expect(again == DebtPaymentSplit(interestE4: money("300"), principalE4: money("700")))
    // Less than the interest: all of it is interest.
    let small = DebtInterest.split(
      payment: money("50"), on: day("2026-11-01"), debt: Self.loan(), journal: journal,
      calendar: .utc)
    #expect(small == DebtPaymentSplit(interestE4: money("50"), principalE4: .zero))
  }

  // MARK: The grace period

  /// The programme's 40 %: 56 of 140, then 120 of 84 carried and 300 more. The 264 not paid
  /// joins the principal on the first day of the main schedule, and earns from the next.
  @Test func theInterestPutOffJoinsThePrincipalAtTheSwitch() throws {
    let debt = Self.loan(grace: DebtGrace(mainFrom: day("2026-11-15"), payment: .programme))
    let journal = [
      Self.borrowed, payment("2026-09-15", "56", 1), payment("2026-10-15", "120", 2),
    ]
    let reading = try #require(
      DebtInterest.read(debt: debt, journal: journal, through: day("2026-11-20"), calendar: .utc))
    let capitalized = try #require(
      reading.lines.first { $0.id == DebtInterest.capitalizedLineId(forDebt: Self.debtId) })
    #expect(capitalized.amountE4 == money("264"))
    #expect(capitalized.date == day("2026-11-15"))
    #expect(reading.interestByPayment == [id(9_911): money("56"), id(9_912): money("120")])
    // 31 days of 100 000, then 5 of 100 264.
    #expect(reading.accruedE4 == money("360.13"))
    let effective = DebtInterest.effectiveJournal(
      debt: debt, journal: journal, through: day("2026-11-20"), calendar: .utc)
    #expect(DebtRules.balance(entries: effective) == money("100264"))
    // Before the switch nothing has joined the principal yet.
    let before = DebtInterest.effectiveJournal(
      debt: debt, journal: journal, through: day("2026-11-14"), calendar: .utc)
    #expect(DebtRules.balance(entries: before) == money("100000"))
  }

  // MARK: The dues

  /// The dues never ask for more than the principal and the interest accrued on it.
  @Test func theDuesAreCappedByThePrincipalAndTheInterest() {
    var sketch = Sketch()
    sketch.debts = [Self.loan()]
    let journal = [Self.borrowed, payment("2026-10-01", "1000", 1)]
    let state = DebtDues.states(
      debts: [Self.loan()], ledger: sketch.ledger, journal: journal, today: day("2026-10-11")
    )[Self.debtId]
    #expect(state?.balanceE4 == money("99399.3"))
    #expect(state?.paidCount == 1)
    // The same loan without interest: the journal as it is.
    var plain = Self.loan(accrues: false)
    plain.id = Self.debtId
    let unchanged = DebtDues.states(
      debts: [plain], ledger: sketch.ledger, journal: journal, today: day("2026-10-11")
    )[Self.debtId]
    #expect(unchanged?.balanceE4 == money("99000"))
  }
}
