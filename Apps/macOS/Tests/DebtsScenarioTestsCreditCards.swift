import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A credit card kept as an account, read on the screens the way the app builds them: counted
/// on the 1st of September at zero, a statement every 5th with 25 days to pay. What is due by
/// when and the minimum, the statement paid in full or missed, the reminder five days ahead, a
/// purchase after the statement, cash taken from the card, the 31st in February, a card never
/// counted, days from a purchase — and «Оставить только счёт» refused where it cannot be.
@MainActor
final class DebtsScenarioTestsCreditCards: DebtsScenarioCase {
  private let counted = DateOnly(year: 2026, month: 9, day: 1)
  private let statement = DateOnly(year: 2026, month: 10, day: 5)
  private let payBy = DateOnly(year: 2026, month: 10, day: 30)

  private func terms(
    grace: CreditGrace = .statement(day: 5, payDays: 25), cashWithoutGrace: Bool = true
  ) -> CreditCardTerms {
    CreditCardTerms(
      limitE4: money(150_000), grace: grace, purchaseRate: Decimal(string: "29.9"),
      cashRate: Decimal(string: "49.9"), minPercent: 8, minFloorE4: money(600),
      cashFeePercent: Decimal(string: "2.9"), cashFeeFixedE4: money(290),
      cashWithoutGrace: cashWithoutGrace)
  }

  /// The card, counted at zero on `counted` unless told otherwise.
  private func creditCard(
    terms: CreditCardTerms? = nil, countedOn: DateOnly? = nil, count: Bool = true
  ) async throws -> PaymentMethod {
    let account = PaymentMethod(name: "T-Card", currency: .rub, credit: terms ?? self.terms())
    try XCTUnwrap(environment.references).save(account)
    if count { try self.count(account, 0, on: countedOn ?? counted) }
    try await show()
    return account
  }

  private func now(_ account: PaymentMethod) throws -> CreditCardNow {
    try XCTUnwrap(try snapshot.planning.creditCards[account.id])
  }

  /// Money onto the card from the main card, at noon of `day`.
  private func repay(_ account: PaymentMethod, _ whole: Int64, on day: DateOnly) throws {
    var rows = PlanningRows.empty
    rows.transfers = [
      Transfer(
        occurredAt: noon(day), fromAccountId: card.id, fromCurrency: .rub,
        fromAmountE4: money(whole), toAccountId: account.id, toCurrency: .rub,
        toAmountE4: money(whole))
    ]
    XCTAssertTrue(PlanningActions(deps).apply(PlanningChange(upsert: rows)))
  }

  /// Money from the card to the cash, at noon of `day`.
  private func takeCash(_ account: PaymentMethod, _ whole: Int64, on day: DateOnly) throws {
    var rows = PlanningRows.empty
    rows.transfers = [
      Transfer(
        occurredAt: noon(day), fromAccountId: account.id, fromCurrency: .rub,
        fromAmountE4: money(whole), toAccountId: cash.id, toCurrency: .rub,
        toAmountE4: money(whole))
    ]
    XCTAssertTrue(PlanningActions(deps).apply(PlanningChange(upsert: rows)))
  }

  private func reminders(_ account: PaymentMethod) throws -> [DebtReminder] {
    try snapshot.planning.debtReminders.filter {
      switch $0 {
      case .cardPayBy(let id, _, _, _), .cardGraceMissed(let id, _, _): id == account.id
      default: false
      }
    }
  }

  // MARK: A statement waiting

  func testAStatementWaitingSaysWhatToPayByWhenAndTheMinimum() async throws {
    let account = try await creditCard()
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try spend(2_000, on: DateOnly(year: 2026, month: 9, day: 20), account: account)
    try await show()
    let now = try now(account)
    XCTAssertEqual(now.debtE4, money(5_000))
    XCTAssertEqual(now.availableE4, money(145_000))
    XCTAssertEqual(now.toPayNoInterestE4, money(5_000))
    XCTAssertEqual(now.payBy, payBy)
    XCTAssertEqual(now.minimumE4, money(600), "8 % is 400, the floor is 600")
    XCTAssertEqual(now.nextStatement, DateOnly(year: 2026, month: 11, day: 5))
    XCTAssertTrue(now.graceKept)
  }

