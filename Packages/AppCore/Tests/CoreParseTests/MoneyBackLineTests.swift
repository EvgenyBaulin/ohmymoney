import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Money back names whom it came from with «от» / "from"; nothing else does. And a name read
/// behind its marker keeps the marker in its token, so an operation without that field can give
/// the whole phrase back to its note.
@Suite("Возврат денег: «от кого» и слова маркеров")
struct MoneyBackLineTests {
  @Test("«возврат денег 1700 от Ани» — возврат денег от Ани")
  func moneyBackReadsFromWhom() {
    let result = Fixture.parse("возврат денег 1700 от Ани")
    #expect(result.kind == .reimbursement)
    #expect(result.amount == dec("1700"))
    #expect(result.personId == Fixture.anya)
    #expect(result.note.isEmpty)
  }

  @Test("\"money back 1700 from Anya\" reads the person in English")
  func moneyBackReadsFromInEnglish() {
    let result = Fixture.parse("money back 1700 from Anya")
    #expect(result.kind == .reimbursement)
    #expect(result.personId == Fixture.anya)
    #expect(result.note.isEmpty)
  }

  @Test("Возврат денег, выбранный в панели: «1700 от Ани» — от Ани")
  func moneyBackChosenInThePanelReadsFrom() {
    let result = Fixture.parser.parse("1700 от Ани", today: Fixture.today, kind: .reimbursement)
    #expect(result.personId == Fixture.anya)
    #expect(result.note.isEmpty)
    // Chosen as a purchase, the same line keeps «от Ани» in its note.
    let purchase = Fixture.parser.parse("1700 от Ани", today: Fixture.today, kind: .expense)
    #expect(purchase.personId == nil)
    #expect(purchase.note == "от Ани")
  }

  @Test("«для» по-прежнему работает у возврата денег")
  func forStillWorksForMoneyBack() {
    let result = Fixture.parse("возврат денег 1700 для Ани")
    #expect(result.kind == .reimbursement)
    #expect(result.personId == Fixture.anya)
  }

  @Test("У покупки «от Ани» остаётся в описании")
  func fromIsANoteWordOfAPurchase() {
    let result = Fixture.parse("торт 900 от Ани")
    #expect(result.kind == .expense)
    #expect(result.personId == nil)
    #expect(result.forWhom == nil)
    #expect(result.note == "торт от Ани")
  }

  @Test("У дохода «from John» остаётся в описании")
  func fromIsANoteWordOfIncome() {
    let result = Fixture.parse("+500 gift from John")
    #expect(result.kind == .income)
    #expect(result.personId == nil)
    #expect(result.note == "gift from John")
  }

  @Test("Незнакомое имя после «от» у возврата денег — предложение завести человека")
  func anUnknownNameBehindFrom() {
    let result = Fixture.parse("возврат денег 300 от Пети")
    #expect(result.kind == .reimbursement)
    #expect(result.personId == nil)
    #expect(result.unknownPersonName == "Пети")
    #expect(result.unknownPersonPhrase == "от Пети")
  }

  @Test("Токен имени несёт свой маркер: «для мамы», «в Пятёрочке», «цель Квартира»")
  func tokensKeepTheirMarkers() {
    let family = Fixture.parse("+5000 для мамы")
    #expect(family.tokens.contains(ParsedToken(role: .forWhom, text: "для мамы")))

    let person = Fixture.parse("+5000 для моей Маши")
    #expect(person.tokens.contains(ParsedToken(role: .person, text: "для моей Маши")))

    let place = Fixture.parse("+5000 в Пятёрочке")
    #expect(place.tokens.contains(ParsedToken(role: .place, text: "в Пятёрочке")))

    let goal = Fixture.parse("5000 цель Квартира")
    #expect(goal.tokens.contains(ParsedToken(role: .goal, text: "цель Квартира")))

    let event = Fixture.parse("+5000 в День рождения")
    #expect(event.tokens.contains(ParsedToken(role: .event, text: "в День рождения")))

    // A name with no marker keeps its own words only.
    let bare = Fixture.parse("+5000 Пятёрочка")
    #expect(bare.tokens.contains(ParsedToken(role: .place, text: "Пятёрочка")))
  }
}
