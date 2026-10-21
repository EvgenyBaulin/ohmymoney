import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// The words of the line new in 1.9: «со счёта» asks for no card, «смз» is income of the
/// self-employed, the owner's own currencies are read by their code and symbol, and an instalment
/// plan is never typed — «рассрочка» and «частями» stay words of the note.
@Suite("Строка ввода 1.9: со счёта, смз, свои валюты")
struct EntryLine19Tests {
  static let zzt = CurrencyCode("ZZT")
  static let catalog = CurrencyCatalog(custom: [
    CustomCurrency(code: zzt, name: "Звёзды", symbol: "★", fractionDigits: 0),
    CustomCurrency(code: CurrencyCode("QQX"), name: "Old", symbol: "¤q", archived: true),
  ])

  private func read(
    _ line: String, catalog: CurrencyCatalog = Self.catalog,
    vocabulary: ParserVocabulary = Fixture.vocabulary
  ) -> InputLineReading {
    InputLineParser(vocabulary: vocabulary, calendar: .utc, catalog: catalog)
      .read(line, today: Fixture.today)
  }

  // MARK: Со счёта

  @Test(
    "«со счёта» и «from account» — без карты",
    arguments: [
      "кофе 250 со счёта", "кофе 250 со счета", "кофе со счёта 250", "кофе 250 счётом",
      "кофе 250 со своего счёта", "coffee 250 from account", "coffee 250 from the account",
      "Кофе 250 СО СЧЁТА",
    ])
  func withoutCard(_ line: String) {
    let parsed = read(line).parsed
    #expect(parsed.withoutCard)
    #expect(parsed.amount == 250)
    #expect(parsed.kind == .expense)
    #expect(parsed.note.lowercased() == (line.hasPrefix("c") ? "coffee" : "кофе"))
  }

  @Test(
    "Без этих слов — с карты, «счёт за свет» — описание",
    arguments: ["кофе 250", "счёт за свет 2000", "coffee 250 from Anya", "кофе 250 счёт"])
  func withCard(_ line: String) {
    let parsed = read(line).parsed
    #expect(!parsed.withoutCard)
  }

  @Test("«со счёта» с названным счётом: счёт и без карты")
  func namedAccountWithoutCard() {
    let parsed = read("кофе 250 тинек со счёта").parsed
    #expect(parsed.paymentMethodId == Fixture.tinkoff)
    #expect(parsed.withoutCard)
    #expect(parsed.cardId == nil)
    #expect(parsed.note == "кофе")
  }

  @Test("Перевод своими словами «со счёта» не читает")
  func transferKeepsItsWords() {
    let parsed = read("перевод 5000 тинек наличные").parsed
    #expect(parsed.transfer != nil)
    #expect(!parsed.withoutCard)
  }

  // MARK: Смз

  @Test("«смз 15000» — доход самозанятого", arguments: ["смз 15000", "СМЗ 15000", "+смз 15000"])
  func selfEmployed(_ line: String) {
    let reading = read(line)
    #expect(reading.selfEmployed)
    #expect(reading.parsed.kind == .income)
    #expect(reading.parsed.amount == 15000)
    #expect(reading.parsed.note.isEmpty)
  }

  @Test("«смз» с описанием: описание остаётся")
  func selfEmployedWithANote() {
    let reading = read("смз 6000 вёрстка сайта")
    #expect(reading.selfEmployed)
    #expect(reading.parsed.note == "вёрстка сайта")
  }

  @Test("parse тоже читает «смз» доходом")
  func parseReadsIncome() {
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("смз 15000", today: Fixture.today)
    #expect(parsed.kind == .income)
    #expect(parsed.note.isEmpty)
  }

  @Test("Возврат со «смз» — возврат, слово в описании")
  func refundKeepsTheWord() {
    let reading = read("возврат смз 500")
    #expect(!reading.selfEmployed)
    #expect(reading.parsed.kind == .refund)
    #expect(reading.parsed.note == "смз")
  }

  @Test("Без «смз» — не самозанятость")
  func notSelfEmployed() {
    #expect(!read("зарплата 100000").selfEmployed)
    #expect(!read("кофе 300").selfEmployed)
  }

  // MARK: Свои валюты

  @Test(
    "Свой код и символ вплотную — валюта",
    arguments: [
      "ZZT 100", "100 ZZT", "100zzt", "100 zzt", "zzt100", "★100", "100★", "подарок 100 ZZT",
      "ZZT подарок 100",
    ])
  func customCurrency(_ line: String) {
    let parsed = read(line).parsed
    #expect(parsed.currency == Self.zzt)
    #expect(parsed.amount == 100)
  }

  @Test("Символ отдельно от числа и код строчными не у числа — не валюта")
  func notACustomCurrency() {
    let apart = read("подарок 100 ★").parsed
    #expect(apart.currency == nil)
    #expect(apart.amount == 100)
    let lower = read("zzt подарок 100").parsed
    #expect(lower.currency == nil)
    #expect(lower.note.contains("zzt"))
  }

  @Test("Валюта в архиве и без справочника своих валют не читается")
  func archivedOrUnknown() {
    #expect(read("QQX 100").parsed.currency == nil)
    #expect(read("ZZT 100", catalog: .empty).parsed.currency == nil)
    #expect(read("ZZT 100", catalog: .empty).parsed.note == "ZZT")
  }

  @Test("Валюты ЦБ читаются как раньше рядом со своими")
  func bankCurrenciesStay() {
    #expect(read("кофе 5$").parsed.currency == .usd)
    #expect(read("кофе 5 EUR").parsed.currency == CurrencyCode("EUR"))
  }

  // MARK: Рассрочка

  @Test(
    "«рассрочка» и «частями» строкой не вводятся — слова в описании",
    arguments: ["телефон рассрочка 12000", "телефон частями 12000", "phone instalments 12000"])
  func instalmentWordsStayInTheNote(_ line: String) {
    let parsed = read(line).parsed
    #expect(parsed.kind == .expense)
    #expect(parsed.amount == 12000)
    #expect(parsed.debtId == nil)
    #expect(parsed.note == line.replacingOccurrences(of: " 12000", with: ""))
  }
}
