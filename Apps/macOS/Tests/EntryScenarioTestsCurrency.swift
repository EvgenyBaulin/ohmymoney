import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Money in other currencies through the line: codes, symbols and words, the codes that are also
/// words («try», «gel», «amd») only next to the number or in capitals, the owner's own currencies
/// with their rates typed by hand, a rate written as a formula, and a save without any rate that
/// is refused and writes nothing.
@MainActor
final class EntryScenarioCurrencyTests: EntryScenarioCase {
  private let tether = CustomCurrency(
    code: CurrencyCode("UST"), name: "Tether", symbol: "₮", fractionDigits: 2)

  private func currency(of line: String) -> CurrencyCode? {
    book.reading(line).parsed.currency
  }

  private func addTether(rateFrom day: DateOnly, rubles: Decimal) throws {
    let currencies = CurrencyRepository(writer: try XCTUnwrap(book.environment.stack).writer)
    _ = try XCTUnwrap(book.environment.planning).apply(
      try currencies.saving(tether, firstRate: (day, rubles)))
    book.environment.refreshCurrencyCatalog()
    book.environment.refreshVocabulary()
  }

  func testCodesSymbolsAndWordsOfTheDollar() {
    for line in ["кофе 5 usd", "кофе 5$", "кофе $5", "coffee 5 USD", "кофе 5 долларов"] {
      XCTAssertEqual(currency(of: line), .usd, line)
    }
  }

  func testTheEuroAndTheTenge() {
    XCTAssertEqual(currency(of: "ужин 10€"), .eur)
    XCTAssertEqual(currency(of: "ужин 10 евро"), .eur)
    XCTAssertEqual(currency(of: "ужин 5000 kzt"), CurrencyCode("KZT"))
  }

  func testACodeThatIsAWordIsAWordAwayFromTheNumber() {
    let read = book.reading("try again 300")
    XCTAssertNil(read.parsed.currency)
    XCTAssertTrue(read.parsed.note.contains("try"))
    XCTAssertEqual(currency(of: "кебаб 300try"), CurrencyCode("TRY"))
    XCTAssertEqual(currency(of: "кебаб 300 TRY"), CurrencyCode("TRY"))
    XCTAssertNil(currency(of: "кебаб TRY 300"), "capitals count right after the number only")
  }

  func testGelAndAmdBesideTheNumberOnly() {
    XCTAssertEqual(currency(of: "хинкали 30gel"), CurrencyCode("GEL"))
    XCTAssertNil(currency(of: "gel для душа 300"))
    XCTAssertEqual(currency(of: "такси 1500 AMD"), CurrencyCode("AMD"))
  }

  func testRublesNamedAreRubles() {
    for line in ["кофе 300 руб", "кофе 300₽", "кофе 300 р"] {
      let model = book.model()
      try? book.enter(line, into: model)
      XCTAssertEqual(model.draft.currency, .rub, line)
    }
  }

  func testWithoutAnyRateTheSaveIsRefusedAndNothingIsWritten() throws {
    let model = book.model()
    try book.enter("кофе 5 usd", into: model)
    model.setCategory(book.coffeeShops.id, forPartAt: 0)
    XCTAssertThrowsError(
      try EntrySave.write(model, environment: book.environment, store: book.store)
    ) {
      XCTAssertEqual(EntryCommit.errorKey(of: $0), "entry.error.rateMissing")
    }
    XCTAssertTrue(try book.entries().isEmpty)
    XCTAssertFalse(book.store.canUndo)
  }

  func testARateTypedByHandGivesTheRubles() throws {
    let model = book.model()
    try book.enter("кофе 5 usd", into: model)
    model.setCategory(book.coffeeShops.id, forPartAt: 0)
    model.setManualRate("90")
    let entry = try book.save(model)
    XCTAssertEqual(entry.transaction.currency, .usd)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 5))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 450))
    XCTAssertEqual(entry.transaction.rateSource, .manual)
  }

  func testARateAsAFormula() throws {
    let model = book.model()
    try book.enter("кофе 10 usd", into: model)
    model.setManualRate("(90+92)/2")
    XCTAssertEqual(model.draft.rate, 91)
    XCTAssertEqual(model.draft.rateSource, .manual)
  }

  func testARateOfZeroOrLessOrNonsenseIsNotTaken() throws {
    let model = book.model()
    try book.enter("кофе 10 usd", into: model)
    model.setManualRate("90")
    for text in ["0", "-5", "abc", "10/0"] {
      model.setManualRate(text)
      XCTAssertEqual(model.draft.rate, 90, text)
    }
  }

  func testEmptyingTheRateFieldForgetsTheRate() throws {
    let model = book.model()
    try book.enter("кофе 10 usd", into: model)
    model.setManualRate("90")
    model.setManualRate("")
    XCTAssertNil(model.draft.rate)
    XCTAssertNil(model.draft.rateSource)
  }

  func testTheAccountOfTheLineGivesItsCurrency() throws {
    let model = book.model()
    try book.enter("кофе 5 wise", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, book.wise.id)
    XCTAssertEqual(model.currencyOnSaving(book.reading("кофе 5 wise").parsed), .usd)
  }

  func testAnIncomeInDollarsAtARateTypedByHand() throws {
    let model = book.model()
    try book.enter("+100 usd гонорар", into: model)
    model.setCategory(book.earnings.id, forPartAt: 0)
    model.setManualRate("95.5")
    let entry = try book.save(model)
    XCTAssertEqual(entry.transaction.kind, .income)
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 9_550))
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
  }

  func testTheOwnersCurrencyIsReadByItsCode() throws {
    try addTether(rateFrom: book.today.adding(days: -10), rubles: 95)
    XCTAssertEqual(currency(of: "подписка 10 UST"), tether.code)
    XCTAssertEqual(currency(of: "подписка 10 ust"), tether.code)
  }

  func testTheOwnersSymbolBesideTheNumber() throws {
    try addTether(rateFrom: book.today.adding(days: -10), rubles: 95)
    XCTAssertEqual(currency(of: "подписка 10₮"), tether.code)
  }

  func testTheOwnersCurrencyIsWrittenAtItsOwnRate() throws {
    try addTether(rateFrom: book.today.adding(days: -10), rubles: 95)
    let model = book.model()
    try book.enter("подписка 10 UST", into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertEqual(entry.transaction.currency, tether.code)
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 950))
  }

  func testBeforeItsFirstRateTheOwnersCurrencyHasNone() throws {
    try addTether(rateFrom: book.today, rubles: 95)
    let model = book.model()
    try book.enter("подписка 10 UST вчера", into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    XCTAssertThrowsError(
      try EntrySave.write(model, environment: book.environment, store: book.store)
    ) {
      XCTAssertEqual(EntryCommit.errorKey(of: $0), "entry.error.rateMissing")
    }
  }

  func testAnUnknownThreeLetterWordIsNoCurrency() {
    let read = book.reading("кофе 300 abc")
    XCTAssertNil(read.parsed.currency)
    XCTAssertTrue(read.parsed.note.contains("abc"))
  }

  func testTheCurrencyOfTheNextLineReplacesTheFirst() throws {
    let model = book.model()
    try book.enter("кофе 5 usd", into: model)
    try book.enter("кофе 5 eur", into: model)
    XCTAssertEqual(model.draft.currency, .eur)
  }
}
