import CoreKit
import Foundation
import Testing

@testable import CoreParse

private func money(_ text: String, _ currency: CurrencyCode = .rub) -> Money {
  Money(
    amount: try! AmountE4(
      decimal: Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!),
    currency: currency)
}

@Suite("Paste into the entry field")
struct BankPasteTests {
  let parser = BankTextParser()
  let today = DateOnly(year: 2026, month: 10, day: 13)

  // MARK: What a paste is

  @Test func anOrdinaryTextIsPastedAsItIs() {
    let text = "Обед с коллегами 1450 вчера"
    #expect(parser.reading(of: text, today: today) == .plain(text))
  }

  @Test func oneBankTextIsOneMessage() throws {
    let reading = parser.reading(
      of: "Покупка, карта *3230. 1 250 ₽. PYATEROCHKA. Доступно 52 340,11 ₽", today: today)
    guard case .message(let message) = reading else {
      Issue.record("not a message: \(reading)")
      return
    }
    #expect(message.cardLast4 == "3230")
    #expect(message.money == money("1250"))
  }

  @Test func aListOfPushesIsAListOfMessages() throws {
    let text = """
      MIR-3230 12:45 Покупка 1250р PYATEROCHKA Баланс: 52340.11р
      MIR-3230 13:10 Покупка 320р LENTA Баланс: 52020.11р
      MIR-3230 14:00 Оплата 99р APPLE.COM/BILL Баланс: 51921.11р
      """
    guard case .list(let items) = parser.reading(of: text, today: today) else {
      Issue.record("not a list")
      return
    }
    #expect(items.count == 3)
    #expect(items.compactMap(\.message).map(\.money) == [money("1250"), money("320"), money("99")])
  }

  @Test func textsSeparatedByBlankLinesAreSeveral() {
    let text = """
      Покупка, карта *3230. 300 ₽. LENTA. Доступно 1 000 ₽

      Покупка, карта *3230. 200 ₽. MAGNIT. Доступно 800 ₽
      """
    #expect(parser.items(in: text).compactMap(\.message).count == 2)
  }

  @Test func aLetterWithTheFieldsOnSeparateLinesIsOneMessage() throws {
    let text = """
      Покупка
      Карта *3230
      Сумма 1250.00 RUB
      PYATEROCHKA
      Доступно 52340.11 RUB
      """
    let items = parser.items(in: text)
    #expect(items.count == 1)
    let message = try #require(items.first?.message)
    #expect(message.money == money("1250"))
    #expect(message.merchant == "PYATEROCHKA")
    #expect(message.balance == money("52340.11"))
  }

  @Test func aMostlyOrdinaryTextWithOnePushInItStaysAText() {
    let text = """
      Привет!
      Вот что пришло утром:
      Покупка, карта *3230. 300 ₽. LENTA. Доступно 1 000 ₽
      Как дела?
      Увидимся вечером.
      """
    #expect(parser.reading(of: text, today: today) == .plain(text))
  }

  // MARK: A history copied from the bank's app

