import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «перевод 5000 сбер т-банк» and the transfer chosen in the panel, followed to the database:
/// the line names the sides in either order and in either language, the form starts with what
/// the panel holds, what is left to choose stops the save with its reason, and a transfer — with
/// its fee — is neither an expense nor an income, and goes back with one ⌘Z.
@MainActor
final class EntryScenarioTransferTests: EntryScenarioCase {
  private var actions: TransferActions {
    TransferActions(environment: book.environment, store: book.store)
  }

  /// The line Enter reads, and the fields of the transfer it starts (`EntryBar.startTransfer`).
  private func form(
    _ line: String, on day: DateOnly? = nil
  ) throws
    -> (form: TransferForm, reading: TransferReading)
  {
    let model = book.model()
    try book.enter(line, into: model, on: day)
    let reading = try XCTUnwrap(
      book.reading(line, on: day).parsed.transfer, "no transfer in «\(line)»")
    let form = TransferForm(
      fromTheLine: reading, draft: model.draft, accounts: model.paymentMethods,
      calendar: book.calendar)
    return (form, reading)
  }

  private func save(_ form: TransferForm) async throws -> TransferOutcome {
    let books = try await XCTUnwrapAsync(await actions.books())
    return actions.save(
      form, occurredAt: form.occurredAt(now: Date(), calendar: book.calendar), books: books)
  }

  private func transfers() async throws -> [Transfer] {
    try await XCTUnwrapAsync(await actions.books()).dataset.transfers
  }

