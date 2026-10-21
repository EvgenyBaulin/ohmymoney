import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A card named in the line names its account too: the account is what moves the money, the
/// card says what paid. On equal spellings the account wins; a card of another account than
/// the one the line read stays in the note; the account's own name after its card says nothing
/// new and leaves the note.
@Suite("Карта в строке ввода")
struct CardNameTests {
  static let tBank = Fixture.id("61")
  static let sber = Fixture.id("62")
  static let kaspi = Fixture.id("63")
  static let cashAccount = Fixture.id("64")
  static let black = Fixture.id("71")
  static let virtual = Fixture.id("72")
  static let sberCard = Fixture.id("73")
  static let kaspiCard = Fixture.id("74")

  static let vocabulary = ParserVocabulary(
    paymentMethods: [
      .init(id: tBank, name: "Т-Банк"), .init(id: sber, name: "Сбер"),
      .init(id: kaspi, name: "Kaspi"), .init(id: cashAccount, name: "Наличные"),
    ],
    cards: [
      .init(entry: .init(id: black, name: "Black"), accountId: tBank),
      .init(entry: .init(id: virtual, name: "Virtual", aliases: ["виртуалка"]), accountId: tBank),
      .init(entry: .init(id: sberCard, name: "Сбер"), accountId: sber),
      .init(entry: .init(id: kaspiCard, name: "Kaspi"), accountId: kaspi),
    ])

  private func parse(
    _ line: String, _ vocabulary: ParserVocabulary = Self.vocabulary
  )
    -> ParsedInput
  {
    InputLineParser(vocabulary: vocabulary, calendar: .utc).parse(line, today: Fixture.today)
  }

  struct Row: Sendable, CustomTestStringConvertible {
    let line: String
    let account: UUID?
    let card: UUID?
    let note: String
    var testDescription: String { line }
  }

  @Test(
    "A card and its account read in the line",
    arguments: [
      Row(line: "кофе 300 black", account: tBank, card: black, note: "кофе"),
      Row(line: "кофе 300 виртуалка", account: tBank, card: virtual, note: "кофе"),
      Row(line: "кофе 300 т-банк black", account: tBank, card: black, note: "кофе"),
      Row(line: "кофе 300 black т-банк", account: tBank, card: black, note: "кофе"),
      Row(line: "кофе 300 сбер", account: sber, card: nil, note: "кофе"),
      Row(line: "кофе 300 сбер black", account: sber, card: nil, note: "кофе black"),
      Row(line: "кофе 300 в Сбере", account: sber, card: nil, note: "кофе"),
      Row(line: "кофе 300 kaspi", account: kaspi, card: nil, note: "кофе"),
      Row(line: "кофе 300", account: nil, card: nil, note: "кофе"),
    ])
  func readsTheCard(_ row: Row) {
    let result = parse(row.line)
    #expect(result.amount == 300)
    #expect(result.paymentMethodId == row.account)
    #expect(result.cardId == row.card)
    #expect(result.note == row.note)
  }

  @Test("Другое имя карты читается как карта")
  func cardAliasResolves() {
    let result = parse("такси 450 Виртуалка")
    #expect(result.cardId == Self.virtual)
    #expect(result.paymentMethodId == Self.tBank)
    #expect(result.tokens.contains { $0.role == .paymentMethod && $0.text == "Виртуалка" })
  }

  @Test("Две карты одного счёта с одним именем — только счёт")
  func twoCardsOneSpellingOneAccountGiveTheAccount() {
    var vocabulary = Self.vocabulary
    vocabulary.cards.append(
      .init(entry: .init(id: Fixture.id("75"), name: "Black"), accountId: Self.tBank))
    let result = parse("кофе 300 black", vocabulary)
    #expect(result.paymentMethodId == Self.tBank)
    #expect(result.cardId == nil)
    #expect(result.note == "кофе")
  }

  @Test("Две карты разных счетов с одним именем — ни то, ни другое")
  func twoCardsOneSpellingTwoAccountsGiveNothing() {
    var vocabulary = Self.vocabulary
    vocabulary.cards.append(
      .init(entry: .init(id: Fixture.id("75"), name: "Black"), accountId: Self.sber))
    let result = parse("кофе 300 black", vocabulary)
    #expect(result.paymentMethodId == nil)
    #expect(result.cardId == nil)
    #expect(result.note == "кофе black")
  }

  /// A card is a known name like any other: a person marker in front of it does not make it a
  /// new person, and a kind word inside a longer card name belongs to the card.
  @Test("Карта — известное имя")
  func aCardIsAKnownName() {
    var vocabulary = Self.vocabulary
    vocabulary.cards.append(
      .init(entry: .init(id: Fixture.id("76"), name: "Доход плюс"), accountId: Self.sber))
    let income = parse("кофе 300 доход плюс", vocabulary)
    #expect(income.kind == .expense)
    #expect(income.cardId == Fixture.id("76"))
    let forCard = parse("кофе 300 для black")
    #expect(forCard.unknownPersonName == nil)
  }
}
