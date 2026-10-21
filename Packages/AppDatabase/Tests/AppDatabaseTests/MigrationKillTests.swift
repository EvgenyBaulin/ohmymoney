import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// A class of ours, only so the test can find the build's products beside its own bundle.
private final class KillProbeAnchor: NSObject {}

/// The update lands whole or not at all even when the process is killed in the middle of it —
/// `kill -9`, a crash, the power button: no error is thrown, nothing rolls back by hand, and
/// the file must still be the older database it was, asking for the same update, which the
/// next start then gives exactly as if nothing had happened.
///
/// It has to be a process of its own (`ohmymoney-durability-probe --die-in-the-update`): it opens
/// an older database and kills itself inside the one transaction of the update, after the SQL
/// of the migration ran and before its data step wrote a row.
@Suite("An update killed halfway leaves the older database as it was")
struct MigrationKillTests {
  private var probe: URL {
    Bundle(for: KillProbeAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ohmymoney-durability-probe")
  }

  private func dieInTheUpdate(_ url: URL) throws -> (killed: Bool, output: String) {
    try #require(FileManager.default.fileExists(atPath: probe.path), "no probe at \(probe.path)")
    let process = Process()
    process.executableURL = probe
    process.arguments = [url.path, "--die-in-the-update"]
    var environment = ProcessInfo.processInfo.environment
    environment["OHMYMONEY_SCHEMA_DIR"] = TestSupport.schemaDirectory.path
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
      String(decoding: data, as: UTF8.self)
    )
  }

  /// Older databases that need an account made for their operations, large enough that the
  /// update writes many pages before it is killed: the file holds the same data as a copy taken
  /// before, it is sound, it still asks for the update, and the update of the next start gives
  /// what the update of an untouched twin gives, value for value.
  @Test(arguments: [UInt64(601), 602, 603])
  func anUpdateKilledHalfwayLeavesTheOlderDatabase(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(
      seed: seed, operations: 3_000, accounts: 1...4, flags: RandomLegacyDatabase.Flags.none,
      unassigned: true)
    defer { book.remove() }
    #expect(
      MainAccountModel.main(accounts: book.accounts, operations: book.operationAccounts)
        == .created, "seed \(seed): the update would make no account, so nothing would be killed")
    let folder = book.url.deletingLastPathComponent()
    let before = folder.appendingPathComponent("before.sqlite")
    let twin = folder.appendingPathComponent("twin.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: before)
    try DatabaseStack.backup(fileAt: book.url, to: twin)

    let (killed, output) = try dieInTheUpdate(book.url)

    #expect(killed, "seed \(seed): the probe was not killed: \(output)")
    #expect(output.contains("in the update"), "seed \(seed): \(output)")
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url), "seed \(seed)")
    #expect(try DatabaseStack.check(fileAt: book.url, schema: TestSupport.schemaSource) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: TestSupport.schemaSource)
        == [
          "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
          "0009_credit_and_allocation",
          "0010_scenarios",
          "0011_travel",
        ], "seed \(seed)")

    let made = UUID()
    let context = MigrationContext(mainAccountName: "Основной счёт", makeId: { made })
    let restarted = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: context)
    let direct = try DatabaseStack(url: twin, schema: TestSupport.schemaSource, context: context)
    #expect(restarted.applied.dataSteps == direct.applied.dataSteps, "seed \(seed)")
    let left = try restarted.writer.read { db in try ExactTables.read(db) }
    let right = try direct.writer.read { db in try ExactTables.read(db) }
    try restarted.close()
    try direct.close()
    #expect(left == right, "seed \(seed)")
  }
}
