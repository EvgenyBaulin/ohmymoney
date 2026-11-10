import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The settings of the entry the owner asked for on 08.11: «Основной счёт» and «Валюта по
/// умолчанию» show the values of their own sections and lead there, with no key of their own;
/// «Карта или счёт» speaks only for the first purchase at a new place; «Добавить шаблон…» makes a
/// template by hand.
@MainActor
final class EntrySettingsLinksTests: XCTestCase {
  private var book: CardEntryBook!

  override func setUp() async throws {
    UserDefaults.standard.removeObject(forKey: AppEnvironment.entryFirstPurchaseKey)
    book = try await CardEntryBook()
  }

  override func tearDown() async throws {
    await book?.close()
    book = nil
    UserDefaults.standard.removeObject(forKey: AppEnvironment.entryFirstPurchaseKey)
    SettingsNavigation.shared.section = .general
  }

  // MARK: The links

  /// «Основной счёт» is the main account of «Счета»: renamed or passed on there, the row follows.
  func testTheMainAccountRowShowsTheMainAccountOfTheAccounts() throws {
    XCTAssertEqual(EntryLinks.mainAccountName(book.environment), "Сбер")
    var tBank = book.tBank
    tBank.isDefault = true
    try XCTUnwrap(book.environment.references).save(tBank)
    XCTAssertEqual(EntryLinks.mainAccountName(book.environment), "Т-Банк")
  }

  /// «Валюта по умолчанию» is the default currency of «Валюты», by its name.
  func testTheCurrencyRowShowsTheDefaultCurrency() {
    let name = EntryLinks.currencyName(book.environment)
    XCTAssertFalse(name.isEmpty)
    XCTAssertNotEqual(name, "rub")
    XCTAssertTrue(name.first?.isUppercase == true || name == book.environment.defaultCurrency.code)
  }

  /// A link opens its section of the settings window, and clears a search that would hide it.
  func testALinkOpensItsSection() {
    SettingsNavigation.shared.query = "ввод"
    EntryLinks.open(.accounts)
    XCTAssertEqual(SettingsNavigation.shared.section, .accounts)
    XCTAssertEqual(SettingsNavigation.shared.query, "")
    EntryLinks.open(.currencies)
    XCTAssertEqual(SettingsNavigation.shared.section, .currencies)
  }

  /// The search finds the three rows in «Ввод», in both languages.
  func testTheSearchFindsTheRowsOfTheEntry() {
    let words = SettingsSearch.catalogWords()
    for key in [
      "settings.entry.mainAccount", "settings.entry.defaultCurrency",
      "settings.entry.firstPurchase",
    ] {
      XCTAssertTrue(SettingsSection.entry.index.map(\.key).contains(key), key)
      for code in SettingsSearch.languages {
        let text = words(SettingsCaption(key: key, table: EntryLinks.table), code)
        XCTAssertFalse(text.isEmpty || text == key, "\(key) \(code)")
      }
    }
    XCTAssertTrue(
      SettingsSearch.find("Карта или счёт", words: words).contains { $0.section == .entry })
  }

  // MARK: «Карта или счёт»

  /// A card by default; the choice is kept, and the archive of the data carries it.
  func testTheChoiceIsACardUntilChangedAndTravelsWithTheArchive() {
    XCTAssertEqual(book.environment.entryFirstPurchase, .card)
    book.environment.entryFirstPurchase = .account
    XCTAssertEqual(AppEnvironment().entryFirstPurchase, .account)
    XCTAssertEqual(
      book.environment.portableSettings()[AppEnvironment.entryFirstPurchaseKey], "account")
  }

  /// «Счёт»: the first purchase at a place never paid at is made without a card…
  func testTheFirstPurchaseAtANewPlaceFollowsTheChoice() throws {
    book.environment.entryFirstPurchase = .account
    let place = Place(name: "Дикси")
    try XCTUnwrap(book.environment.references).save(place)
    book.environment.refreshVocabulary()
    let model = book.model()
    try book.enter("хлеб 120 в Дикси", into: model)
    XCTAssertEqual(model.draft.placeId, place.id)
    XCTAssertEqual(model.draft.paymentMethodId, book.sber.id)
    XCTAssertNil(model.draft.cardId, "the first purchase there is made from the account")
    XCTAssertFalse(model.paysWithCard)
    // «Карта» chosen in the panel brings the card all the same.
    model.setPaysFromAccount(false)
    XCTAssertEqual(model.draft.cardId, book.sberCard.id)
  }

  /// …every later one takes the card of the last purchase there, and a purchase with no place
  /// keeps the main card.
  func testALaterPurchaseThereTakesTheCardOfTheLastOne() throws {
    book.environment.entryFirstPurchase = .account
    let place = Place(name: "Магнит")
    try XCTUnwrap(book.environment.references).save(place)
    book.environment.refreshVocabulary()
    try book.history("продукты", 700, on: book.tBank, card: book.virtual, at: place)
    let there = book.model()
    try book.enter("продукты 500 в Магните", into: there)
    XCTAssertEqual(there.draft.cardId, book.virtual.id)
    let nowhere = book.model()
    try book.enter("кофе 300", into: nowhere)
    XCTAssertEqual(nowhere.draft.cardId, book.sberCard.id)
  }

  /// «Карта» — the default — keeps the rule of before: the first purchase at a new place too is
  /// made with the main card.
  func testWithACardTheNewPlaceKeepsTheMainCard() throws {
    let place = Place(name: "Спар")
    try XCTUnwrap(book.environment.references).save(place)
    book.environment.refreshVocabulary()
    let model = book.model()
    try book.enter("бинт 90 в Спаре", into: model)
    XCTAssertEqual(model.draft.placeId, place.id)
    XCTAssertEqual(model.draft.cardId, book.sberCard.id)
  }

  // MARK: «Добавить шаблон…»

  /// The words typed, an amount at their end, pinned; nothing for blank words.
  func testATemplateByHand() throws {
    let coffee = try XCTUnwrap(TemplatesByHand.template(from: "  кофе 250 "))
    XCTAssertEqual(coffee.text, "кофе")
    XCTAssertEqual(coffee.amountE4, AmountE4(whole: 250))
    XCTAssertTrue(coffee.pinned)
    XCTAssertEqual(coffee.useCount, 0)
    XCTAssertEqual(
      TemplatesByHand.template(from: "такси 12,5")?.amountE4, try AmountE4(decimal: 12.5))
    let words = try XCTUnwrap(TemplatesByHand.template(from: "обед в столовой"))
    XCTAssertEqual(words.text, "обед в столовой")
    XCTAssertNil(words.amountE4)
    XCTAssertEqual(TemplatesByHand.template(from: "кофе 25abc")?.text, "кофе 25abc")
    XCTAssertNil(TemplatesByHand.template(from: "   "))
  }

  /// The hint of the templates says both: they fill themselves and are added by hand.
  func testTheHintOfTheTemplatesSaysTheyAreAddedByHandToo() {
    for (code, word) in [("ru", "вручную"), ("en", "add one yourself")] {
      let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
      let hint = bundle?.localizedString(
        forKey: "templates.hintAdded", value: nil, table: "SettingsAccounts")
      XCTAssertTrue(hint?.contains(word) == true, "\(code): \(hint ?? "")")
    }
  }
}
