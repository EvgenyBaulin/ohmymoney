import Foundation
import Testing

@testable import CoreArchive

/// The check value in the CRC-32 specification is the one for "123456789"; the rest are
/// the values zip tools produce for the same bytes.
@Suite("CRC-32 matches the published check values")
struct CRC32Tests {
  @Test func checkValueOfTheStandardString() {
    #expect(CRC32.checksum("123456789") == 0xCBF4_3926)
  }

  @Test func emptyInputIsZero() {
    #expect(CRC32.checksum(Data()) == 0)
  }

  @Test func singleLetter() {
    #expect(CRC32.checksum("a") == 0xE8B7_BE43)
  }

  @Test func quickBrownFox() {
    #expect(
      CRC32.checksum("The quick brown fox jumps over the lazy dog") == 0x414F_A339)
  }

  @Test func nonAsciiTextIsCheckedAsUTF8Bytes() {
    #expect(CRC32.checksum("Итого") == 0xE98C_825E)
  }

  @Test func aChangedByteChangesTheChecksum() {
    var data = Data(repeating: 0x2A, count: 1000)
    let before = CRC32.checksum(data)
    data[500] ^= 0x01
    #expect(CRC32.checksum(data) != before)
  }
}
