import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// SMS and pushes of the four banks the owner named — Т-Банк, Сбер, Альфа, ВТБ — as they come
/// to the phone and are passed on by «Быстрые команды». Made up: the shapes are the banks', every
/// digit and every shop is invented.
enum AutoEntryCorpus {
  static let samples: [BankSample] = [
    // Sber
    .init(
      text: "MIR-4417 07:55 Покупка 450р KOFEMANIYA Баланс: 12300р", bank: .sber,
      operation: .purchase, amount: "450", merchant: "KOFEMANIYA", last4: "4417",
      balance: "12300", time: (7, 55)),
    .init(
      text: "MIR-4417 13:02 Оплата 2380.40р VKUSVILL Баланс: 9919.60р", bank: .sber,
      operation: .purchase, amount: "2380.4", merchant: "VKUSVILL", last4: "4417",
      balance: "9919.6", time: (13, 2)),
    .init(
      text: "VISA9021 22:14 Покупка 1999р YANDEX EDA Баланс: 31000.75р", bank: .sber,
      operation: .purchase, amount: "1999", merchant: "YANDEX EDA", last4: "9021",
      balance: "31000.75", time: (22, 14)),
    .init(
      text: "MIR-4417 10:00 Зарплата 120000р Баланс: 131000р", bank: .sber, operation: .income,
      amount: "120000", last4: "4417", balance: "131000", time: (10, 0)),
    .init(
      text: "MIR-4417 16:40 Возврат покупки 1200р WILDBERRIES Баланс: 13500р", bank: .sber,
      operation: .refund, amount: "1200", merchant: "WILDBERRIES", last4: "4417",
      balance: "13500", time: (16, 40)),
    .init(
      text: "MIR-4417 11:11 Выдача наличных 3000р ATM 556677 Баланс: 10500р", bank: .sber,
      operation: .cashWithdrawal, amount: "3000", last4: "4417", balance: "10500",
      time: (11, 11)),
    .init(
      text: "MIR-4417 19:30 Перевод от Анна К. 2500р Баланс: 15000р", bank: .sber,
      operation: .transferIn, amount: "2500", merchant: "Анна К.", last4: "4417",
      balance: "15000", time: (19, 30)),
    .init(
      text: "MIR-4417 08:45 Покупка 89р METRO MOSKVA Баланс: 14911р", bank: .sber,
      operation: .purchase, amount: "89", merchant: "METRO MOSKVA", last4: "4417",
      balance: "14911", time: (8, 45)),
    .init(
      text: "VISA9021 12:00 Покупка 15.00$ APPLE.COM/BILL Баланс: 30000р", bank: .sber,
      operation: .purchase, amount: "15", currency: "USD", merchant: "APPLE.COM/BILL",
      last4: "9021", balance: "30000", time: (12, 0)),
    // T-Bank
    .init(
      text: "Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽", bank: .tbank,
      operation: .purchase, amount: "450", merchant: "KOFEMANIYA", last4: "7788",
      balance: "12300"),
    .init(
      text: "Покупка, карта *7788. 2 380,40 ₽. VKUSVILL. Доступно 9 919,60 ₽", bank: .tbank,
      operation: .purchase, amount: "2380.4", merchant: "VKUSVILL", last4: "7788",
      balance: "9919.6"),
    .init(
      text: "Покупка, карта *7788. 1 999 ₽. YANDEX EDA. Доступно 31 000,75 ₽", bank: .tbank,
      operation: .purchase, amount: "1999", merchant: "YANDEX EDA", last4: "7788",
      balance: "31000.75"),
    .init(
      text: "Возврат покупки, карта *7788. 1 200 ₽. WILDBERRIES. Доступно 13 500 ₽",
      bank: .tbank, operation: .refund, amount: "1200", merchant: "WILDBERRIES",
      last4: "7788", balance: "13500"),
    .init(
      text: "Снятие наличных, карта *7788. 3 000 ₽. Доступно 10 500 ₽", bank: .tbank,
      operation: .cashWithdrawal, amount: "3000", last4: "7788", balance: "10500"),
    .init(
      text: "Пополнение, счет RUB. 2 500 ₽. Анна К. Доступно 15 000 ₽", bank: .tbank,
      operation: .transferIn, amount: "2500", merchant: "Анна К.", balance: "15000"),
    .init(
      text: "Кэшбэк, карта *7788. 340 ₽. Доступно 15 340 ₽", bank: .tbank, operation: .income,
      amount: "340", last4: "7788", balance: "15340"),
    .init(
      text: "Покупка, карта *7788. 9,99 €. SPOTIFY. Доступно 15 000 ₽", bank: .tbank,
      operation: .purchase, amount: "9.99", currency: "EUR", merchant: "SPOTIFY",
      last4: "7788", balance: "15000"),
    .init(
      text: "Покупка, карта *7788. 89 ₽. METRO MOSKVA. Доступно 14 911 ₽", bank: .tbank,
      operation: .purchase, amount: "89", merchant: "METRO MOSKVA", last4: "7788",
      balance: "14911"),
    // VTB
    .init(
      text: "Карта *5150: Покупка 450.00 RUR, KOFEMANIYA. Доступно 12300.00 RUR", bank: .vtb,
      operation: .purchase, amount: "450", merchant: "KOFEMANIYA", last4: "5150",
      balance: "12300"),
    .init(
      text: "Карта *5150: Оплата 2380.40 RUR, VKUSVILL. Доступно 9919.60 RUR", bank: .vtb,
      operation: .purchase, amount: "2380.4", merchant: "VKUSVILL", last4: "5150",
      balance: "9919.6"),
    .init(
      text: "Карта *5150: Покупка 1999.00 RUR, YANDEX EDA. Доступно 31000.75 RUR", bank: .vtb,
      operation: .purchase, amount: "1999", merchant: "YANDEX EDA", last4: "5150",
      balance: "31000.75"),
    .init(
      text: "ВТБ: Карта *5150. Зачисление 120 000,00 RUR. Доступно 131 000,00 RUR", bank: .vtb,
      operation: .transferIn, amount: "120000", last4: "5150", balance: "131000"),
    .init(
      text: "Карта *5150: Снятие 3000.00 RUR, ATM 4455. Доступно 10500.00 RUR", bank: .vtb,
      operation: .cashWithdrawal, amount: "3000", last4: "5150", balance: "10500"),
    .init(
      text: "Карта *5150: Покупка 640.00 RUR, PEREKRESTOK 1122 RUS. Доступно 9860.00 RUR",
      bank: .vtb, operation: .purchase, amount: "640", merchant: "PEREKRESTOK",
      last4: "5150", balance: "9860"),
    .init(
      text: "Карта *5150: Возврат 1200.00 RUR, WILDBERRIES. Доступно 13500.00 RUR", bank: .vtb,
      operation: .refund, amount: "1200", merchant: "WILDBERRIES", last4: "5150",
      balance: "13500"),
    .init(
      text: "Карта *5150: Покупка 89.00 RUR, METRO MOSKVA. Доступно 14911.00 RUR", bank: .vtb,
      operation: .purchase, amount: "89", merchant: "METRO MOSKVA", last4: "5150",
      balance: "14911"),
    // Alfa
    .init(
      text: "Альфа-Банк. Покупка 450 ₽, KOFEMANIYA. Карта *2604. Остаток 12 300 ₽", bank: .alfa,
      operation: .purchase, amount: "450", merchant: "KOFEMANIYA", last4: "2604",
      balance: "12300"),
    .init(
      text: "Альфа-Банк. Покупка 2 380,40 ₽, VKUSVILL. Карта *2604. Остаток 9 919,60 ₽",
      bank: .alfa, operation: .purchase, amount: "2380.4", merchant: "VKUSVILL", last4: "2604",
      balance: "9919.6"),
    .init(
      text: "Оплата 1999.00 RUR. YANDEX EDA. Карта *2604. Доступно 31000.75 RUR", bank: .alfa,
      operation: .purchase, amount: "1999", merchant: "YANDEX EDA", last4: "2604",
      balance: "31000.75"),
    .init(
      text: "Оплата 640.00 RUR. PEREKRESTOK. Карта *2604. Доступно 9860.00 RUR", bank: .alfa,
      operation: .purchase, amount: "640", merchant: "PEREKRESTOK", last4: "2604",
      balance: "9860"),
    .init(
      text: "Перевод 2000 RUR на карту *9090. Доступно 7860 RUR", bank: .alfa,
      operation: .transferOut, amount: "2000", last4: "9090", balance: "7860"),
    .init(
      text: "Alfa-Bank: Payment 9.99 USD, SPOTIFY. Card *2604. Available 7000 RUR", bank: .alfa,
      operation: .purchase, amount: "9.99", currency: "USD", merchant: "SPOTIFY",
      last4: "2604", balance: "7000"),
    .init(
      text: "Альфа-Банк. Покупка 89 ₽, METRO MOSKVA. Карта *2604. Остаток 14 911 ₽",
      bank: .alfa, operation: .purchase, amount: "89", merchant: "METRO MOSKVA", last4: "2604",
      balance: "14911"),
  ]
}

