import CoreKit
import Foundation

@testable import CoreArchive

/// Hexadecimal literal from an RFC turned into bytes. Whitespace is ignored so the
/// vectors can be pasted in the grouping the document uses.
func bytes(hex: String) -> [UInt8] {
  var digits = [UInt8]()
  for character in hex.unicodeScalars {
    switch character {
    case "0"..."9": digits.append(UInt8(character.value - 48))
    case "a"..."f": digits.append(UInt8(character.value - 87))
    case "A"..."F": digits.append(UInt8(character.value - 55))
    default: continue
    }
  }
  precondition(digits.count % 2 == 0, "a hexadecimal string needs an even number of digits")
  var result = [UInt8]()
  result.reserveCapacity(digits.count / 2)
  for index in stride(from: 0, to: digits.count, by: 2) {
    result.append(digits[index] << 4 | digits[index + 1])
  }
  return result
}

func repeated(_ byte: UInt8, _ count: Int) -> [UInt8] {
  [UInt8](repeating: byte, count: count)
}

/// Stand-in for AES-256-GCM used by the archive tests.
///
/// It checks the *format*, not the cryptography: a keystream of SHA-256 blocks over
/// `key || nonce || counter`, and an HMAC-SHA-256 over `nonce || ciphertext` truncated to
/// the 16 bytes AES-GCM would spend on its tag. That is enough to prove that the header
/// travels intact, that the key really comes out of the password, and that a wrong
/// password is rejected instead of producing rubbish. It must never leave the tests.
struct TestCipher: ArchiveCipher {
  enum Failure: Error, Equatable {
    case sealedTooShort
    case authenticationFailed
  }

  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    let stream = keystream(count: plaintext.count, key: key, nonce: nonce)
    var ciphertext = [UInt8]()
    ciphertext.reserveCapacity(plaintext.count)
    for (index, byte) in plaintext.enumerated() {
      ciphertext.append(byte ^ stream[index])
    }
    var output = Data(ciphertext)
    output.append(contentsOf: tag(key: key, nonce: nonce, ciphertext: ciphertext))
    return output
  }

  func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    let all = [UInt8](sealed)
    guard all.count >= EncryptionHeader.tagByteCount else { throw Failure.sealedTooShort }
    let split = all.count - EncryptionHeader.tagByteCount
    let ciphertext = [UInt8](all[0..<split])
    let received = [UInt8](all[split...])
    guard HMACSHA256.equal(received, tag(key: key, nonce: nonce, ciphertext: ciphertext))
    else { throw Failure.authenticationFailed }
    let stream = keystream(count: ciphertext.count, key: key, nonce: nonce)
    var plaintext = [UInt8]()
    plaintext.reserveCapacity(ciphertext.count)
    for (index, byte) in ciphertext.enumerated() {
      plaintext.append(byte ^ stream[index])
    }
    return Data(plaintext)
  }

  private func keystream(count: Int, key: Data, nonce: Data) -> [UInt8] {
    var stream = [UInt8]()
    stream.reserveCapacity(count + SHA256.digestByteCount)
    var counter: UInt32 = 0
    while stream.count < count {
      var block = [UInt8](key)
      block.append(contentsOf: [UInt8](nonce))
      block.append(UInt8(truncatingIfNeeded: counter >> 24))
      block.append(UInt8(truncatingIfNeeded: counter >> 16))
      block.append(UInt8(truncatingIfNeeded: counter >> 8))
      block.append(UInt8(truncatingIfNeeded: counter))
      stream.append(contentsOf: SHA256.hash(block))
      counter += 1
    }
    return stream
  }

  private func tag(key: Data, nonce: Data, ciphertext: [UInt8]) -> [UInt8] {
    var message = [UInt8](nonce)
    message.append(contentsOf: ciphertext)
    let code = HMACSHA256(key: key).authenticationCode(for: message)
    return [UInt8](code[0..<EncryptionHeader.tagByteCount])
  }
}

/// Deterministic generator for the tests: the archive format needs a salt and a nonce, the
/// tests need the same ones every run. The application passes a real random source.
struct SplitMix64: RandomSource {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed
  }

  mutating func nextUInt64() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var result = state
    result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
    result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
    return result ^ (result >> 31)
  }
}

/// A small archive with the layout the transfer format prescribes.
func sampleBuilder(
  schemaVersion: Int = 7, createdAt: DateOnly = DateOnly(year: 2026, month: 9, day: 18)
) throws -> ArchiveBuilder {
  var builder = ArchiveBuilder(
    metadata: ArchiveBuilder.Metadata(
      appVersion: "1.0.0", schemaVersion: schemaVersion, createdAt: createdAt,
      platform: "macOS", rowCounts: ["transactions": 2, "people": 1]))
  try builder.add(path: ArchivePaths.database, data: Data([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65]))
  try builder.add(
    path: ArchivePaths.csv(table: "transactions"),
    text: "id,date,amount\n1,2026-09-17,250.0000\n2,2026-09-18,-120.0000\n")
  try builder.add(path: ArchivePaths.csv(table: "people"), text: "id,name\n1,Sample\n")
  try builder.add(path: ArchivePaths.settings, text: "{\"language\":\"ru\"}")
  return builder
}
