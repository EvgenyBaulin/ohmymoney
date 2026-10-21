import Foundation
import Testing

@testable import CoreSync

// Synthetic data only.

private func at(_ s: Int) -> SyncInstant {
  SyncInstant(String(format: "2026-10-21T10:%02d:%02dZ", s / 60, s % 60))!
}

private func entry(
  _ uuid: String, _ op: SyncOp, _ note: String, _ time: Int, base: VersionStamp? = nil,
  table: String = "transactions", amount: Int64 = 1_000_000
) -> SyncEntry {
  SyncEntry(
    table: table, uuid: uuid, op: op,
    fields: ["note": .string(note), "amount_e4": .int(amount), "flag": .bool(true), "x": .null],
    updatedAt: at(time), base: base)
}

private func file(
  _ device: String, _ seq: Int, _ entries: [SyncEntry]
) -> (
  JournalFile, String, Data
) {
  let f = JournalFile(
    deviceId: device, deviceName: "Name \(device)", sequence: seq, entries: entries)
  return (f, f.name, try! JournalCoder.encode(f))
}

private func stamp(_ time: Int, _ device: String) -> VersionStamp {
  VersionStamp(updatedAt: at(time), deviceId: device)
}

private func state(from files: [(JournalFile, String, Data)]) throws -> SyncState {
  var s = SyncState()
  for (f, n, d) in files { try s.ingest(f, name: n, bytes: d) }
  return s
}

private func permutations<T>(_ a: [T]) -> [[T]] {
  if a.count <= 1 { return [a] }
  var out: [[T]] = []
  for i in a.indices {
    var rest = a
    let x = rest.remove(at: i)
    for p in permutations(rest) { out.append([x] + p) }
  }
  return out
}

private struct SplitMix {
  var s: UInt64
  mutating func next() -> UInt64 {
    s &+= 0x9E37_79B9_7F4A_7C15
    var z = s
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func shuffle<T>(_ a: inout [T]) {
    guard a.count > 1 else { return }
    for i in stride(from: a.count - 1, to: 0, by: -1) {
      a.swapAt(i, Int(next() % UInt64(i + 1)))
    }
  }
}

@Suite struct JournalFormatTests {
  @Test func roundTripKeepsEverything() throws {
    let (f, name, data) = file("dev-a", 3, [entry("u1", .created, "кофе", 5, amount: -12_345_678)])
    let back = try JournalCoder.decode(data)
    #expect(back == f)
    #expect(name == "journal-dev-a-0000000003.json")
    #expect(SyncFormat.parse(fileName: name)! == ("dev-a", 3))
    #expect(String(decoding: data, as: UTF8.self).hasSuffix("}"))
  }

  @Test func namesThatAreNotJournalsAreIgnored() {
    for n in [
      ".writing-journal-a-0000000001.json", "journal-a-1.json", "notes.txt",
      "journal--0000000001.json", "journal-a-000000000x.json",
    ] { #expect(SyncFormat.parse(fileName: n) == nil) }
  }

  @Test func newerFormatVersionIsARefusalNotACrash() {
    let json = #"{"formatVersion":99,"somethingNew":[1,2,3]}"#
    #expect(throws: SyncError.unsupportedFormatVersion(found: 99, supported: 1)) {
      try JournalCoder.decode(Data(json.utf8))
    }
  }

  @Test func damagedContentIsMalformed() {
    let cases = [
      "", "not json", "{}", #"{"formatVersion":0}"#,
      #"{"formatVersion":1,"deviceId":"a","deviceName":"n","sequence":0,"entries":[{"table":"t","uuid":"u","op":"created","fields":{"a":1.5},"updatedAt":"2026-10-21T10:00:00Z"}]}"#,
      #"{"formatVersion":1,"deviceId":"a","deviceName":"n","sequence":0,"entries":[{"table":"t","uuid":"u","op":"created","fields":{},"updatedAt":"yesterday"}]}"#,
      #"{"formatVersion":1,"deviceId":"a b","deviceName":"n","sequence":0,"entries":[]}"#,
      #"{"formatVersion":1,"deviceId":"a","deviceName":"n","sequence":0,"entries":[{"table":"T!","uuid":"u","op":"created","fields":{},"updatedAt":"2026-10-21T10:00:00Z"}]}"#,
    ]
    for c in cases {
      #expect(throws: SyncError.malformed) { try JournalCoder.decode(Data(c.utf8)) }
    }
  }

