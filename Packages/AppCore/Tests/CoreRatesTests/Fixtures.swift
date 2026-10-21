import Foundation
import Testing

/// Access to the sample documents in `Fixtures/`, declared as a resource in `Package.swift`.
/// The XML files are stored in windows-1251, exactly as the bank serves them, so they are
/// always read as raw bytes and never as text.
enum Fixture {
  static func data(_ name: String, _ suffix: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Fixtures"),
      "fixture \(name).\(suffix) is missing from the test bundle")
    return try Data(contentsOf: url)
  }

  static func cbrWednesday() throws -> Data { try data("cbr_2026-09-16", "xml") }
  static func cbrFriday() throws -> Data { try data("cbr_2026-09-18", "xml") }
  static func mirror() throws -> Data { try data("mirror_2026-09-18", "json") }
}
