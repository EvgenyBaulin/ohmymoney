import Foundation
import Testing

@testable import CoreSync

// Synthetic data only.

private func at(_ s: Int) -> SyncInstant {
  SyncInstant(String(format: "2026-11-01T09:%02d:%02dZ", s / 60, s % 60))!
}

private func stamp(_ time: Int, _ device: String) -> VersionStamp {
  VersionStamp(updatedAt: at(time), deviceId: device)
}

private func entry(
  _ uuid: String, _ op: SyncOp, _ fields: [String: SyncValue], _ time: Int,
  table: String = "transactions", base: VersionStamp? = nil
) -> SyncEntry {
  SyncEntry(table: table, uuid: uuid, op: op, fields: fields, updatedAt: at(time), base: base)
}

private func file(_ device: String, _ sequence: Int, _ entries: [SyncEntry]) -> JournalFile {
  JournalFile(
    deviceId: device, deviceName: device.uppercased(), sequence: sequence, entries: entries)
}

private func state(_ files: [JournalFile]) throws -> SyncState {
  var s = SyncState()
  for f in files { try s.ingest(f, name: f.name, bytes: try JournalCoder.encode(f)) }
  return s
}

private let deleted: [String: SyncValue] = [
  "description": .string("coffee"), "deleted_at": .string("2026-11-01T09:00:09Z"),
]

/// The owner's rule for a delete against an edit made on another device: the delete stands
/// when nobody edited the operation after it; an edit made after the delete brings the
/// operation back. Neither waits in the list of conflicts, and the order the files arrive in
/// changes nothing.
@Suite("Delete against edit")
struct DeleteAgainstEditTests {
  private let key = RecordKey(table: "transactions", uuid: "op")
  private let created = file(
    "mac", 0, [entry("op", .created, ["description": .string("coffee")], 1)])

  @Test func aDeleteMadeAfterTheEditStandsOnBothDevices() throws {
    let edit = file(
      "mac", 1, [entry("op", .updated, ["description": .string("tea")], 5, base: stamp(1, "mac"))])
    let delete = file("phone", 0, [entry("op", .deleted, deleted, 9, base: stamp(1, "mac"))])
    let s = try state([created, edit, delete])
    let record = try #require(s.resolve(key))
    #expect(record.isDeleted)
    #expect(record.contested.isEmpty)
    #expect(record.disposition(ownDeviceId: "mac") == .applyWinner)
    #expect(record.disposition(ownDeviceId: "phone") == .keepLocal)
    #expect(s.openConflicts(ownDeviceId: "mac").isEmpty)
    #expect(s.openConflicts(ownDeviceId: "phone").isEmpty)
    #expect(s.conflicts().isEmpty)
    // The edit is not lost: it stays a version of the row, for the history.
    #expect(record.conflicts.map(\.stamp) == [stamp(5, "mac")])
  }

  @Test func anEditMadeAfterTheDeleteBringsTheOperationBack() throws {
    let delete = file("phone", 0, [entry("op", .deleted, deleted, 5, base: stamp(1, "mac"))])
    let edit = file(
      "mac", 1, [entry("op", .updated, ["description": .string("tea")], 9, base: stamp(1, "mac"))])
    let s = try state([created, delete, edit])
    let record = try #require(s.resolve(key))
    #expect(!record.isDeleted)
    #expect(record.fields["description"] == .string("tea"))
    #expect(record.disposition(ownDeviceId: "phone") == .applyWinner)
    #expect(record.disposition(ownDeviceId: "mac") == .keepLocal)
    #expect(s.openConflicts(ownDeviceId: "phone").isEmpty)
    #expect(s.openConflicts(ownDeviceId: "mac").isEmpty)
  }

  @Test func twoEditsMadeApartStillWaitBesideAnEarlierDelete() throws {
    let delete = file("tablet", 0, [entry("op", .deleted, deleted, 3, base: stamp(1, "mac"))])
    let mine = file(
      "mac", 1, [entry("op", .updated, ["description": .string("tea")], 6, base: stamp(1, "mac"))])
    let theirs = file(
      "phone", 0,
      [entry("op", .updated, ["description": .string("juice")], 8, base: stamp(1, "mac"))])
    let s = try state([created, delete, mine, theirs])
    let record = try #require(s.resolve(key))
    #expect(record.contested.map(\.stamp) == [stamp(6, "mac")])
    #expect(record.disposition(ownDeviceId: "mac") == .conflict)
    let conflict = try #require(s.openConflicts(ownDeviceId: "mac").first)
    #expect(conflict.differingFields == ["description"])
    #expect(!conflict.differingFields.contains("deleted"))
  }

