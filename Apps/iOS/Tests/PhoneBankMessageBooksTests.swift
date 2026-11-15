import AppCore
import XCTest

@testable import OhMyMoney

/// A text of a bank handed to the phone, once the books are open: what is refused and why, what
/// waits in «Запишу потом», that a second delivery adds nothing, and that the operation is never
/// written on the spot.
@MainActor
final class PhoneBankMessageBooksTests: XCTestCase {
  private var harness: PhoneHarness!

  /// The four digits of a card of the synthetic book whose account is in view: a text of a bank
  /// names the card by them.
  private var last4: String {
    let dataset = harness.compute.wholeSnapshot?.dataset
    let hidden = Set((dataset?.paymentMethods ?? []).filter(\.hidden).map(\.id))
    return dataset?.cards.first { $0.last4 != nil && !hidden.contains($0.accountId) }?.last4
      ?? "7788"
  }

  private var push: String {
    "Покупка, карта *\(last4). 450 ₽. KOFEMANIYA. Доступно 12 300 ₽. Код 9911"
  }

  override func setUp() async throws {
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.pendingKey)
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.fingerprintsKey)
    harness = try await PhoneHarness.make()
  }

  override func tearDown() async throws {
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.pendingKey)
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.fingerprintsKey)
    await harness.tearDown()
    harness = nil
  }

  private var drafts: [PendingDraft] {
    SettingsDraftStore(settings: harness.environment.settings).load()
  }

  private func receive(_ text: String) -> PhoneAutoEntry.Outcome {
    PhoneAutoEntry.receive(text, dependencies: harness.deps, enabled: true)
  }

  func testATextTypedByHandIsNoBankTextAndKeepsNothing() {
    for text in ["кофе 250", "", "   ", "450", "Привет! Как дела?", "💸💸💸"] {
      guard case .refused(let said) = receive(text) else {
        return XCTFail("«\(text)» was taken for a bank text")
      }
      XCTAssertFalse(said.isEmpty)
    }
    XCTAssertTrue(drafts.isEmpty)
  }

  func testAReadOnlyPhoneWritesNothingAndSaysSo() {
    harness.environment.shield.turnReadOnlyOn()
    guard case .refused(let said) = receive(push) else { return XCTFail("read-only took a draft") }
    XCTAssertFalse(said.isEmpty)
    XCTAssertFalse(said.contains("450"))
    XCTAssertTrue(drafts.isEmpty)
    let off = PhoneAutoEntry.receive(push, dependencies: harness.deps, enabled: false)
    XCTAssertNotEqual(off, receive(push), "«off» and «read-only» are not the same answer")
  }

  func testABankTextWaitsAsADraftWithoutTheTextOrTheCode() {
    XCTAssertTrue(drafts.isEmpty)
    guard case .done(let said) = receive(push) else { return XCTFail("the text was refused") }
    XCTAssertFalse(said.isEmpty)
    XCTAssertEqual(drafts.count, 1)
    let kept = drafts.map(\.text).joined(separator: "\n")
    XCTAssertTrue(kept.contains("450"), kept)
    XCTAssertFalse(kept.contains("9911"), "the code of the bank is kept nowhere")
    XCTAssertFalse(kept.contains("Доступно"), "nor the rest of the text")
  }

  func testTheSameTextTwiceIsOneDraft() {
    guard case .done = receive(push) else { return XCTFail("the first delivery was refused") }
    XCTAssertEqual(drafts.count, 1)
    guard case .done = receive(push) else { return XCTFail("the second delivery was refused") }
    XCTAssertEqual(drafts.count, 1, "a delivery repeated adds nothing")
  }

  func testAnHugeAmountAndAnotherCurrencyAreOfferedWithTheirExactDigits() {
    let huge = "Покупка, карта *\(last4). 999 999 999,99 ₽. BIGSHOP. Доступно 1 ₽"
    guard case .done = receive(huge) else { return XCTFail("a huge amount was refused") }
    XCTAssertEqual(drafts.count, 1)
    let kept = drafts.map(\.text).joined(separator: "\n")
    XCTAssertTrue(kept.filter(\.isNumber).contains("99999999999"), "the amount is whole: \(kept)")
    XCTAssertFalse(kept.contains("e+") || kept.contains("E+"), "no float notation: \(kept)")

    let dollars = "Покупка, карта *\(last4). 25,50 $. STEAM. Доступно 3 000 ₽"
    guard case .done = receive(dollars) else { return XCTFail("a dollar amount was refused") }
    XCTAssertEqual(drafts.count, 2)
    let afterDollars = drafts.map(\.text).joined(separator: "\n")
    XCTAssertTrue(afterDollars.contains("25.5") || afterDollars.contains("25,5"), afterDollars)
    XCTAssertTrue(afterDollars.contains("USD"), afterDollars)
  }

  func testWhileTheNumbersAreHiddenTheAnswerNamesNoAmount() {
    harness.environment.amounts.hidesAmounts = true
    defer { harness.environment.amounts.hidesAmounts = false }
    guard case .done(let said) = receive(push) else { return XCTFail("the text was refused") }
    XCTAssertEqual(drafts.count, 1, "a draft was kept, not a duplicate answer")
    XCTAssertFalse(said.contains("450"), "the answer of a phone with hidden amounts: \(said)")
  }
}
