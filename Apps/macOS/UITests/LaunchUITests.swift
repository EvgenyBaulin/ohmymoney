import XCTest

/// UI tests are written but excluded from `make test`: they can block on system prompts, and
/// nobody may be at the machine to answer them.
///
/// On synthetic data, like every other UI test: launched bare, this opened the owner's own
/// Debug database, and no test may ever read the owner's data.
@MainActor
final class LaunchUITests: XCTestCase {
  func testAppLaunches() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--data-set", "ui-test", "--generate", "2",
      "-app.language", "en", "-AppleLanguages", "(en)",
      "-ApplePersistenceIgnoreState", "YES", "--no-reminders",
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
  }
}
