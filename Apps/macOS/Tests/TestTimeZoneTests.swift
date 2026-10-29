import XCTest

/// The bundle runs in the zone it pinned (`TestTimeZone`), whatever zone the Mac is in: a test
/// that reads `TimeZone.current`, `Calendar.current` or a formatter gets the same zone everywhere.
final class TestTimeZoneTests: XCTestCase {
  func testEveryWayOfAskingForTheZoneAnswersWithThePinnedOne() {
    let pinned = TestTimeZone.pinned.identifier
    XCTAssertEqual(TimeZone.current.identifier, pinned)
    XCTAssertEqual(TimeZone.autoupdatingCurrent.identifier, pinned)
    XCTAssertEqual(Calendar.current.timeZone.identifier, pinned)
    XCTAssertEqual(DateFormatter().timeZone.identifier, pinned)
  }

  func testTheZoneIsTheOneNamedByTheEnvironmentOrUTC() {
    let named = ProcessInfo.processInfo.environment["OHMYMONEY_TEST_TZ"].flatMap {
      $0.isEmpty ? nil : $0
    }
    // «UTC» is a name for «GMT»: compare the zones, not the spellings.
    XCTAssertEqual(TestTimeZone.pinned, named.flatMap { TimeZone(identifier: $0) } ?? TimeZone.gmt)
  }
}
