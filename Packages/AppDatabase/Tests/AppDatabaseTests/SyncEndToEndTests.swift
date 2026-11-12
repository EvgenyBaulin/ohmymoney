import AppCore
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// AES-256-GCM as the app's cipher does it, so the files in these tests are the real sealed
/// files.
private struct TestCipher: ArchiveCipher {
  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    let box = try AES.GCM.seal(
      plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
    return box.ciphertext + box.tag
  }
  func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
    return try AES.GCM.open(box, using: SymmetricKey(data: key))
  }
}

private func sealed(key byte: UInt8) -> SealedPayloadCodec {
  SealedPayloadCodec(cipher: TestCipher(), key: Data(repeating: byte, count: 32))
}

private struct SplitMix: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

extension TestDevice {
  /// The operations that are live (not soft-deleted), by id.
  fileprivate func liveIds() throws -> [String] {
    try stack.writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT id FROM transactions WHERE deleted_at IS NULL ORDER BY id")
    }
  }
  fileprivate func deletedIds() throws -> [String] {
    try stack.writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT id FROM transactions WHERE deleted_at IS NOT NULL ORDER BY id")
    }
  }
  fileprivate func softDelete(_ id: String) throws {
    try sql("UPDATE transactions SET deleted_at = '2026-10-22 10:00:00.000' WHERE id = ?", [id])
  }
  fileprivate func restore(_ id: String) throws {
    try sql("UPDATE transactions SET deleted_at = NULL WHERE id = ?", [id])
  }
  fileprivate func amountRub(_ id: String) throws -> Int64? {
    try stack.writer.read { db in
      try Int64.fetchOne(
        db, sql: "SELECT amount_rub_e4 FROM transactions WHERE id = ?", arguments: [id])
    }
  }
}

@Suite("Mac and iPhone on one folder: two real stacks, sealed files, nothing lost (0507, 0518)")
struct SyncEndToEndTests {
  private func folderURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Both devices exchange until neither has anything new to say.
  private func settle(
    _ devices: [TestDevice], _ folder: any JournalFolder, rounds: Int = 6
  ) throws {
    for _ in 0..<rounds {
      var wrote = 0
      for device in devices { wrote += try device.exchange.exchange(with: folder).entriesWritten }
      if wrote == 0 { return }
    }
  }

