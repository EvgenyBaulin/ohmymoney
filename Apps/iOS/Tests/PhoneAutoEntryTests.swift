import AppCore
import XCTest

@testable import OhMyMoney

/// «Передать сообщение банка» on the phone waits for the paid developer account: hidden from
/// «Быстрые команды» and refusing politely until the switch is turned on.
@MainActor
final class PhoneAutoEntryTests: XCTestCase {
  private let push = "Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽"

  func testTheActionIsOffUntilTheDeveloperAccount() {
    XCTAssertFalse(PhoneIntents.isEnabled)
    XCTAssertFalse(PhoneBankMessageIntent.isDiscoverable)
  }

  func testSwitchedOffItRefusesAndKeepsNothing() {
    guard case .refused(let said) = PhoneAutoEntry.receive(push, dependencies: nil) else {
      return XCTFail("an action that is off writes nothing")
    }
    XCTAssertFalse(said.isEmpty)
    XCTAssertFalse(said.contains("450"))
  }

  func testWithoutTheBooksItSaysTheAppIsNotReady() {
    let off = PhoneAutoEntry.receive(push, dependencies: nil)
    let on = PhoneAutoEntry.receive(push, dependencies: nil, enabled: true)
    guard case .refused(let notReady) = on else { return XCTFail("\(on)") }
    XCTAssertNotEqual(on, off, "«not ready» is not «off»")
    XCTAssertFalse(notReady.isEmpty)
  }
}
