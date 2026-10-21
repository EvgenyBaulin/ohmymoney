import Foundation
import Testing

@testable import CoreRates

@Suite("windows-1251 decodes the same way on every platform")
struct CP1251Tests {
  @Test func asciiRangeIsUnchanged() {
    let bytes = Data((0...0x7F).map { UInt8($0) })
    let decoded = CP1251.decode(bytes)
    #expect(decoded.unicodeScalars.count == 128)
    for (offset, scalar) in decoded.unicodeScalars.enumerated() {
      #expect(scalar.value == UInt32(offset))
    }
  }

  @Test func russianLettersDecode() {
    // "Привет, мир" as the code page writes it.
    let bytes = Data([
      0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x2C, 0x20, 0xEC, 0xE8, 0xF0,
    ])
    #expect(CP1251.decode(bytes) == "Привет, мир")
  }

  @Test func currencyNameFromTheFeedDecodes() {
    // "Австралийский доллар", the first name in the Bank of Russia document.
    let bytes = Data([
      0xC0, 0xE2, 0xF1, 0xF2, 0xF0, 0xE0, 0xEB, 0xE8, 0xE9, 0xF1, 0xEA, 0xE8, 0xE9, 0x20,
      0xE4, 0xEE, 0xEB, 0xEB, 0xE0, 0xF0,
    ])
    #expect(CP1251.decode(bytes) == "Австралийский доллар")
  }

  @Test func upperHalfCoversTheWholeCyrillicAlphabet() {
    let upper = Data((0xC0...0xDF).map { UInt8($0) })
    let lower = Data((0xE0...0xFF).map { UInt8($0) })
    #expect(CP1251.decode(upper) == "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
    #expect(CP1251.decode(lower) == "абвгдежзийклмнопрстуфхцчшщъыьэюя")
  }

  @Test func punctuationAndSignsInTheHighRange() {
    #expect(CP1251.decode(Data([0xA0])) == "\u{00A0}")  // no-break space
    #expect(CP1251.decode(Data([0xA8])) == "Ё")
    #expect(CP1251.decode(Data([0xB8])) == "ё")
    #expect(CP1251.decode(Data([0xB9])) == "№")
    #expect(CP1251.decode(Data([0x88])) == "€")
    #expect(CP1251.decode(Data([0x96])) == "–")
    #expect(CP1251.decode(Data([0x99])) == "™")
  }

  @Test func everyByteFromEightyUpwardsDecodesToOneScalar() {
    for value in 0x80...0xFF {
      let decoded = CP1251.decode(Data([UInt8(value)]))
      #expect(decoded.unicodeScalars.count == 1, "byte \(value) did not give one scalar")
    }
  }

  @Test func onlyTheUndefinedByteGivesAReplacement() {
    var replacements: [Int] = []
    for value in 0...0xFF where CP1251.decode(Data([UInt8(value)])) == "\u{FFFD}" {
      replacements.append(value)
    }
    #expect(replacements == [0x98])
  }

  @Test func everyDefinedByteRoundTrips() {
    for value in 0...0xFF where value != 0x98 {
      let byte = UInt8(value)
      let text = CP1251.decode(Data([byte]))
      #expect(CP1251.encode(text) == Data([byte]), "byte \(value) failed the round trip")
    }
  }

  @Test func charactersOutsideTheCodePageAreReported() {
    #expect(CP1251.encode("日本") == nil)
  }
}
