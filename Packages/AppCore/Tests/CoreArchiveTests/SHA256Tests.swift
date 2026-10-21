import Foundation
import Testing

@testable import CoreArchive

/// Vectors from RFC 6234, section 8.5 (the same digests FIPS 180-4 publishes).
@Suite("SHA-256 matches the RFC 6234 vectors")
struct SHA256Tests {
  @Test func hashesTheEmptyMessage() {
    #expect(
      SHA256.hexDigest("")
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  @Test func hashesABC() {
    #expect(
      SHA256.hexDigest("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func hashesA448BitMessage() {
    let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    #expect(
      SHA256.hexDigest(message)
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  }

  @Test func hashesAn896BitMessageThatSpansTwoPaddedBlocks() {
    let message =
      "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
      + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
    #expect(
      SHA256.hexDigest(message)
        == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
  }

  @Test func hashesOneMillionLettersA() {
    let message = [UInt8](repeating: 0x61, count: 1_000_000)
    #expect(
      SHA256.hexDigest(message)
        == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  }

  @Test func hashesAMessageOfExactlyOneBlock() {
    // 64 bytes: the padding has to spill into a second block.
    let message = [UInt8](repeating: 0x61, count: 64)
    var reference = SHA256()
    reference.update(message)
    #expect(SHA256.hexString(reference.finalize()) == SHA256.hexDigest(message))
    #expect(SHA256.hash(message).count == SHA256.digestByteCount)
  }

  @Test func incrementalUpdatesMatchTheOneShotDigest() {
    let message = (0..<500).map { UInt8($0 % 251) }
    for chunk in [1, 7, 31, 64, 65, 199] {
      var hasher = SHA256()
      var offset = 0
      while offset < message.count {
        let end = min(offset + chunk, message.count)
        hasher.update([UInt8](message[offset..<end]))
        offset = end
      }
      #expect(SHA256.hexString(hasher.finalize()) == SHA256.hexDigest(message))
    }
  }

  @Test func digestsDataAndBytesAlike() {
    let data = Data("итого".utf8)
    #expect(SHA256.hexDigest(data) == SHA256.hexDigest([UInt8](data)))
  }

  @Test func hexStringIsLowerCaseAndFullWidth() {
    let hex = SHA256.hexString([0x00, 0x0F, 0xA0, 0xFF])
    #expect(hex == "000fa0ff")
  }

  /// The lengths where the padding changes behaviour: 55 still fits the length field in
  /// its own block, 56 does not, and 63/64/65 and 119/120 straddle the block boundaries.
  @Test func hashesEveryLengthAroundABlockBoundary() {
    let expected: [(Int, String)] = [
      (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
      (55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
      (56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
      (63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
      (64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
      (65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"),
      (119, "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"),
      (120, "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c"),
    ]
    for (length, digest) in expected {
      #expect(SHA256.hexDigest(repeated(0x61, length)) == digest, "length \(length)")
    }
  }

  @Test func anEmptyUpdateDoesNotDisturbTheState() {
    var hasher = SHA256()
    hasher.update([UInt8]())
    hasher.update([UInt8]("abc".utf8))
    hasher.update(Data())
    #expect(
      SHA256.hexString(hasher.finalize())
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }
}
