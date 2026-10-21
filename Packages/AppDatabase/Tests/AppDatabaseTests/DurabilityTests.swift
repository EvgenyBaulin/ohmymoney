import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// A class of ours, only so the test can ask which bundle it is in and find the build's
/// products beside it — that is where the probe binary lands.
private final class Anchor: NSObject {}

/// «Тест долговечности: сохранённая операция переживает `kill -9` процесса».
///
/// This is the promise everything else rests on: whatever else breaks, an operation that
/// was saved is saved. It cannot be checked inside one process — `kill -9` cannot be
/// survived — so a process of its own writes the operation and kills itself, and this test
/// opens the database afterwards and looks.
@Suite("An operation that was saved survives the process being killed")
struct DurabilityTests {
  private var products: URL {
    Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()
  }

  private var probe: URL { products.appendingPathComponent("ohmymoney-durability-probe") }

  /// The probe must be there: a durability test that skipped itself would leave the promise
  /// unproved without a word. When the toolchain lays the products out differently, the
  /// failure says where the probe was looked for and on what assumption.
  private func requireTheProbe(sourceLocation: SourceLocation = #_sourceLocation) throws {
    try #require(
      FileManager.default.fileExists(atPath: probe.path),
      """
      the probe was not found at \(probe.path): the test looks for it next to its own test \
      bundle (\(Bundle(for: Anchor.self).bundleURL.lastPathComponent)), where SwiftPM puts the \
      build products; if this toolchain puts them elsewhere, update DurabilityTests.products
      """, sourceLocation: sourceLocation)
  }

  /// The same migrations every other test of this package reads.
  private func schemaDirectory() -> URL { TestSupport.schemaDirectory }

  private struct Ending {
    var status: Int32
    var killed: Bool
  }

  @discardableResult
  private func run(_ arguments: [String]) throws -> Ending {
    let process = Process()
    process.executableURL = probe
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["OHMYMONEY_SCHEMA_DIR"] = schemaDirectory().path
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    return Ending(
      status: process.terminationStatus, killed: process.terminationReason == .uncaughtSignal)
  }

  private func notes(in url: URL) throws -> [String] {
    let stack = try DatabaseStack(
      url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    return try TransactionRepository(writer: stack.writer).recentEntries(limit: 50)
      .compactMap(\.transaction.note)
  }

  @Test func anOperationSurvivesTheProcessBeingKilled() throws {
    try requireTheProbe()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-durability-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("finance.sqlite")

    // The probe writes the operation and then kills itself: no close, no checkpoint, nothing
    // that a crash would have skipped.
    let ending = try run([database.path, "survives a kill", "--commit-only"])
    #expect(ending.killed, "the probe exited instead of being killed: the test proves nothing")
    #expect(ending.status == SIGKILL, "killed by something other than SIGKILL")

    #expect(try notes(in: database) == ["survives a kill"])
  }

  /// The same without the kill, so a failure in the first test means the kill and not the
  /// probe.
  @Test func theProbeWritesAnOperationWhenItIsLeftToFinish() throws {
    try requireTheProbe()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-durability-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("finance.sqlite")

    let ending = try run([database.path, "written and closed"])
    #expect(!ending.killed)
    #expect(ending.status == 0)
    #expect(try notes(in: database) == ["written and closed"])
  }
}
