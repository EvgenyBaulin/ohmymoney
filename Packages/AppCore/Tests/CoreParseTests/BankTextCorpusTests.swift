import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// The texts below are made up: the shapes are the ones banks use, every digit is invented.
struct BankSample: Sendable, CustomTestStringConvertible {
  var text: String
  var bank: BankBrand
  var operation: BankOperation
  var amount: String
  var currency: String = "RUB"
  var merchant: String?
  var last4: String?
  var account = false
  var balance: String?
  var time: (Int, Int)?

  var testDescription: String { text }
}

enum BankCorpus {
  static let samples: [BankSample] = [
    // Sber
    .init(
      text: "MIR-3230 12:45 Покупка 1250р PYATEROCHKA Баланс: 52340.11р", bank: .sber,
      operation: .purchase, amount: "1250", merchant: "PYATEROCHKA", last4: "3230",
      balance: "52340.11", time: (12, 45)),
    .init(
      text: "VISA1234 08:10 Оплата 450.50р YANDEX GO Баланс: 12000.50р", bank: .sber,
      operation: .purchase, amount: "450.5", merchant: "YANDEX GO", last4: "1234",
      balance: "12000.5", time: (8, 10)),
    .init(
      text: "MIR-3230 09:00 Зарплата 85000р Баланс: 90000.00р", bank: .sber, operation: .income,
      amount: "85000", last4: "3230", balance: "90000", time: (9, 0)),
    .init(
      text: "СЧЁТ3230 15:00 перевод 5000р Баланс: 1000р", bank: .sber, operation: .transferOut,
      amount: "5000", last4: "3230", account: true, balance: "1000", time: (15, 0)),
    .init(
      text: "MIR-3230 18:20 Выдача наличных 5000р ATM 12345 Баланс: 7000р", bank: .sber,
      operation: .cashWithdrawal, amount: "5000", last4: "3230", balance: "7000", time: (18, 20)),
    .init(
      text: "MIR-3230 19:00 Возврат покупки 700р OZON Баланс: 8000р", bank: .sber,
      operation: .refund, amount: "700", merchant: "OZON", last4: "3230", balance: "8000",
      time: (19, 0)),
    .init(
      text: "MIR-3230 10:10 Перевод от Иван И. 3000р Баланс: 9000р", bank: .sber,
      operation: .transferIn, amount: "3000", merchant: "Иван И.", last4: "3230",
      balance: "9000", time: (10, 10)),
    .init(
      text: "MIR-3230 21:30 Покупка 99.90р Apple.com/bill Баланс: 4000.10р", bank: .sber,
      operation: .purchase, amount: "99.9", merchant: "Apple.com/bill", last4: "3230",
      balance: "4000.1", time: (21, 30)),
    .init(
      text: "VISA1234 13:00 Покупка 12.50$ STEAM Баланс: 3000р", bank: .sber, operation: .purchase,
      amount: "12.5", currency: "USD", merchant: "STEAM", last4: "1234", balance: "3000",
      time: (13, 0)),
    // T-Bank
    .init(
      text: "Покупка, карта *3230. 1 250 ₽. PYATEROCHKA. Доступно 52 340,11 ₽", bank: .tbank,
      operation: .purchase, amount: "1250", merchant: "PYATEROCHKA", last4: "3230",
      balance: "52340.11"),
    .init(
      text: "Пополнение, счет RUB. 5 000 ₽. Иван И. Доступно 57 340,11 ₽", bank: .tbank,
      operation: .transferIn, amount: "5000", merchant: "Иван И.", balance: "57340.11"),
    .init(
      text: "Снятие наличных, карта *3230. 10 000 ₽. Доступно 30 000 ₽", bank: .tbank,
      operation: .cashWithdrawal, amount: "10000", last4: "3230", balance: "30000"),
    .init(
      text: "Покупка, карта *3230. 25,50 $. STEAM. Доступно 3 000 ₽", bank: .tbank,
      operation: .purchase, amount: "25.5", currency: "USD", merchant: "STEAM", last4: "3230",
      balance: "3000"),
    .init(
      text: "Возврат покупки, карта *3230. 700 ₽. OZON. Доступно 8 000 ₽", bank: .tbank,
      operation: .refund, amount: "700", merchant: "OZON", last4: "3230", balance: "8000"),
    .init(
      text: "Кэшбэк, карта *3230. 120 ₽. Доступно 5 000 ₽", bank: .tbank, operation: .income,
      amount: "120", last4: "3230", balance: "5000"),
    .init(
      text: "Покупка, карта *3230. 1 000 ₽. LENTA. Кэшбэк 10 ₽. Доступно 5 000 ₽", bank: .tbank,
      operation: .purchase, amount: "1000", merchant: "LENTA", last4: "3230", balance: "5000"),
    // VTB
    .init(
      text: "Карта *3230: Покупка 1250.00 RUR, PYATEROCHKA. Доступно 52340.11 RUR", bank: .vtb,
      operation: .purchase, amount: "1250", merchant: "PYATEROCHKA", last4: "3230",
      balance: "52340.11"),
    .init(
      text: "Карта *3230: Оплата 450.00 RUR, YANDEX GO. Доступно 12000.50 RUR", bank: .vtb,
      operation: .purchase, amount: "450", merchant: "YANDEX GO", last4: "3230",
      balance: "12000.5"),
    .init(
      text: "ВТБ: Карта *3230. Зачисление 85 000,00 RUR. Доступно 90 000,00 RUR", bank: .vtb,
      operation: .transferIn, amount: "85000", last4: "3230", balance: "90000"),
    .init(
      text: "Карта *3230: Снятие 5000.00 RUR, ATM 7788. Комиссия 50.00 RUR. Доступно 7000.00 RUR",
      bank: .vtb, operation: .cashWithdrawal, amount: "5000", last4: "3230", balance: "7000"),
    .init(
      text: "Карта *3230: Покупка 3200.00 RUR, MAGNIT 9876 RUS. Доступно 5000.00 RUR", bank: .vtb,
      operation: .purchase, amount: "3200", merchant: "MAGNIT", last4: "3230", balance: "5000"),
    // Raiffeisen
    .init(
      text: "Покупка. Карта *3230. Сумма 1250.00 RUB. PYATEROCHKA. Доступно 52340.11 RUB",
      bank: .raiffeisen, operation: .purchase, amount: "1250", merchant: "PYATEROCHKA",
      last4: "3230", balance: "52340.11"),
    .init(
      text: "Raiffeisen: Card *3230; Purchase 1,250.00 RUB; MAGNIT; Balance 52,340.11 RUB",
      bank: .raiffeisen, operation: .purchase, amount: "1250", merchant: "MAGNIT", last4: "3230",
      balance: "52340.11"),
    .init(
      text: "Райффайзенбанк. Поступление 15 000,00 RUB на карту *3230. Доступно 67 340,11 RUB",
      bank: .raiffeisen, operation: .transferIn, amount: "15000", last4: "3230",
      balance: "67340.11"),
    // Alfa
    .init(
      text: "Оплата 1250.00 RUR. PYATEROCHKA. Карта *3230. Доступно 52340.11 RUR", bank: .alfa,
      operation: .purchase, amount: "1250", merchant: "PYATEROCHKA", last4: "3230",
      balance: "52340.11"),
    .init(
      text: "Альфа-Банк. Покупка 450 ₽, YANDEX GO. Карта *3230. Остаток 12 000 ₽", bank: .alfa,
      operation: .purchase, amount: "450", merchant: "YANDEX GO", last4: "3230",
      balance: "12000"),
    .init(
      text: "Перевод 5000 RUR на карту *1111. Доступно 7000 RUR", bank: .alfa,
      operation: .transferOut, amount: "5000", last4: "1111", balance: "7000"),
    .init(
      text: "Alfa-Bank: Payment 12.99 USD, NETFLIX.COM. Card *3230. Available 3000 RUR",
      bank: .alfa, operation: .purchase, amount: "12.99", currency: "USD",
      merchant: "NETFLIX.COM", last4: "3230", balance: "3000"),
  ]