  func testTheMinimumIsItsPercentOnceAboveTheFloor() async throws {
    let account = try await creditCard()
    try spend(20_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try await show()
    XCTAssertEqual(try now(account).minimumE4, money(1_600))
  }

  func testAPurchaseAfterTheStatementWaitsForTheNextOne() async throws {
    let account = try await creditCard()
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try spend(7_000, on: DateOnly(year: 2026, month: 10, day: 10), account: account)
    try await show()
    let now = try now(account)
    XCTAssertEqual(now.debtE4, money(10_000))
    XCTAssertEqual(now.toPayNoInterestE4, money(3_000))
  }

  func testTheStatementsOfTheCardSinceItsCount() async throws {
    let account = try await creditCard()
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try await show()
    let movements = CreditStatements.movements(
      account: account, ledger: try snapshot.ledger, transfers: [])
    let statements = CreditStatements.statements(
      account: account, terms: terms(), movements: movements,
      balances: try snapshot.planning.accounts.balances, through: today, calendar: calendar)
    XCTAssertEqual(statements.map(\.closesOn), [DateOnly(year: 2026, month: 9, day: 5), statement])
    XCTAssertEqual(statements.map(\.state), [.paidInFull, .waiting])
    XCTAssertEqual(statements.last?.purchasesE4, money(3_000))
  }

  // MARK: The reminder

  func testThePaymentIsRemindedOfFiveDaysBeforeItIsDue() async throws {
    let account = try await creditCard()
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try await move(to: payBy.adding(days: -6))
    XCTAssertEqual(try reminders(account), [])
    try await move(to: payBy.adding(days: -5))
    XCTAssertEqual(
      try reminders(account),
      [.cardPayBy(accountId: account.id, due: payBy, fullE4: money(3_000), minimumE4: money(600))])
    try await move(to: payBy)
    XCTAssertEqual(try reminders(account).count, 1)
  }

  func testACardWithNothingToPayIsNotReminded() async throws {
    let account = try await creditCard()
    try await move(to: payBy.adding(days: -2))
    XCTAssertEqual(try reminders(account), [])
  }

  // MARK: Paid in full or missed

  func testAStatementPaidInFullKeepsTheGracePeriodAndAsksNothingMore() async throws {
    let account = try await creditCard()
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try repay(account, 3_000, on: DateOnly(year: 2026, month: 10, day: 20))
    try await move(to: DateOnly(year: 2026, month: 11, day: 1))
    let now = try now(account)
    XCTAssertTrue(now.graceKept)
    XCTAssertEqual(now.toPayNoInterestE4, .zero)
    XCTAssertEqual(now.debtE4, .zero)
    XCTAssertNil(now.estimate)
    XCTAssertEqual(try reminders(account), [])
  }

  func testAPartPaidLeavesTheRestToPayAndTheMinimumLeft() async throws {
    let account = try await creditCard()
    try spend(20_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try repay(account, 1_000, on: DateOnly(year: 2026, month: 10, day: 12))
    try await show()
    let now = try now(account)
    XCTAssertEqual(now.toPayNoInterestE4, money(19_000))
    XCTAssertEqual(now.minimumE4, money(600))
  }

  func testAMissedStatementLosesTheGracePeriodAndTheInterestShows() async throws {
    let account = try await creditCard()
    try spend(10_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try await move(to: DateOnly(year: 2026, month: 11, day: 1))
    let now = try now(account)
    XCTAssertFalse(now.graceKept)
    XCTAssertEqual(now.toPayNoInterestE4, money(10_000), "the whole debt stops the interest")
    XCTAssertNil(now.payBy)
    XCTAssertGreaterThan(try XCTUnwrap(now.estimate).purchaseInterestE4.raw, 0)
    XCTAssertTrue(
      try reminders(account).contains {
        if case .cardGraceMissed = $0 { true } else { false }
      })
  }

  func testAMissedStatementPaidLaterBringsTheGracePeriodBackOnlyAtTheNextStatement() async throws {
    let account = try await creditCard()
    try spend(10_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try repay(account, 10_000, on: DateOnly(year: 2026, month: 11, day: 2))
    try await move(to: DateOnly(year: 2026, month: 11, day: 3))
    XCTAssertFalse(try now(account).graceKept)
    try await move(to: DateOnly(year: 2026, month: 12, day: 6))
    XCTAssertTrue(try now(account).graceKept, "the statement of November was paid in full")
  }

  // MARK: Cash

  func testCashTakenFromTheCardChargesItsFeeAndInterestAtOnce() async throws {
    let account = try await creditCard()
    try takeCash(account, 5_000, on: DateOnly(year: 2026, month: 10, day: 7))
    try await show()
    let estimate = try XCTUnwrap(try now(account).estimate)
    XCTAssertEqual(estimate.statementDay, DateOnly(year: 2026, month: 11, day: 5))
    XCTAssertEqual(estimate.cashFeesE4, money(435), "2.9 % and 290")
    XCTAssertGreaterThan(estimate.cashInterestE4.raw, 0)
    XCTAssertEqual(estimate.purchaseInterestE4, .zero)
  }

  func testCashWithTheGracePeriodChargesOnlyItsFeeWhilePaidInTime() async throws {
    let account = try await creditCard(terms: terms(cashWithoutGrace: false))
    try takeCash(account, 5_000, on: DateOnly(year: 2026, month: 10, day: 7))
    try await show()
    let estimate = try XCTUnwrap(try now(account).estimate)
    XCTAssertEqual(estimate.cashFeesE4, money(435))
    XCTAssertEqual(estimate.cashInterestE4, .zero)
  }

  func testTheFeeOfCashIsItsPercentAndItsFixedSum() {
    XCTAssertEqual(CreditInterest.cashFee(amount: money(5_000), terms: terms()), money(435))
    XCTAssertEqual(CreditInterest.cashFee(amount: .zero, terms: terms()), .zero)
    XCTAssertEqual(
      CreditInterest.cashFee(amount: money(5_000), terms: CreditCardTerms(limitE4: money(1))),
      .zero)
  }

  // MARK: Days

  func testAStatementOnThe31stClosesOnTheLastDayOfFebruary() async throws {
    let account = try await creditCard(terms: terms(grace: .statement(day: 31, payDays: 25)))
    try await move(to: DateOnly(year: 2027, month: 2, day: 10))
    XCTAssertEqual(try now(account).nextStatement, DateOnly(year: 2027, month: 2, day: 28))
    try await move(to: DateOnly(year: 2028, month: 2, day: 10))
    XCTAssertEqual(try now(account).nextStatement, DateOnly(year: 2028, month: 2, day: 29))
  }

  func testTheNextStatementAfterTheDecemberOneIsInJanuary() async throws {
    let account = try await creditCard()
    try await move(to: DateOnly(year: 2026, month: 12, day: 5))
    XCTAssertEqual(try now(account).nextStatement, DateOnly(year: 2027, month: 1, day: 5))
  }

  func testDaysFromTheFirstPurchaseAreCountedFromTheOldestUnpaid() async throws {
    let account = try await creditCard(terms: terms(grace: .fromPurchase(days: 55)))
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try spend(1_000, on: DateOnly(year: 2026, month: 10, day: 1), account: account)
    try await show()
    let now = try now(account)
    XCTAssertEqual(now.payBy, DateOnly(year: 2026, month: 11, day: 4))
    XCTAssertEqual(now.toPayNoInterestE4, money(4_000))
    XCTAssertTrue(now.graceKept)
  }

  func testAFirstPurchaseRepaidMovesTheDayToTheNextOne() async throws {
    let account = try await creditCard(terms: terms(grace: .fromPurchase(days: 55)))
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try spend(1_000, on: DateOnly(year: 2026, month: 10, day: 1), account: account)
    try repay(account, 3_000, on: DateOnly(year: 2026, month: 10, day: 5))
    try await show()
    XCTAssertEqual(
      try now(account).payBy, DateOnly(year: 2026, month: 10, day: 1).adding(days: 55))
  }

  // MARK: A card never counted

  func testACardNeverCountedHasNoStatementButItsLimit() async throws {
    let account = try await creditCard(count: false)
    try spend(3_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try await show()
    let now = try now(account)
    XCTAssertNil(now.payBy)
    XCTAssertEqual(now.toPayNoInterestE4, .zero)
    XCTAssertEqual(try reminders(account), [])
  }

  func testAnArchivedCardIsNotRead() async throws {
    var account = try await creditCard()
    account.archived = true
    try XCTUnwrap(environment.references).save(account)
    try await show()
    XCTAssertNil(try snapshot.planning.creditCards[account.id])
  }

  // MARK: The key of the interest recorded

  func testTheKeyOfAStatementsInterestReadsBack() {
    let id = UUID()
    let key = CreditInterest.recordKey(account: id, statementDay: statement)
    XCTAssertEqual(key, "ccinterest:\(id.uuidString.lowercased()):2026-10-05")
    let parsed = CreditInterest.parseKey(key)
    XCTAssertEqual(parsed?.account, id)
    XCTAssertEqual(parsed?.statementDay, statement)
    XCTAssertNil(CreditInterest.parseKey("ccinterest:nope:2026-10-05"))
    XCTAssertNil(CreditInterest.parseKey("debtcost:\(id.uuidString)"))
    XCTAssertNil(CreditInterest.parseKey(nil))
  }

  func testTheMinimumIsNeverMoreThanTheDebt() {
    XCTAssertEqual(CreditStatements.minimum(debt: money(300), terms: terms()), money(300))
    XCTAssertEqual(CreditStatements.minimum(debt: .zero, terms: terms()), .zero)
    XCTAssertNil(
      CreditStatements.minimum(debt: money(300), terms: CreditCardTerms(limitE4: money(1))))
  }

  // MARK: The card and a debt of the same card

  func testKeepingOnlyTheAccountNeedsTheTermsOfTheAccount() async throws {
    let debt = Debt(direction: .iOwe, type: .creditCard, name: "T-Card", interestRate: 30)
    XCTAssertFalse(actions.keepOnlyAccount(debt, account: cash))
    let loan = try await makeLoan()
    let account = try await creditCard()
    XCTAssertFalse(actions.keepOnlyAccount(loan, account: account), "a loan is no credit card")
  }

  func testTheRateOfTheAccountIsKeptWhenItHasOne() async throws {
    let account = try await creditCard()
    let debt = Debt(direction: .iOwe, type: .creditCard, name: "T-Card", interestRate: 35)
    var rows = PlanningRows.empty
    rows.debts = [debt]
    XCTAssertTrue(PlanningActions(deps).apply(PlanningChange(upsert: rows)))
    try await show()
    XCTAssertTrue(actions.keepOnlyAccount(try self.debt(debt.id), account: account))
    let saved = try XCTUnwrap(
      try XCTUnwrap(environment.references).paymentMethods(includeArchived: true)
        .first { $0.id == account.id })
    XCTAssertEqual(saved.credit?.purchaseRate, Decimal(string: "29.9"))
    XCTAssertNotNil(try self.debt(debt.id).deletedAt)
  }

  func testACardInDebtIsAStepOfTheLadder() async throws {
    let account = try await creditCard()
    try spend(10_000, on: DateOnly(year: 2026, month: 9, day: 10), account: account)
    try await show()
    let candidates = LadderSection.candidates(try snapshot)
    XCTAssertEqual(candidates.map(\.source), [.creditCard(account.id)])
    XCTAssertEqual(candidates.first?.balanceRub, money(10_000))
  }
}
