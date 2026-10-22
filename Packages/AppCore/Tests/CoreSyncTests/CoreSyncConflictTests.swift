import Foundation
import Testing

@testable import CoreSync

// Synthetic data only.

private func at(_ s: Int) -> SyncInstant {
  SyncInstant(String(format: "2026-10-22T10:%02d:%02dZ", s / 60, s % 60))!
}

private func stamp(_ time: Int, _ device: String) -> VersionStamp {
  VersionStamp(updatedAt: at(time), deviceId: device)
}

private func entry(
  _ note: String, _ time: Int, op: SyncOp = .updated, base: VersionStamp? = nil,
  resolves: [VersionStamp]? = nil
) -> SyncEntry {
  SyncEntry(
    table: "transactions", uuid: "u1", op: op, fields: ["note": .string(note)],
    updatedAt: at(time), base: base, resolves: resolves)
}

private func ingest(
  _ state: inout SyncState, _ device: String, _ sequence: Int, _ e: SyncEntry
)
  throws
{
  let file = JournalFile(deviceId: device, deviceName: device, sequence: sequence, entries: [e])
  try state.ingest(file, name: file.name, bytes: try JournalCoder.encode(file))
}

@Suite struct DeviceConflictTests {
  private let key = RecordKey(table: "transactions", uuid: "u1")

  @Test func aVersionBuiltOnMineIsTheNextVersionNotAConflict() throws {
    var s = SyncState()
    try ingest(&s, "mac", 0, entry("coffee", 1))
    try ingest(&s, "phone", 0, entry("tea", 2, base: stamp(1, "mac")))
    let r = try #require(s.resolve(key))
    #expect(r.disposition(ownDeviceId: "mac") == .applyWinner)
    #expect(s.openConflicts(ownDeviceId: "mac").isEmpty)
  }

  @Test func twoVersionsMadeApartAreAConflictOnBothDevices() throws {
    var s = SyncState()
    try ingest(&s, "mac", 0, entry("coffee 250", 5, base: stamp(1, "x")))
    try ingest(&s, "phone", 0, entry("coffee 300", 6, base: stamp(1, "x")))
    // The phone's version is the later, so core would pick it; for me it must wait.
    #expect(s.resolve(key)?.winner.stamp.deviceId == "phone")
    #expect(s.resolve(key)?.disposition(ownDeviceId: "mac") == .conflict)
    #expect(s.resolve(key)?.disposition(ownDeviceId: "phone") == .conflict)
    let mine = try #require(s.openConflicts(ownDeviceId: "mac").first)
    #expect(mine.mine.fields["note"] == .string("coffee 250"))
    #expect(mine.theirs.fields["note"] == .string("coffee 300"))
    #expect(mine.differingFields == ["note"])
    let theirs = try #require(s.openConflicts(ownDeviceId: "phone").first)
    #expect(theirs.mine.fields["note"] == .string("coffee 300"))
  }

  @Test func onlyForeignVersionsNeverConflictForMe() throws {
    var s = SyncState()
    try ingest(&s, "phone", 0, entry("a", 5))
    try ingest(&s, "tablet", 0, entry("b", 6))
    #expect(s.resolve(key)?.disposition(ownDeviceId: "mac") == .applyWinner)
    #expect(s.resolve(key)?.disposition(ownDeviceId: "phone") == .conflict)
  }

  @Test func onlyMyVersionsMeanThereIsNothingToTake() throws {
    var s = SyncState()
    try ingest(&s, "mac", 0, entry("a", 5))
    try ingest(&s, "mac", 1, entry("b", 6, base: stamp(5, "mac")))
    #expect(s.resolve(key)?.disposition(ownDeviceId: "mac") == .keepLocal)
  }

  @Test func oneEditThatResolvesBothSettlesTheConflictOnEveryDevice() throws {
    var s = SyncState()
    try ingest(&s, "mac", 0, entry("mine", 5, base: stamp(1, "x")))
    try ingest(&s, "phone", 0, entry("theirs", 6, base: stamp(1, "x")))
    #expect(s.openConflicts(ownDeviceId: "mac").count == 1)
    // Mac chooses "keep mine": a new version on top of mine that settles the phone's.
    try ingest(
      &s, "mac", 1,
      entry("mine", 9, base: stamp(5, "mac"), resolves: [stamp(6, "phone")]))
    #expect(s.openConflicts(ownDeviceId: "mac").isEmpty)
    #expect(s.openConflicts(ownDeviceId: "phone").isEmpty)
    #expect(s.resolve(key)?.winner.fields["note"] == .string("mine"))
    #expect(s.resolve(key)?.conflicts.isEmpty == true)
    #expect(s.resolve(key)?.disposition(ownDeviceId: "phone") == .applyWinner)
  }