  /// Typed by hand or written about money, and never a bank's text.
  static let notBank: [String] = [
    "кофе 250",
    "Покупка 500 р кофе",
    "Обед с Машей 1500 вчера",
    "Оплата 1250р",
    "ужин 3200 карта тинькофф",
    "Перевод 5000 р маше",
    "Купил за 4000 р, баланс не сходится",
    "Баланс: 52340.11р",
    "Доступно 5000 ₽",
    "Покупка 1250р 3230",
    "",
    "   ",
  ]
}

private func decimal(_ text: String) -> AmountE4 {
  try! AmountE4(decimal: Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!)
}

@Suite("Texts of banks")
struct BankTextCorpusTests {
  let parser = BankTextParser()

  @Test(arguments: BankCorpus.samples)
  func readsTheSample(_ sample: BankSample) throws {
    let message = try #require(parser.parse(sample.text))
    #expect(message.bank == sample.bank)
    #expect(message.operation == sample.operation)
    #expect(message.money.amount == decimal(sample.amount))
    #expect(message.money.currency == CurrencyCode(sample.currency))
    #expect(message.merchant == sample.merchant)
    #expect(message.cardLast4 == sample.last4)
    #expect(message.isAccountDigits == sample.account)
    #expect(message.balance?.amount == sample.balance.map(decimal))
    if let time = sample.time {
      #expect(message.time == TimeOfDay(hour: time.0, minute: time.1))
    } else {
      #expect(message.time == nil)
    }
  }

  @Test(arguments: BankCorpus.notBank)
  func leavesOrdinaryTextAlone(_ text: String) {
    #expect(parser.parse(text) == nil)
  }

  @Test func theCorpusCoversEveryBankAndEveryOperation() {
    #expect(Set(BankCorpus.samples.map(\.bank)) == Set(BankBrand.allCases).subtracting([.unknown]))
    #expect(
      Set(BankCorpus.samples.map(\.operation)) == Set(BankOperation.allCases).subtracting([.fee]))
  }

  @Test func theBalanceIsNeverTheAmount() throws {
    let message = try #require(parser.parse("Покупка, карта *3230. 300 ₽. Доступно 52 340,11 ₽"))
    #expect(message.money.amount == decimal("300"))
    #expect(message.balance?.amount == decimal("52340.11"))
  }

  @Test func aHugeAmountIsNotRead() {
    let text = "MIR-3230 12:45 Покупка 99999999999999р X Баланс: 1р"
    #expect(parser.parse(text) == nil)
  }

  @Test func aTextLongerThanAnySmsIsNotRead() {
    let text = String(repeating: "слово ", count: 1_000) + "MIR-3230 Покупка 100р X Баланс: 1р"
    #expect(parser.parse(text) == nil)
  }

  @Test func theTextIsKeptAsItCame() throws {
    let text = "  Покупка, карта *3230. 300 ₽. LENTA. Доступно 1 000 ₽ \n"
    let message = try #require(parser.parse(text))
    #expect(message.source == text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @Test func noBreakSpacesGroupThousandsToo() throws {
    let message = try #require(
      parser.parse("Покупка, карта *3230. 1\u{00A0}250\u{00A0}₽. LENTA. Доступно 9\u{202F}000 ₽"))
    #expect(message.money.amount == decimal("1250"))
    #expect(message.balance?.amount == decimal("9000"))
  }
}