  @Test func rowsOfAHistoryAreReadWithTheirDays() throws {
    let text = """
      PYATEROCHKA −1 250,00 ₽ 12 октября
      YANDEX GO −450,50 ₽ 12 октября
      Иван И. +3 000 ₽ 11 октября
      """
    let items = parser.items(in: text, today: today)
    let messages = items.compactMap(\.message)
    #expect(messages.count == 3)
    #expect(messages.map(\.operation) == [.purchase, .purchase, .income])
    #expect(messages.map(\.money) == [money("1250"), money("450.5"), money("3000")])
    #expect(messages.map(\.merchant) == ["PYATEROCHKA", "YANDEX GO", "Иван И."])
    #expect(
      messages.map(\.day) == [
        DateOnly(year: 2026, month: 10, day: 12), DateOnly(year: 2026, month: 10, day: 12),
        DateOnly(year: 2026, month: 10, day: 11),
      ])
  }

  @Test func aSingleSignedRowIsNotABankText() {
    #expect(parser.reading(of: "кофе −250 ₽ вчера", today: today) == .plain("кофе −250 ₽ вчера"))
  }

  @Test func daysAreReadInAllTheirWritings() throws {
    func day(_ row: String) -> DateOnly? {
      parser.readHistoryRow(row, today: today)?.day
    }
    #expect(day("LENTA −300 ₽ вчера") == DateOnly(year: 2026, month: 10, day: 12))
    #expect(day("LENTA −300 ₽ позавчера") == DateOnly(year: 2026, month: 10, day: 11))
    #expect(day("LENTA −300 ₽ сегодня") == today)
    #expect(day("LENTA −300 ₽ 05.10") == DateOnly(year: 2026, month: 10, day: 5))
    #expect(day("LENTA −300 ₽ 05.10.2025") == DateOnly(year: 2025, month: 10, day: 5))
    #expect(day("LENTA −300 ₽ 5 окт") == DateOnly(year: 2026, month: 10, day: 5))
    #expect(day("LENTA −300 ₽ 5 октября 2024") == DateOnly(year: 2024, month: 10, day: 5))
    #expect(day("LENTA −300 ₽") == nil)
  }

  @Test func aDayAfterTodayWithoutAYearMeansLastYear() {
    let early = DateOnly(year: 2026, month: 1, day: 3)
    let row = parser.readHistoryRow("LENTA −300 ₽ 28 декабря", today: early)
    #expect(row?.day == DateOnly(year: 2025, month: 12, day: 28))
  }

  @Test func aDayTheCalendarDoesNotHaveIsNoDay() {
    #expect(parser.readHistoryRow("LENTA −300 ₽ 31.09", today: today)?.day == nil)
    #expect(parser.readHistoryRow("LENTA −300 ₽ 29.02.2026", today: today)?.day == nil)
  }

  // MARK: Duplicates

  @Test func anOperationAlreadyWrittenIsNotTicked() {
    let items = parser.items(
      in: """
        PYATEROCHKA −1 250,00 ₽ 12 октября
        YANDEX GO −450,50 ₽ 12 октября
        """, today: today)
    let known = [
      KnownOperation(
        day: DateOnly(year: 2026, month: 10, day: 12), kind: .expense, money: money("1250"))
    ]
    let candidates = BankImport.candidates(items, known: known, today: today)
    #expect(candidates.map(\.isDuplicate) == [true, false])
    #expect(candidates.map(\.isSelected) == [false, true])
  }

  @Test func oneWrittenOperationCoversOnlyOneOfTwoAlikeOnes() {
    let items = parser.items(
      in: """
        KOFE −250 ₽ 12 октября
        KOFE −250 ₽ 12 октября
        """, today: today)
    let known = [
      KnownOperation(
        day: DateOnly(year: 2026, month: 10, day: 12), kind: .expense, money: money("250"))
    ]
    #expect(
      BankImport.candidates(items, known: known, today: today).map(\.isDuplicate) == [true, false])
  }

  @Test func theSameAmountOfAnotherKindOrDayIsNotADuplicate() {
    let items = parser.items(
      in: """
        KOFE −250 ₽ 12 октября
        Иван И. +250 ₽ 12 октября
        """, today: today)
    let day = DateOnly(year: 2026, month: 10, day: 11)
    let known = [
      KnownOperation(day: day, kind: .expense, money: money("250")),
      KnownOperation(
        day: DateOnly(year: 2026, month: 10, day: 12), kind: .refund, money: money("250")),
    ]
    #expect(BankImport.candidates(items, known: known, today: today).allSatisfy { !$0.isDuplicate })
  }

  @Test func aPushWithoutADayIsTodays() {
    let items = parser.items(in: "Покупка, карта *3230. 300 ₽. LENTA. Доступно 1 000 ₽")
    let known = [KnownOperation(day: today, kind: .expense, money: money("300"))]
    #expect(BankImport.candidates(items, known: known, today: today).map(\.isDuplicate) == [true])
  }

  // MARK: Cards

  @Test func aCardIsFoundByItsLastDigits() throws {
    let account = UUID()
    let card = CardDigits(cardId: UUID(), accountId: account, last4: "3230")
    let index = CardDigitsIndex([
      card, CardDigits(cardId: UUID(), accountId: UUID(), last4: "9999"),
    ])
    let message = try #require(
      parser.parse("Покупка, карта *3230. 300 ₽. LENTA. Доступно 1 000 ₽"))
    #expect(index.lookup(message) == .card(card))
  }

  @Test func unknownDigitsAreAskedOnce() throws {
    let message = try #require(
      parser.parse("Покупка, карта *3230. 300 ₽. LENTA. Доступно 1 000 ₽"))
    #expect(CardDigitsIndex([]).lookup(message) == .unknown(last4: "3230"))
  }

  @Test func twoCardsWithTheSameEndingAreAmbiguous() throws {
    let first = CardDigits(cardId: UUID(), accountId: UUID(), last4: "3230")
    let second = CardDigits(cardId: UUID(), accountId: UUID(), last4: "3230")
    let message = try #require(
      parser.parse("Покупка, карта *3230. 300 ₽. LENTA. Доступно 1 000 ₽"))
    #expect(CardDigitsIndex([first, second]).lookup(message) == .ambiguous([first, second]))
  }

  @Test func aTextWithoutDigitsNamesNoCard() throws {
    let message = try #require(parser.parse("Пополнение, счет RUB. 5 000 ₽. Доступно 7 000 ₽"))
    #expect(CardDigitsIndex([]).lookup(message) == .none)
  }

  // MARK: The balance

  @Test func theBalanceOfferIsOffByDefault() {
    #expect(BankMessage.reconcileOfferedByDefault == false)
  }

  // MARK: Shops

  @Test func aShopOfTheOwnersListWinsOverTheBuiltInNames() {
    let places: [ParserVocabulary.Entry] = [
      .init(id: Fixture.pyaterochka, name: "Пятёрочка у дома", aliases: ["pyaterochka"])
    ]
    let resolved = BankMerchants.resolve("PYATEROCHKA 4512 RUS", places: places)
    #expect(resolved?.placeId == Fixture.pyaterochka)
    #expect(resolved?.name == "Пятёрочка у дома")
    #expect(resolved?.isKnownPlace == true)
  }

  @Test func aChainWithoutAPlaceGetsItsRussianName() {
    let resolved = BankMerchants.resolve("YANDEX GO", places: [])
    #expect(resolved?.name == "Яндекс Go")
    #expect(resolved?.placeId == nil)
  }

  @Test func aChainFindsThePlaceOfThatName() {
    let resolved = BankMerchants.resolve("PYATEROCHKA", places: Fixture.vocabulary.places)
    #expect(resolved?.placeId == Fixture.pyaterochka)
    #expect(resolved?.name == "Пятёрочка")
  }

  @Test func shortChainNamesMustBeWholeWords() {
    #expect(BankMerchants.resolve("MTS", places: [])?.name == "МТС")
    #expect(BankMerchants.resolve("MTSENSK TRANS", places: [])?.name != "МТС")
    #expect(BankMerchants.resolve("OZON.RU", places: [])?.name == "Ozon")
  }

  @Test func anUnknownShopKeepsItsNameInSmallLetters() {
    #expect(BankMerchants.resolve("KOFEMANIYA", places: [])?.name == "Kofemaniya")
    #expect(BankMerchants.resolve("Кофемания", places: [])?.name == "Кофемания")
  }

  @Test func branchNumbersAndCountriesAreDropped() {
    #expect(BankMerchants.cleaned("MAGNIT 9876 RUS") == "MAGNIT")
    #expect(BankMerchants.cleaned("SHOP #12345") == "SHOP")
    #expect(BankMerchants.cleaned("RUS") == "RUS")
    #expect(BankMerchants.cleaned("   ") == nil)
  }

  // MARK: The line it makes

  @Test func theSuggestedLineIsReadBackAsTheSameOperation() throws {
    let entryParser = Fixture.parser
    for sample in BankCorpus.samples {
      let message = try #require(parser.parse(sample.text), "\(sample.text)")
      let place = message.merchant.flatMap {
        BankMerchants.resolve($0, places: Fixture.vocabulary.places)
      }
      let line = message.suggestedLine(merchantName: place?.name)
      let parsed = entryParser.parse(line, today: Fixture.today)
      #expect(
        parsed.amount == message.money.amount.decimal, "\(line) ← \(sample.text)")
      #expect(parsed.kind == message.kind, "\(line) ← \(sample.text)")
      let wanted = message.money.currency
      #expect(
        (parsed.currency ?? .rub) == wanted, "\(line) ← \(sample.text)")
      if let id = place?.placeId { #expect(parsed.placeId == id, "\(line)") }
    }
  }

  @Test func theLineOfAKnownShopIsTheExampleOfTheOwner() throws {
    let message = try #require(
      parser.parse("Покупка 1 250,00 ₽ PYATEROCHKA 4512 Карта *3230 Баланс 52 340,11 ₽"))
    let place = BankMerchants.resolve(
      try #require(message.merchant), places: Fixture.vocabulary.places)
    #expect(message.suggestedLine(merchantName: place?.name) == "Пятёрочка 1250")
  }

  @Test func aForeignAmountKeepsItsCurrencyInTheLine() throws {
    let message = try #require(
      parser.parse("Покупка, карта *3230. 25,50 $. STEAM. Доступно 3 000 ₽"))
    #expect(message.suggestedLine() == "STEAM 25.5 USD")
  }

  @Test func aRefundAndAnIncomeNameThemselves() throws {
    let refund = try #require(
      parser.parse("Возврат покупки, карта *3230. 700 ₽. OZON. Доступно 8 000 ₽"))
    #expect(refund.suggestedLine() == "возврат OZON 700")
    let income = try #require(
      parser.parse("MIR-3230 09:00 Зарплата 85000р Баланс: 90000.00р"))
    #expect(income.suggestedLine() == "+85000")
  }
}
