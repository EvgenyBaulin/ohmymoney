import Foundation
import Testing

@testable import CoreArchive

/// Vectors from RFC 4231, section 4 — the HMAC-SHA-256 set RFC 6234 ships in its own
/// test driver.
@Suite("HMAC-SHA-256 matches the RFC 4231 vectors")
struct HMACSHA256Tests {
  @Test func case1ShortKey() {
    let code = HMACSHA256.code(key: repeated(0x0b, 20), message: [UInt8]("Hi There".utf8))
    #expect(
      SHA256.hexString(code)
        == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
  }

  @Test func case2TextKeyAndText() {
    let code = HMACSHA256(key: "Jefe")
      .authenticationCode(for: "what do ya want for nothing?")
    #expect(
      SHA256.hexString(code)
        == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  }

  @Test func case3FullLengthKeyAndFiftyBytes() {
    let code = HMACSHA256.code(key: repeated(0xaa, 20), message: repeated(0xdd, 50))
    #expect(
      SHA256.hexString(code)
        == "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
  }

  @Test func case4CountingKey() {
    let key = (1...25).map { UInt8($0) }
    let code = HMACSHA256.code(key: key, message: repeated(0xcd, 50))
    #expect(
      SHA256.hexString(code)
        == "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
  }

  @Test func case5TruncationVectorKeepsItsFirst128Bits() {
    let code = HMACSHA256.code(
      key: repeated(0x0c, 20), message: [UInt8]("Test With Truncation".utf8))
    #expect(
      SHA256.hexString(code)
        == "a3b6167473100ee06e0c796c2955552bfa6f7c0a6a8aef8b93f860aab0cd20c5")
    #expect(SHA256.hexString([UInt8](code[0..<16])) == "a3b6167473100ee06e0c796c2955552b")
  }

  @Test func case6KeyLongerThanOneBlockIsHashedFirst() {
    let message = "Test Using Larger Than Block-Size Key - Hash Key First"
    let code = HMACSHA256.code(key: repeated(0xaa, 131), message: [UInt8](message.utf8))
    #expect(
      SHA256.hexString(code)
        == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
  }

  @Test func case7LongKeyAndLongMessage() {
    let message =
      "This is a test using a larger than block-size key and a larger "
      + "than block-size data. The key needs to be hashed before being "
      + "used by the HMAC algorithm."
    let code = HMACSHA256.code(key: repeated(0xaa, 131), message: [UInt8](message.utf8))
    #expect(
      SHA256.hexString(code)
        == "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
  }

  @Test func aKeyOfExactlyOneBlockIsNotHashed() {
    // 64 bytes is the boundary: at 65 the key is replaced by its digest.
    let code = HMACSHA256.code(key: repeated(0xaa, 64), message: [UInt8]("boundary".utf8))
    let other = HMACSHA256.code(key: repeated(0xaa, 65), message: [UInt8]("boundary".utf8))
    #expect(code != other)
    #expect(code.count == HMACSHA256.codeByteCount)
  }

  @Test func constantTimeComparisonAgreesWithEquality() {
    let left = HMACSHA256.code(key: [1, 2, 3], message: [4, 5, 6])
    var right = left
    #expect(HMACSHA256.equal(left, right))
    right[31] ^= 0x01
    #expect(!HMACSHA256.equal(left, right))
    #expect(!HMACSHA256.equal(left, [UInt8](left[0..<31])))
  }
}
