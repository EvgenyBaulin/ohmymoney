import Foundation
import Testing

@testable import AppDatabase

/// The problem report names the versions of the storage (`StorageVersions`), and a report
/// that names the wrong one sends its reader after the wrong release.
@Suite("The versions of the storage are the ones it is built on")
struct StorageVersionsTests {
  /// `Package.resolved` of this package, where GRDB is pinned.
  private static var resolved: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // AppDatabaseTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // AppDatabase
      .appendingPathComponent("Package.resolved")
  }

  private struct Resolved: Decodable {
    struct Pin: Decodable {
      struct State: Decodable { var version: String? }
      var identity: String
      var state: State
    }
    var pins: [Pin]
  }

  @Test func theVersionOfGRDBIsThePinnedOne() throws {
    let file = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: Self.resolved))
    let pin = try #require(file.pins.first { $0.identity == "grdb.swift" })
    #expect(pin.state.version == StorageVersions.grdb)
  }

  @Test func theVersionOfSQLiteIsTheLibrarysOwn() {
    #expect(StorageVersions.sqlite.hasPrefix("3."))
  }
}
