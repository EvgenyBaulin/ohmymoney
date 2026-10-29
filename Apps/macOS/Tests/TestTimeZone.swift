import Foundation

/// The time zone the tests run in, whatever zone the Mac is in.
///
/// Many tests build their data in a calendar of their own (`CalendarContext.utc`, a fixed
/// `Calendar`), while the code under test reads `TimeZone.current` where the app reads the zone of
/// the Mac (`CalendarContext.system`, `TransactionDraft.materialize`, formatters). On a Mac in
/// another zone the two disagree around midnight and the test fails for the Mac, not for the code.
/// So before the first test the bundle sets the zone of the process: UTC, the calendar the tests
/// build their data in, or the zone named by `OHMYMONEY_TEST_TZ` (`make test-zones` runs the tests
/// in several, to find the tests that lean on the zone).
///
/// A test whose subject is the zone (a trip, a recorded zone) sets the zone it needs itself and
/// never relies on this one.
enum TestTimeZone {
  /// The zone the bundle pinned; read by a test that wants to know which one it runs in.
  nonisolated(unsafe) static var pinned: TimeZone = .current

  /// Sets the zone of the process. Called once by the principal class of the bundle.
  static func pin() {
    let name = ProcessInfo.processInfo.environment["OHMYMONEY_TEST_TZ"].flatMap {
      $0.isEmpty ? nil : $0
    }
    let zone =
      name.flatMap { TimeZone(identifier: $0) } ?? .gmt
    // `NSTimeZone.default = zone` is not enough: `TimeZone.current` keeps the zone of the Mac
    // (it is a cached copy of the system zone), and the app reads that one. Naming the zone in
    // `TZ` and resetting the system zone moves `TimeZone.current`, `Calendar.current`,
    // `TimeZone.autoupdatingCurrent` and the formatters together.
    setenv("TZ", zone.identifier, 1)
    tzset()
    NSTimeZone.resetSystemTimeZone()
    pinned = zone
  }
}
