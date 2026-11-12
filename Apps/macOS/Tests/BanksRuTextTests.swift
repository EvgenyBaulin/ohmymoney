import AppCore
import XCTest

@testable import OhMyMoney

/// The words about the rules of Russian banks exist in both languages and carry the figures the
/// core worked out: the tax on interest, the cap on cards, the fee past the SBP limit, the cashback
/// hint and the debt burden as a bank reads it.
@MainActor
final class BanksRuTextTests: XCTestCase {
  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func environments() -> [AppEnvironment] {
    [AppLanguage.Choice.russian, .english].map { choice in
      let environment = AppEnvironment()
      environment.language.choice = choice
      return environment
    }
  }

  func testEveryKeyIsInBothLanguages() {
    for environment in environments() {
      for key in BanksRuText.keys {
        XCTAssertNotEqual(environment.language(key, table: BanksRuText.table), key, key)
      }
      XCTAssertNotEqual(
        environment.language("bank.limit.sbpOwn", table: BankText.table), "bank.limit.sbpOwn")
      for key in ["planning.free.interestTax"] {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, key)
      }
      XCTAssertNotEqual(
        environment.language("why.free.interestTax", table: "Overview"), "why.free.interestTax")
    }
  }

  func testTheCardCountNameTheDateAndTheNumbers() {
    for environment in environments() {
      let before = BanksRuText.cardCountNote(
        count: 16, limit: 20, from: DateOnly(year: 2027, month: 9, day: 1), inForce: false,
        environment)
      XCTAssertTrue(before.contains("16") && before.contains("20") && before.contains("2027"), before)
      let after = BanksRuText.cardCountNote(
        count: 21, limit: 20, from: DateOnly(year: 2027, month: 9, day: 1), inForce: true,
        environment)
      XCTAssertNotEqual(before, after)
    }
  }

  func testTheInterestTaxNoteSaysTheYearTheSumAndTheDueDay() {
    for environment in environments() {
      let note = BanksRuText.interestTaxNote(
        year: 2026, taxE4: rub(3_900), dueDay: InterestTax.dueDay(year: 2026), environment)
      XCTAssertTrue(note.contains("2026") && note.contains("3") && note.contains("2027"), note)
    }
  }

  func testTheYearLinesCarryTheFreeSumAndTheForecast() {
    let year = InterestTax.Year(
      year: 2026, receivedE4: rub(100_000), accruedE4: rub(30_000), expectedE4: rub(190_000),
      withoutRate: [.usd])
    for environment in environments() {
      let lines = BanksRuText.interestLines(year, environment).joined(separator: "\n")
      XCTAssertTrue(lines.contains("160"), lines)
      XCTAssertTrue(lines.contains("190"), lines)
      XCTAssertTrue(lines.contains(CurrencyCode.usd.code), lines)
    }
  }

  func testTheFeeLineShowsOnlyPastTheLimit() {
    let line = BankLimitLine(
      accountId: UUID(), kind: .sbp, currency: .rub, limitE4: rub(50_000), usedE4: rub(70_000),
      movements: [
        BankLimitMovement(
          id: UUID(), source: .operation, accountId: UUID(), kind: .sbp,
          day: DateOnly(year: 2026, month: 10, day: 5), amountE4: rub(70_000))
      ])
    let within = BankLimitLine(
      accountId: UUID(), kind: .sbp, currency: .rub, limitE4: rub(50_000), usedE4: rub(10_000),
      movements: [])
    for environment in environments() {
      XCTAssertNotNil(BanksRuText.sbpFeeLine(line, environment))
      XCTAssertNil(BanksRuText.sbpFeeLine(within, environment))
    }
  }

  func testTheCashbackNoteNamesTheFourThousand() {
    for environment in environments() {
      let note = BanksRuText.cashbackNote(totalRub: rub(120_000), environment)
      XCTAssertTrue(note.contains("120"), note)
      XCTAssertTrue(note.contains("4"), note)
    }
  }

  func testTheBurdenLinesAreThreeWithAnIncomeAndOneWithout() {
    let pdn = BankPdn(
      creditsRub: rub(30_000), cardsRub: rub(10_000), instalmentsRub: rub(5_000),
      incomeRub: rub(100_000), withoutRate: [])
    let none = BankPdn(
      creditsRub: rub(30_000), cardsRub: rub(10_000), instalmentsRub: rub(5_000), incomeRub: nil,
      withoutRate: [])
    for environment in environments() {
      let lines = BanksRuText.pdnLines(pdn, environment)
      XCTAssertEqual(lines.count, 3)
      XCTAssertTrue(lines[0].contains("40"), lines[0])
      XCTAssertTrue(lines[1].contains("45"), lines[1])
      XCTAssertEqual(BanksRuText.pdnLines(none, environment).count, 1)
    }
  }

  func testTheNotesOfTheNewKindsHaveWordsAndASymbol() {
    let environment = environments()[1]
    let notes: [BankNote] = [
      .cardCount(count: 17, limit: 20, from: DateOnly(year: 2027, month: 9, day: 1), inForce: false),
      .interestTax(
        year: 2026, taxE4: rub(3_900), estimate: true, dueDay: InterestTax.dueDay(year: 2026)),
      .cashbackTax(year: 2026, totalRub: rub(120_000)),
    ]
    for note in notes {
      XCTAssertFalse(WorthALookNoteText.bankText(note, accounts: [:], environment).isEmpty)
      XCTAssertFalse(WorthALookNoteText.bankSymbol(note).isEmpty)
      XCTAssertTrue(note.canBePutAway)
      XCTAssertFalse(note.isAlarm)
    }
    XCTAssertEqual(Set(notes.map(\.id)).count, 3)
  }
}
