import AppCore
import XCTest

@testable import OhMyMoney

/// An amount field tells the form every amount the owner types, once. Enter writes «1500,5» back
/// as «1,500.50»; that text is the field's own, and telling it again would put 1,500.50 into the
/// form the same Enter has just saved and emptied for the next operation.
@MainActor
final class AmountFieldEchoTests: XCTestCase {
  /// The field as its view drives it: every change of the text goes through `tells`, Enter and
  /// leaving the field through `settle`, whose text is a change of its own.
  @MainActor
  private struct Field {
    var echo = AmountFieldEcho()
    var text = ""
    var told: [AmountE4] = []

    mutating func type(_ typed: String) {
      text = typed
      changed()
    }

    mutating func enter() {
      guard let settled = echo.settle(text) else { return }
      text = settled
      changed()
    }

    private mutating func changed() {
      guard echo.tells(text), let amount = AmountField.amount(from: text) else { return }
      told.append(amount)
    }
  }

  private func amount(_ text: String) throws -> AmountE4 {
    try AmountE4(decimal: try XCTUnwrap(Decimal(string: text)))
  }

  func testTheAmountWrittenBackIsNotToldASecondTime() throws {
    var field = Field()
    field.type("1500,5")
    XCTAssertEqual(field.told, [try amount("1500.5")])
    field.enter()
    XCTAssertEqual(field.text, "1,500.50")
    XCTAssertEqual(field.told, [try amount("1500.5")], "told once, not again by the echo")
  }

  /// A formula comes to its value on Enter, and that value is not told again either.
  func testAFormulaSettledIsToldOnce() throws {
    var field = Field()
    field.type("(1000+600)/2")
    field.enter()
    XCTAssertEqual(field.text, "800")
    XCTAssertEqual(field.told, [try amount("800")])
  }

  /// Only the one change the field made itself is skipped: what the owner types next — even the
  /// same text again — is told.
  func testWhatIsTypedAfterTheEchoIsTold() throws {
    var field = Field()
    field.type("1500,5")
    field.enter()
    field.type("2000")
    field.type("1,500.50")
    XCTAssertEqual(
      field.told, [try amount("1500.5"), try amount("2000"), try amount("1500.5")])
  }

  /// Text already written the app's way is left alone: Enter writes nothing back, and nothing is
  /// held back from the owner's next change.
  func testTextAlreadyWrittenTheAppsWayIsLeftAlone() throws {
    var echo = AmountFieldEcho()
    XCTAssertNil(echo.settle("1,500.50"))
    XCTAssertNil(echo.settle("1700+"), "text that does not read stays for the owner")
    XCTAssertTrue(echo.tells("1,500.50"))
  }
}
