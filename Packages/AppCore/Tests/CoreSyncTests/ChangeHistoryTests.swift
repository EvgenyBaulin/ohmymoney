import Foundation
import Testing

@testable import CoreSync

// Synthetic data only.

private func at(_ s: Int) -> SyncInstant {
  SyncInstant(String(format: "2026-11-01T12:%02d:%02dZ", s / 60, s % 60))!
}

private func line(
  _ seq: Int64, _ table: String, _ uuid: String, _ op: SyncOp, _ time: Int,
  device: String = "mac", name: String = "MacBook", _ fields: [String: SyncValue]
) -> ChangeRecord {
  ChangeRecord(
    seq: seq, key: RecordKey(table: table, uuid: uuid), op: op, at: at(time), deviceId: device,
    deviceName: name, fields: fields)
}

private func op(_ description: String, deleted: Bool = false) -> [String: SyncValue] {
  var f: [String: SyncValue] = [
    "description": .string(description), "updated_at": .string("t\(description)"),
  ]
  f["deleted_at"] = deleted ? .string("2026-11-01T12:00:00Z") : .null
  return f
}

private func part(
  _ amount: Int64, owner: String = "op", category: String = "food"
)
  -> [String: SyncValue]
{
  ["transaction_id": .string(owner), "amount_e4": .int(amount), "category_id": .string(category)]
}

@Suite("History of an operation")
struct ChangeHistoryTests {
  @Test func aNewOperationIsOneEventWithoutFieldNoise() {
    let records = [
      line(1, "transaction_parts", "p1", .created, 1, part(2_500_000)),
      line(2, "transactions", "op", .created, 1, op("coffee")),
    ]
    let events = ChangeHistory.events(forOperation: "op", records: records)
    #expect(events.count == 1)
    #expect(events[0].kind == .created)
    #expect(events[0].changes.isEmpty)
    #expect(events[0].deviceName == "MacBook")
  }

