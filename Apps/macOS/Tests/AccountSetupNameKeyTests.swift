import XCTest

@testable import OhMyMoney

/// Names in the account setup are compared as everywhere else in the app: case, «ё» and the
/// spaces around do not matter; «й» and «и» are different letters.
final class AccountSetupNameKeyTests: XCTestCase {
  func testCaseSpacesAndYoAreIgnored() {
    XCTAssertEqual(
      AccountSetupModel.nameKey("  Тинькофф \n"), AccountSetupModel.nameKey("тинькофф"))
    XCTAssertEqual(AccountSetupModel.nameKey("Ёлка"), AccountSetupModel.nameKey("елка"))
  }

  func testShortIAndIAreDifferentNames() {
    XCTAssertNotEqual(AccountSetupModel.nameKey("Йога"), AccountSetupModel.nameKey("Иога"))
  }
}
