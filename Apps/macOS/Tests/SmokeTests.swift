import XCTest

final class SmokeTests: XCTestCase {
  /// The Debug build has an id of its own, and with it a container, defaults and a place in
  /// Launch Services of its own: the owner's copy in /Applications is never touched by a
  /// build from the repository, nor killed by `make run`. Release and AppStore keep the id
  /// that may never change.
  func testAppBundleIdentifierIsStable() {
    #if DEBUG
      XCTAssertEqual(Bundle.main.bundleIdentifier, "io.github.EvgenyBaulin.ohmymoney.debug")
    #else
      XCTAssertEqual(Bundle.main.bundleIdentifier, "io.github.EvgenyBaulin.ohmymoney")
    #endif
  }
}