  private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }

  func testTheWordAndTwoAccountsIsATransferWrittenAtOnce() async throws {
    let (form, reading) = try form("перевод 5000 сбер т-банк")
    XCTAssertEqual(form.fromAccountId, book.sber.id)
    XCTAssertEqual(form.toAccountId, book.tBank.id)
    XCTAssertEqual(form.sent, AmountE4(whole: 5_000))
    XCTAssertTrue(form.savesAtOnce(reading))
    let outcome = try await save(form)
    XCTAssertEqual(outcome, .done)
    let written = try await transfers()
    XCTAssertEqual(written.count, 1)
    XCTAssertEqual(written.first?.toAmountE4, AmountE4(whole: 5_000))
    XCTAssertTrue(try book.entries().isEmpty, "a transfer is no operation")
  }

  func testFromAndToSayTheSidesWhateverTheOrder() throws {
    let (form, _) = try form("перевод 5000 на сбер с т-банка")
    XCTAssertEqual(form.fromAccountId, book.tBank.id)
    XCTAssertEqual(form.toAccountId, book.sber.id)
  }

  func testAnEnglishTransfer() throws {
    let (form, _) = try form("transfer 700 from т-банк to сбер")
    XCTAssertEqual(form.fromAccountId, book.tBank.id)
    XCTAssertEqual(form.toAccountId, book.sber.id)
    XCTAssertEqual(form.sent, AmountE4(whole: 700))
  }

  func testUndoTakesTheTransferBack() async throws {
    let (form, _) = try form("перевод 5000 сбер т-банк")
    _ = try await save(form)
    book.store.undo()
    let written = try await transfers()
    XCTAssertTrue(written.isEmpty)
  }

  /// One account and no second word is the expense it always was.
  func testOneAccountOnlyIsAnExpenseOnIt() throws {
    let read = book.reading("перевод 5000 сбер")
    XCTAssertNil(read.parsed.transfer)
    let model = book.model()
    try book.enter("перевод 5000 сбер", into: model)
    XCTAssertEqual(model.draft.kind, .expense)
    XCTAssertEqual(model.draft.paymentMethodId, book.sber.id)
  }

  func testTheSameAccountOnBothSidesIsRefused() async throws {
    var form = TransferForm(from: book.sber, accounts: [book.sber, book.tBank], day: book.today)
    form.chooseTo(book.sber)
    form.sent = AmountE4(whole: 100)
    let outcome = try await save(form)
    XCTAssertEqual(outcome, .refused(.issue(.sameKey)))
  }

  func testAnotherCurrencyIsAnExchangeThatWaitsForWhatCame() async throws {
    let (form, reading) = try form("перевод 9000 сбер wise")
    XCTAssertTrue(form.isExchange)
    XCTAssertEqual(form.toCurrency, CurrencyCode("USD"))
    XCTAssertFalse(form.savesAtOnce(reading), "the dollars that came are asked")
    var typed = form
    typed.received = AmountE4(whole: 100)
    XCTAssertNotNil(typed.impliedRate)
    let outcome = try await save(typed)
    XCTAssertEqual(outcome, .done)
    let all = try await transfers()
    let written = try XCTUnwrap(all.first)
    XCTAssertEqual(written.fromAmountE4, AmountE4(whole: 9_000))
    XCTAssertEqual(written.toAmountE4, AmountE4(whole: 100))
    XCTAssertEqual(written.toCurrency, CurrencyCode("USD"))
  }

  func testAFeeIsAnExpenseWrittenWithTheTransferAndUndoneWithIt() async throws {
    var (form, _) = try form("перевод 5000 сбер т-банк")
    form.fee = AmountE4(whole: 50)
    let outcome = try await save(form)
    XCTAssertEqual(outcome, .done)
    let fees = try book.entries()
    XCTAssertEqual(fees.count, 1)
    XCTAssertEqual(fees.first?.transaction.kind, .expense)
    XCTAssertEqual(fees.first?.transaction.amountE4, AmountE4(whole: 50))
    XCTAssertEqual(fees.first?.transaction.paymentMethodId, book.sber.id)
    XCTAssertEqual(RowTotals(entries: fees).myExpenses, AmountE4(whole: 50))
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
    let written = try await transfers()
    XCTAssertTrue(written.isEmpty)
  }

  func testANegativeFeeIsRefused() async throws {
    var (form, _) = try form("перевод 5000 сбер т-банк")
    form.fee = AmountE4(whole: -5)
    let outcome = try await save(form)
    XCTAssertEqual(outcome, .refused(.negativeFee))
  }

  func testTheDayOfTheLineIsTheDayOfTheTransfer() async throws {
    let (form, _) = try form("перевод 1000 сбер т-банк вчера")
    XCTAssertEqual(form.day, book.today.adding(days: -1))
    _ = try await save(form)
    let all = try await transfers()
    let written = try XCTUnwrap(all.first)
    XCTAssertEqual(book.calendar.day(of: written.occurredAt), book.today.adding(days: -1))
  }

  func testAPersonIsNoAccountAndTheLineStaysAnExpense() throws {
    let read = book.reading("перевод маше 500")
    XCTAssertNil(read.parsed.transfer)
    XCTAssertEqual(read.parsed.kind, .expense)
  }

  func testThePanelStartsTheTransferWithWhatItHolds() throws {
    let model = book.model()
    try book.enter("на отпуск 300 т-банк вчера", into: model)
    model.chooseTransfer(calendar: book.calendar)
    let form = try XCTUnwrap(model.transfer).form
    XCTAssertEqual(form.fromAccountId, book.tBank.id)
    XCTAssertEqual(form.sent, AmountE4(whole: 300))
    XCTAssertEqual(form.day, book.today.adding(days: -1))
    XCTAssertFalse(form.note.isEmpty, "the note goes with it")
  }

  func testChoosingTheTransferTwiceKeepsTheFirstFields() throws {
    let model = book.model()
    try book.enter("300 т-банк", into: model)
    model.chooseTransfer(calendar: book.calendar)
    model.transfer?.form.chooseTo(book.sber)
    model.chooseTransfer(calendar: book.calendar)
    XCTAssertEqual(model.transfer?.form.toAccountId, book.sber.id)
  }

  func testResetMakesTheNextEntryAnOperationAgain() throws {
    let model = book.model()
    try book.enter("300", into: model)
    model.chooseTransfer(calendar: book.calendar)
    XCTAssertNotNil(model.transfer)
    model.reset()
    XCTAssertNil(model.transfer)
  }

  func testTheLineTypedOverOpenFieldsTakesTheAmountAndTheSide() throws {
    var (form, _) = try form("перевод 5000 сбер т-банк")
    form.take(
      line: book.reading("перевод 6000 т-банк наличные").parsed.transfer,
      amount: AmountE4(whole: 6_000), currency: nil, day: nil,
      accounts: [book.sber, book.tBank, book.cash, book.wise])
    XCTAssertEqual(form.sent, AmountE4(whole: 6_000))
    XCTAssertEqual(form.fromAccountId, book.tBank.id)
    XCTAssertEqual(form.toAccountId, book.cash.id)
  }

  func testATransferIsNeitherMySpendingNorMyIncome() async throws {
    let (form, _) = try form("перевод 5000 сбер т-банк")
    _ = try await save(form)
    let totals = RowTotals(entries: try book.entries())
    XCTAssertEqual(totals.myExpenses, .zero)
    XCTAssertEqual(totals.income, .zero)
  }

  func testATransferToAnArchivedAccountIsRefused() async throws {
    var archived = book.cash
    archived.archived = true
    try book.references.save(archived)
    var form = TransferForm(from: book.sber, accounts: [book.sber, archived], day: book.today)
    form.chooseTo(archived)
    form.sent = AmountE4(whole: 100)
    let outcome = try await save(form)
    XCTAssertEqual(outcome, .refused(.issue(.archivedAccount)))
  }
}