  @Test func instantsAreFixedWidthUTC() {
    #expect(SyncInstant("2026-10-21T10:00:00Z") != nil)
    #expect(SyncInstant("2026-10-21T10:00:00+03:00") == nil)
    #expect(SyncInstant("2026-10-21 10:00:00Z") == nil)
    #expect(at(59) < at(60))
  }

  @Test func codecIsTheExtensionPoint() throws {
    struct Reverse: PayloadCodec {
      func encode(_ d: Data) throws -> Data { Data(d.reversed()) }
      func decode(_ d: Data) throws -> Data { Data(d.reversed()) }
    }
    let f = JournalFile(
      deviceId: "a", deviceName: "n", sequence: 0, entries: [entry("u", .created, "x", 1)])
    let stored = try JournalCoder.encode(f, codec: Reverse())
    #expect(try JournalCoder.decode(stored, codec: Reverse()) == f)
    #expect(throws: SyncError.malformed) { try JournalCoder.decode(stored) }
  }
}

@Suite struct TornFileTests {
  @Test func everyProperPrefixIsRefused() throws {
    let (_, _, data) = file(
      "dev-a", 0, [entry("u1", .created, "a", 1), entry("u2", .deleted, "b", 2)])
    for cut in 0..<data.count {
      #expect(throws: SyncError.self) { try JournalCoder.decode(data.prefix(cut)) }
    }
    #expect((try? JournalCoder.decode(data)) != nil)
  }

  @Test func aTornFileIsNeverAppliedNorRemembered() throws {
    let (f, name, data) = file("dev-a", 0, [entry("u1", .created, "a", 1)])
    let folder = InMemoryFolder()
    let applier = InMemoryApplier()
    let store = InMemoryStateStore()
    let run = SyncRun(ownDeviceId: "dev-me")
    for cut in 0..<data.count {
      folder.plant(name: name, data: data.prefix(cut))
      let report = try run.run(folder: folder, applier: applier, store: store)
      #expect(report.filesApplied == 0)
      #expect(report.filesRefused[name] != nil)
      #expect(applier.records.isEmpty)
      #expect(try store.load().appliedFileNames.isEmpty)
    }
    // The writer finishes: the next run picks the file up.
    folder.plant(name: name, data: data)
    let report = try run.run(folder: folder, applier: applier, store: store)
    #expect(report.filesApplied == 1)
    #expect(applier.records[f.entries[0].key] != nil)
  }

  @Test func theWriterKeepsAHalfFileUnderATemporaryName() throws {
    final class CrashingFolder: JournalFolder, @unchecked Sendable {
      let inner = InMemoryFolder()
      func listNames() throws -> [String] { try inner.listNames() }
      func read(name: String) throws -> Data { try inner.read(name: name) }
      func put(temporaryName: String, data: Data) throws {
        try inner.put(temporaryName: temporaryName, data: data.prefix(data.count / 2))
      }
      func rename(temporaryName: String, to name: String) throws { throw SyncError.malformed }
    }
    let folder = CrashingFolder()
    let writer = JournalWriter(deviceId: "dev-a", deviceName: "A")
    #expect(throws: SyncError.malformed) {
      try writer.write([entry("u", .created, "x", 1)], to: folder)
    }
    let applier = InMemoryApplier()
    let report = try SyncRun(ownDeviceId: "me").run(
      folder: folder, applier: applier, store: InMemoryStateStore())
    #expect(report.filesApplied == 0 && report.filesRefused.isEmpty)
    #expect(applier.records.isEmpty)
  }
}

@Suite struct IdempotenceTests {
  @Test func applyingTwiceIsApplyingOnce() throws {
    let files = [
      file("dev-a", 0, [entry("u1", .created, "a", 1)]),
      file("dev-b", 0, [entry("u1", .updated, "b", 2, base: stamp(1, "dev-a"))]),
    ]
    let once = try state(from: files)
    var twice = once
    for (f, n, d) in files {
      let changed = try twice.ingest(f, name: n, bytes: d)
      #expect(changed.isEmpty)
    }
    #expect(twice == once)
  }

