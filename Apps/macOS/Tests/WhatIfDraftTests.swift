import AppCore
import XCTest

@testable import OhMyMoney

final class WhatIfDraftTests: XCTestCase {
  func testAHalfTypedLineIsLeftOutUntilItIsReadable() {
    var draft = WhatIfDraft()
    draft.rows[0].kind = .loan
    draft.rows[0].amount = "500 000"
    XCTAssertTrue(draft.spec.changes.isEmpty)
    XCTAssertEqual(draft.unreadRows, 1)
    draft.rows[0].months = "36"
    draft.rows[0].rate = "12,5"
    let change = draft.spec.changes.first
    XCTAssertEqual(change?.amountE4, 5_000_000_000)
    XCTAssertEqual(change?.months, 36)
    XCTAssertEqual(change?.rateBp, 1250)
    XCTAssertEqual(draft.unreadRows, 0)
  }

  func testIncomeLossAsksForMonthsOnly() {
    var row = WhatIfRow()
    row.kind = .incomeLoss
    row.months = "3"
    XCTAssertEqual(row.change?.kind, .incomeLoss)
    XCTAssertNil(row.change?.amountE4)
  }

  func testTheHorizonIsKeptInsideItsLimits() {
    var draft = WhatIfDraft()
    draft.horizon = "9999"
    XCTAssertEqual(draft.spec.horizonMonths, ScenarioSpec.maxHorizonMonths)
    draft.horizon = "abc"
    XCTAssertEqual(draft.spec.horizonMonths, ScenarioSpec.defaultHorizonMonths)
  }

  func testASavedScenarioOpensBackAsTheSameForm() throws {
    var row = WhatIfRow()
    row.kind = .loan
    row.amount = "500000"
    row.months = "36"
    row.rate = "12.5"
    var draft = WhatIfDraft()
    draft.rows = [row]
    draft.horizon = "24"
    let spec = draft.spec
    let reopened = try XCTUnwrap(ScenarioSpec(json: spec.json()))
    XCTAssertEqual(WhatIfDraft(reopened).spec, spec)
  }
}
