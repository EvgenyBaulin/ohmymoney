import CoreKit
import Foundation
import Testing

@testable import CoreSync

// Synthetic data only.

/// A stand-in for AES-256-GCM that checks the format, not the cryptography: a keystream from
/// FNV-1a over key, nonce and counter, and a 16-byte tag over key, nonce and ciphertext. The
/// real cipher (CryptoKit) is checked against published vectors in the app's tests.
private struct FakeCipher: ArchiveCipher {
  struct Refused: Error {}

  private func mix(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in bytes {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01b3
    }
    return h
  }

  private func stream(_ count: Int, key: Data, nonce: Data) -> [UInt8] {
    var out: [UInt8] = []
    var counter: UInt64 = 0
    while out.count < count {
      var word = mix(Array(key) + Array(nonce) + withUnsafeBytes(of: counter) { Array($0) })
      for _ in 0..<8 {
        out.append(UInt8(truncatingIfNeeded: word))
        word >>= 8
      }
      counter += 1
    }
    return Array(out.prefix(count))
  }

  private func tag(key: Data, nonce: Data, cipher: [UInt8]) -> [UInt8] {
    let a = mix(Array(key) + Array(nonce) + cipher)
    let b = mix(cipher + Array(nonce) + Array(key))
    return withUnsafeBytes(of: a) { Array($0) } + withUnsafeBytes(of: b) { Array($0) }
  }

  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    let s = stream(plaintext.count, key: key, nonce: nonce)
    let c = zip(Array(plaintext), s).map { $0 ^ $1 }
    return Data(c + tag(key: key, nonce: nonce, cipher: c))
  }

  func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    let all = Array(sealed)
    guard all.count >= 16 else { throw Refused() }
    let c = Array(all.dropLast(16))
    guard Array(all.suffix(16)) == tag(key: key, nonce: nonce, cipher: c) else { throw Refused() }
    let s = stream(c.count, key: key, nonce: nonce)
    return Data(zip(c, s).map { $0 ^ $1 })
  }
}

private let key = Data((0..<32).map { UInt8($0) })
private let otherKey = Data((0..<32).map { UInt8(255 - $0) })

private func codec(
  _ key: Data = key, nonce: UInt8 = 7, acceptsPlain: Bool = true
)
  -> SealedPayloadCodec
{
  SealedPayloadCodec(
    cipher: FakeCipher(), key: key, acceptsPlain: acceptsPlain,
    makeNonce: { [UInt8](repeating: nonce, count: 12) })
}

private func journal() -> JournalFile {
  JournalFile(
    deviceId: "mac", deviceName: "Mac", sequence: 3,
    entries: [
      SyncEntry(
        table: "transactions", uuid: "u1", op: .created,
        fields: ["description": .string("coffee"), "amount_e4": .int(2_500_000)],
        updatedAt: SyncInstant("2026-11-01T10:00:00Z")!)
    ])
}

@Suite("Sealed journal and snapshot")
struct SealedPayloadCodecTests {
  @Test func sealedThenOpenedIsTheSameFile() throws {
    let file = journal()
    let sealed = try JournalCoder.encode(file, codec: codec())
    #expect(SealedPayloadCodec.isSealed(sealed))
    #expect(Array(sealed.prefix(8)) == Array("OMMSEAL1".utf8))
    #expect(Array(sealed.dropFirst(8).prefix(12)) == [UInt8](repeating: 7, count: 12))
    #expect(try JournalCoder.decode(sealed, codec: codec()) == file)
    // Nothing of the content shows through.
    #expect(!String(decoding: sealed, as: UTF8.self).contains("coffee"))
  }

  @Test func aSnapshotOfAnySizeComesBackByteForByte() throws {
    for size in [0, 1, 15, 16, 17, 4096, 100_003] {
      let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 5) })
      let sealed = try codec().encode(bytes)
      #expect(sealed.count == size + 8 + 12 + 16)
      #expect(try codec().decode(sealed) == bytes)
    }
  }

  @Test func aWrongKeyAndAChangedByteAreRefusedAlike() throws {
    let sealed = try JournalCoder.encode(journal(), codec: codec())
    #expect(throws: SyncError.codec) { try JournalCoder.decode(sealed, codec: codec(otherKey)) }
    for index in [0, 8, 20, sealed.count - 1] {
      var changed = sealed
      changed[index] ^= 0x01
      #expect(throws: SyncError.self) { try JournalCoder.decode(changed, codec: codec()) }
    }
    for length in [0, 7, 8, 19, 20, 35] {
      #expect(throws: SyncError.self) {
        try JournalCoder.decode(sealed.prefix(length), codec: codec())
      }
    }
  }

  @Test func aJournalOfBeforeSealingStillReads() throws {
    let plain = try JournalCoder.encode(journal())
    #expect(!SealedPayloadCodec.isSealed(plain))
    #expect(try JournalCoder.decode(plain, codec: codec()) == journal())
    #expect(throws: SyncError.codec) {
      try JournalCoder.decode(plain, codec: codec(acceptsPlain: false))
    }
    #expect(throws: SyncError.codec) { try codec().decode(Data("garbage".utf8)) }
  }

  @Test func everyFileTakesItsOwnNonce() throws {
    let real = SealedPayloadCodec(cipher: FakeCipher(), key: key)
    let a = try real.encode(Data("same".utf8))
    let b = try real.encode(Data("same".utf8))
    #expect(a != b)
    #expect(try real.decode(a) == Data("same".utf8))
    #expect(SealedPayloadCodec.randomNonce().count == 12)
  }

  @Test func aKeyOfTheWrongLengthSealsNothing() {
    #expect(throws: SyncError.codec) {
      try codec(Data(repeating: 1, count: 16)).encode(Data("x".utf8))
    }
  }

  @Test func theExchangeRunsOnSealedFiles() throws {
    let folder = InMemoryFolder()
    let mac = JournalWriter(deviceId: "mac", deviceName: "Mac", codec: codec(nonce: 1))
    try mac.write(journal().entries, to: folder)
    let applier = InMemoryApplier()
    let report = try SyncRun(ownDeviceId: "phone", codec: codec())
      .run(folder: folder, applier: applier, store: InMemoryStateStore())
    #expect(report.filesApplied == 1)
    #expect(applier.records.count == 1)
    // A device with another key refuses the file and applies nothing.
    let stranger = InMemoryApplier()
    let refused = try SyncRun(ownDeviceId: "tablet", codec: codec(otherKey))
      .run(folder: folder, applier: stranger, store: InMemoryStateStore())
    #expect(refused.filesRefused.count == 1)
    #expect(stranger.records.isEmpty)
  }
}