private func amount(_ text: String) -> AmountE4 {
  try! AmountE4(decimal: Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!)
}

private func rub(_ text: String) -> Money { Money(amount: amount(text), currency: .rub) }

@Suite("Auto entry from texts of banks")
struct AutoEntryTests {
  let parser = BankTextParser()
  let received = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: The four banks

  @Test(arguments: AutoEntryCorpus.samples)
  func readsTheText(_ sample: BankSample) throws {
    let message = try #require(parser.parse(sample.text, today: nil, ownBanks: []))
    #expect(message.bank == sample.bank)
    #expect(message.operation == sample.operation)
    #expect(message.money.amount == amount(sample.amount))
    #expect(message.money.currency == CurrencyCode(sample.currency))
    #expect(message.merchant == sample.merchant)
    #expect(message.cardLast4 == sample.last4)
    #expect(message.balance?.amount == sample.balance.map(amount))
  }

  @Test func eachOfTheFourBanksHasManyTexts() {
    for bank in [BankBrand.sber, .tbank, .vtb, .alfa] {
      #expect(AutoEntryCorpus.samples.filter { $0.bank == bank }.count >= 7, "\(bank)")
    }
  }

  @Test(arguments: BankCorpus.notBank)
  func aLineTypedByHandIsNotABanksText(_ text: String) {
    #expect(parser.parse(text, today: nil, ownBanks: ["Т-Банк", "Озон Банк"]) == nil)
  }

