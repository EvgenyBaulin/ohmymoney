import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// «за машу», «пополам с машей», «угостил машу» — the name in any case.
@Suite("За кого строкой")
struct PayingForLineTests {
  static let masha = Fixture.id("91")
  static let petya = Fixture.id("92")
  static let vocabulary = ParserVocabulary(
    people: [.init(id: masha, name: "Маша"), .init(id: petya, name: "Петя")])

  private func parse(_ line: String, kind: TransactionKind? = nil) -> ParsedInput {
    InputLineParser(vocabulary: Self.vocabulary, calendar: .utc)
      .parse(line, today: Fixture.today, kind: kind)
  }

  @Test func forSomebodyInAnyCase() {
    for line in ["ужин 1200 за машу", "за Машу ужин 1200", "ужин за маша 1200"] {
      let read = parse(line)
      #expect(
        read.payingFor == PayingForReading(way: .forSomebody, personId: Self.masha), "\(line)")
      #expect(read.amount == 1200, "\(line)")
      #expect(read.note == "ужин", "\(line)")
    }
  }

  @Test func halfWithSomebody() {
    for line in [
      "пицца 900 пополам с машей", "пицца пополам с Петей 900", "pizza 900 split with маша",
    ] {
      let read = parse(line)
      #expect(read.payingFor?.way == .half, "\(line)")
      #expect(read.payingFor?.personId != nil, "\(line)")
    }
    #expect(parse("пицца 900 пополам с петей").payingFor?.personId == Self.petya)
  }

  /// «поровну с машей и петей»: the bill is shared by me and each named person; the line says the
  /// whole company at once.
  @Test func evenlyWithSeveralPeople() {
    for line in [
      "ужин 6000 поровну с машей и петей", "ужин поровну с Машей и Петей 6000",
      "dinner 6000 evenly with маша and петя",
    ] {
      let read = parse(line)
      #expect(read.payingFor?.way == .evenly, "\(line)")
      #expect(read.payingFor?.people == [Self.masha, Self.petya], "\(line)")
      #expect(read.amount == 6000, "\(line)")
      #expect(read.note == "ужин" || read.note == "dinner", "\(line)")
    }
  }

  @Test func evenlyWithOnePersonIsHalf() {
    let read = parse("ужин 900 поровну с машей")
    #expect(read.payingFor?.way == .half)
    #expect(read.payingFor?.personId == Self.masha)
  }

  @Test func evenlyBeforeAnUnknownNameIsNotGuessed() {
    // Only the known people are read; an unknown second name leaves the line to the panel.
    let read = parse("ужин 900 поровну с машей и олей")
    #expect(read.payingFor?.way == .half)
    #expect(read.payingFor?.personId == Self.masha)
  }

  @Test func aTreatIsAGift() {
    let read = parse("угостил машу кофе 300")
    #expect(read.payingFor == PayingForReading(way: .gift, personId: Self.masha))
    #expect(read.note == "кофе")
    #expect(parse("угостила маше 300").payingFor?.personId == Self.masha)
  }

  /// A name nobody knows: offered to be added, never a person silently.
  @Test func anUnknownNameIsOfferedToBeAdded() {
    let read = parse("кино 800 пополам с олей")
    #expect(read.payingFor == PayingForReading(way: .half, unknownName: "олей"))
    #expect(read.unknownPersonName == "олей")
  }

  /// «за» before a sum, a job or an unknown word is the note's.
  @Test func zaBeforeAnythingElseIsJustAWord() {
    #expect(parse("кофе за 300").payingFor == nil)
    #expect(parse("кофе за 300").amount == 300)
    #expect(parse("аванс за ремонт 5000").payingFor == nil)
    #expect(parse("штраф 500 за парковку").payingFor == nil)
    #expect(parse("угостил кофе 300").payingFor == nil)
    #expect(parse("подарок кофе 300").note == "подарок кофе")
  }

  @Test func onlyAnExpenseIsPaidForSomebody() {
    #expect(parse("+ 5000 за машу").payingFor == nil)
    #expect(parse("1200 за машу", kind: .income).payingFor == nil)
  }
}
