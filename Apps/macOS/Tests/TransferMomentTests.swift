import AppCore
import XCTest

@testable import OhMyMoney

/// The date and the time of a transfer are one field, as they are for an expense and an income
/// (one `DatePicker` with both parts), and the ↓ panel hands what it holds to the form of a
/// transfer.
final class TransferMomentTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let today = DateOnly(year: 2026, month: 10, day: 4)

  private func form() -> TransferForm {
    TransferForm(from: nil, accounts: [], day: today)
  }

  /// The picker shows the moment the transfer would get — now, for today — and gives back the
  /// moment picked. Another day alone is no chosen time: the transfer stays free of the question
  /// about the counts of its day (`asksAboutTheCount`).
  func testPickingAnotherDayAloneChoosesNoTime() {
    var form = form()
    let shown = calendar.moment(today, hour: 14, minute: 5)
    let picked = calendar.moment(DateOnly(year: 2026, month: 10, day: 2), hour: 14, minute: 5)
    form.choose(moment: picked, shown: shown, calendar: calendar)
    XCTAssertEqual(form.day, DateOnly(year: 2026, month: 10, day: 2))
    XCTAssertNil(form.time, "only the day was chosen")
  }

  func testPickingTheClockChoosesTheTimeAndKeepsTheDay() {
    var form = form()
    let shown = calendar.moment(today, hour: 14, minute: 5)
    form.choose(
      moment: calendar.moment(today, hour: 15, minute: 30), shown: shown, calendar: calendar)
    XCTAssertEqual(form.day, today)
    XCTAssertEqual(form.time, TimeOfDay(hour: 15, minute: 30))
  }

  func testPickingBothChoosesBoth() {
    var form = form()
    let shown = calendar.moment(today, hour: 14, minute: 5)
    let picked = calendar.moment(DateOnly(year: 2026, month: 10, day: 1), hour: 9, minute: 0)
    form.choose(moment: picked, shown: shown, calendar: calendar)
    XCTAssertEqual(form.day, DateOnly(year: 2026, month: 10, day: 1))
    XCTAssertEqual(form.time, TimeOfDay(hour: 9, minute: 0))
  }

  /// A time chosen once stays while only the day moves afterwards.
  func testAChosenTimeStaysWhenOnlyTheDayMovesLater() {
    var form = form()
    form.choose(
      moment: calendar.moment(today, hour: 15, minute: 30),
      shown: calendar.moment(today, hour: 14, minute: 5), calendar: calendar)
    let shown = form.occurredAt(
      now: calendar.moment(today, hour: 16, minute: 0), calendar: calendar)
    let yesterday = DateOnly(year: 2026, month: 10, day: 3)
    form.choose(
      moment: calendar.moment(yesterday, hour: 15, minute: 30), shown: shown, calendar: calendar)
    XCTAssertEqual(form.day, yesterday)
    XCTAssertEqual(form.time, TimeOfDay(hour: 15, minute: 30))
  }

  // MARK: «Перевести…» in the panel

  private let main = PaymentMethod(name: "Main", isDefault: true)
  private let wallet = PaymentMethod(
    name: "Wallet", currency: .usd, otherCurrencies: [.rub])

  private func draft(currency: CurrencyCode = .usd) -> TransactionDraft {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.moment(
        DateOnly(year: 2026, month: 10, day: 2), hour: 12, minute: 0),
      currency: currency, amount: AmountE4(whole: 100), note: "  gift  ")
    draft.normalizeSinglePart()
    return draft
  }

  /// What the panel holds — the amount, its currency, the account, the day, the note — is what
  /// the form of a new transfer starts with; the other side is the main account.
  func testThePanelBecomesTheFormOfATransfer() {
    let form = TransferForm(
      fromThePanel: draft(), account: wallet, accounts: [main, wallet], calendar: calendar)
    XCTAssertEqual(form.fromAccountId, wallet.id)
    XCTAssertEqual(form.fromCurrency, .usd)
    XCTAssertEqual(form.sent, AmountE4(whole: 100))
    XCTAssertEqual(form.day, DateOnly(year: 2026, month: 10, day: 2))
    XCTAssertEqual(form.note, "gift")
    XCTAssertEqual(form.toAccountId, main.id)
    XCTAssertEqual(form.toCurrency, .rub, "the main account holds rubles: an exchange")
    XCTAssertNil(form.time)
    XCTAssertNil(form.previous)
  }

  /// An account that does not hold the currency of the panel sends in its own.
  func testTheAccountSendsInItsOwnCurrencyWhenItDoesNotHoldTheOneOfThePanel() {
    let form = TransferForm(
      fromThePanel: draft(currency: .eur), account: wallet, accounts: [main, wallet],
      calendar: calendar)
    XCTAssertEqual(form.fromCurrency, .usd)
  }

  /// Nothing typed yet: the form is the empty form of a transfer from that account.
  func testAnEmptyPanelSendsNothingYet() {
    var empty = draft()
    empty.amount = .zero
    empty.note = nil
    let form = TransferForm(
      fromThePanel: empty, account: main, accounts: [main, wallet], calendar: calendar)
    XCTAssertEqual(form.sent, .zero)
    XCTAssertEqual(form.note, "")
    XCTAssertEqual(form.fromAccountId, main.id)
    XCTAssertNil(form.toAccountId, "the main account is the one money leaves from")
  }
}
