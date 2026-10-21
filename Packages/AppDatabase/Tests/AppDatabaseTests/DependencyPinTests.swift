import Foundation
import Testing

/// The storage layer is the code that opens the owner's database, and the application
/// resolves its packages on its own: Xcode reads this package's manifest, never its
/// `Package.resolved`, which answers only `swift test` of the package itself. A range in the
/// manifest let the app link whatever GRDB 7.x was newest the day it was built while these
/// tests ran against the pin. Whether the committed `Package.resolved` is
/// SwiftPM's own output cannot be asked from here — `swift test` rewrites it before any test
/// runs — so `make test-db` asks it: the run must leave the file as it found it.
@Suite("The storage layer's dependencies are pinned where the app reads them")
struct DependencyPinTests {
  private static var packageDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // AppDatabaseTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // AppDatabase
  }

  /// A remote package of the manifest, by the identity SwiftPM gives it, with the version it
  /// is pinned to exactly, or nil when it is declared by a range.
  private struct Declared {
    var identity: String
    var exact: String?
  }

  private static func declared() throws -> [Declared] {
    let manifest = try String(
      contentsOf: packageDirectory.appendingPathComponent("Package.swift"), encoding: .utf8)
    return manifest.split(separator: "\n").compactMap { line -> Declared? in
      guard line.contains(".package(url:"),
        let url = line.firstMatch(of: /url: "([^"]+)"/)?.1
      else { return nil }
      let identity = String(url.split(separator: "/").last ?? "")
        .replacingOccurrences(of: ".git", with: "", options: .anchored.union(.backwards))
        .lowercased()
      return Declared(
        identity: identity, exact: line.firstMatch(of: /exact: "([^"]+)"/).map { String($0.1) })
    }
  }

  @Test("GRDB is pinned exactly in the manifest, where the app reads it")
  func grdbIsPinnedExactly() throws {
    let grdb = try #require(
      try Self.declared().first { $0.identity == "grdb.swift" }, "the manifest names no GRDB")
    #expect(grdb.exact != nil, "GRDB is declared by a range, so the app links the newest 7.x")
  }
}
