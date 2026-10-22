import XCTest

#if os(macOS)
  @testable import OhMyMoney
#else
  @testable import OhMyMoney
#endif

/// When the entry line of the phone is on screen and when it may take the keyboard. Plain logic:
/// it runs on the Mac and compiles into the iPhone tests too.
@MainActor
final class PhoneEntryGateTests: XCTestCase {
  func testTheLineIsHiddenAtLaunchAndNoEventOfTheLaunchAsksForTheKeyboard() {
    var state = PhoneEntryState()
    XCTAssertFalse(state.isShown)
    XCTAssertTrue(state.showsPlus)
    for tab in PhoneTab.allCases {
      XCTAssertFalse(
        state.apply(.tabChanged(tab)), "switching to \(tab) must not open the keyboard")
      XCTAssertFalse(state.isShown)
    }
  }

  func testOnlyAnActOfTheOwnerOnTheLineAsksForTheKeyboard() {
    let events: [PhoneEntryEvent] = [
      .plusTapped, .newEntryRequested, .saved, .escaped, .tappedOutside,
      .tabChanged(.overview), .tabChanged(.operations), .tabChanged(.accounts), .tabChanged(.more),
    ]
    for event in events {
      var state = PhoneEntryState(tab: .operations)
      let asks = state.apply(event)
      XCTAssertEqual(asks, PhoneEntryState.focusesLine(event), "\(event)")
      XCTAssertEqual(asks, event == .plusTapped || event == .newEntryRequested, "\(event)")
    }
  }

  func testThePlusShowsTheLineOnTheSectionItWasTappedOn() {
    var state = PhoneEntryState(tab: .planning)
    XCTAssertTrue(state.apply(.plusTapped))
    XCTAssertTrue(state.isShown)
    XCTAssertTrue(state.shows(lineOf: .planning))
    XCTAssertFalse(state.shows(lineOf: .operations))
  }

  func testThePlusHidesWhileTheLineIsUpAndComesBackWithoutIt() {
    var state = PhoneEntryState(tab: .overview)
    XCTAssertTrue(state.showsPlus)
    state.apply(.plusTapped)
    XCTAssertFalse(state.showsPlus)
    state.apply(.saved)
    XCTAssertTrue(state.showsPlus)
  }

  func testMoreHasNoLineAndNoPlus() {
    var state = PhoneEntryState(tab: .more)
    XCTAssertFalse(state.showsPlus)
    XCTAssertFalse(state.apply(.plusTapped))
    XCTAssertFalse(state.apply(.newEntryRequested))
    XCTAssertFalse(state.isShown)
  }

  func testSavingEscapeAndATapOutsidePutTheLineAway() {
    for event in [PhoneEntryEvent.saved, .escaped, .tappedOutside] {
      var state = PhoneEntryState(tab: .accounts)
      state.apply(.plusTapped)
      XCTAssertTrue(state.isShown)
      state.apply(event)
      XCTAssertFalse(state.isShown, "\(event)")
    }
  }

  func testSwitchingTheSectionPutsTheLineAwayAndItIsNotShownOnTheNewOne() {
    var state = PhoneEntryState(tab: .operations)
    state.apply(.plusTapped)
    XCTAssertFalse(state.apply(.tabChanged(.planning)))
    XCTAssertFalse(state.isShown)
    XCTAssertFalse(state.shows(lineOf: .planning))
    XCTAssertTrue(state.showsPlus)
  }

  func testTheHardwareShortcutOpensTheLineAndAskingAgainKeepsItUp() {
    var state = PhoneEntryState(tab: .operations)
    XCTAssertTrue(state.apply(.newEntryRequested))
    XCTAssertTrue(state.apply(.newEntryRequested))
    XCTAssertTrue(state.shows(lineOf: .operations))
  }

  func testTheGateAnswersAsTheStateDoes() {
    let gate = PhoneEntryGate()
    XCTAssertFalse(gate.isShown)
    XCTAssertFalse(gate.send(.tabChanged(.operations)))
    XCTAssertTrue(gate.showsPlus)
    XCTAssertTrue(gate.send(.plusTapped))
    XCTAssertTrue(gate.isShown)
    XCTAssertFalse(gate.showsPlus)
    let access = PhoneEntryAccess(gate: gate, tab: .operations)
    XCTAssertTrue(access.isShown)
    XCTAssertFalse(PhoneEntryAccess(gate: gate, tab: .planning).isShown)
    gate.send(.saved)
    XCTAssertFalse(access.isShown)
  }
}