  @Test func theSameNameWithOtherBytesIsRefused() throws {
    let (f, n, d) = file("dev-a", 0, [entry("u1", .created, "a", 1)])
    var s = SyncState()
    try s.ingest(f, name: n, bytes: d)
    #expect(throws: SyncError.fileChanged(name: n)) {
      try s.ingest(f, name: n, bytes: d + Data(" ".utf8))
    }
  }

  @Test func aFileWhoseNameLiesIsRefused() {
    let (f, _, d) = file("dev-a", 0, [entry("u1", .created, "a", 1)])
    var s = SyncState()
    #expect(throws: SyncError.nameMismatch) {
      try s.ingest(f, name: "journal-dev-b-0000000000.json", bytes: d)
    }
    #expect(s.appliedFileNames.isEmpty)
  }

  private func smallSet() -> [(JournalFile, String, Data)] {
    [
      file("dev-a", 0, [entry("u1", .created, "a1", 1), entry("u2", .created, "a2", 2)]),
      file("dev-a", 1, [entry("u1", .updated, "a3", 5, base: stamp(1, "dev-a"))]),
      file("dev-b", 0, [entry("u1", .updated, "b1", 4, base: stamp(1, "dev-a"))]),
      file("dev-b", 1, [entry("u2", .deleted, "b2", 6, base: stamp(2, "dev-a"))]),
      file("dev-c", 0, [entry("u3", .created, "c", 3, table: "places")]),
    ]
  }

  @Test func everyPermutationOfASmallSetGivesTheSameState() throws {
    let files = smallSet()
    let reference = try state(from: files)
    var count = 0
    for order in permutations(files) {
      let s = try state(from: order)
      #expect(s == reference)
      #expect(s.allRecords() == reference.allRecords())
      count += 1
    }
    #expect(count == 120)
  }

  @Test func randomOrdersOfALargeSetGiveTheSameState() throws {
    var rng = SplitMix(s: 42)
    var files: [(JournalFile, String, Data)] = []
    for device in ["dev-a", "dev-b", "dev-c"] {
      for seq in 0..<20 {
        var entries: [SyncEntry] = []
        for _ in 0..<5 {
          let row = "u\(rng.next() % 12)"
          let op: SyncOp = [.created, .updated, .deleted][Int(rng.next() % 3)]
          let t = Int(rng.next() % 3000)
          let base: VersionStamp? =
            rng.next() % 2 == 0
            ? stamp(Int(rng.next() % 3000), device == "dev-a" ? "dev-b" : "dev-a") : nil
          entries.append(entry(row, op, "n\(rng.next() % 100)", t, base: base))
        }
        files.append(file(device, seq, entries))
      }
    }
    let reference = try state(from: files)
    for _ in 0..<40 {
      var order = files
      rng.shuffle(&order)
      let s = try state(from: order)
      #expect(s == reference)
    }
  }

  @Test func deleteBeforeCreateDoesNotLoseTheRecord() throws {
    let create = file("dev-a", 0, [entry("u1", .created, "x", 1)])
    let delete = file("dev-b", 0, [entry("u1", .deleted, "x", 9, base: stamp(1, "dev-a"))])
    for order in [[create, delete], [delete, create]] {
      let s = try state(from: order)
      let r = try #require(s.resolve(RecordKey(table: "transactions", uuid: "u1")))
      #expect(r.isDeleted)  // kept as a tombstone row, not forgotten
      #expect(r.conflicts.isEmpty)
    }
    // A delete that is older than a later update loses to it: the row lives.
    let late = file("dev-a", 1, [entry("u1", .updated, "back", 20, base: stamp(9, "dev-b"))])
    let s = try state(from: [late, delete, create])
    #expect(s.resolve(RecordKey(table: "transactions", uuid: "u1"))!.isDeleted == false)
  }
}

@Suite struct ConflictTests {
  let key = RecordKey(table: "transactions", uuid: "u1")

