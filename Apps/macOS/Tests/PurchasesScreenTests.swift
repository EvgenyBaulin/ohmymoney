import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The screens of the purchases on synthetic data: the page carries what the core counts (the
/// wait for a wish, the operations offered for «Купил», the cost of owning a thing, the refunds
/// waited for, the savings), the links and the sale are written as the rules say, and every word
/// reads in both languages.
@MainActor
final class PurchasesPageTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 29)
  private let calendar = CalendarContext.utc

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }
  private func day(_ month: Int, _ day: Int, year: Int = 2026) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func entry(
    _ amount: Int64, on date: DateOnly, kind: TransactionKind = .expense, note: String? = nil,
    currency: CurrencyCode = .rub, rubles: Int64? = nil
  ) throws -> TransactionEntry {
    let draft = TransactionDraft(
      kind: kind, occurredAt: calendar.noon(of: date), currency: currency, amount: rub(amount),
      note: note, parts: [PartDraft(amount: rub(amount))])
    return try draft.materialize(
      timeZone: TimeZone(secondsFromGMT: 0)!, rublesConverter: { _ in self.rub(rubles ?? amount) })
  }

  private func build(
    _ dataset: Dataset, canSave: CanSave? = nil, rates: [CurrencyCode: Decimal] = [:],
    waiting: WaitingRefunds = WaitingRefunds(items: [])
  ) -> PurchasesPage {
    PurchasesPage.build(
      dataset: dataset, canSave: canSave, rubPerUnit: rates, today: today, calendar: calendar,
      waiting: waiting)
  }

  // MARK: Wishes

  func testTheMostWantedWishComesFirstAndAPriorityOfZeroLast() {
    let none = Wish(name: "Без важности", priceE4: rub(1000), createdOn: day(1, 1))
    let second = Wish(name: "Второе", priceE4: rub(1000), priority: 2, createdOn: day(1, 2))
    let first = Wish(name: "Первое", priceE4: rub(1000), priority: 1, createdOn: day(1, 3))
    let page = build(Dataset(wishes: [none, second, first]))
    XCTAssertEqual(page.wishes.map(\.wish.name), ["Первое", "Второе", "Без важности"])
  }

  func testWithoutTheMonthlySavingNoDateIsTold() {
    let wish = Wish(name: "Наушники", priceE4: rub(32_000), createdOn: day(10, 1))
    let page = build(Dataset(wishes: [wish]))
    let line = page.wishes[0]
    XCTAssertEqual(line.afford.outcome, .noSavingPace)
    XCTAssertEqual(line.priceRubE4, rub(32_000))
    for choice in [AppLanguage.Choice.russian, .english] {
      let text = PurchasesText.afford(line, environment(choice))
      XCTAssertEqual(text, PurchasesText.t("purchases.afford.noPace", environment(choice)))
    }
  }

  func testAWishInAForeignCurrencyWithoutARateSaysSoAndIsNotGuessed() {
    let wish = Wish(
      name: "Часы", priceE4: rub(300), currency: CurrencyCode("USD"), createdOn: day(10, 1))
    let page = build(Dataset(wishes: [wish]))
    let line = page.wishes[0]
    XCTAssertTrue(line.rateMissing)
    XCTAssertNil(line.priceRubE4)
    XCTAssertEqual(
      PurchasesText.afford(line, environment(.english)),
      PurchasesText.t("purchases.afford.noRate", environment(.english)))
    let withRate = build(Dataset(wishes: [wish]), rates: [CurrencyCode("USD"): 90])
    XCTAssertFalse(withRate.wishes[0].rateMissing)
    XCTAssertEqual(withRate.wishes[0].priceRubE4, rub(27_000))
  }

  func testTheWaitIsToldInMonthsAtThePaceOfTheMonth() {
    let line = WishLine(
      wish: Wish(name: "Ноутбук", priceE4: rub(100_000), createdOn: day(10, 1)),
      tracking: WishPriceTracking.track(
        wish: Wish(name: "Ноутбук", priceE4: rub(100_000), createdOn: day(10, 1)), prices: [],
        today: today),
      afford: TimeToAfford(
        outcome: .months(4), priceRubE4: rub(100_000), savedE4: .zero,
        monthlySavingE4: rub(25_000), remainingE4: rub(100_000), readyIn: nil, lowData: false),
      priceRubE4: rub(100_000), rateMissing: false)
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let text = PurchasesText.afford(line, environment) ?? ""
      XCTAssertTrue(text.contains("4"), text)
      XCTAssertTrue(text.contains(environment.money.rounded(rub(25_000))), text)
    }
  }

  func testAPriceNotedLowerThanBeforeIsTimeToBuyAndTheChangeCarriesItsSign() {
    var wish = Wish(name: "Пылесос", priceE4: rub(20_000), createdOn: day(9, 1))
    wish.expectedE4 = rub(15_000)
    let prices = [
      WishPrice(wishId: wish.id, onDate: day(9, 1), priceE4: rub(20_000)),
      WishPrice(wishId: wish.id, onDate: day(10, 10), priceE4: rub(14_500)),
    ]
    wish.priceE4 = rub(14_500)
    let page = build(Dataset(wishes: [wish], wishPrices: prices))
    let line = page.wishes[0]
    XCTAssertEqual(line.tracking.timeToBuy, .belowExpected)
    XCTAssertEqual(line.tracking.lowestE4, rub(14_500))
    let text = PurchasesText.change(line, environment(.english)) ?? ""
    XCTAssertTrue(text.contains("\u{2212}"), "a fall is told by its sign: \(text)")
  }

  // MARK: «Купил»

  func testOnlyOperationsOfAboutThePriceFromTheLastTwoMonthsAreOffered() throws {
    let wish = Wish(name: "Наушники", priceE4: rub(32_000), createdOn: day(10, 1))
    let close = try entry(31_000, on: day(10, 25), note: "наушники")
    let far = try entry(36_000, on: day(10, 20), note: "ещё")
    let old = try entry(32_000, on: day(7, 1), note: "давно")
    let small = try entry(5_000, on: day(10, 25), note: "мелочь")
    let income = try entry(32_000, on: day(10, 25), kind: .income)
    let taken = try entry(32_000, on: day(10, 26), note: "занято")
    let found = PurchasesPage.candidates(
      for: wish, entries: [far, old, small, income, close, taken], takenBy: [taken.id],
      rubPerUnit: [:], today: today, calendar: calendar)
    XCTAssertEqual(found.map(\.id), [close.id, far.id], "the closest first")
  }

  func testAWishWithoutAPriceOrARateOffersNothing() throws {
    let operation = try entry(32_000, on: day(10, 25))
    var wish = Wish(name: "Без цены", createdOn: day(10, 1))
    XCTAssertTrue(
      PurchasesPage.candidates(
        for: wish, entries: [operation], takenBy: [], rubPerUnit: [:], today: today,
        calendar: calendar
      ).isEmpty)
    wish.priceE4 = rub(300)
    wish.currency = CurrencyCode("USD")
    XCTAssertTrue(
      PurchasesPage.candidates(
        for: wish, entries: [operation], takenBy: [], rubPerUnit: [:], today: today,
        calendar: calendar
      ).isEmpty)
  }

  func testWhatCameOutIsComparedWithWhatWasThought() throws {
    var wish = Wish(name: "Наушники", priceE4: rub(32_000), createdOn: day(10, 1))
    let operation = try entry(29_900, on: day(10, 25))
    wish.boughtTransactionId = operation.id
    wish.expectedE4 = rub(32_000)
    let page = build(Dataset(entries: [operation], wishes: [wish]))
    XCTAssertTrue(page.wishes.isEmpty, "a bought wish leaves the list of what is wanted")
    let outcome = try XCTUnwrap(page.bought.first?.outcome)
    XCTAssertEqual(outcome.expectedE4, rub(32_000))
    XCTAssertEqual(outcome.paidE4, rub(29_900))
    XCTAssertEqual(outcome.differenceE4, rub(-2_100))
    for choice in [AppLanguage.Choice.russian, .english] {
      let text = PurchasesText.outcome(outcome, currency: .rub, environment(choice))
      XCTAssertTrue(text.contains("\u{2212}"), text)
    }
  }

  func testWhatWasPaidInAnotherCurrencyIsBroughtToTheCurrencyOfTheWish() throws {
    let wish = Wish(
      name: "Часы", priceE4: rub(300), currency: CurrencyCode("USD"), createdOn: day(10, 1))
    let operation = try entry(27_000, on: day(10, 25))
    XCTAssertEqual(
      PurchasesPage.paidAmount(
        of: operation, inCurrencyOf: wish, rubPerUnit: [CurrencyCode("USD"): 90]),
      rub(300))
    XCTAssertNil(PurchasesPage.paidAmount(of: operation, inCurrencyOf: wish, rubPerUnit: [:]))
  }

  // MARK: Things

  func testAThingNotedApartCostsItsPriceOverTheMonthsOwned() {
    let item = OwnedItem(name: "Ноутбук", boughtOn: day(4, 29), priceE4: rub(60_000))
    let page = build(Dataset(ownedItems: [item]))
    let line = page.things[0]
    XCTAssertEqual(line.cost.months, 6)
    XCTAssertEqual(line.cost.totalRubE4, rub(60_000))
    XCTAssertEqual(line.cost.perMonthRubE4, rub(10_000))
    XCTAssertNil(line.vehicle)
    for choice in [AppLanguage.Choice.russian, .english] {
      XCTAssertFalse(PurchasesText.ownership(line.cost, environment(choice)).isEmpty)
    }
  }

  func testInvestmentsAreNotThingsAndASoldThingGoesToTheSoldOnes() {
    let car = Asset(name: "Машина", kind: .vehicle)
    let shares = Asset(name: "Брокерский счёт", kind: .investment)
    let sold = OwnedItem(
      name: "Велосипед", boughtOn: day(1, 10), priceE4: rub(20_000), soldOn: day(9, 1))
    let valuations = [
      AssetValuation(assetId: car.id, day: day(1, 1), valueE4: rub(1_200_000)),
      AssetValuation(assetId: shares.id, day: day(1, 1), valueE4: rub(500_000)),
    ]
    let page = build(
      Dataset(assets: [car, shares], assetValuations: valuations, ownedItems: [sold]))
    XCTAssertEqual(page.things.map(\.name), ["Машина"])
    XCTAssertEqual(page.soldThings.map(\.name), ["Велосипед"])
    XCTAssertNil(page.things.first?.vehicle, "without a tag nothing is known of the fuel")
    let tagged = build(
      Dataset(
        assets: [car], assetValuations: valuations, tagBook: TagBook(tags: [Tag(name: "Машина")])))
    XCTAssertNotNil(
      tagged.things.first?.vehicle, "a car with a tag carries the fuel and the kilometre")
  }

  func testTheRunningCostsOfAThingAreWhatIsSpentUnderItsTag() throws {
    let tag = Tag(name: "ноутбук")
    let service = try entry(3_000, on: day(8, 10), note: "ремонт")
    let part = service.parts[0]
    let item = OwnedItem(name: "Ноутбук", boughtOn: day(4, 29), priceE4: rub(60_000), tagId: tag.id)
    let book = TagBook(tags: [tag], links: [PartTag(partId: part.id, tagId: tag.id)])
    let page = build(Dataset(entries: [service], tagBook: book, ownedItems: [item]))
    let line = page.things[0]
    XCTAssertEqual(line.cost.runningRubE4, rub(3_000))
    XCTAssertEqual(line.cost.totalRubE4, rub(63_000))
    XCTAssertEqual(line.cost.perMonthRubE4, rub(10_500))
  }

  func testTheSaleIsAnIncomeInTheSalesCategoryNamedAfterTheThing() {
    let first = PurchaseActions.salesCategory(categories: [], name: "Продажа вещей")
    XCTAssertEqual(first.made.count, 1)
    XCTAssertEqual(first.made[0].kind, .income)
    XCTAssertNil(first.made[0].parentId)
    XCTAssertNil(first.made[0].systemRole)
    // The category made once is found again, in either language, and not made twice.
    let again = PurchaseActions.salesCategory(
      categories: first.made, name: "Sale of things", alsoKnownAs: ["Продажа вещей"])
    XCTAssertEqual(again.id, first.id)
    XCTAssertTrue(again.made.isEmpty)
    let archived = { () -> [CoreKit.Category] in
      var category = first.made[0]
      category.archived = true
      return [category]
    }()
    XCTAssertEqual(
      PurchaseActions.salesCategory(categories: archived, name: "Продажа вещей").made.count, 1,
      "an archived category is not used")
    let draft = PurchaseActions.saleDraft(
      name: "Велосипед", price: rub(15_000), currency: .rub, day: today, category: first.id,
      accountId: nil, noon: calendar.noon(of: today))
    XCTAssertEqual(draft.kind, .income)
    XCTAssertEqual(draft.note, "Велосипед")
    XCTAssertEqual(draft.parts.map(\.amount), [rub(15_000)])
    XCTAssertEqual(draft.parts.first?.categoryId, first.id)
  }

  func testAnAssetSoldIsFoundByItsNameAndDay() throws {
    let sale = try entry(900_000, on: day(9, 5), kind: .income, note: "Машина")
    let other = try entry(900_000, on: day(9, 6), kind: .income, note: "Машина")
    XCTAssertEqual(
      PurchasesPage.saleOf("Машина", on: day(9, 5), entries: [other, sale], calendar: calendar),
      sale.id)
    XCTAssertNil(
      PurchasesPage.saleOf("Дача", on: day(9, 5), entries: [other, sale], calendar: calendar))
    let car = Asset(name: "Машина", kind: .vehicle, disposedOn: day(9, 5))
    let valuations = [AssetValuation(assetId: car.id, day: day(1, 1), valueE4: rub(1_000_000))]
    let page = build(Dataset(entries: [sale], assets: [car], assetValuations: valuations))
    let line = try XCTUnwrap(page.soldThings.first)
    XCTAssertEqual(line.cost.saleRubE4, rub(900_000))
    XCTAssertEqual(line.cost.totalRubE4, rub(100_000))
  }

  // MARK: Rules of the forms

  func testALinkIsReadWithOrWithoutItsSchemeAndOnlyAsHTTP() {
    XCTAssertEqual(
      PurchaseActions.link("example.ru/item")?.absoluteString, "https://example.ru/item")
    XCTAssertEqual(PurchaseActions.link(" http://shop.example/a ")?.scheme, "http")
    XCTAssertNil(PurchaseActions.link("ftp://example.ru"))
    XCTAssertNil(PurchaseActions.link("не ссылка"))
    XCTAssertNil(PurchaseActions.link("localhost"))
    XCTAssertNil(PurchaseActions.link("   "))
    var wish = Wish(name: "Чайник", createdOn: day(10, 1))
    wish.url = "не ссылка"
    XCTAssertEqual(PurchaseActions.refusal(saving: wish), .badLink)
    wish.url = "shop.example/kettle"
    XCTAssertNil(PurchaseActions.refusal(saving: wish))
    XCTAssertEqual(PurchaseActions.cleaned(wish).url, "https://shop.example/kettle")
    wish.name = "   "
    XCTAssertEqual(PurchaseActions.refusal(saving: wish), .emptyName)
  }

  func testTheShoppingListKeepsTheUndoneFirst() {
    let a = ShoppingItem(name: "Хлеб", done: true, createdOn: day(10, 1), sort: 0)
    let b = ShoppingItem(name: "Молоко", createdOn: day(10, 2), sort: 1)
    let c = ShoppingItem(name: "Яйца", createdOn: day(10, 3), sort: 2)
    let page = build(Dataset(shoppingItems: [a, b, c]))
    XCTAssertEqual(page.shopping.map(\.name), ["Молоко", "Яйца", "Хлеб"])
  }

  // MARK: Refunds and discounts

  func testTheWaitingRefundsAreTheOnesOfTheSnapshot() throws {
    var refund = try entry(2_500, on: day(10, 20), kind: .refund, note: "Кроссовки")
    refund.transaction.refundWaitingUntil = day(10, 27)
    let waiting = WaitingRefunds.list(entries: [refund], calendar: calendar)
    let page = build(Dataset(entries: [refund]), waiting: waiting)
    XCTAssertEqual(page.waiting.items.count, 1)
    let item = page.waiting.items[0]
    XCTAssertTrue(item.isLate(today: today))
    XCTAssertEqual(page.waiting.totalRubE4, rub(2_500))
    for choice in [AppLanguage.Choice.russian, .english] {
      XCTAssertTrue(PurchasesText.expected(item, today: today, environment(choice)).contains("2"))
    }
  }

  func testTheSavingsAreTheDiscountsOfTheMonthAndOfTheYear() throws {
    var thisMonth = try entry(900, on: day(10, 5), note: "кроссовки")
    thisMonth.transaction.discountE4 = rub(100)
    var earlier = try entry(1_800, on: day(3, 5), note: "куртка")
    earlier.transaction.discountE4 = rub(200)
    let page = build(Dataset(entries: [thisMonth, earlier]))
    XCTAssertEqual(page.savingsMonth.totalRubE4, rub(100))
    XCTAssertEqual(page.savingsYear.totalRubE4, rub(300))
    XCTAssertEqual(page.savingsYear.count, 2)
    XCTAssertEqual(page.savingsYear.fullPriceRubE4, rub(3_000))
  }

  // MARK: Words

  func testEveryWordIsInBothLanguages() {
    let keys = Self.keys
    XCTAssertFalse(keys.isEmpty)
    for code in ["ru", "en"] {
      let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
      for key in keys {
        let value = bundle?.localizedString(forKey: key, value: nil, table: "Purchases")
        XCTAssertNotNil(value, "\(code) \(key)")
        XCTAssertNotEqual(value, key, "\(code) has no words for \(key)")
        XCTAssertFalse(value?.isEmpty ?? true, "\(code) \(key)")
      }
      for key in ["section.purchases"] {
        XCTAssertNotEqual(bundle?.localizedString(forKey: key, value: nil, table: "Common"), key)
      }
      XCTAssertNotEqual(
        bundle?.localizedString(forKey: "settings.tab.purchases", value: nil, table: "Settings"),
        "settings.tab.purchases")
    }
  }

  func testThePagesHaveWordsAndSymbolsOfTheirOwn() {
    let pages = PurchasesText.Page.allCases
    XCTAssertEqual(Set(pages.map(\.symbol)).count, pages.count)
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let titles = pages.map { PurchasesText.t($0.titleKey, environment) }
      XCTAssertEqual(Set(titles).count, titles.count, "two pages share a name")
      XCTAssertNotEqual(titles, pages.map(\.titleKey))
    }
  }

  func testThePluralWordsAgreeWithTheirNumbers() {
    let russian = environment(.russian)
    XCTAssertEqual(
      PurchasesText.count("purchases.savings.count", russian, 1), "1 покупка со скидкой")
    XCTAssertEqual(
      PurchasesText.count("purchases.savings.count", russian, 3), "3 покупки со скидкой")
    XCTAssertEqual(
      PurchasesText.count("purchases.savings.count", russian, 5), "5 покупок со скидкой")
    let english = environment(.english)
    XCTAssertEqual(
      PurchasesText.count("purchases.savings.count", english, 1), "1 purchase with a discount")
    XCTAssertEqual(
      PurchasesText.count("purchases.savings.count", english, 2), "2 purchases with a discount")
  }

  func testTheSettingsSectionIsFoundByItsWordsInBothLanguages() {
    let words = SettingsSearch.catalogWords()
    XCTAssertTrue(SettingsSearch.find("пауза", words: words).map(\.section).contains(.purchases))
    XCTAssertTrue(SettingsSearch.find("mileage", words: words).map(\.section).contains(.purchases))
    XCTAssertTrue(
      SettingsSearch.find("не пожалели", words: words).map(\.section).contains(.purchases))
  }

  func testTheSectionIsReachedByTheSeventhShortcutAndFromTheMoreScreen() {
    XCTAssertEqual(MainWindow.Section.purchases.shortcutIndex, 7)
    XCTAssertEqual(MainWindow.Section.purchases.rawValue, "purchases")
    XCTAssertEqual(
      PhoneNavigation.route(forShortcutIndex: 7), PhoneRoute(tab: .more, more: .purchases))
    XCTAssertTrue(MoreMenu.make(more: [], tripIsOn: false).sections.contains(.purchases))
    XCTAssertEqual(MoreRow.purchases.id, "purchases")
  }

  /// Every key the screens read from the table «Purchases».
  private static let keys: [String] = [
    "purchases.title", "purchases.subtitle", "purchases.page.wishes", "purchases.page.shopping",
    "purchases.page.things", "purchases.page.waiting", "purchases.page.savings",
    "purchases.wishes.heading", "purchases.wishes.add", "purchases.wishes.empty",
    "purchases.wish.noPrice", "purchases.priority.none", "purchases.wish.priority",
    "purchases.afford.now", "purchases.afford.noPace", "purchases.afford.noRate",
    "purchases.afford.months", "purchases.afford.pace", "purchases.timeToBuy",
    "purchases.timeToBuy.expected", "purchases.timeToBuy.fell", "purchases.price.change",
    "purchases.price.lowest", "purchases.price.highest", "purchases.wish.price",
    "purchases.wish.bought", "purchases.wish.link", "purchases.wish.edit", "purchases.wish.archive",
    "purchases.wish.more", "purchases.wish.delete.title", "purchases.wish.delete.message",
    "purchases.bought.heading", "purchases.bought.noOutcome", "purchases.outcome",
    "purchases.wish.editor.new", "purchases.wish.editor.edit", "purchases.wish.editor.name",
    "purchases.wish.editor.price", "purchases.wish.editor.currency",
    "purchases.wish.editor.priority", "purchases.wish.editor.link", "purchases.wish.editor.note",
    "purchases.price.title", "purchases.price.now", "purchases.price.day",
    "purchases.price.history", "purchases.price.none", "purchases.price.remove",
    "purchases.price.note", "purchases.bought.title", "purchases.bought.hint",
    "purchases.bought.none", "purchases.bought.noDescription", "purchases.bought.link",
    "purchases.things.heading", "purchases.things.add", "purchases.things.empty",
    "purchases.things.sold", "purchases.thing.fromCapital", "purchases.thing.noteApart",
    "purchases.thing.boughtOn", "purchases.thing.noPrice", "purchases.thing.cost",
    "purchases.thing.months", "purchases.thing.warranty", "purchases.thing.warrantyOver",
    "purchases.thing.noTag", "purchases.thing.sell", "purchases.thing.edit",
    "purchases.thing.soldFor", "purchases.thing.delete.title", "purchases.thing.delete.message",
    "purchases.vehicle.fuel", "purchases.vehicle.average", "purchases.vehicle.perKm",
    "purchases.thing.editor.new", "purchases.thing.editor.edit", "purchases.thing.editor.name",
    "purchases.thing.editor.price", "purchases.thing.editor.currency",
    "purchases.thing.editor.hasDay", "purchases.thing.editor.day", "purchases.thing.editor.tag",
    "purchases.thing.editor.noTag", "purchases.thing.editor.tagHint",
    "purchases.thing.editor.note", "purchases.sale.title", "purchases.sale.price",
    "purchases.sale.currency", "purchases.sale.day", "purchases.sale.account",
    "purchases.sale.mainAccount", "purchases.sale.hint", "purchases.sale.button",
    "purchases.category.sales", "purchases.waiting.empty", "purchases.waiting.total",
    "purchases.waiting.hint", "purchases.waiting.noNote", "purchases.waiting.until",
    "purchases.waiting.late", "purchases.waiting.credited", "purchases.waiting.postpone",
    "purchases.postpone.title", "purchases.postpone.day", "purchases.savings.empty",
    "purchases.savings.month", "purchases.savings.year", "purchases.savings.byMonth",
    "purchases.savings.count", "purchases.savings.share", "purchases.shopping.add",
    "purchases.shopping.addButton", "purchases.shopping.empty", "purchases.shopping.clear",
    "purchases.shopping.tick", "purchases.shopping.untick", "purchases.shopping.remove",
    "purchases.refusal.name", "purchases.refusal.price", "purchases.refusal.link",
    "purchases.refusal.notFound", "purchases.refusal.failed", "purchases.settings.title",
    "purchases.settings.pause", "purchases.settings.pauseHint", "purchases.settings.pausePercent",
    "purchases.settings.pauseFooter", "purchases.settings.regret",
    "purchases.settings.regretHint", "purchases.settings.askAfter", "purchases.settings.mileage",
    "purchases.settings.mileageHint",
  ]
}