  @Test func aSettlingEditWinsEvenWhenItsStampIsEarlierThanWhatItSettles() throws {
    var s = SyncState()
    try ingest(&s, "mac", 0, entry("mine", 5, base: stamp(1, "x")))
    try ingest(&s, "phone", 0, entry("theirs", 9, base: stamp(1, "x")))
    try ingest(&s, "mac", 1, entry("mine", 7, base: stamp(5, "mac"), resolves: [stamp(9, "phone")]))
    let r = try #require(s.resolve(key))
    #expect(r.winner.stamp == stamp(7, "mac"))
    #expect(r.conflicts.isEmpty)
    #expect(r.disposition(ownDeviceId: "phone") == .applyWinner)
  }

  @Test func theOrderOfFilesDoesNotChangeWhoseConflictItIs() throws {
    let files: [(String, Int, SyncEntry)] = [
      ("mac", 0, entry("mine", 5, base: stamp(1, "x"))),
      ("phone", 0, entry("theirs", 6, base: stamp(1, "x"))),
      ("mac", 1, entry("mine", 9, base: stamp(5, "mac"), resolves: [stamp(6, "phone")])),
    ]
    var results = Set<String>()
    let orders = [[0, 1, 2], [2, 1, 0], [1, 2, 0], [2, 0, 1]]
    for order in orders {
      var s = SyncState()
      for i in order { try ingest(&s, files[i].0, files[i].1, files[i].2) }
      results.insert("\(s.openConflicts(ownDeviceId: "mac").count)")
    }
    #expect(results == ["0"])
  }

  @Test func aDeleteAgainstAnEditIsAConflictOfTheDeletedKind() throws {
    var s = SyncState()
    try ingest(&s, "mac", 0, entry("kept", 5, base: stamp(1, "x")))
    try ingest(&s, "phone", 0, entry("kept", 6, op: .deleted, base: stamp(1, "x")))
    let c = try #require(s.openConflicts(ownDeviceId: "mac").first)
    #expect(c.differingFields == ["deleted"])
  }
}

@Suite struct ResolvesFormatTests {
  @Test func aFileWithoutResolvesStillReadsAndNilIsNotWritten() throws {
    let file = JournalFile(
      deviceId: "mac", deviceName: "Mac", sequence: 0, entries: [entry("a", 1)])
    let data = try JournalCoder.encode(file)
    #expect(!String(decoding: data, as: UTF8.self).contains("resolves"))
    #expect(try JournalCoder.decode(data).entries.first?.resolves == nil)
  }

  @Test func resolvesRoundTrips() throws {
    let e = entry("a", 3, base: stamp(1, "mac"), resolves: [stamp(2, "phone")])
    let file = JournalFile(deviceId: "mac", deviceName: "Mac", sequence: 4, entries: [e])
    #expect(try JournalCoder.decode(try JournalCoder.encode(file)) == file)
  }

  @Test func aStateSavedBeforeResolvesExistedStillLoads() throws {
    var s = SyncState()
    try ingest(&s, "mac", 0, entry("a", 1))
    let json = try JSONEncoder().encode(s)
    let text = String(decoding: json, as: UTF8.self)
    #expect(!text.contains("resolves"))
    #expect(try JSONDecoder().decode(SyncState.self, from: json) == s)
  }
}

@Suite struct SyncInstantDateTests {
  @Test func aDateBecomesTheStoredText() {
    let instant = SyncInstant(date: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(SyncInstant(instant.text) != nil)
    #expect(instant.text == "2026-09-21T14:13:20Z")
  }

  @Test func addingSecondsKeepsTheShapeAndOrder() {
    let a = at(59)
    let b = a.adding(seconds: 1)
    #expect(b.text == "2026-10-22T10:01:00Z")
    #expect(a < b)
    #expect(SyncInstant(b.text) != nil)
  }
}
