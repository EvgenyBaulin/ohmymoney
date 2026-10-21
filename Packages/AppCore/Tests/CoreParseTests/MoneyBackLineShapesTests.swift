import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Money back typed the ways people type it: the person before or after the amount, the amount
/// grouped or with kopecks, a currency, a day, an account — each read the way the rest of the
/// line reads them, and nothing of it left in the note.
@Suite("Возврат денег: как ещё его пишут")
struct MoneyBackLineShapesTests {
  @Test("«возврат денег от Ани 1700» — человек до суммы")
  func thePersonBeforeTheAmount() {
    let result = Fixture.parse("возврат денег от Ани 1700")
    #expect(result.kind == .reimbursement)
    #expect(result.amount == dec("1700"))
    #expect(result.personId == Fixture.anya)
    #expect(result.note.isEmpty)
  }

  @Test("«возврат денег 1 700 от Ани» — сумма с пробелом")
  func anAmountGroupedBySpace() {
    let result = Fixture.parse("возврат денег 1 700 от Ани")
    #expect(result.amount == dec("1700"))
    #expect(result.personId == Fixture.anya)
  }

  @Test("«возврат денег 1,700.50 от Ани» — копейки")
  func anAmountWithKopecks() {
    let result = Fixture.parse("возврат денег 1,700.50 от Ани")
    #expect(result.amount == dec("1700.5"))
    #expect(result.personId == Fixture.anya)
  }

  @Test("«возврат денег 1,500 от Ани» — одна запятая с тремя цифрами — тысячи")
  func aLoneCommaWithThreeDigitsGroupsThousands() {
    #expect(Fixture.parse("возврат денег 1,500 от Ани").amount == dec("1500"))
    #expect(Fixture.parse("возврат денег 1,5 от Ани").amount == dec("1.5"))
  }

  @Test("«возврат денег 20$ от Ани» и «20 usd» — в долларах")
  func dollars() {
    for line in [
      "возврат денег 20$ от Ани", "возврат денег 20 usd от Ани", "money back 20 USD from Anya",
    ] {
      let result = Fixture.parse(line)
      #expect(result.kind == .reimbursement, "\(line)")
      #expect(result.currency == .usd, "\(line)")
      #expect(result.amount == dec("20"), "\(line)")
      #expect(result.personId == Fixture.anya, "\(line)")
    }
  }

  @Test("«возврат денег 1700 от Ани вчера» — день")
  func aDay() {
    let result = Fixture.parse("возврат денег 1700 от Ани вчера")
    #expect(result.personId == Fixture.anya)
    #expect(result.date == DateOnly(year: 2026, month: 9, day: 17))
    #expect(result.note.isEmpty)
  }

  @Test("«возврат денег 1700 от Ани наличные» — счёт по другому названию")
  func anAccountByItsOtherName() {
    let result = Fixture.parse("возврат денег 1700 от Ани наличные")
    #expect(result.personId == Fixture.anya)
    #expect(result.paymentMethodId == Fixture.cash)
    #expect(result.note.isEmpty)
  }

  @Test("«возврат денег 1700 от Anya» — человек по другому имени")
  func aPersonByTheirOtherName() {
    let result = Fixture.parse("возврат денег 1700 от Anya")
    #expect(result.personId == Fixture.anya)
  }

  @Test("«возврат денег 1700 от Анна Петрова» — имя из двух слов, как записано")
  func aNameOfTwoWords() {
    let result = Fixture.parse("возврат денег 1700 от Анна Петрова")
    #expect(result.personId == Fixture.annaPetrova)
  }

  @Test("«возврат денег 1700 от Анны Петровой» — имя из двух слов, склонённое")
  func aDeclinedNameOfTwoWords() {
    let result = Fixture.parse("возврат денег 1700 от Анны Петровой")
    #expect(result.kind == .reimbursement)
    #expect(result.amount == dec("1700"))
    #expect(result.personId == Fixture.annaPetrova)
    #expect(result.note.isEmpty)
  }

  @Test("«возврат 1700 от Ани» — это возврат покупки, «от Ани» остаётся в описании")
  func aPurchaseRefundKeepsFromInItsNote() {
    let result = Fixture.parse("возврат 1700 от Ани")
    #expect(result.kind == .refund)
    #expect(result.personId == nil)
    #expect(result.note.contains("от Ани"))
  }
}
