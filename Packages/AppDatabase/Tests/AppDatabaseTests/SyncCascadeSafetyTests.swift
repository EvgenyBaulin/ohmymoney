import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Incoming deletions do not silently discard pending dependent edits")
struct SyncCascadeSafetyTests {
  @Test func aRemoteAssetDeletionReachesAPendingLocalValuationThroughItsCascade() throws {
    let device = try TestDevice("phone")
    try device.sql(
      """
      INSERT INTO assets (id, name) VALUES ('asset', 'Synthetic asset');
      INSERT INTO asset_valuations (id, asset_id, day, value_e4)
      VALUES ('valuation', 'asset', '2026-11-01', 10000);
      DELETE FROM sync_outbox;
      UPDATE asset_valuations SET value_e4 = 20000 WHERE id = 'valuation';
      """)
    let at = try #require(SyncInstant("2026-11-02T10:00:00Z"))
    let file = JournalFile(
      deviceId: "mac", deviceName: "Synthetic Mac", sequence: 0,
      entries: [
        SyncEntry(table: "assets", uuid: "asset", op: .deleted, fields: [:], updatedAt: at),
        SyncEntry(
          table: "asset_valuations", uuid: "valuation", op: .deleted, fields: [:], updatedAt: at),
      ])
    var state = SyncState()
    _ = try state.ingest(file, name: file.name, bytes: JournalCoder.encode(file))
    let records = try file.entries.map { try #require(state.resolve($0.key)) }
    let applier = DatabaseRecordApplier(writer: device.stack.writer, ownDeviceId: "phone")
    try applier.apply(records)
    let value = try device.stack.writer.read {
      try Int64.fetchOne($0, sql: "SELECT value_e4 FROM asset_valuations WHERE id = 'valuation'")
    }
    #expect(applier.takeTally().deferred == 1)
    withKnownIssue("Decide whether a parent deletion waits for pending edits of its dependents") {
      #expect(
        value == 20000,
        "The pending local edit must remain available for exchange or conflict resolution")
    }
  }
}