  /// An operation is the row and its parts. Deleting it marks only the operation; an edit on
  /// another device made later rewrites the operation and a part. The parts the delete never
  /// touched stay, so the operation comes back whole.
  @Test func anOperationWithPartsComesBackWholeAfterALaterEdit() throws {
    let part1: [String: SyncValue] = [
      "transaction_id": .string("op"), "amount_e4": .int(2_000_000), "category_id": .string("food"),
    ]
    let part2: [String: SyncValue] = [
      "transaction_id": .string("op"), "amount_e4": .int(1_000_000), "category_id": .string("home"),
    ]
    let start = file(
      "mac", 0,
      [
        entry("op", .created, ["description": .string("shop")], 1),
        entry("p1", .created, part1, 1, table: "transaction_parts"),
        entry("p2", .created, part2, 1, table: "transaction_parts"),
      ])
    let delete = file(
      "mac", 1,
      [
        entry(
          "op", .deleted, ["description": .string("shop"), "deleted_at": .string("x")], 4,
          base: stamp(1, "mac"))
      ])
    var edited = part2
    edited["amount_e4"] = .int(1_500_000)
    let edit = file(
      "phone", 0,
      [
        entry("op", .updated, ["description": .string("shop!")], 7, base: stamp(1, "mac")),
        entry("p2", .updated, edited, 7, table: "transaction_parts", base: stamp(1, "mac")),
      ])
    let orders = [[start, delete, edit], [edit, delete, start], [delete, edit, start]]
    for order in orders {
      let s = try state(order)
      let op = try #require(s.resolve(key))
      #expect(!op.isDeleted)
      #expect(op.fields["description"] == .string("shop!"))
      let p1 = try #require(s.resolve(RecordKey(table: "transaction_parts", uuid: "p1")))
      let p2 = try #require(s.resolve(RecordKey(table: "transaction_parts", uuid: "p2")))
      #expect(!p1.isDeleted && !p2.isDeleted)
      #expect(p2.fields["amount_e4"] == .int(1_500_000))
      #expect(s.openConflicts(ownDeviceId: "mac").isEmpty)
      #expect(s.openConflicts(ownDeviceId: "phone").isEmpty)
    }
  }

  /// Two devices, the same edits and deletes in any order of files: one and the same state,
  /// and the same answer for every row on each device.
  @Test func anyOrderOfFilesGivesTheSameBooks() throws {
    let files = [
      created,
      file(
        "mac", 1,
        [entry("op", .updated, ["description": .string("a")], 4, base: stamp(1, "mac"))]),
      file("phone", 0, [entry("op", .deleted, deleted, 6, base: stamp(1, "mac"))]),
      file(
        "phone", 1,
        [entry("op", .updated, ["description": .string("b")], 11, base: stamp(6, "phone"))]),
      file("mac", 2, [entry("op", .deleted, deleted, 9, base: stamp(4, "mac"))]),
    ]
    let reference = try state(files)
    let expected = try #require(reference.resolve(key))
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<30 {
      let s = try state(files.shuffled(using: &rng))
      #expect(s == reference)
      #expect(s.resolve(key) == expected)
      #expect(
        s.resolve(key)?.disposition(ownDeviceId: "mac") == expected.disposition(ownDeviceId: "mac"))
    }
    // The phone's edit at 11 came after both deletes: the operation lives.
    #expect(!expected.isDeleted)
    #expect(expected.fields["description"] == .string("b"))
  }
}

/// A row the app computes (a reconciliation difference) goes into the journal like any other.
/// Computed the same on two devices, there is nothing to choose; computed differently while one
/// was offline, it waits in the list like any other row, out of the sums.
@Suite("Computed rows")
struct ComputedRowTests {
  private let key = RecordKey(table: "transactions", uuid: "diff")

  private func difference(_ amount: Int64) -> [String: SyncValue] {
    ["external_id": .string("reconcile:r1:b1"), "amount_e4": .int(amount)]
  }

  @Test func theRoleOfARowFollowsItsExternalKey() {
    #expect(SyncRowRole.of(table: "transactions", fields: difference(1)) == .computed)
    #expect(
      SyncRowRole.of(table: "transactions", fields: ["external_id": .string("npd:2026-10")])
        == .computed)
    #expect(
      SyncRowRole.of(table: "transactions", fields: ["external_id": .string("sched:x:2026-10-01")])
        == .owner)
    #expect(SyncRowRole.of(table: "transactions", fields: ["description": .string("x")]) == .owner)
    #expect(SyncRowRole.of(table: "categories", fields: difference(1)) == .owner)
  }

  @Test func aDifferenceComputedDifferentlyOfflineWaitsForTheOwner() throws {
    let base = stamp(1, "mac")
    let s = try state([
      file("mac", 0, [entry("diff", .created, difference(-50_000), 1)]),
      file("mac", 1, [entry("diff", .updated, difference(-80_000), 5, base: base)]),
      file("phone", 0, [entry("diff", .updated, difference(-60_000), 7, base: base)]),
    ])
    let conflict = try #require(s.openConflicts(ownDeviceId: "mac").first)
    #expect(conflict.key == key)
    #expect(conflict.differingFields == ["amount_e4"])
    #expect(SyncRowRole.of(table: key.table, fields: conflict.theirs.fields) == .computed)
    // Out of the sums: neither device takes the other's figure until the owner chooses.
    #expect(s.resolve(key)?.disposition(ownDeviceId: "mac") == .conflict)
    #expect(s.resolve(key)?.disposition(ownDeviceId: "phone") == .conflict)
  }

  @Test func aDifferenceComputedTheSameHasNoDifferingField() throws {
    let base = stamp(1, "mac")
    let s = try state([
      file("mac", 0, [entry("diff", .created, difference(-50_000), 1)]),
      file("mac", 1, [entry("diff", .updated, difference(-80_000), 5, base: base)]),
      file("phone", 0, [entry("diff", .updated, difference(-80_000), 7, base: base)]),
    ])
    // The exchange answers such a pair itself (the device with the smaller id settles it).
    let conflict = try #require(s.openConflicts(ownDeviceId: "mac").first)
    #expect(conflict.differingFields.isEmpty)
  }
}