/// The actions of the purchases against a database in memory: what an action wrote is read back
/// from the database, not from a snapshot.
final class PurchaseActionsTests: CapitalStoreTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 29)

  private var purchases: PurchaseActions {
    PurchaseActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func expense(_ amount: Int64, note: String) throws -> TransactionEntry {
    let draft = TransactionDraft(
      kind: .expense, occurredAt: environment.calendar.noon(of: today), currency: .rub,
      amount: rub(amount), note: note, parts: [PartDraft(amount: rub(amount))])
    return try draft.materialize(
      timeZone: environment.calendar.timeZone, rublesConverter: { $0 })
  }

  // MARK: Wishes

  func testAWishIsAddedCleanedWithItsFirstPriceAndItsOrder() throws {
    var wish = Wish(
      name: "  Наушники ", priceE4: rub(32_000), createdOn: today)
    wish.note = "  "
    wish.url = "shop.example/a"
    XCTAssertEqual(purchases.add(wish), .done)
    XCTAssertEqual(purchases.add(Wish(name: "Чайник", createdOn: today)), .done)
    let repository = try XCTUnwrap(environment.wishes)
    let stored = try repository.wishes()
    XCTAssertEqual(stored.map(\.name), ["Наушники", "Чайник"])
    XCTAssertNil(stored[0].note, "an empty note was kept as text")
    XCTAssertEqual(stored[0].url, "https://shop.example/a")
    XCTAssertEqual(stored[0].sort + 1, stored[1].sort, "the second wish stands after the first")
    XCTAssertEqual(try repository.prices(of: stored[0].id).map(\.priceE4), [rub(32_000)])
    XCTAssertTrue(try repository.prices(of: stored[1].id).isEmpty, "no price, no history")
  }

  func testAnEmptyNameOrABadLinkOrAPriceBelowZeroWritesNothing() throws {
    XCTAssertEqual(purchases.add(Wish(name: "   ", createdOn: today)), .refused(.emptyName))
    var wish = Wish(name: "Чайник", createdOn: today)
    wish.url = "не ссылка"
    XCTAssertEqual(purchases.add(wish), .refused(.badLink))
    wish.url = nil
    wish.priceE4 = rub(-1)
    XCTAssertEqual(purchases.add(wish), .refused(.badPrice))
    XCTAssertTrue(try XCTUnwrap(environment.wishes).wishes().isEmpty)
  }

  func testANotedPriceJoinsTheHistoryAndTheSameOneAddsNoRow() throws {
    let wish = Wish(name: "Пылесос", priceE4: rub(20_000), createdOn: today)
    XCTAssertEqual(purchases.add(wish), .done)
    XCTAssertEqual(
      purchases.notePrice(of: wish.id, rub(18_000), on: DateOnly(year: 2026, month: 10, day: 30)),
      .done)
    XCTAssertEqual(
      purchases.notePrice(of: wish.id, rub(18_000), on: DateOnly(year: 2026, month: 11, day: 1)),
      .done)
    XCTAssertEqual(purchases.notePrice(of: wish.id, .zero, on: today), .refused(.badPrice))
    let repository = try XCTUnwrap(environment.wishes)
    XCTAssertEqual(try repository.prices(of: wish.id).map(\.priceE4), [rub(20_000), rub(18_000)])
    XCTAssertEqual(try repository.wish(id: wish.id)?.priceE4, rub(18_000))
  }

  func testBoughtTiesTheOperationAndKeepsWhatWasExpected() async throws {
    let wish = Wish(name: "Наушники", priceE4: rub(32_000), createdOn: today)
    XCTAssertEqual(purchases.add(wish), .done)
    let operation = try expense(29_900, note: "наушники")
    XCTAssertTrue(store.save(operation))
    XCTAssertEqual(purchases.markBought(wish, by: operation.id), .done)
    let repository = try XCTUnwrap(environment.wishes)
    XCTAssertTrue(try repository.wishes().isEmpty, "a bought wish left the list")
    let stored = try XCTUnwrap(try repository.wish(id: wish.id))
    XCTAssertEqual(stored.boughtTransactionId, operation.id)
    XCTAssertEqual(stored.expectedE4, rub(32_000))
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let page = PurchasesPage.build(
      dataset: dataset, canSave: nil, rubPerUnit: [:], today: today,
      calendar: environment.calendar, waiting: WaitingRefunds(items: []))
    XCTAssertEqual(page.bought.first?.outcome?.differenceE4, rub(-2_100))
  }

  func testAWishCanBeTakenOffTheListOrDeletedWithItsPrices() throws {
    let kept = Wish(name: "Оставить", priceE4: rub(1_000), createdOn: today)
    let gone = Wish(name: "Удалить", priceE4: rub(2_000), createdOn: today)
    XCTAssertEqual(purchases.add(kept), .done)
    XCTAssertEqual(purchases.add(gone), .done)
    XCTAssertEqual(purchases.archive(kept), .done)
    let repository = try XCTUnwrap(environment.wishes)
    XCTAssertEqual(try repository.wishes().map(\.name), ["Удалить"])
    XCTAssertEqual(purchases.delete(wish: gone.id), .done)
    XCTAssertTrue(try repository.wishes().isEmpty)
    XCTAssertTrue(try repository.prices(of: gone.id).isEmpty, "the prices stayed")
  }

  // MARK: Shopping

  func testTheShoppingListAddsTicksAndClears() throws {
    XCTAssertEqual(purchases.addShopping("  Молоко "), .done)
    XCTAssertEqual(purchases.addShopping("Хлеб"), .done)
    XCTAssertEqual(purchases.addShopping("   "), .refused(.emptyName))
    let repository = try XCTUnwrap(environment.shopping)
    var items = try repository.items()
    XCTAssertEqual(items.map(\.name), ["Молоко", "Хлеб"])
    XCTAssertEqual(purchases.setDone(items[0].id, true), .done)
    items = try repository.items()
    XCTAssertEqual(items.map(\.name), ["Хлеб", "Молоко"], "the undone first")
    XCTAssertEqual(purchases.clearDone(), .done)
    XCTAssertEqual(try repository.items().map(\.name), ["Хлеб"])
    XCTAssertEqual(purchases.deleteShopping(items[0].id), .done)
  }

  // MARK: Things

  func testAThingIsAddedEditedAndDeleted() throws {
    var item = OwnedItem(name: " Ноутбук ", boughtOn: today, priceE4: rub(60_000), note: " ")
    XCTAssertEqual(purchases.add(item), .done)
    let repository = try XCTUnwrap(environment.ownedItems)
    var stored = try XCTUnwrap(try repository.items().first)
    XCTAssertEqual(stored.name, "Ноутбук")
    XCTAssertNil(stored.note)
    item = stored
    item.priceE4 = rub(55_000)
    XCTAssertEqual(purchases.save(item), .done)
    stored = try XCTUnwrap(try repository.item(id: item.id))
    XCTAssertEqual(stored.priceE4, rub(55_000))
    XCTAssertEqual(purchases.add(OwnedItem(name: " ")), .refused(.emptyName))
    XCTAssertEqual(purchases.delete(item: item.id), .done)
    XCTAssertTrue(try repository.items().isEmpty)
  }

  func testSellingAThingWritesAnIncomeAndClosesTheThing() async throws {
    let item = OwnedItem(name: "Велосипед", boughtOn: today, priceE4: rub(20_000))
    XCTAssertEqual(purchases.add(item), .done)
    let selling = DateOnly(year: 2026, month: 10, day: 30)
    XCTAssertEqual(
      purchases.sell(.item(item), for: rub(12_000), currency: .rub, on: selling, to: nil), .done)
    // A second sale finds the category made by the first.
    let other = OwnedItem(name: "Самокат", boughtOn: today, priceE4: rub(5_000))
    XCTAssertEqual(purchases.add(other), .done)
    XCTAssertEqual(
      purchases.sell(.item(other), for: rub(3_000), currency: .rub, on: selling, to: nil), .done)

    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let sales = dataset.categories.filter {
      $0.kind == .income && $0.name == PurchasesText.t("purchases.category.sales", environment)
    }
    XCTAssertEqual(sales.count, 1, "the category of sales was made twice")
    let income = try XCTUnwrap(
      dataset.entries.first { $0.transaction.note == "Велосипед" })
    XCTAssertEqual(income.transaction.kind, .income)
    XCTAssertEqual(income.transaction.amountE4, rub(12_000))
    XCTAssertEqual(income.parts.first?.categoryId, sales.first?.id)
    let closed = try XCTUnwrap(dataset.ownedItems.first { $0.id == item.id })
    XCTAssertEqual(closed.soldOn, selling)
    XCTAssertEqual(closed.saleTransactionId, income.id)
    let page = PurchasesPage.build(
      dataset: dataset, canSave: nil, rubPerUnit: [:], today: today,
      calendar: environment.calendar, waiting: WaitingRefunds(items: []))
    let line = try XCTUnwrap(page.soldThings.first { $0.name == "Велосипед" })
    XCTAssertEqual(line.cost.saleRubE4, rub(12_000))
    XCTAssertEqual(line.cost.totalRubE4, rub(8_000), "price less what the sale brought")
  }

  func testSellingAnAssetDisposesOfItAndAPriceOfZeroWritesNothing() async throws {
    let car = Asset(name: "Машина", kind: .vehicle)
    let assets = AssetActions(
      AppDependencies(environment: environment, store: store, compute: compute))
    XCTAssertEqual(assets.create(car, value: rub(1_000_000), on: today), .done)
    let selling = DateOnly(year: 2026, month: 10, day: 30)
    XCTAssertEqual(
      purchases.sell(.asset(car), for: .zero, currency: .rub, on: selling, to: nil),
      .refused(.badPrice))
    XCTAssertEqual(
      purchases.sell(.asset(car), for: rub(900_000), currency: .rub, on: selling, to: nil), .done)
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertEqual(dataset.assets.first?.disposedOn, selling)
    XCTAssertEqual(dataset.entries.filter { $0.transaction.kind == .income }.count, 1)
  }

  // MARK: Refunds that are waited for

  func testCreditedEndsTheWaitAndPostponingMovesTheDay() throws {
    var operation = try expense(2_500, note: "кроссовки")
    operation.transaction.refundWaitingUntil = DateOnly(year: 2026, month: 10, day: 27)
    XCTAssertTrue(store.save(operation))
    let later = DateOnly(year: 2026, month: 11, day: 5)
    XCTAssertEqual(purchases.expect(operation.id, by: later), .done)
    let repository = try XCTUnwrap(environment.transactions)
    XCTAssertEqual(try repository.entry(id: operation.id)?.transaction.refundWaitingUntil, later)
    XCTAssertEqual(purchases.credit(operation.id), .done)
    XCTAssertNil(try repository.entry(id: operation.id)?.transaction.refundWaitingUntil)
    XCTAssertEqual(purchases.credit(UUID()), .refused(.notFound))
  }

  // MARK: Settings

  func testTheSettingsStartAsTheirDefaultsAndAreKept() throws {
    let repository = try XCTUnwrap(environment.purchaseSettings)
    let initial = try repository.settings()
    XCTAssertFalse(initial.pauseEnabled)
    XCTAssertEqual(initial.pausePercent, 20)
    XCTAssertTrue(initial.regretEnabled)
    XCTAssertEqual(initial.regretAskAfterDays, 1)
    XCTAssertTrue(initial.fuelAskMileage)
    var next = initial
    next.pauseEnabled = true
    next.pausePercent = 35
    next.regretAskAfterDays = 3
    next.fuelAskMileage = false
    XCTAssertTrue(purchases.save(next))
    XCTAssertEqual(try repository.settings(), next)
  }
}
