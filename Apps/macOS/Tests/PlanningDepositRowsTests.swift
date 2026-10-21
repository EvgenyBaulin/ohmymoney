import AppCore
import XCTest

@testable import OhMyMoney

/// The interest of deposits among «Поступления»: which payouts are listed — those of this month
/// not received, and those that did not come —, in what order, from when «Записать…» is
/// offered, and the words of a row in both languages.
@MainActor
final class PlanningDepositRowsTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 11)
  private let deposit = UUID()
  private let savings = UUID()

  private func payout(
    _ account: UUID, _ payDate: DateOnly, _ expected: Int64, _ state: DepositPayout.State
  ) -> DepositPayout {
    DepositPayout(
      accountId: account, target: BalanceKey(accountId: account, currency: .rub),
      periodStart: payDate.adding(days: -30), payDate: payDate, accruedE4: .zero,
      expectedE4: AmountE4(whole: expected), capitalized: true, state: state)
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  /// Received payouts are gone — they are income now —; one of an earlier month is listed only
  /// when it did not come; this month's are listed by pay date whatever their state.
  func testTheRowsAreThePayoutsOfTheMonthNotReceivedAndTheMissingOnes() {
    let missing = payout(deposit, DateOnly(year: 2026, month: 9, day: 30), 2_345, .missing)
    let receivedEarlier = payout(
      savings, DateOnly(year: 2026, month: 9, day: 15), 500, .received(UUID()))
    let dueEarlier = payout(savings, DateOnly(year: 2026, month: 9, day: 28), 400, .due)
    let due = payout(savings, DateOnly(year: 2026, month: 10, day: 9), 510, .due)
    let accruing = payout(deposit, DateOnly(year: 2026, month: 10, day: 31), 3_100, .accruing)
    let receivedNow = payout(
      deposit, DateOnly(year: 2026, month: 10, day: 5), 100, .received(UUID()))

    let shown = DepositPayoutRows.shown(
      [accruing, receivedNow, due, dueEarlier, receivedEarlier, missing], today: today)
    XCTAssertEqual(shown.map(\.payDate), [missing.payDate, due.payDate, accruing.payDate])
  }

  /// «Записать…» from three days before the pay date on — earlier the income would not be
  /// taken for the payout.
  func testRecordingIsOfferedFromAFewDaysBeforeThePayDate() {
    XCTAssertTrue(
      DepositPayoutRows.offersRecording(
        payout(deposit, DateOnly(year: 2026, month: 9, day: 30), 1, .missing), today: today))
    XCTAssertTrue(
      DepositPayoutRows.offersRecording(
        payout(deposit, DateOnly(year: 2026, month: 10, day: 14), 1, .accruing), today: today))
    XCTAssertFalse(
      DepositPayoutRows.offersRecording(
        payout(deposit, DateOnly(year: 2026, month: 10, day: 15), 1, .accruing), today: today))
  }

  /// «Проценты · Вклад ≈ 3,100.00 ₽ · 31 октября»; one that did not come asks «не пришли?».
  func testTheWordsOfARowInBothLanguages() {
    let ru = environment(.russian)
    let names = [deposit: "Вклад"]
    let money = ru.money
    XCTAssertEqual(
      DepositPayoutRows.text(
        payout(deposit, DateOnly(year: 2026, month: 10, day: 31), 3_100, .accruing),
        names: names, ru),
      "Проценты · Вклад ≈\u{00A0}\(money.exact(AmountE4(whole: 3_100))) · 31 октября")
    XCTAssertEqual(
      DepositPayoutRows.text(
        payout(deposit, DateOnly(year: 2026, month: 9, day: 30), 2_345, .missing),
        names: names, ru),
      "Проценты · Вклад ≈\u{00A0}\(money.exact(AmountE4(whole: 2_345))) · 30 сентября"
        + " · не пришли?")

    let en = environment(.english)
    XCTAssertEqual(
      DepositPayoutRows.text(
        payout(deposit, DateOnly(year: 2026, month: 9, day: 30), 2_345, .missing),
        names: names, en),
      "Interest · Вклад ≈\u{00A0}\(en.money.exact(AmountE4(whole: 2_345))) · September 30"
        + " · did not come?")
    ru.language.choice = .russian
  }

  /// A row's «Записать…» starts the income on the account the payout goes to, with the sum
  /// expected, dated the pay date.
  func testARowRecordsOnTheAccountThePayoutGoesTo() {
    let card = UUID()
    let paid = DepositPayout(
      accountId: deposit, target: BalanceKey(accountId: card, currency: .rub),
      periodStart: DateOnly(year: 2026, month: 9, day: 1),
      payDate: DateOnly(year: 2026, month: 9, day: 30), accruedE4: AmountE4(whole: 99),
      expectedE4: AmountE4(whole: 120), capitalized: false, state: .missing)
    let prefill = DepositIncomePrefill(paid)
    XCTAssertEqual(prefill.accountId, card)
    XCTAssertEqual(prefill.depositId, deposit)
    XCTAssertEqual(prefill.amount, AmountE4(whole: 120), "the sum expected, not the accrued")
    XCTAssertEqual(prefill.day, DateOnly(year: 2026, month: 9, day: 30))
  }
}