  @Test func aWholeLifeOfTwoDevicesOnASealedFolderEndsWithEqualBooks() throws {
    let url = try folderURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let folder = DirectoryJournalFolder(url: url)
    let mac = try TestDevice("mac", journalCodec: sealed(key: 7), snapshotCodec: sealed(key: 9))
    let phone = try TestDevice("phone", journalCodec: sealed(key: 7), snapshotCodec: sealed(key: 9))

    // 1. The Mac writes; the phone reads and agrees.
    try mac.insertOperation("t1", note: "coffee beans", amount: 25_000_000)
    try mac.insertOperation("t2", note: "groceries", amount: 70_000_000)
    try mac.stamp("2026-10-22T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    let first = try phone.exchange.exchange(with: folder)
    #expect(first.filesApplied >= 1 && first.conflictsOpen == 0)
    #expect(try phone.books() == mac.books())

    // 2. Each side edits different rows apart, then they exchange.
    try mac.insertOperation("t3", note: "mac new", amount: 10_000_000)
    try mac.setNote("t2", "groceries and milk")
    try mac.stamp("2026-10-22T10:05:00Z")
    try phone.insertOperation("t4", note: "phone new", amount: 20_000_000)
    try phone.setNote("t1", "coffee beans 1kg")
    try phone.stamp("2026-10-22T10:06:00Z")
    try settle([mac, phone], folder)
    #expect(try mac.books() == phone.books())
    #expect(try mac.liveIds() == ["t1", "t2", "t3", "t4"])
    #expect(try mac.note("t1") == "coffee beans 1kg")
    #expect(try phone.note("t2") == "groceries and milk")
    #expect(try mac.count("transaction_parts") == 4, "no part is lost or doubled")

    // 3. One row edited apart: it waits for the owner on both sides, the books keep their own.
    try mac.sql(
      "UPDATE transactions SET note = 'mac says', amount_e4 = 30000000, amount_rub_e4 = 30000000 WHERE id = 't3'"
    )
    try mac.stamp("2026-10-22T10:10:00Z")
    try phone.sql(
      "UPDATE transactions SET note = 'phone says', amount_e4 = 40000000, amount_rub_e4 = 40000000 WHERE id = 't3'"
    )
    try phone.stamp("2026-10-22T10:11:00Z")
    try settle([mac, phone], folder)
    let key = RecordKey(table: "transactions", uuid: "t3")
    #expect(try mac.exchange.conflicts().map(\.key) == [key])
    #expect(try phone.exchange.conflicts().map(\.key) == [key])
    #expect(try mac.note("t3") == "mac says")
    #expect(try phone.note("t3") == "phone says")
    #expect(try mac.amountRub("t3") == 30_000_000, "the other side's amount is in no sum")
    #expect(try phone.amountRub("t3") == 40_000_000)
    // Everything else is equal already; the conflicted row is the only difference.
    #expect(try mac.liveIds() == phone.liveIds())
    #expect(try mac.count("transactions") == 4 && phone.count("transactions") == 4)

    // 4. The owner answers on the phone, and the Mac's list empties by itself.
    try phone.exchange.takeTheirs(key)
    try settle([mac, phone], folder)
    #expect(try mac.exchange.conflicts().isEmpty)
    #expect(try phone.exchange.conflicts().isEmpty)
    #expect(try phone.note("t3") == "mac says")
    #expect(try mac.books() == phone.books())

    // 5. Delete on one side, restore on the other side's next move, hard delete of another.
    try mac.softDelete("t4")
    try mac.sql("DELETE FROM transactions WHERE id = 't1'")
    try mac.stamp("2026-10-22T10:20:00Z")
    try settle([mac, phone], folder)
    #expect(try phone.deletedIds() == ["t4"])
    #expect(try phone.count("transactions") == 3, "the hard delete went with its parts")
    #expect(try phone.count("transaction_parts") == 3)
    #expect(try mac.books() == phone.books())
    try phone.restore("t4")
    try phone.stamp("2026-10-22T10:30:00Z")
    try settle([mac, phone], folder)
    #expect(try mac.deletedIds().isEmpty)
    #expect(try mac.liveIds() == ["t2", "t3", "t4"])
    #expect(try mac.books() == phone.books())

    // Settled: nothing more is written, nothing is applied twice.
    let names = try folder.listNames()
    for device in [mac, phone] {
      let outcome = try device.exchange.exchange(with: folder)
      #expect(outcome.entriesWritten == 0 && outcome.conflictsOpen == 0)
    }
    #expect(try folder.listNames() == names)

    // The folder holds sealed files only, and no note is readable in them.
    #expect(!names.isEmpty)
    for name in names {
      let bytes = try folder.read(name: name)
      #expect(SealedPayloadCodec.isSealed(bytes), "\(name)")
      #expect(bytes.range(of: Data("coffee".utf8)) == nil)
      #expect(bytes.range(of: Data("groceries".utf8)) == nil)
    }

    // A third device that has the folder but another key reads nothing and says so.
    let stranger = try TestDevice(
      "tablet", journalCodec: sealed(key: 8), snapshotCodec: sealed(key: 9))
    let outcome = try stranger.exchange.exchange(with: folder)
    #expect(outcome.filesDamaged > 0 && outcome.filesApplied == 0)
    #expect(try stranger.count("transactions") == 0)

    // A device with the right key joins late and reaches the same books from the files alone.
    let late = try TestDevice("tablet2", journalCodec: sealed(key: 7), snapshotCodec: sealed(key: 9))
    _ = try late.exchange.exchange(with: folder)
    #expect(try late.books() == mac.books())
  }

  @Test func aFileOfBeforeSealingStillReadsThroughTheSealedCodec() throws {
    // The journal files written before sealing existed stay readable.
    let folder = InMemoryFolder()
    let old = try TestDevice("mac")  // plain codec
    try old.insertOperation("t1", note: "plain", amount: 5_000_000)
    _ = try old.exchange.exchange(with: folder)
    let new = try TestDevice("phone", journalCodec: sealed(key: 7), snapshotCodec: sealed(key: 9))
    _ = try new.exchange.exchange(with: folder)
    #expect(try new.note("t1") == "plain")
    #expect(try new.books() == old.books())
  }

  /// Random edits on both devices (own rows, or the same row apart), the owner answering every
  /// conflict on the phone; then a third reader takes the files in a shuffled order, in batches.
  @Test(arguments: Array(1...30))
  func randomEditsEndInEqualBooksWhateverTheOrderOfReading(seed: Int) throws {
    var rng = SplitMix(state: UInt64(seed) &* 7919)
    let folder = InMemoryFolder()
    let mac = try TestDevice("mac", journalCodec: sealed(key: 7), snapshotCodec: sealed(key: 9))
    let phone = try TestDevice("phone", journalCodec: sealed(key: 7), snapshotCodec: sealed(key: 9))
    let devices = [mac, phone]
    var serial = 0
    var minute = 0
    func nextId() -> String {
      serial += 1
      return "r\(serial)"
    }

    for round in 0..<8 {
      for device in devices {
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
          let live = try device.liveIds()
          let deleted = try device.deletedIds()
          switch Int.random(in: 0..<5, using: &rng) {
          case 0, 1:
            try device.insertOperation(nextId(), note: "n\(serial)", amount: 10_000)
          case 2:
            if let id = live.randomElement(using: &rng) {
              try device.setNote(id, "e\(Int.random(in: 0..<1000, using: &rng))")
            }
          case 3:
            if let id = live.randomElement(using: &rng) { try device.softDelete(id) }
          default:
            if let id = deleted.randomElement(using: &rng) { try device.restore(id) }
          }
        }
        minute += 1
        try device.stamp(
          "2026-10-22T\(String(format: "%02d", 10 + minute / 60)):\(String(format: "%02d", minute % 60)):00Z"
        )
      }
      // Mid-way exchanges happen only on some rounds: the rest are edits made apart.
      if round % 2 == 1 || Bool.random(using: &rng) {
        for device in devices { _ = try device.exchange.exchange(with: folder) }
      }
    }
    // The owner answers every conflict on the phone, either way, and the devices settle.
    for _ in 0..<8 {
      for device in devices { _ = try device.exchange.exchange(with: folder) }
      for conflict in try phone.exchange.conflicts() {
        if Bool.random(using: &rng) {
          try phone.exchange.keepMine(conflict.key)
        } else {
          try phone.exchange.takeTheirs(conflict.key)
        }
      }
    }
    for device in devices { _ = try device.exchange.exchange(with: folder) }
    #expect(try mac.exchange.conflicts().isEmpty, "seed \(seed)")
    #expect(try phone.exchange.conflicts().isEmpty, "seed \(seed)")
    #expect(try mac.books() == phone.books(), "seed \(seed)")

    // A reader that sees the files in any order, in any batches, reaches the same books.
    var names = try folder.listNames()
    names.shuffle(using: &rng)
    let reader = try TestDevice("tablet", journalCodec: sealed(key: 7), snapshotCodec: sealed(key: 9))
    let seen = InMemoryFolder()
    var index = 0
    while index < names.count {
      let size = Int.random(in: 1...4, using: &rng)
      for name in names[index..<min(index + size, names.count)] {
        seen.plant(name: name, data: try folder.read(name: name))
      }
      index += size
      _ = try reader.exchange.exchange(with: seen)
    }
    _ = try reader.exchange.exchange(with: seen)
    #expect(try reader.books() == mac.books(), "seed \(seed)")
  }
}