  @Test func aFollowingEditIsNotAConflict() throws {
    let s = try state(from: [
      file("dev-a", 0, [entry("u1", .created, "1", 1)]),
      file("dev-b", 0, [entry("u1", .updated, "2", 2, base: stamp(1, "dev-a"))]),
      file("dev-a", 1, [entry("u1", .updated, "3", 3, base: stamp(2, "dev-b"))]),
    ])
    let r = try #require(s.resolve(key))
    #expect(r.fields["note"] == .string("3"))
    #expect(r.conflicts.isEmpty)
    #expect(s.conflicts().isEmpty)
  }

  @Test func apartEditsKeepTheLoserInTheConflictList() throws {
    let s = try state(from: [
      file("dev-a", 0, [entry("u1", .created, "0", 1)]),
      file("dev-a", 1, [entry("u1", .updated, "mac", 5, base: stamp(1, "dev-a"))]),
      file("dev-b", 0, [entry("u1", .updated, "phone", 8, base: stamp(1, "dev-a"))]),
    ])
    let r = try #require(s.resolve(key))
    #expect(r.fields["note"] == .string("phone"))
    #expect(r.conflicts.count == 1)
    #expect(r.conflicts[0].fields["note"] == .string("mac"))
    #expect(r.conflicts[0].stamp.deviceId == "dev-a")
  }

  @Test func equalStampsAreBrokenByDeviceId() throws {
    let files = [
      file("dev-a", 0, [entry("u1", .created, "from a", 7)]),
      file("dev-b", 0, [entry("u1", .created, "from b", 7)]),
    ]
    for order in permutations(files) {
      let r = try #require(try state(from: order).resolve(key))
      #expect(r.winner.stamp.deviceId == "dev-b")
      #expect(r.conflicts.map(\.stamp.deviceId) == ["dev-a"])
    }
  }

  @Test func aSlowClockLosesButIsNotLost() throws {
    // The phone's clock is ten minutes behind: its real later edit carries an earlier stamp.
    let s = try state(from: [
      file("dev-a", 0, [entry("u1", .created, "start", 600)]),
      file(
        "dev-b", 0,
        [entry("u1", .updated, "later but stamped early", 30, base: stamp(600, "dev-a"))]),
    ])
    let r = try #require(s.resolve(key))
    #expect(r.winner.stamp.deviceId == "dev-a")
    #expect(r.conflicts.count == 1)
    #expect(r.conflicts[0].fields["note"] == .string("later but stamped early"))
  }

  @Test func theLoserOfAnEarlierRoundStaysVisibleThroughLaterEdits() throws {
    // b's edit was overruled by a, then a edited again on top of its own: b's is still unseen.
    let s = try state(from: [
      file(
        "dev-a", 0,
        [entry("u1", .created, "0", 1), entry("u1", .updated, "a2", 6, base: stamp(1, "dev-a"))]),
      file("dev-b", 0, [entry("u1", .updated, "b", 4, base: stamp(1, "dev-a"))]),
      file("dev-a", 1, [entry("u1", .updated, "a3", 9, base: stamp(6, "dev-a"))]),
    ])
    let r = try #require(s.resolve(key))
    #expect(r.fields["note"] == .string("a3"))
    #expect(r.conflicts.map { $0.fields["note"] } == [.string("b")])
  }
}

@Suite struct SyncRunTests {
  let mine = "dev-me"

