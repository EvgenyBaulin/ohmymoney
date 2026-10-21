import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// «перевод 5000 сбер т-банк» is a transfer between two accounts; «перевод маше 500» stays the
/// operation it always was.
@Suite("Перевод строкой")
struct TransferLineTests {
  static let tBank = Fixture.id("81")
  static let sber = Fixture.id("82")
  static let cash = Fixture.id("83")
  static let black = Fixture.id("84")
  static let masha = Fixture.id("85")
  static let tinkoffName = Fixture.id("86")

  static let vocabulary = ParserVocabulary(
    people: [.init(id: masha, name: "Маша"), .init(id: tinkoffName, name: "Сбер")],
    paymentMethods: [
      .init(id: tBank, name: "Т-Банк", aliases: ["тинькофф"]), .init(id: sber, name: "Сбер"),
      .init(id: cash, name: "Наличные", aliases: ["cash"]),
    ],
    cards: [.init(entry: .init(id: black, name: "Black"), accountId: tBank)])

  private func parse(_ line: String) -> ParsedInput {
    InputLineParser(vocabulary: Self.vocabulary, calendar: .utc).parse(line, today: Fixture.today)
  }

  @Test func twoAccountsAreATransferFromTheFirstToTheSecond() {
    let line = parse("перевод 5000 сбер т-банк")
    #expect(line.transfer == TransferReading(fromAccountId: Self.sber, toAccountId: Self.tBank))
    #expect(line.transfer?.isComplete == true)
    #expect(line.amount == 5000)
    #expect(line.paymentMethodId == Self.sber)
    #expect(line.note == "")
  }

  @Test func theOrderOfTheAmountAndTheAccountsDoesNotMatter() {
    for text in [
      "сбер т-банк перевод 5000", "перевод сбер т-банк 5000", "5000 перевод сбер т-банк",
    ] {
      let line = parse(text)
      #expect(line.transfer?.fromAccountId == Self.sber, "\(text)")
      #expect(line.transfer?.toAccountId == Self.tBank, "\(text)")
      #expect(line.amount == 5000, "\(text)")
    }
  }

  @Test func markersSayWhichWay() {
    let back = parse("перевёл 5000 на сбер с т-банка")
    #expect(back.transfer == TransferReading(fromAccountId: Self.tBank, toAccountId: Self.sber))
    let english = parse("transfer 300 to cash from black")
    #expect(english.transfer?.fromAccountId == Self.tBank)
    #expect(english.transfer?.fromCardId == Self.black)
    #expect(english.transfer?.toAccountId == Self.cash)
    let into = parse("перевод 1000 сбер в наличные")
    #expect(into.transfer == TransferReading(fromAccountId: Self.sber, toAccountId: Self.cash))
  }

  @Test func aCardNamesItsAccount() {
    let line = parse("перевод 700 black наличные")
    #expect(line.transfer?.fromAccountId == Self.tBank)
    #expect(line.transfer?.fromCardId == Self.black)
    #expect(line.transfer?.toAccountId == Self.cash)
  }

  @Test func thousandsWithK() {
    let line = parse("перевод 5к сбер т-банк")
    #expect(line.amount == 5000)
    #expect(line.transfer?.isComplete == true)
  }

  /// «перевод другу», «перевод маше» — a person or nobody: the operation it always was.
  @Test func aPersonOrNoAccountIsAnOperation() {
    #expect(parse("перевод другу 500").transfer == nil)
    #expect(parse("перевод маше 500").transfer == nil)
    #expect(parse("перевод маше 500").note == "перевод маше")
    #expect(parse("перевод 500 для маши сбер").transfer == nil)
    #expect(parse("перевод 500").transfer == nil)
    #expect(parse("перевод 500 сбер").transfer == nil, "one account alone pays for the transfer")
  }

  /// One account and a word in the place of the other: the sheet finishes it, nothing is
  /// written silently.
  @Test func anUnknownSecondAccountLeavesTheTransferIncomplete() {
    let line = parse("перевод 5000 со сбера на альфу")
    #expect(line.transfer?.fromAccountId == Self.sber)
    #expect(line.transfer?.toAccountId == nil)
    #expect(line.transfer?.unknownName == "альфу")
    #expect(line.transfer?.isComplete == false)
    let first = parse("перевод 5000 на сбер с альфы")
    #expect(first.transfer?.toAccountId == Self.sber && first.transfer?.fromAccountId == nil)
  }

  /// A person called like an account: the person read behind «для» wins and the line is an
  /// operation; without «для» the account's name is the account.
  @Test func aPersonCalledLikeAnAccount() {
    #expect(parse("перевод 500 для сбер т-банк").transfer == nil)
    #expect(parse("перевод 500 сбер т-банк").transfer?.isComplete == true)
  }

  @Test func theSameAccountTwiceIsNoTransfer() {
    #expect(parse("перевод 500 сбер сбер").transfer == nil)
  }

  /// An account whose name holds «для» — «Карта для поездок» — is that account, either way
  /// round and declined behind «с», and an expense paid from it too: «для поездок» inside the
  /// name is no person the line pays for.
  @Test func anAccountNamedWithForIsNoPerson() {
    let trip = Fixture.id("87")
    let parser = InputLineParser(
      vocabulary: ParserVocabulary(
        people: [.init(id: Self.masha, name: "Маша")],
        paymentMethods: [
          .init(id: Self.cash, name: "Наличные"), .init(id: trip, name: "Карта для поездок"),
        ]),
      calendar: .utc)
    func parse(_ line: String) -> ParsedInput { parser.parse(line, today: Fixture.today) }
    let there = parse("перевод 1000 наличные карта для поездок")
    #expect(there.transfer == TransferReading(fromAccountId: Self.cash, toAccountId: trip))
    #expect(there.unknownPersonName == nil)
    #expect(there.amount == 1000)
    let back = parse("перевод 500 на наличные с карты для поездок")
    #expect(back.transfer == TransferReading(fromAccountId: trip, toAccountId: Self.cash))
    let coffee = parse("кофе 300 карта для поездок")
    #expect(coffee.paymentMethodId == trip)
    #expect(coffee.unknownPersonName == nil && coffee.personId == nil)
    #expect(coffee.note == "кофе")
    // «для» outside a name still names whom it is for.
    #expect(parse("цветы 500 для маши карта для поездок").personId == Self.masha)
  }

  /// A line without a transfer word is never a transfer, two accounts or not.
  @Test func noTransferWordNoTransfer() {
    #expect(parse("кофе 300 сбер т-банк").transfer == nil)
    #expect(parse("кофе 300 сбер").paymentMethodId == Self.sber)
  }
}