  // MARK: The owner's banks

  @Test func aBankOfTheOwnersAccountsIsNotTheShop() throws {
    let text = "Пополнение, счет RUB. 2 500 ₽. Озон Банк. Доступно 15 000 ₽"
    let plain = try #require(parser.parse(text, today: nil, ownBanks: []))
    #expect(plain.merchant == "Озон Банк")
    let known = try #require(parser.parse(text, today: nil, ownBanks: ["Озон Банк", "Сбер"]))
    #expect(known.merchant == nil)
    #expect(known.money.amount == amount("2500"))
  }

  @Test func aShopIsKeptWhenItIsNoBankOfTheOwner() throws {
    let message = try #require(
      parser.parse(
        "Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽", today: nil,
        ownBanks: ["Озон Банк"]))
    #expect(message.merchant == "KOFEMANIYA")
  }

  // MARK: Nothing whole is kept

  @Test func theSuggestionKeepsTheFieldsNotTheText() throws {
    let text = "Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽. Код 4455 никому"
    let message = try #require(parser.parse(text))
    let suggestion = AutoEntrySuggestion(
      message: message, line: message.suggestedLine(), receivedAt: received)
    let json = String(data: try JSONEncoder().encode(suggestion), encoding: .utf8) ?? ""
    #expect(!json.contains("Код"))
    #expect(!json.contains("Доступно"))
    #expect(!json.contains(text))
    #expect(suggestion.money == rub("450"))
    #expect(suggestion.balance == rub("12300"))
    #expect(suggestion.cardLast4 == "7788")
    #expect(suggestion.merchant == "KOFEMANIYA")
    let back = try JSONDecoder().decode(AutoEntrySuggestion.self, from: Data(json.utf8))
    #expect(back == suggestion)
  }

  @Test func theSmsAndThePushOfOnePurchaseShareAFingerprint() throws {
    let sms = try #require(parser.parse("MIR-7788 07:55 Покупка 450р KOFEMANIYA Баланс: 12300р"))
    let push = try #require(
      parser.parse("Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽"))
    let first = AutoEntrySuggestion(message: sms, line: "", receivedAt: received)
    let second = AutoEntrySuggestion(message: push, line: "", receivedAt: received)
    #expect(first.fingerprint == second.fingerprint)
    let next = try #require(
      parser.parse("Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 11 850 ₽"))
    #expect(
      AutoEntrySuggestion(message: next, line: "", receivedAt: received).fingerprint
        != first.fingerprint, "a second coffee leaves another balance")
  }

  // MARK: Learning from the owner's corrections

  @Test func aCorrectedNameIsOfferedNextTime() {
    var names = AutoEntryNames()
    #expect(names.name(for: "KOFEMANIYA") == nil)
    let taught = names.learn(merchant: "KOFEMANIYA", name: "Кофемания")
    #expect(taught)
    #expect(names.name(for: "KOFEMANIYA") == "Кофемания")
    #expect(names.name(for: "kofemaniya") == "Кофемания", "the key ignores case")
    let again = names.learn(merchant: "KOFEMANIYA", name: "Кофемания")
    #expect(!again, "taught once")
    let back = AutoEntryNames.decoded(names.encoded())
    #expect(back == names)
  }

  @Test func theBuiltInNameTeachesNothing() {
    var names = AutoEntryNames()
    let builtIn = names.learn(merchant: "PYATEROCHKA 4512", name: "Пятёрочка")
    #expect(!builtIn)
    let empty = names.learn(merchant: "KOFEMANIYA", name: "   ")
    #expect(!empty)
    let digits = names.learn(merchant: "12345", name: "Кафе")
    #expect(!digits, "a key needs a letter")
    #expect(names.names.isEmpty)
  }

  @Test func theListKeepsTheLatestNames() {
    var names = AutoEntryNames()
    for index in 0..<(AutoEntryNames.capacity + 5) {
      names.learn(merchant: "SHOP\(index)", name: "Магазин \(index)")
    }
    #expect(names.names.count == AutoEntryNames.capacity)
    #expect(names.name(for: "SHOP0") == nil)
    #expect(names.name(for: "SHOP\(AutoEntryNames.capacity + 4)") != nil)
  }

  @Test func aBrokenListReadsAsEmpty() {
    #expect(AutoEntryNames.decoded("{not json") == AutoEntryNames())
    #expect(AutoEntryNames.decoded(nil) == AutoEntryNames())
  }

  // MARK: What is done

  @Test func proposingIsTheDefault() {
    #expect(AutoEntryMode.standard == .propose)
    #expect(AutoEntryPlan.action(mode: .propose, isDuplicate: false) == .propose)
    #expect(AutoEntryPlan.action(mode: .immediate, isDuplicate: false) == .write)
  }

  @Test func aDuplicateIsNeitherWrittenNorOffered() {
    for mode in AutoEntryMode.allCases {
      #expect(AutoEntryPlan.action(mode: mode, isDuplicate: true) == .skipDuplicate)
    }
    #expect(
      AutoEntryPlan.notice(
        for: .skipDuplicate, hiddenAccount: false, hidden: .full, amountsHidden: false,
        amountsAlways: true) == .none)
  }

  @Test func aWriteTheLineWouldStopForIsOffered() {
    #expect(AutoEntryPlan.afterWrite(succeeded: true) == .write)
    #expect(AutoEntryPlan.afterWrite(succeeded: false) == .propose)
  }

  @Test(arguments: [AutoEntryPlan.Action.write, .propose])
  func noticesKeepTheOwnersPrivacy(_ action: AutoEntryPlan.Action) {
    func notice(
      hidden: Bool, _ policy: AutoEntryPlan.HiddenAccountNotices, amountsHidden: Bool = false,
      always: Bool = false
    ) -> AutoEntryPlan.Notice {
      AutoEntryPlan.notice(
        for: action, hiddenAccount: hidden, hidden: policy, amountsHidden: amountsHidden,
        amountsAlways: always)
    }
    #expect(notice(hidden: false, .silent) == .named(saysAmount: true))
    #expect(notice(hidden: false, .silent, amountsHidden: true) == .named(saysAmount: false))
    #expect(
      notice(hidden: false, .full, amountsHidden: true, always: true) == .named(saysAmount: true))
    #expect(notice(hidden: true, .silent) == .none)
    #expect(notice(hidden: true, .anonymous) == .anonymous)
    #expect(notice(hidden: true, .full, amountsHidden: true) == .named(saysAmount: true))
  }

  // MARK: The balance

  @Test func aBalanceThatAgreesSaysNothing() {
    // 12 750 in the books, a coffee of 450 not written yet: the bank's 12 300 agrees.
    #expect(
      BankBalanceCheck.compare(
        reported: rub("12300"), ledger: amount("12750"), includesOperation: false,
        operation: .purchase, amount: rub("450"), isCredit: false) == nil)
    #expect(
      BankBalanceCheck.compare(
        reported: rub("12300"), ledger: amount("12300"), includesOperation: true,
        operation: .purchase, amount: rub("450"), isCredit: false) == nil)
    #expect(
      BankBalanceCheck.compare(
        reported: rub("15000"), ledger: amount("12500"), includesOperation: false,
        operation: .transferIn, amount: rub("2500"), isCredit: false) == nil)
  }

  @Test func aBalanceThatDiffersIsAHint() throws {
    let mismatch = try #require(
      BankBalanceCheck.compare(
        reported: rub("12300"), ledger: amount("12600"), includesOperation: false,
        operation: .purchase, amount: rub("450"), isCredit: false))
    #expect(mismatch.bank == rub("12300"))
    #expect(mismatch.ledger == rub("12150"))
    #expect(mismatch.difference == amount("150"))
  }

  @Test func aCreditCardOrAMissingBalanceIsNotCompared() {
    #expect(
      BankBalanceCheck.compare(
        reported: rub("100000"), ledger: amount("-5000"), includesOperation: false,
        operation: .purchase, amount: rub("450"), isCredit: true) == nil)
    #expect(
      BankBalanceCheck.compare(
        reported: nil, ledger: amount("5000"), includesOperation: false, operation: .purchase,
        amount: rub("450"), isCredit: false) == nil)
    #expect(
      BankBalanceCheck.compare(
        reported: rub("5000"), ledger: nil, includesOperation: false, operation: .purchase,
        amount: rub("450"), isCredit: false) == nil)
  }

  @Test func aForeignPurchaseIsNotCompared() {
    // Dollars spent from a ruble card: the rubles it took are the bank's rate, unknown here.
    #expect(
      BankBalanceCheck.compare(
        reported: rub("30000"), ledger: amount("31000"), includesOperation: false,
        operation: .purchase,
        amount: Money(amount: amount("15"), currency: .usd), isCredit: false) == nil)
  }

  // MARK: The same text twice

  @Test func theSameTextWithinMinutesRepeats() {
    var recent = AutoEntryRecent()
    let first = recent.repeats("a", at: received)
    let again = recent.repeats("a", at: received.addingTimeInterval(30))
    let other = recent.repeats("b", at: received.addingTimeInterval(40))
    let later = recent.repeats("a", at: received.addingTimeInterval(AutoEntryRecent.window + 60))
    #expect(!first)
    #expect(again)
    #expect(!other)
    #expect(!later)
  }
}