  @Test func anEditOnAnotherDeviceNamesTheDeviceAndTheFields() throws {
    let records = [
      line(1, "transactions", "op", .created, 1, op("coffee")),
      line(2, "transaction_parts", "p1", .created, 1, part(2_500_000)),
      line(
        3, "transactions", "op", .updated, 30, device: "phone", name: "iPhone", op("latte")),
      line(
        4, "transaction_parts", "p1", .updated, 30, device: "phone", name: "iPhone",
        part(3_000_000)),
    ]
    let events = ChangeHistory.events(forOperation: "op", records: records)
    #expect(events.map(\.kind) == [.edited, .created])
    let edit = events[0]
    #expect(edit.deviceId == "phone")
    #expect(edit.deviceName == "iPhone")
    #expect(
      edit.changes.contains(
        FieldChange(
          scope: .operation, field: "description",
          change: .value(before: .string("coffee"), after: .string("latte")))))
    #expect(
      edit.changes.contains(
        FieldChange(
          scope: .part("p1"), field: "amount_e4",
          change: .value(before: .int(2_500_000), after: .int(3_000_000)))))
    // `updated_at` changes with every write and is never shown.
    #expect(!edit.changes.contains { $0.field == "updated_at" })
  }

  @Test func aSplitShowsTheNewPartAndTheRemovedOne() {
    let records = [
      line(1, "transactions", "op", .created, 1, op("shop")),
      line(2, "transaction_parts", "p1", .created, 1, part(3_000_000)),
      line(3, "transaction_parts", "p1", .deleted, 9, [:]),
      line(4, "transaction_parts", "p2", .created, 9, part(2_000_000)),
      line(5, "transaction_parts", "p3", .created, 9, part(1_000_000, category: "home")),
    ]
    let events = ChangeHistory.events(forOperation: "op", records: records)
    #expect(events.count == 2)
    #expect(events[0].kind == .edited)
    #expect(
      events[0].changes.map(\.change) == [.partRemoved, .partAdded, .partAdded])
  }

  @Test func deleteAndRestoreAreTheirOwnKinds() {
    let records = [
      line(1, "transactions", "op", .created, 1, op("coffee")),
      line(2, "transactions", "op", .deleted, 5, op("coffee", deleted: true)),
      line(3, "transactions", "op", .updated, 9, device: "phone", name: "iPhone", op("tea")),
    ]
    let events = ChangeHistory.events(forOperation: "op", records: records)
    #expect(events.map(\.kind) == [.restored, .deleted, .created])
    #expect(events[0].deviceName == "iPhone")
    #expect(events[0].changes.map(\.field) == ["description"])
  }

  @Test func linesOfOtherRowsAreIgnored() {
    let records = [
      line(1, "transactions", "op", .created, 1, op("coffee")),
      line(2, "transactions", "other", .updated, 5, op("x")),
      line(3, "transaction_parts", "q", .updated, 5, part(1, owner: "other")),
      line(4, "categories", "op", .updated, 5, ["name": .string("op")]),
    ]
    #expect(ChangeHistory.events(forOperation: "op", records: records).count == 1)
  }

  @Test func whatTheNextLineSays() {
    let last = line(1, "transactions", "op", .created, 1, op("coffee"))
    #expect(ChangeHistory.op(current: op("coffee"), last: nil) == .created)
    #expect(ChangeHistory.op(current: op("coffee"), last: last) == nil)
    #expect(ChangeHistory.op(current: op("tea"), last: last) == .updated)
    #expect(ChangeHistory.op(current: op("coffee", deleted: true), last: last) == .deleted)
    #expect(ChangeHistory.op(current: nil, last: last) == .deleted)
    #expect(ChangeHistory.op(current: nil, last: nil) == nil)
    let gone = line(2, "transactions", "op", .deleted, 2, [:])
    #expect(ChangeHistory.op(current: nil, last: gone) == nil)
    #expect(ChangeHistory.op(current: op("coffee"), last: gone) == .updated)
  }

  @Test func theExchangeMemoryBecomesJournalLinesWithDeviceNames() throws {
    var s = SyncState()
    let f1 = JournalFile(
      deviceId: "mac", deviceName: "MacBook", sequence: 0,
      entries: [
        SyncEntry(
          table: "transactions", uuid: "op", op: .created, fields: op("coffee"), updatedAt: at(1))
      ])
    let f2 = JournalFile(
      deviceId: "phone", deviceName: "iPhone", sequence: 0,
      entries: [
        SyncEntry(
          table: "transactions", uuid: "op", op: .updated, fields: op("tea"), updatedAt: at(4),
          base: VersionStamp(updatedAt: at(1), deviceId: "mac"))
      ])
    for f in [f2, f1] { try s.ingest(f, name: f.name, bytes: try JournalCoder.encode(f)) }
    #expect(s.deviceName(of: "phone") == "iPhone")
    #expect(s.deviceName(of: "tablet") == nil)
    let records = ChangeHistory.records(from: s)
    #expect(records.map(\.seq) == [1, 2])
    #expect(records.map(\.deviceName) == ["MacBook", "iPhone"])
    let events = ChangeHistory.events(forOperation: "op", records: records)
    #expect(events.map(\.kind) == [.edited, .created])
  }

  @Test func aStateSavedBeforeDeviceNamesStillLoads() throws {
    // The body of `sync_state` as builds before names were kept wrote it.
    let old = #"{"files":{},"versions":[]}"#
    let s = try JSONDecoder().decode(SyncState.self, from: Data(old.utf8))
    #expect(s.deviceName(of: "mac") == nil)
    #expect(s.appliedFileNames.isEmpty)
  }

  @Test func theNewestFileOfADeviceNamesIt() throws {
    var s = SyncState()
    for (sequence, name) in [(1, "New name"), (0, "Old name")] {
      let f = JournalFile(
        deviceId: "mac", deviceName: name, sequence: sequence,
        entries: [
          SyncEntry(
            table: "transactions", uuid: "op\(sequence)", op: .created, fields: [:],
            updatedAt: at(sequence))
        ])
      try s.ingest(f, name: f.name, bytes: try JournalCoder.encode(f))
    }
    #expect(s.deviceName(of: "mac") == "New name")
  }
}
