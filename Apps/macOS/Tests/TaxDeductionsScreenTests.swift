import AppCore
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// «Вычеты за год» and the mark «Налоговый вычет»: every kind, group and document has its words
/// in both languages, and the mark of the entry lands on every part of the operation and leaves
/// the parts' own kinds alone until the field is touched.
@MainActor
final class TaxDeductionsScreenTests: XCTestCase {
  func testEveryKindGroupAndDocumentHasItsWordsInBothLanguages() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for kind in [nil] + TaxDeductionKind.allCases {
        let words = DeductionsText.kind(kind, environment)
        XCTAssertFalse(words.hasPrefix("deductions."), "\(String(describing: kind)) \(choice)")
      }
      for document in TaxDeductionDocument.allCases {
        let words = DeductionsText.document(document, environment)
        XCTAssertFalse(words.hasPrefix("deductions."), "\(document) \(choice)")
      }
      let keys: [TaxDeductionGroup.Key] = [
        .social, .medicalExpensive, .child(nil), .child(UUID()), .iis, .mortgageInterest,
      ]
      for key in keys {
        let words = DeductionsText.title(of: key, people: [], environment)
        XCTAssertFalse(words.hasPrefix("deductions."), "\(key) \(choice)")
      }
      for key in [
        "deductions.title", "deductions.open", "deductions.field.split", "deductions.empty",
        "deductions.noRules", "deductions.documents", "deductions.hint", "deductions.income",
        "deductions.debt.field", "deductions.account.field", "deductions.refund.exactHint",
        "deductions.group.noLimit", "deductions.group.mortgageNote",
      ] {
        XCTAssertNotEqual(DeductionsText.t(key, environment), key, "\(key) \(choice)")
      }
      XCTAssertNotEqual(
        environment.language("entry.taxDeduction", table: "Entry"), "entry.taxDeduction")
    }
    environment.language.choice = .russian
    XCTAssertEqual(DeductionsText.kind(.medical, environment), "Лечение и лекарства")
    let anya = Person(name: "Аня")
    XCTAssertEqual(
      DeductionsText.title(of: .child(anya.id), people: [anya], environment),
      "Обучение ребёнка: Аня")
    XCTAssertEqual(
      environment.format(
        "deductions.refund.upTo", table: DeductionsText.table,
        environment.money.rounded(AmountE4(whole: 19500))),
      "Вернут до " + environment.money.rounded(AmountE4(whole: 19500)))
  }

  func testTheMarkLandsOnEveryPartAndNoneTakesItAway() {
    var draft = TransactionDraft(kind: .expense, occurredAt: Date(), amount: AmountE4(whole: 300))
    XCTAssertNil(TaxDeductionMark.shared(draft))
    // One part not written yet: the mark makes it.
    TaxDeductionMark.set(.medical, on: &draft)
    XCTAssertEqual(draft.parts.count, 1)
    XCTAssertEqual(TaxDeductionMark.shared(draft), .medical)
    // A split: every part takes the kind; parts that differ share none.
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 200), taxDeduction: .medical),
      PartDraft(amount: AmountE4(whole: 100)),
    ]
    XCTAssertNil(TaxDeductionMark.shared(draft))
    TaxDeductionMark.set(.sport, on: &draft)
    XCTAssertEqual(draft.parts.map(\.taxDeduction), [.sport, .sport])
    // A kind a part may not carry is none.
    TaxDeductionMark.set(.mortgageInterest, on: &draft)
    XCTAssertEqual(draft.parts.map(\.taxDeduction), [nil, nil])
    TaxDeductionMark.set(.education, on: &draft)
    TaxDeductionMark.set(nil, on: &draft)
    XCTAssertNil(TaxDeductionMark.shared(draft))
  }

  func testAnEditKeepsTheKindOfEachPart() {
    let transactionId = UUID()
    let part = TransactionPart(
      transactionId: transactionId, amountE4: AmountE4(whole: 500), taxDeduction: .educationChild)
    let draft = PartDraft(part: part)
    XCTAssertEqual(draft.taxDeduction, .educationChild)
    XCTAssertEqual(
      draft.materialize(transactionId: transactionId, amountRub: AmountE4(whole: 500)).taxDeduction,
      .educationChild)
  }

  func testTheAccountEditorKeepsAndSetsTheInvestmentAccount() {
    let account = PaymentMethod(name: "Брокер", kind: .account, currency: .rub, taxDeduction: .iis)
    var draft = AccountDraft(account)
    XCTAssertTrue(draft.iis)
    XCTAssertEqual(draft.account(over: account).taxDeduction, .iis)
    draft.iis = false
    XCTAssertNil(draft.account(over: account).taxDeduction)
    draft.iis = true
    draft.isBorrowed = true
    XCTAssertNil(draft.account(over: account).taxDeduction, "someone else's card is no IIS")
  }
}