  @Test func writerNumbersFilesAndHidesTemporaryOnes() throws {
    let folder = InMemoryFolder()
    let writer = JournalWriter(deviceId: mine, deviceName: "Mac")
    #expect(try writer.write([], to: folder) == nil)
    #expect(
      try writer.write([entry("u", .created, "x", 1)], to: folder)
        == "journal-dev-me-0000000000.json")
    #expect(
      try writer.write([entry("u", .updated, "y", 2)], to: folder)
        == "journal-dev-me-0000000001.json")
    folder.plant(name: ".writing-journal-dev-me-0000000002.json", data: Data("{".utf8))
    #expect(
      try writer.write([entry("u", .updated, "z", 3)], to: folder)
        == "journal-dev-me-0000000002.json")
    // The stray temporary file did not count as sequence 2's predecessor and was replaced.
    #expect(try folder.listNames().filter { $0.hasPrefix(".writing-") }.isEmpty)
  }

  @Test func appliesOthersAndSkipsOwnRowsButKeepsTheirHistory() throws {
    let folder = InMemoryFolder()
    try JournalWriter(deviceId: "dev-phone", deviceName: "Phone").write(
      [entry("u1", .created, "p", 1), entry("u2", .created, "q", 2)], to: folder)
    try JournalWriter(deviceId: mine, deviceName: "Mac").write(
      [entry("u2", .updated, "m", 9, base: stamp(2, "dev-phone"))], to: folder)
    let applier = InMemoryApplier()
    let store = InMemoryStateStore()
    let report = try SyncRun(ownDeviceId: mine).run(folder: folder, applier: applier, store: store)
    #expect(report.filesApplied == 2 && report.recordsChanged == 1)
    #expect(applier.records.keys.map(\.uuid) == ["u1"])
    // A second run does nothing.
    let again = try SyncRun(ownDeviceId: mine).run(folder: folder, applier: applier, store: store)
    #expect(again.filesApplied == 0 && again.filesAlreadyApplied == 2 && again.recordsChanged == 0)
  }

  @Test func aFailingApplierMarksNothingAndTheRetryDoesTheWork() throws {
    let folder = InMemoryFolder()
    try JournalWriter(deviceId: "dev-phone", deviceName: "P").write(
      [entry("u1", .created, "p", 1)], to: folder)
    let applier = InMemoryApplier()
    let store = InMemoryStateStore()
    applier.failNext()
    #expect(throws: SyncError.self) {
      try SyncRun(ownDeviceId: mine).run(folder: folder, applier: applier, store: store)
    }
    #expect(try store.load().appliedFileNames.isEmpty)
    let report = try SyncRun(ownDeviceId: mine).run(folder: folder, applier: applier, store: store)
    #expect(report.filesApplied == 1 && applier.records.count == 1)
  }

  @Test func aNewerFileIsReportedAndTheRestStillApplies() throws {
    let folder = InMemoryFolder()
    try JournalWriter(deviceId: "dev-phone", deviceName: "P").write(
      [entry("u1", .created, "p", 1)], to: folder)
    folder.plant(name: "journal-dev-new-0000000000.json", data: Data(#"{"formatVersion":2}"#.utf8))
    let report = try SyncRun(ownDeviceId: mine).run(
      folder: folder, applier: InMemoryApplier(), store: InMemoryStateStore())
    #expect(report.filesApplied == 1)
    #expect(
      report.filesRefused["journal-dev-new-0000000000.json"]
        == .unsupportedFormatVersion(found: 2, supported: 1))
  }

  @Test func theOrderOfArrivalAcrossRunsDoesNotMatter() throws {
    // Run 1 sees only the delete, run 2 the create: the row ends the same as with both at once.
    let both = InMemoryFolder()
    let split = InMemoryFolder()
    let (_, cn, cd) = file("dev-a", 0, [entry("u1", .created, "x", 1)])
    let (_, dn, dd) = file("dev-b", 0, [entry("u1", .deleted, "x", 5, base: stamp(1, "dev-a"))])
    both.plant(name: cn, data: cd)
    both.plant(name: dn, data: dd)
    split.plant(name: dn, data: dd)
    let a1 = InMemoryApplier(), a2 = InMemoryApplier()
    let s2 = InMemoryStateStore()
    let run = SyncRun(ownDeviceId: mine)
    _ = try run.run(folder: both, applier: a1, store: InMemoryStateStore())
    _ = try run.run(folder: split, applier: a2, store: s2)
    split.plant(name: cn, data: cd)
    _ = try run.run(folder: split, applier: a2, store: s2)
    #expect(a1.records == a2.records)
    #expect(a2.records.values.first?.isDeleted == true)
  }

  @Test func theReportCarriesCountsOnly() {
    var r = SyncReport()
    r.filesApplied = 2
    #expect(r.logPairs.map(\.0) == ["files", "skipped", "refused", "records", "conflicts"])
  }
}
