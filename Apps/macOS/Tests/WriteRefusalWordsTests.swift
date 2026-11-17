import XCTest

@testable import OhMyMoney

/// A write refused in «Только просмотр» says so in one sentence, in both languages, and not
/// «Не удалось»: a refusal that reads like a breakage sends the owner looking for a fault.
@MainActor
final class WriteRefusalWordsTests: XCTestCase {
  func testReadOnlyUsesItsOwnWordsAndAnythingElseKeepsTheOldOnes() {
    XCTAssertEqual(WriteRefusalWords.keys(readOnly: true).message, "write.refused.readOnly")
    XCTAssertEqual(WriteRefusalWords.keys(readOnly: true).title, "write.refused.readOnly.title")
    XCTAssertEqual(WriteRefusalWords.keys(readOnly: false).message, "write.refused")
    XCTAssertEqual(WriteRefusalWords.keys(readOnly: false).title, "write.refused.title")
  }

  func testTheWordsExistInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in [
        "write.refused.readOnly", "write.refused.readOnly.title", "amount.unreadable",
        "amount.unreadable.form",
      ] {
        XCTAssertNotEqual(environment.language(key), key, "\(key) in \(choice)")
      }
    }
  }

  func testAFormWithAnUnreadableAmountCannotBeSaved() {
    XCTAssertTrue(UnreadableAmountRule.isEnabled(formAllows: true, hasUnreadableAmount: false))
    XCTAssertFalse(UnreadableAmountRule.isEnabled(formAllows: true, hasUnreadableAmount: true))
    XCTAssertFalse(UnreadableAmountRule.isEnabled(formAllows: false, hasUnreadableAmount: false))
  }

  func testWhatDoesNotReadIsKnownByTheField() {
    XCTAssertNil(AmountField.amount(from: "5 000×"))
    XCTAssertNil(AmountField.amount(from: "99999999999999999999"))
    XCTAssertEqual(AmountField.amount(from: ""), .zero)
    XCTAssertNotNil(AmountField.amount(from: "5000×2"))
  }

  func testAnUnreadableAmountStopsTheEntryModelBeforeItCanSaveTheOldAmount() {
    let model = EntryDraftModel(references: nil, transactions: nil, calendar: .utc)
    model.hasUnreadableAmount = true
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountUnreadable")
  }

  func testAReadOnlyStoreAnnouncesWhyTheWriteWasRefused() {
    let store = TransactionsStore()
    store.isReadOnly = { true }
    XCTAssertTrue(store.refuses("save", #fileID))
    XCTAssertEqual(store.refusal, "write.refused.readOnly")
  }
}
