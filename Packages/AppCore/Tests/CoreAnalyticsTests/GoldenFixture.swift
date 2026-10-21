import Foundation
import Testing

@testable import CoreAnalytics

/// How the core's tests reach the golden set: from their own bundle, with every missing
/// answer a failed expectation rather than a crash.
extension Golden {
  static func load() throws -> Golden {
    let url = try #require(
      Bundle.module.url(
        forResource: "golden-small", withExtension: "json", subdirectory: "Fixtures"),
      "golden-small.json is missing from the test bundle")
    return try decode(Data(contentsOf: url))
  }

  func answer(_ name: String) throws -> Answer {
    try #require(expected[name], "no expected answer named \(name)")
  }
}

/// A mistyped amount of the golden set or of a literal in these suites (`money(_:)`).
func reportAmountTypo(_ text: String) {
  Issue.record("«\(text)» is not an amount: write a plain decimal, such as 1250.5")
}
